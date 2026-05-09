import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'queue_persistence.dart';

enum RepeatMode { none, one, all }

class ShamlssPlayer extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  ConcatenatingAudioSource? _source;
  List<Map<String, dynamic>> _queue = [];
  List<int> _shuffleOrder = [];
  int _index = 0;
  bool _shuffle = false;
  RepeatMode _repeat = RepeatMode.none;
  int _crossfadeSec = 0;
  double _targetVol = 1.0;
  bool _autoMixEnabled = false;
  double? _currentBpm;
  String? _pendingBpmTrackId;

  Future<double?> Function(String trackId)? bpmProvider;

  final StreamController<String> _errorController = StreamController.broadcast();
  Stream<String> get errors => _errorController.stream;

  AudioPlayer get player => _player;
  List<Map<String, dynamic>> get queue => _queue;
  int get index => _index;
  bool get shuffle => _shuffle;
  RepeatMode get repeat => _repeat;
  int get crossfadeSec => _crossfadeSec;
  bool get autoMixEnabled => _autoMixEnabled;
  double? get currentBpm => _currentBpm;
  Map<String, dynamic>? get current => _queue.isEmpty ? null : _queue[_index];
  Stream<PlayerState> get stateStream => _player.playerStateStream;
  Stream<Duration?> get positionStream => _player.positionStream;
  Duration? get duration => _player.duration;

  void setAutoMix(bool enabled) {
    _autoMixEnabled = enabled;
    notifyListeners();
  }

  void _loadBpmForTrack(String trackId) {
    _pendingBpmTrackId = trackId;
    _currentBpm = null;
    bpmProvider?.call(trackId).then((bpm) {
      if (_pendingBpmTrackId == trackId) _currentBpm = bpm;
    });
  }

  AudioSource _makeSource(Map<String, dynamic> t, String url) {
    return AudioSource.uri(Uri.parse(url), tag: Map<String, dynamic>.from(t));
  }

  void setCrossfade(int seconds) {
    _crossfadeSec = seconds;
    notifyListeners();
  }

  ShamlssPlayer() {
    _player.currentIndexStream.listen((i) {
      if (i != null && i != _index && _queue.isNotEmpty) {
        _index = i.clamp(0, _queue.length - 1);
        _applyReplayGain(_queue[_index]);
        _loadBpmForTrack(_queue[_index]['id'] as String);
        _saveState();
        notifyListeners();
      }
    });
    // Only handle queue-end completion (processingState=completed = last track done)
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) _handleQueueEnd();
      notifyListeners();
    });
    _player.positionStream.listen((_) {
      _applyCrossfade();
      _savePositionThrottled();
      notifyListeners();
    });
  }

  void _applyCrossfade() {
    if (_crossfadeSec <= 0) return;
    final pos = _player.position;
    final dur = _player.duration;
    if (dur == null || dur.inMilliseconds == 0) return;
    final remaining = dur - pos;
    int fadeMs = _crossfadeSec * 1000;
    if (_autoMixEnabled && _currentBpm != null && _currentBpm! > 0) {
      final beatMs = 60000.0 / _currentBpm!;
      final beatCount = (fadeMs / beatMs).round().clamp(1, 64);
      fadeMs = (beatCount * beatMs).round();
    }
    if (remaining.inMilliseconds < fadeMs && remaining.inMilliseconds >= 0) {
      final ratio = (remaining.inMilliseconds / fadeMs).clamp(0.0, 1.0);
      _player.setVolume((_targetVol * ratio).clamp(0.0, 1.0));
    }
  }

  int _lastSavedPositionMs = -1;

  void _saveState() {
    if (_queue.isNotEmpty) {
      QueuePersistence.save(queue: _queue, index: _index, positionMs: _player.position.inMilliseconds);
    }
  }

  void _savePositionThrottled() {
    final posMs = _player.position.inMilliseconds;
    if ((posMs - _lastSavedPositionMs).abs() > 5000) {
      _lastSavedPositionMs = posMs;
      if (_queue.isNotEmpty) {
        QueuePersistence.save(queue: _queue, index: _index, positionMs: posMs);
      }
    }
  }

  Future<void> restoreQueue(String Function(String) urlBuilder, {String Function(String)? artUrlBuilder}) async {
    final saved = await QueuePersistence.load();
    if (saved == null || saved.queue.isEmpty) return;
    _queue = saved.queue;
    _index = saved.index;

    final sources = _queue.map((t) => _makeSource(t, urlBuilder(t['id'] as String))).toList();

    _source = ConcatenatingAudioSource(children: sources);
    try {
      await _player.setAudioSource(_source!, initialIndex: _index);
      if (saved.positionMs > 0) await _player.seek(Duration(milliseconds: saved.positionMs));
      _applyReplayGain(_queue[_index]);
      _loadBpmForTrack(_queue[_index]['id'] as String);
    } catch (e) {
      debugPrint('ShamlssPlayer restoreQueue error: $e');
    }
    notifyListeners();
  }

  void _handleQueueEnd() {
    switch (_repeat) {
      case RepeatMode.one:
        _player.seek(Duration.zero);
        _player.play();
      case RepeatMode.all:
        _player.seek(Duration.zero, index: 0);
        _player.play();
      case RepeatMode.none:
        break;
    }
  }

  void _advance(int delta, {bool wrap = false}) {
    if (_queue.isEmpty) return;
    int next = _index + delta;
    if (wrap) next = next % _queue.length;
    if (next < 0 || next >= _queue.length) return;
    _index = next;
    _applyReplayGain(_queue[next]);
    _player.seek(Duration.zero, index: next);
    _player.play();
    notifyListeners();
  }

  Future<void> playQueue(
    List<Map<String, dynamic>> tracks,
    int startIndex,
    String Function(String) urlBuilder, {
    String Function(String)? artUrlBuilder,
  }) async {
    _queue = List.from(tracks);
    _index = startIndex;
    if (_shuffle) _buildShuffleOrder(startIndex);

    final sources = _queue.map((t) => _makeSource(t, urlBuilder(t['id'] as String))).toList();
    _source = ConcatenatingAudioSource(children: sources);
    try {
      await _player.setAudioSource(_source!, initialIndex: startIndex);
      _applyReplayGain(tracks[startIndex]);
      _loadBpmForTrack(tracks[startIndex]['id'] as String);
      await _player.play();
    } catch (e) {
      debugPrint('ShamlssPlayer playQueue error: $e');
      _errorController.add('Playback error: $e');
    }
    notifyListeners();
  }

  void _applyReplayGain(Map<String, dynamic> track) {
    final rg = track['replay_gain'];
    if (rg == null) {
      _targetVol = 1.0;
    } else {
      final gain = (rg as num).toDouble();
      _targetVol = pow(10.0, gain / 20.0).clamp(0.0, 1.0).toDouble();
    }
    _player.setVolume(_targetVol);
  }

  void _buildShuffleOrder(int startIndex) {
    _shuffleOrder = List.generate(_queue.length, (i) => i)..remove(startIndex);
    _shuffleOrder.shuffle();
    _shuffleOrder.insert(0, startIndex);
  }

  Future<void> playPause() async {
    _player.playing ? await _player.pause() : await _player.play();
  }

  Future<void> skipNext() async {
    if (_shuffle && _shuffleOrder.isNotEmpty) {
      final pos = _shuffleOrder.indexOf(_index);
      final nextPos = (pos + 1) % _shuffleOrder.length;
      _index = _shuffleOrder[nextPos];
      await _player.seek(Duration.zero, index: _index);
      await _player.play();
      notifyListeners();
    } else {
      _advance(1, wrap: _repeat == RepeatMode.all);
    }
  }

  Future<void> skipPrev() async {
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_shuffle && _shuffleOrder.isNotEmpty) {
      final pos2 = _shuffleOrder.indexOf(_index);
      final prevPos = (pos2 - 1 + _shuffleOrder.length) % _shuffleOrder.length;
      _index = _shuffleOrder[prevPos];
      await _player.seek(Duration.zero, index: _index);
      await _player.play();
      notifyListeners();
    } else {
      _advance(-1, wrap: _repeat == RepeatMode.all);
    }
  }

  Future<void> seek(Duration pos) async => _player.seek(pos);

  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _index = index;
    await _player.seek(Duration.zero, index: index);
    await _player.play();
    notifyListeners();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    if (_shuffle) _buildShuffleOrder(_index);
    notifyListeners();
  }

  void toggleRepeat() {
    _repeat = RepeatMode.values[(_repeat.index + 1) % RepeatMode.values.length];
    notifyListeners();
  }

  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= _queue.length || _queue.length <= 1) return;
    _queue.removeAt(index);
    await _source?.removeAt(index);
    if (_index >= _queue.length) _index = _queue.length - 1;
    if (_shuffle) _buildShuffleOrder(_index);
    notifyListeners();
  }

  Future<void> addToQueue(Map<String, dynamic> track, String streamUrl) async {
    _queue.add(track);
    await _source?.add(_makeSource(track, streamUrl));
    notifyListeners();
  }

  Future<void> moveInQueue(int from, int to) async {
    if (from < 0 || to < 0 || from >= _queue.length || to >= _queue.length) return;
    final track = _queue.removeAt(from);
    _queue.insert(to, track);
    await _source?.move(from, to);
    if (_index == from) {
      _index = to;
    } else if (_index > from && _index <= to) {
      _index--;
    } else if (_index < from && _index >= to) {
      _index++;
    }
    if (_shuffle) _buildShuffleOrder(_index);
    notifyListeners();
  }

  @override
  void dispose() {
    _errorController.close();
    _player.dispose();
    super.dispose();
  }
}
