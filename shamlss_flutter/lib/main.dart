import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import 'core/daemon_client.dart';
import 'core/queue_persistence.dart';
import 'core/player.dart';
import 'core/sleep_timer.dart';
import 'core/theme.dart';
import 'screens/connect_screen.dart';
import 'screens/history_screen.dart';
import 'screens/library_screen.dart';
import 'screens/now_playing_screen.dart';
import 'screens/playlists_screen.dart';
import 'screens/pods_screen.dart';
import 'screens/settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  runApp(const ShamlssApp());
}

class ShamlssApp extends StatelessWidget {
  const ShamlssApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shamlss',
      theme: ShamlssTheme.theme,
      home: const AppShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  final _daemon = DaemonClient();
  final _player = ShamlssPlayer();
  late final SleepTimer _sleepTimer;
  StreamSubscription<String>? _errorSub;

  SleeveTints _tints = SleeveTints.brand;
  String? _lastArtUrl;
  StreamSubscription<String>? _playerErrorSub;

  @override
  void initState() {
    super.initState();
    _daemon.init();
    _sleepTimer = SleepTimer(_player.player);
    _player.bpmProvider = (id) async => (await _daemon.getAnalysis(id))?['bpm']?.toDouble();
    _player.addListener(() {
      setState(() {});
      _updateTints();
    });
    _sleepTimer.addListener(() => setState(() {}));
    _daemon.addListener(_onDaemonChanged);
    _errorSub = _daemon.errors.listen(_onDaemonError);
    _playerErrorSub = _player.errors.listen(_onDaemonError);
    _tryAutoConnect();
  }

  /// Extracts palette tints from the current track's art URL.
  Future<void> _updateTints() async {
    final track = _player.current;
    if (track == null) return;
    final artUrl = track['_art_url'] as String?
        ?? (track['art_hash'] != null ? _daemon.artUrl(track['id'] as String) : null);
    if (artUrl == _lastArtUrl) return;
    _lastArtUrl = artUrl;
    final tints = await tintsFromUrl(artUrl);
    if (mounted) setState(() => _tints = tints);
  }

  void _onDaemonError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12)),
      backgroundColor: const Color(0xFF2A1E19),
      duration: const Duration(seconds: 5),
      action: SnackBarAction(
        label: 'OK',
        textColor: SleeveTokens.rust,
        onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
      ),
    ));
  }

  Future<void> _tryAutoConnect() async {
    final host = await QueuePersistence.loadHost();
    if (host != null && !_daemon.connected) {
      await _daemon.connect(host);
    }
  }

  void _onDaemonChanged() {
    if (_daemon.connected && _player.queue.isEmpty) {
      QueuePersistence.saveHost(_daemon.host!);
      _player.restoreQueue(_daemon.streamUrl, artUrlBuilder: _daemon.artUrl);
    }
    _updateTints();
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _playerErrorSub?.cancel();
    _daemon.removeListener(_onDaemonChanged);
    _sleepTimer.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SleeveTintsProvider(
      tints: _tints,
      child: ListenableBuilder(
        listenable: _daemon,
        builder: (context, _) {
          if (!_daemon.connected) return ConnectScreen(daemon: _daemon);
          return Scaffold(
            backgroundColor: _tints.base,
            body: Stack(
              children: [
                IndexedStack(
                  index: _index,
                  children: [
                    LibraryScreen(daemon: _daemon, player: _player),
                    PlaylistsScreen(daemon: _daemon, player: _player),
                    NowPlayingScreen(player: _player, daemon: _daemon),
                    PodsScreen(daemon: _daemon, player: _player),
                    HistoryScreen(daemon: _daemon, player: _player),
                  ],
                ),
                // Persistent settings gear — top-right, above status bar
                Positioned(
                  top: MediaQuery.of(context).padding.top + 8,
                  right: 14,
                  child: GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SettingsScreen(
                          daemon: _daemon,
                          sleepTimer: _sleepTimer,
                          player: _player,
                        ),
                      ),
                    ),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: _tints.surface.withOpacity(0.88),
                        shape: BoxShape.circle,
                        border: Border.all(color: _tints.line, width: 1),
                      ),
                      child: Icon(Icons.settings_outlined, size: 16, color: _tints.textDim),
                    ),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: _SleeveBottomNav(
              index: _index,
              tints: _tints,
              player: _player,
              daemon: _daemon,
              onIndexChanged: (i) => setState(() => _index = i),
              onMiniPlayerTap: () => setState(() => _index = 2),
            ),
          );
        },
      ),
    );
  }
}

