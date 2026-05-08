import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import '../core/daemon_client.dart';
import '../core/player.dart' as player_lib;
import '../core/theme.dart';
import '../core/waveform_painter.dart';
import 'queue_sheet.dart';

class NowPlayingScreen extends StatelessWidget {
  final player_lib.ShamlssPlayer player;
  final DaemonClient daemon;
  const NowPlayingScreen({super.key, required this.player, required this.daemon});

  String _fmt(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _showSimilar(BuildContext context, Map<String, dynamic> track) async {
    final similar = await daemon.getSimilarTracks(track['id'] as String);
    if (!context.mounted) return;
    if (similar.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No similar tracks found'), duration: Duration(seconds: 2)));
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: ShamlssColors.card,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(children: [
            Icon(Icons.auto_awesome, color: ShamlssColors.amber, size: 16),
            SizedBox(width: 8),
            Text('SIMILAR TRACKS', style: TextStyle(color: ShamlssColors.amberDim, fontSize: 11, letterSpacing: 2)),
          ]),
        ),
        Flexible(child: ListView.builder(
          shrinkWrap: true,
          itemCount: similar.length,
          itemBuilder: (ctx, i) {
            final s = similar[i];
            return ListTile(
              dense: true,
              leading: s['art_hash'] != null
                  ? ClipRRect(borderRadius: BorderRadius.circular(3),
                      child: Image.network(daemon.artUrl(s['id'] as String), width: 36, height: 36, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 16)))
                  : const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 16),
              title: Text(s['title'] ?? 'Unknown', style: const TextStyle(color: ShamlssColors.text, fontSize: 13), overflow: TextOverflow.ellipsis),
              subtitle: Text(s['artist'] ?? '', style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11), overflow: TextOverflow.ellipsis),
              trailing: s['bpm'] != null ? Text('${s['bpm']} BPM', style: const TextStyle(color: ShamlssColors.divider, fontSize: 10)) : null,
              onTap: () {
                Navigator.pop(ctx);
                player.playQueue([s], 0, daemon.streamUrl, artUrlBuilder: daemon.artUrl);
              },
            );
          },
        )),
        const SizedBox(height: 16),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = player.current;
    return Scaffold(
      appBar: AppBar(
        title: const Text('NOW PLAYING', style: TextStyle(letterSpacing: 3, fontSize: 14)),
        actions: [
          if (t != null) IconButton(
            icon: const Icon(Icons.auto_awesome_outlined, size: 20),
            color: ShamlssColors.textMuted,
            tooltip: 'Similar tracks',
            onPressed: () => _showSimilar(context, t),
          ),
          if (t != null) IconButton(
            icon: const Icon(Icons.queue_music, size: 20),
            color: ShamlssColors.textMuted,
            onPressed: () => showQueueSheet(context, player),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: t == null
          ? const Center(child: Text('Nothing playing', style: TextStyle(color: ShamlssColors.textMuted)))
          : ListenableBuilder(
              listenable: player,
              builder: (context, _) => _PlayerBody(player: player, track: t, daemon: daemon, fmt: _fmt), // ignore: no_logic_in_create_state
            ),
    );
  }
}

class _PlayerBody extends StatefulWidget {
  final player_lib.ShamlssPlayer player;
  final Map<String, dynamic> track;
  final DaemonClient daemon;
  final String Function(Duration?) fmt;
  const _PlayerBody({required this.player, required this.track, required this.daemon, required this.fmt});

  @override
  State<_PlayerBody> createState() => _PlayerBodyState();
}

class _PlayerBodyState extends State<_PlayerBody> {
  bool _showLyrics = false;
  List<Map<String, dynamic>>? _lyrics;
  bool _lyricsLoading = false;
  Map<String, dynamic>? _analysis;
  List<double>? _waveform;
  Map<String, int> _reactionCounts = {};
  double _speed = 1.0;

  static const _reactionEmojis = ['❤️', '🔥', '👏', '😮'];

  @override
  void initState() {
    super.initState();
    _fetchAnalysis();
    _fetchWaveform();
    _fetchReactions();
  }

  @override
  void didUpdateWidget(_PlayerBody old) {
    super.didUpdateWidget(old);
    if (old.track['id'] != widget.track['id']) {
      setState(() { _analysis = null; _waveform = null; _lyrics = null; _showLyrics = false; _reactionCounts = {}; });
      _fetchAnalysis();
      _fetchWaveform();
      _fetchReactions();
    }
  }

  Future<void> _fetchAnalysis() async {
    final result = await widget.daemon.getAnalysis(widget.track['id'] as String);
    if (mounted && result != null) setState(() => _analysis = result);
  }

  Future<void> _fetchWaveform() async {
    final result = await widget.daemon.getTrackWaveform(widget.track['id'] as String);
    if (mounted && result != null) setState(() => _waveform = result);
  }

  Future<void> _fetchReactions() async {
    final id = widget.track['id'] as String?;
    if (id == null) return;
    final data = await widget.daemon.get('/reactions/$id');
    if (!mounted) return;
    final counts = <String, int>{};
    if (data is List) {
      for (final r in data) {
        if (r is Map) {
          final emoji = r['emoji'] as String?;
          if (emoji == null) continue;
          final c = r['count'];
          if (c is num) {
            counts[emoji] = (counts[emoji] ?? 0) + c.toInt();
          } else {
            counts[emoji] = (counts[emoji] ?? 0) + 1;
          }
        }
      }
    } else if (data is Map) {
      data.forEach((k, v) {
        if (k is String && v is num) counts[k] = v.toInt();
      });
    }
    setState(() => _reactionCounts = counts);
  }

  Future<void> _react(String emoji) async {
    final id = widget.track['id'] as String?;
    if (id == null) return;
    await widget.daemon.post('/reactions', {
      'track_id': id,
      'emoji': emoji,
      'node_id': 'local',
    });
    await _fetchReactions();
  }

  Future<void> _setSpeed(double v) async {
    await widget.player.player.setSpeed(v);
    if (mounted) setState(() => _speed = v);
  }

  Future<void> _savePosition() async {
    final id = widget.track['id'] as String?;
    if (id == null) return;
    final posMs = widget.player.player.position.inMilliseconds;
    final res = await widget.daemon.post('/library/tracks/$id/resume', {'position_ms': posMs});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res != null ? 'Position saved' : 'Failed to save position'),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _toggleLyrics() async {
    if (_showLyrics) { setState(() => _showLyrics = false); return; }
    if (_lyrics != null) { setState(() => _showLyrics = true); return; }
    setState(() { _lyricsLoading = true; _showLyrics = true; });
    try {
      final res = await http.get(Uri.parse(widget.daemon.lyricsUrl(widget.track['id'] as String)));
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body);
        setState(() { _lyrics = List<Map<String, dynamic>>.from(data['lines'] as List); _lyricsLoading = false; });
      } else if (mounted) {
        setState(() { _lyrics = []; _lyricsLoading = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _lyrics = []; _lyricsLoading = false; });
    }
  }

  player_lib.ShamlssPlayer get player => widget.player;
  Map<String, dynamic> get track => widget.track;
  DaemonClient get daemon => widget.daemon;
  String Function(Duration?) get fmt => widget.fmt;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(children: [
        const Spacer(),
        GestureDetector(
          onTap: _toggleLyrics,
          child: _showLyrics
              ? _LyricsPanel(lyrics: _lyrics, loading: _lyricsLoading, player: player)
              : _AlbumArt(artUrl: track['_art_url'] as String? ?? (track['art_hash'] != null ? daemon.artUrl(track['id'] as String) : null)),
        ),
        const SizedBox(height: 32),
        Text(track['title'] ?? 'Unknown',
            style: const TextStyle(color: ShamlssColors.text, fontSize: 20, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(track['artist'] ?? '', style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 14), textAlign: TextAlign.center),
        Text(track['album'] ?? '', style: const TextStyle(color: ShamlssColors.divider, fontSize: 12), textAlign: TextAlign.center),
        if (_analysis != null && (_analysis!['bpm'] != null || _analysis!['key'] != null))
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (_analysis!['bpm'] != null)
                _AnalysisBadge(label: '${_analysis!['bpm']} BPM'),
              if (_analysis!['bpm'] != null && _analysis!['key'] != null)
                const SizedBox(width: 8),
              if (_analysis!['key'] != null)
                _AnalysisBadge(label: _analysis!['key'] as String),
            ]),
          ),
        if (_waveform != null && _waveform!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: _WaveformWidget(
              samples: _waveform!,
              positionStream: player.positionStream,
              getDuration: () => player.duration,
              onSeek: player.seek,
            ),
          ),
        const SizedBox(height: 32),
        StreamBuilder<Duration?>(
          stream: player.positionStream,
          builder: (_, snap) {
            final pos = snap.data ?? Duration.zero;
            final dur = player.duration ?? Duration.zero;
            return Column(children: [
              SliderTheme(
                data: SliderThemeData(
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: SliderComponentShape.noOverlay,
                  trackHeight: 2,
                ),
                child: Slider(
                  value: dur.inMilliseconds > 0 ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0) : 0,
                  onChanged: (v) => player.seek(Duration(milliseconds: (v * dur.inMilliseconds).round())),
                  activeColor: ShamlssColors.amber,
                  inactiveColor: ShamlssColors.divider,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(fmt(pos), style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11)),
                  Text(fmt(dur), style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11)),
                ]),
              ),
            ]);
          },
        ),
        const SizedBox(height: 8),
        // Reactions strip
        _ReactionsStrip(
          counts: _reactionCounts,
          emojis: _reactionEmojis,
          onTap: _react,
        ),
        if (track['type'] == 'podcast' || track['type'] == 'audiobook') ...[
          const SizedBox(height: 8),
          _PodcastControls(
            speed: _speed,
            onSpeedChanged: _setSpeed,
            onSavePosition: _savePosition,
          ),
        ],
        const SizedBox(height: 16),
        // Shuffle + Repeat row
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
            icon: Icon(Icons.shuffle,
                color: player.shuffle ? ShamlssColors.amber : ShamlssColors.textMuted, size: 20),
            onPressed: player.toggleShuffle,
          ),
          const SizedBox(width: 8),
          _repeatIcon(player.repeat),
          const SizedBox(width: 8),
        ]),
        const SizedBox(height: 8),
        // Transport row
        StreamBuilder<PlayerState>(
          stream: player.stateStream,
          builder: (_, snap) {
            final playing = snap.data?.playing ?? false;
            final loading = snap.data?.processingState == ProcessingState.loading ||
                snap.data?.processingState == ProcessingState.buffering;
            return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(icon: const Icon(Icons.skip_previous), color: ShamlssColors.text, iconSize: 36, onPressed: player.skipPrev),
              const SizedBox(width: 16),
              Container(
                width: 64, height: 64,
                decoration: const BoxDecoration(color: ShamlssColors.amber, shape: BoxShape.circle),
                child: loading
                    ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: ShamlssColors.black, strokeWidth: 2)))
                    : IconButton(icon: Icon(playing ? Icons.pause : Icons.play_arrow, color: ShamlssColors.black, size: 32), onPressed: player.playPause),
              ),
              const SizedBox(width: 16),
              IconButton(icon: const Icon(Icons.skip_next), color: ShamlssColors.text, iconSize: 36, onPressed: player.skipNext),
            ]);
          },
        ),
        const Spacer(),
      ]),
    );
  }

  Widget _repeatIcon(player_lib.RepeatMode mode) {
    switch (mode) {
      case player_lib.RepeatMode.none:
        return IconButton(icon: const Icon(Icons.repeat, size: 20, color: ShamlssColors.textMuted), onPressed: player.toggleRepeat);
      case player_lib.RepeatMode.all:
        return IconButton(icon: const Icon(Icons.repeat, size: 20, color: ShamlssColors.amber), onPressed: player.toggleRepeat);
      case player_lib.RepeatMode.one:
        return IconButton(icon: const Icon(Icons.repeat_one, size: 20, color: ShamlssColors.amber), onPressed: player.toggleRepeat);
    }
  }
}

