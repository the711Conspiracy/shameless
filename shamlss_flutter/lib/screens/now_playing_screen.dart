import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
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
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No similar tracks found'), duration: Duration(seconds: 2)));
      return;
    }
    final tints = SleeveTintsProvider.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: tints.surface,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(children: [
            Icon(Icons.auto_awesome, color: tints.accent, size: 16),
            const SizedBox(width: 8),
            Text('SIMILAR TRACKS',
                style: GoogleFonts.jetBrainsMono(color: tints.textMute, fontSize: 11, letterSpacing: 0.18)),
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
                      child: Image.network(daemon.artUrl(s['id'] as String), width: 36, height: 36,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              Icon(Icons.music_note, color: tints.accent, size: 16)))
                  : Icon(Icons.music_note, color: tints.accent, size: 16),
              title: Text(s['title'] ?? 'Unknown',
                  style: GoogleFonts.interTight(color: tints.text, fontSize: 13),
                  overflow: TextOverflow.ellipsis),
              subtitle: Text(s['artist'] ?? '',
                  style: GoogleFonts.interTight(color: tints.textMute, fontSize: 11),
                  overflow: TextOverflow.ellipsis),
              trailing: s['bpm'] != null
                  ? Text('${s['bpm']} BPM',
                      style: GoogleFonts.jetBrainsMono(color: tints.textDim, fontSize: 10))
                  : null,
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
    final tints = SleeveTintsProvider.of(context);
    final t = player.current;
    return Scaffold(
      backgroundColor: tints.base,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: tints.text, size: 28),
          onPressed: () {},
        ),
        title: Text(
          'NOW PLAYING',
          style: GoogleFonts.jetBrainsMono(
            color: tints.textMute,
            fontSize: 11,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.18,
          ),
        ),
        centerTitle: true,
        actions: [
          if (t != null) IconButton(
            icon: Icon(Icons.queue_music, size: 20, color: tints.textMute),
            onPressed: () => showQueueSheet(context, player),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: t == null
          ? Center(child: Text('Nothing playing',
              style: GoogleFonts.interTight(color: tints.textMute, fontSize: 14)))
          : ListenableBuilder(
              listenable: player,
              builder: (context, _) =>
                  _PlayerBody(player: player, track: t, daemon: daemon, fmt: _fmt),
            ),
    );
  }
}

