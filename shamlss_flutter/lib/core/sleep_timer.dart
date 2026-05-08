import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

class SleepTimer extends ChangeNotifier {
  final AudioPlayer _player;
  Timer? _ticker;
  Duration? _remaining;
  static const _fadeDuration = Duration(seconds: 30);

  SleepTimer(this._player);

  Duration? get remaining => _remaining;
  bool get active => _remaining != null;

  String get label {
    final r = _remaining;
    if (r == null) return 'Off';
    final m = r.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = r.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${r.inHours > 0 ? "${r.inHours}:" : ""}$m:$s';
  }

  void set(Duration duration) {
    cancel();
    _remaining = duration;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    notifyListeners();
  }

  void cancel() {
    _ticker?.cancel();
    _ticker = null;
    _remaining = null;
    _player.setVolume(1.0);
    notifyListeners();
  }

  void _tick() {
    if (_remaining == null) return;
    _remaining = _remaining! - const Duration(seconds: 1);

    if (_remaining! <= Duration.zero) {
      _player.pause();
      cancel();
      return;
    }

    // Fade volume over last 30s
    if (_remaining! <= _fadeDuration) {
      final frac = _remaining!.inMilliseconds / _fadeDuration.inMilliseconds;
      _player.setVolume(frac.clamp(0.0, 1.0));
    }

    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