class _WaveformWidget extends StatelessWidget {
  final List<double> samples;
  final Stream<Duration?> positionStream;
  final Duration? Function() getDuration;
  final void Function(Duration) onSeek;

  const _WaveformWidget({
    required this.samples,
    required this.positionStream,
    required this.getDuration,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: LayoutBuilder(
        builder: (ctx, constraints) => StreamBuilder<Duration?>(
          stream: positionStream,
          builder: (_, snap) {
            final pos = snap.data ?? Duration.zero;
            final dur = getDuration() ?? Duration.zero;
            final ratio = dur.inMilliseconds > 0
                ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                : 0.0;
            return GestureDetector(
              onTapDown: (details) {
                final r = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                final d = getDuration();
                if (d != null) onSeek(Duration(milliseconds: (r * d.inMilliseconds).round()));
              },
              child: CustomPaint(
                painter: WaveformPainter(
                  samples: samples,
                  position: ratio,
                  activeColor: ShamlssColors.amber,
                  inactiveColor: ShamlssColors.divider,
                ),
                size: Size(constraints.maxWidth, 48),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LyricsPanel extends StatelessWidget {
  final List<Map<String, dynamic>>? lyrics;
  final bool loading;
  final player_lib.ShamlssPlayer player;
  const _LyricsPanel({this.lyrics, required this.loading, required this.player});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220, height: 220,
      decoration: BoxDecoration(
        color: ShamlssColors.surface,
        border: Border.all(color: ShamlssColors.amberDim.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: loading
          ? const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))
          : lyrics == null || lyrics!.isEmpty
              ? const Center(child: Text('No lyrics', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 12)))
              : StreamBuilder<Duration?>(
                  stream: player.positionStream,
                  builder: (_, snap) {
                    final posMs = snap.data?.inMilliseconds ?? 0;
                    final timed = lyrics!.where((l) => l['time_ms'] != null).toList();
                    final plain = lyrics!.where((l) => l['time_ms'] == null).toList();

                    if (timed.isEmpty) {
                      return ListView(padding: const EdgeInsets.all(12), children: plain.map((l) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(l['text'] ?? '', style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11), textAlign: TextAlign.center),
                      )).toList());
                    }

                    int active = 0;
                    for (int i = 0; i < timed.length; i++) {
                      if ((timed[i]['time_ms'] as int) <= posMs) active = i;
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: timed.length,
                      itemBuilder: (_, i) => Text(
                        timed[i]['text'] ?? '',
                        style: TextStyle(
                          color: i == active ? ShamlssColors.amber : ShamlssColors.textMuted,
                          fontSize: i == active ? 12 : 10,
                          fontWeight: i == active ? FontWeight.bold : FontWeight.normal,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    );
                  },
                ),
    );
  }
}

class _AnalysisBadge extends StatelessWidget {
  final String label;
  const _AnalysisBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ShamlssColors.amberDim.withOpacity(0.15),
        border: Border.all(color: ShamlssColors.amberDim.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: const TextStyle(color: ShamlssColors.amberDim, fontSize: 11, letterSpacing: 0.5)),
    );
  }
}

class _ReactionsStrip extends StatelessWidget {
  final Map<String, int> counts;
  final List<String> emojis;
  final Future<void> Function(String) onTap;
  const _ReactionsStrip({required this.counts, required this.emojis, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final entries = counts.entries.where((e) => e.value > 0).toList();
    return SizedBox(
      height: 48,
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        // Existing reaction counts (chips)
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: entries.map((e) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: ShamlssColors.surface,
                  border: Border.all(color: ShamlssColors.divider),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(e.key, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 4),
                  Text('${e.value}', style: const TextStyle(color: ShamlssColors.amberDim, fontSize: 11)),
                ]),
              ),
            )).toList()),
          ),
        ),
        // Tap-to-react buttons
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: emojis.map((e) => InkWell(
            onTap: () => onTap(e),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(e, style: const TextStyle(fontSize: 18)),
            ),
          )).toList()),
        ),
      ]),
    );
  }
}