// ─── Main player body ──────────────────────────────────────────────────────

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
      setState(() {
        _analysis = null;
        _waveform = null;
        _lyrics = null;
        _showLyrics = false;
        _reactionCounts = {};
      });
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
        setState(() {
          _lyrics = List<Map<String, dynamic>>.from(data['lines'] as List);
          _lyricsLoading = false;
        });
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
    final tints = SleeveTintsProvider.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final discSize = screenWidth * 0.82;
    final artUrl = track['_art_url'] as String?
        ?? (track['art_hash'] != null ? daemon.artUrl(track['id'] as String) : null);

    // Mono strip data
    final bpm = _analysis?['bpm'];
    final key = _analysis?['key'] as String?;
    final format = track['format'] as String?;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tints.surfaceHi, tints.surface, tints.base, SleeveTokens.black],
          stops: const [0.0, 0.3, 0.65, 1.0],
        ),
      ),
      child: Stack(
        children: [
          // Paper grain overlay
          const _PaperGrain(),
          // Scrollable content
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(children: [
                // Top spacer for AppBar
                const SizedBox(height: 56),

                // VinylDisc hero
                SizedBox(
                  height: discSize,
                  child: GestureDetector(
                    onTap: _toggleLyrics,
                    child: _showLyrics
                        ? _LyricsPanel(lyrics: _lyrics, loading: _lyricsLoading, player: player, tints: tints)
                        : _VinylDisc(size: discSize, artUrl: artUrl, tints: tints, peek: 0.36),
                  ),
                ),

                const SizedBox(height: 28),

                // Title
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    track['title'] ?? 'Unknown',
                    style: GoogleFonts.newsreader(
                      color: tints.text,
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.02,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                const SizedBox(height: 6),

                // Artist — italic Inter Tight 14
                Text(
                  track['artist'] ?? '',
                  style: GoogleFonts.interTight(
                    color: tints.textMute,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 12),

                // MonoStrip
                _MonoStrip(bpm: bpm, keyStr: key, format: format, tints: tints),

                const SizedBox(height: 16),

                // Waveform (if available)
                if (_waveform != null && _waveform!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: _WaveformWidget(
                      samples: _waveform!,
                      positionStream: player.positionStream,
                      getDuration: () => player.duration,
                      onSeek: player.seek,
                      tints: tints,
                    ),
                  ),

                // Progress bar (2px, no thumb)
                const SizedBox(height: 8),
                StreamBuilder<Duration?>(
                  stream: player.positionStream,
                  builder: (_, snap) {
                    final pos = snap.data ?? Duration.zero;
                    final dur = player.duration ?? Duration.zero;
                    final ratio = dur.inMilliseconds > 0
                        ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                        : 0.0;
                    return Column(children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: GestureDetector(
                          onTapDown: (details) {
                            final box = context.findRenderObject() as RenderBox?;
                            if (box == null) return;
                            final localWidth = screenWidth - 48;
                            final r = (details.localPosition.dx / localWidth).clamp(0.0, 1.0);
                            player.seek(Duration(milliseconds: (r * dur.inMilliseconds).round()));
                          },
                          child: Stack(children: [
                            // Track background
                            Container(
                              height: 2,
                              decoration: BoxDecoration(
                                color: tints.line,
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                            // Filled portion
                            FractionallySizedBox(
                              widthFactor: ratio,
                              child: Container(
                                height: 2,
                                decoration: BoxDecoration(
                                  color: tints.accent,
                                  borderRadius: BorderRadius.circular(1),
                                ),
                              ),
                            ),
                          ]),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text(fmt(pos), style: GoogleFonts.jetBrainsMono(color: tints.textDim, fontSize: 10)),
                          Text(fmt(dur), style: GoogleFonts.jetBrainsMono(color: tints.textDim, fontSize: 10)),
                        ]),
                      ),
                    ]);
                  },
                ),

                const SizedBox(height: 16),

                // Reactions strip (unchanged functionality)
                _ReactionsStrip(
                  counts: _reactionCounts,
                  emojis: _reactionEmojis,
                  onTap: _react,
                  tints: tints,
                ),

                // Podcast controls (unchanged functionality)
                if (track['type'] == 'podcast' || track['type'] == 'audiobook') ...[
                  const SizedBox(height: 8),
                  _PodcastControls(
                    speed: _speed,
                    onSpeedChanged: _setSpeed,
                    onSavePosition: _savePosition,
                    tints: tints,
                  ),
                ],

                const SizedBox(height: 16),

                // Shuffle + Repeat row
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton(
                    icon: Icon(Icons.shuffle,
                        color: player.shuffle ? tints.accent : tints.textMute, size: 20),
                    onPressed: player.toggleShuffle,
                  ),
                  const SizedBox(width: 8),
                  _repeatIcon(player.repeat, tints),
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
                      // Prev — 22px icon in touch target
                      IconButton(
                        icon: Icon(Icons.skip_previous, color: tints.text, size: 22),
                        onPressed: player.skipPrev,
                        padding: const EdgeInsets.all(11),
                      ),
                      const SizedBox(width: 20),
                      // 72px circular play button
                      GestureDetector(
                        onTap: player.playPause,
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: const BoxDecoration(
                            color: SleeveTokens.rust,
                            shape: BoxShape.circle,
                          ),
                          child: loading
                              ? const Center(child: SizedBox(
                                  width: 24, height: 24,
                                  child: CircularProgressIndicator(
                                    color: SleeveTokens.paper, strokeWidth: 2)))
                              : Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  color: SleeveTokens.paper,
                                  size: 36,
                                ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      // Next — 22px icon
                      IconButton(
                        icon: Icon(Icons.skip_next, color: tints.text, size: 22),
                        onPressed: player.skipNext,
                        padding: const EdgeInsets.all(11),
                      ),
                    ]);
                  },
                ),

                const SizedBox(height: 24),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _repeatIcon(player_lib.RepeatMode mode, SleeveTints tints) {
    switch (mode) {
      case player_lib.RepeatMode.none:
        return IconButton(
            icon: Icon(Icons.repeat, size: 20, color: tints.textMute),
            onPressed: player.toggleRepeat);
      case player_lib.RepeatMode.all:
        return IconButton(
            icon: Icon(Icons.repeat, size: 20, color: tints.accent),
            onPressed: player.toggleRepeat);
      case player_lib.RepeatMode.one:
        return IconButton(
            icon: Icon(Icons.repeat_one, size: 20, color: tints.accent),
            onPressed: player.toggleRepeat);
    }
  }
}

// ─── VinylDisc ─────────────────────────────────────────────────────────────

class _VinylDisc extends StatefulWidget {
  final double size;
  final String? artUrl;
  final SleeveTints tints;
  final double peek;

  const _VinylDisc({
    required this.size,
    required this.artUrl,
    required this.tints,
    this.peek = 0.36,
  });

  @override
  State<_VinylDisc> createState() => _VinylDiscState();
}

class _VinylDiscState extends State<_VinylDisc> with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1818), // 33⅓ rpm
    )..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final peekOffset = s * widget.peek; // disc left edge starts this many px from left

    return SizedBox(
      width: double.infinity,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Album sleeve peeks out to the left
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: peekOffset + s * 0.18, // sleeve visible portion
            child: _SleeveCover(artUrl: widget.artUrl, tints: widget.tints),
          ),
          // Rotating disc positioned so left edge = peekOffset
          Positioned(
            left: peekOffset,
            top: 0,
            width: s,
            height: s,
            child: RotationTransition(
              turns: _spin,
              child: _DiscFace(size: s, tints: widget.tints),
            ),
          ),
        ],
      ),
    );
  }
}