// ─── Bottom nav + mini-player combined widget ──────────────────────────────

class _SleeveBottomNav extends StatelessWidget {
  final int index;
  final SleeveTints tints;
  final ShamlssPlayer player;
  final DaemonClient daemon;
  final ValueChanged<int> onIndexChanged;
  final VoidCallback onMiniPlayerTap;

  const _SleeveBottomNav({
    required this.index,
    required this.tints,
    required this.player,
    required this.daemon,
    required this.onIndexChanged,
    required this.onMiniPlayerTap,
  });

  static const _labels = ['LIBRARY', 'LISTS', 'NOW\nPLAYING', 'PODS', 'HISTORY'];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Floating mini-player pill
        if (player.current != null)
          _MiniPlayer(
            player: player,
            daemon: daemon,
            tints: tints,
            onTap: onMiniPlayerTap,
          ),
        // Bottom navigation bar
        Container(
          color: tints.base.withOpacity(0.92),
          child: SafeArea(
            top: false,
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: tints.line, width: 1)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(_labels.length, (i) {
                  final selected = i == index;
                  final isNowPlaying = i == 2;
                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onIndexChanged(i),
                      child: isNowPlaying
                          // Centre NOW PLAYING — raised disc button
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: selected ? tints.accent : tints.surface,
                                    border: Border.all(
                                      color: selected ? tints.accent : tints.line,
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.album_outlined,
                                    size: 20,
                                    color: selected ? tints.text : tints.textMute,
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: selected ? tints.accent : Colors.transparent,
                                    border: selected
                                        ? null
                                        : Border.all(color: tints.textDim, width: 1),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _labels[i],
                                  style: GoogleFonts.jetBrainsMono(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w400,
                                    letterSpacing: 0.18,
                                    color: selected ? tints.accent : tints.textDim,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Floating mini-player pill ─────────────────────────────────────────────

class _MiniPlayer extends StatelessWidget {
  final ShamlssPlayer player;
  final DaemonClient daemon;
  final SleeveTints tints;
  final VoidCallback onTap;

  const _MiniPlayer({
    required this.player,
    required this.daemon,
    required this.tints,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = player.current!;
    final artUrl = t['_art_url'] as String?
        ?? (t['art_hash'] != null ? daemon.artUrl(t['id'] as String) : null);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: tints.base.withOpacity(0.92),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: tints.line, width: 1),
            boxShadow: const [
              BoxShadow(
                color: Color(0x80000000),
                blurRadius: 32,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Row(children: [
              const SizedBox(width: 10),
              // 42px sleeve art
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: _SleeveArt(artUrl: artUrl, size: 42),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t['title'] ?? 'Unknown',
                      style: GoogleFonts.interTight(
                        color: tints.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (t['artist'] != null)
                      Text(
                        t['artist'] as String,
                        style: GoogleFonts.interTight(
                          color: tints.textMute,
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              // Play/pause 36px circle
              StreamBuilder<PlayerState>(
                stream: player.stateStream,
                builder: (_, snap) {
                  final playing = snap.data?.playing ?? false;
                  return Row(children: [
                    GestureDetector(
                      onTap: player.playPause,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: SleeveTokens.rust,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          playing ? Icons.pause : Icons.play_arrow,
                          color: SleeveTokens.paper,
                          size: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: player.skipNext,
                      child: Icon(Icons.skip_next, color: tints.textMute, size: 20),
                    ),
                    const SizedBox(width: 12),
                  ]);
                },
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─── Shared sleeve art widget ──────────────────────────────────────────────

class _SleeveArt extends StatelessWidget {
  final String? artUrl;
  final double size;
  const _SleeveArt({this.artUrl, required this.size});

  @override
  Widget build(BuildContext context) {
    if (artUrl == null) {
      return Container(
        width: size, height: size,
        color: SleeveTints.brand.surface,
        child: Icon(Icons.music_note, color: SleeveTokens.rust, size: size * 0.45),
      );
    }
    return Image.network(
      artUrl!,
      width: size, height: size,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        width: size, height: size,
        color: SleeveTints.brand.surface,
        child: Icon(Icons.music_note, color: SleeveTokens.rust, size: size * 0.45),
      ),
    );
  }
}