class _PodcastControls extends StatelessWidget {
  final double speed;
  final Future<void> Function(double) onSpeedChanged;
  final Future<void> Function() onSavePosition;
  const _PodcastControls({required this.speed, required this.onSpeedChanged, required this.onSavePosition});

  static const _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: _speeds.map((s) {
            final selected = (s - speed).abs() < 0.01;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                onTap: () => onSpeedChanged(s),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: selected ? ShamlssColors.amber : ShamlssColors.surface,
                    border: Border.all(color: selected ? ShamlssColors.amber : ShamlssColors.divider),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('${s}x', style: TextStyle(
                    color: selected ? ShamlssColors.black : ShamlssColors.textMuted,
                    fontSize: 12,
                  )),
                ),
              ),
            );
          }).toList()),
        ),
        const SizedBox(height: 6),
        TextButton.icon(
          icon: const Icon(Icons.bookmark_outline, size: 16, color: ShamlssColors.amberDim),
          label: const Text('SAVE POSITION', style: TextStyle(color: ShamlssColors.amberDim, fontSize: 11, letterSpacing: 1.5)),
          onPressed: onSavePosition,
        ),
      ]),
    );
  }
}

class _AlbumArt extends StatelessWidget {
  final String? artUrl;
  const _AlbumArt({this.artUrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220, height: 220,
      decoration: BoxDecoration(
        color: ShamlssColors.surface,
        border: Border.all(color: ShamlssColors.amberDim.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: artUrl != null
            ? Image.network(artUrl!, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 80, color: ShamlssColors.amberDim))
            : const Icon(Icons.music_note, size: 80, color: ShamlssColors.amberDim),
      ),
    );
  }
}