class _SleeveCover extends StatelessWidget {
  final String? artUrl;
  final SleeveTints tints;
  const _SleeveCover({this.artUrl, required this.tints});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: tints.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 16,
            offset: const Offset(4, 0),
          ),
        ],
      ),
      child: artUrl != null
          ? Image.network(artUrl!, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Icon(Icons.album, color: tints.accent, size: 40))
          : Icon(Icons.album, color: tints.accent, size: 40),
    );
  }
}

class _DiscFace extends StatelessWidget {
  final double size;
  final SleeveTints tints;
  const _DiscFace({required this.size, required this.tints});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _VinylPainter(tints: tints),
    );
  }
}

class _VinylPainter extends CustomPainter {
  final SleeveTints tints;
  const _VinylPainter({required this.tints});

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = Offset(r, r);

    // Drop shadow — done via Container decoration on parent, just paint disc.

    // Black disc body
    final discPaint = Paint()..color = const Color(0xFF0A0908);
    canvas.drawCircle(center, r, discPaint);

    // Groove rings — thin white @ ~3% opacity
    final grooveRadii = [0.97, 0.92, 0.86, 0.78, 0.68, 0.58, 0.48];
    final groovePaint = Paint()
      ..color = Colors.white.withOpacity(0.03)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (final f in grooveRadii) {
      canvas.drawCircle(center, r * f, groovePaint);
    }

    // Center label (32% of disc diameter)
    final labelR = r * 0.32;
    final labelPaint = Paint()
      ..shader = RadialGradient(colors: [
        tints.accent,
        Color.lerp(tints.accent, const Color(0xFF0A0908), 0.5)!,
      ]).createShader(Rect.fromCircle(center: center, radius: labelR));
    canvas.drawCircle(center, labelR, labelPaint);

    // "SHAMLSS" text on label
    final tp = TextPainter(
      text: TextSpan(
        text: 'SHAMLSS',
        style: TextStyle(
          color: Colors.white.withOpacity(0.85),
          fontSize: labelR * 0.22,
          fontWeight: FontWeight.w600,
          letterSpacing: labelR * 0.04,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));

    // Center hole (1.8% of diameter)
    final holePaint = Paint()..color = const Color(0xFF0A0908);
    canvas.drawCircle(center, r * 0.018, holePaint);
  }

  @override
  bool shouldRepaint(_VinylPainter old) => old.tints != tints;
}

// ─── Paper grain overlay ───────────────────────────────────────────────────

class _PaperGrain extends StatelessWidget {
  const _PaperGrain();

  @override
  Widget build(BuildContext context) {
    // Implemented as a semi-transparent noise layer via CustomPaint.
    // A true feTurbulence grain would require a shader — we approximate with
    // a fine dot-dither pattern at very low opacity.
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(painter: _GrainPainter()),
      ),
    );
  }
}

class _GrainPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rng = math.Random(42);
    final paint = Paint()..color = Colors.white.withOpacity(0.03);
    const step = 4.0;
    var x = 0.0;
    while (x < size.width) {
      var y = 0.0;
      while (y < size.height) {
        if (rng.nextDouble() < 0.35) {
          canvas.drawCircle(Offset(x, y), 0.6, paint);
        }
        y += step;
      }
      x += step;
    }
  }

  @override
  bool shouldRepaint(_GrainPainter old) => false;
}

// ─── MonoStrip ─────────────────────────────────────────────────────────────

class _MonoStrip extends StatelessWidget {
  final dynamic bpm;
  final String? keyStr;
  final String? format;
  final SleeveTints tints;

  const _MonoStrip({this.bpm, this.keyStr, this.format, required this.tints});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (bpm != null) parts.add('${bpm} BPM');
    if (keyStr != null && keyStr!.isNotEmpty) parts.add(keyStr!.toUpperCase());
    if (format != null && format!.isNotEmpty) parts.add(format!.toUpperCase());

    if (parts.isEmpty) return const SizedBox.shrink();

    return Text(
      parts.join(' · '),
      style: GoogleFonts.jetBrainsMono(
        color: tints.textDim,
        fontSize: 11,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.18,
      ),
      textAlign: TextAlign.center,
    );
  }
}

// ─── Waveform widget (unchanged logic, updated colors) ─────────────────────

class _WaveformWidget extends StatelessWidget {
  final List<double> samples;
  final Stream<Duration?> positionStream;
  final Duration? Function() getDuration;
  final void Function(Duration) onSeek;
  final SleeveTints tints;

  const _WaveformWidget({
    required this.samples,
    required this.positionStream,
    required this.getDuration,
    required this.onSeek,
    required this.tints,
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
                  activeColor: tints.accent,
                  inactiveColor: tints.line,
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

// ─── Lyrics panel (unchanged logic, updated colors) ────────────────────────

class _LyricsPanel extends StatelessWidget {
  final List<Map<String, dynamic>>? lyrics;
  final bool loading;
  final player_lib.ShamlssPlayer player;
  final SleeveTints tints;
  const _LyricsPanel({this.lyrics, required this.loading, required this.player, required this.tints});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: tints.surface.withOpacity(0.8),
        border: Border.all(color: tints.line),
      ),
      child: loading
          ? Center(child: CircularProgressIndicator(color: tints.accent, strokeWidth: 2))
          : lyrics == null || lyrics!.isEmpty
              ? Center(child: Text('No lyrics',
                  style: GoogleFonts.interTight(color: tints.textMute, fontSize: 12)))
              : StreamBuilder<Duration?>(
                  stream: player.positionStream,
                  builder: (_, snap) {
                    final posMs = snap.data?.inMilliseconds ?? 0;
                    final timed = lyrics!.where((l) => l['time_ms'] != null).toList();
                    final plain = lyrics!.where((l) => l['time_ms'] == null).toList();

                    if (timed.isEmpty) {
                      return ListView(
                        padding: const EdgeInsets.all(16),
                        children: plain.map((l) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(l['text'] ?? '',
                              style: GoogleFonts.interTight(color: tints.textMute, fontSize: 13),
                              textAlign: TextAlign.center),
                        )).toList(),
                      );
                    }

                    int active = 0;
                    for (int i = 0; i < timed.length; i++) {
                      if ((timed[i]['time_ms'] as int) <= posMs) active = i;
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: timed.length,
                      itemBuilder: (_, i) => Text(
                        timed[i]['text'] ?? '',
                        style: GoogleFonts.interTight(
                          color: i == active ? tints.accent : tints.textMute,
                          fontSize: i == active ? 14 : 11,
                          fontWeight: i == active ? FontWeight.w600 : FontWeight.normal,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    );
                  },
                ),
    );
  }
}

// ─── Reactions strip (unchanged logic) ────────────────────────────────────

class _ReactionsStrip extends StatelessWidget {
  final Map<String, int> counts;
  final List<String> emojis;
  final Future<void> Function(String) onTap;
  final SleeveTints tints;
  const _ReactionsStrip({required this.counts, required this.emojis, required this.onTap, required this.tints});

  @override
  Widget build(BuildContext context) {
    final entries = counts.entries.where((e) => e.value > 0).toList();
    return SizedBox(
      height: 48,
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: entries.map((e) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: tints.accentSoft,
                  border: Border.all(color: tints.line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(e.key, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 4),
                  Text('${e.value}', style: GoogleFonts.jetBrainsMono(color: tints.textMute, fontSize: 11)),
                ]),
              ),
            )).toList()),
          ),
        ),
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

// ─── Podcast controls (unchanged logic) ────────────────────────────────────

class _PodcastControls extends StatelessWidget {
  final double speed;
  final Future<void> Function(double) onSpeedChanged;
  final Future<void> Function() onSavePosition;
  final SleeveTints tints;
  const _PodcastControls({
    required this.speed,
    required this.onSpeedChanged,
    required this.onSavePosition,
    required this.tints,
  });

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
                    color: selected ? tints.accent : tints.surface,
                    border: Border.all(color: selected ? tints.accent : tints.line),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('${s}x',
                      style: GoogleFonts.jetBrainsMono(
                        color: selected ? SleeveTokens.paper : tints.textMute,
                        fontSize: 12,
                      )),
                ),
              ),
            );
          }).toList()),
        ),
        const SizedBox(height: 6),
        TextButton.icon(
          icon: Icon(Icons.bookmark_outline, size: 16, color: tints.textMute),
          label: Text('SAVE POSITION',
              style: GoogleFonts.jetBrainsMono(color: tints.textMute, fontSize: 11, letterSpacing: 0.18)),
          onPressed: onSavePosition,
        ),
      ]),
    );
  }
}
