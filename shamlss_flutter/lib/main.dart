import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  @override
  void initState() {
    super.initState();
    _daemon.init();
    _sleepTimer = SleepTimer(_player.player);
    _player.bpmProvider = (id) async => (await _daemon.getAnalysis(id))?['bpm']?.toDouble();
    _player.addListener(() => setState(() {}));
    _sleepTimer.addListener(() => setState(() {}));
    _daemon.addListener(_onDaemonChanged);
    _errorSub = _daemon.errors.listen(_onDaemonError);
    _tryAutoConnect();
  }

  void _onDaemonError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12)),
      backgroundColor: const Color(0xFF1e2d47),
      duration: const Duration(seconds: 5),
      action: SnackBarAction(label: 'OK', textColor: Color(0xFFf59e0b), onPressed: () =>
          ScaffoldMessenger.of(context).hideCurrentSnackBar()),
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
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _daemon.removeListener(_onDaemonChanged);
    _sleepTimer.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _daemon,
      builder: (context, _) {
        if (!_daemon.connected) return ConnectScreen(daemon: _daemon);
        return Scaffold(
          body: IndexedStack(
            index: _index,
            children: [
              LibraryScreen(daemon: _daemon, player: _player),
              PlaylistsScreen(daemon: _daemon, player: _player),
              NowPlayingScreen(player: _player, daemon: _daemon),
              PodsScreen(daemon: _daemon, player: _player),
              HistoryScreen(daemon: _daemon, player: _player),
              SettingsScreen(daemon: _daemon, sleepTimer: _sleepTimer, player: _player),
            ],
          ),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_player.current != null) _MiniPlayer(player: _player, daemon: _daemon, onTap: () => setState(() => _index = 2)), // index 2 = Now Playing
              NavigationBar(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Library'),
                  NavigationDestination(icon: Icon(Icons.queue_music_outlined), selectedIcon: Icon(Icons.queue_music), label: 'Playlists'),
                  NavigationDestination(icon: Icon(Icons.graphic_eq_outlined), selectedIcon: Icon(Icons.graphic_eq), label: 'Playing'),
                  NavigationDestination(icon: Icon(Icons.group_outlined), selectedIcon: Icon(Icons.group), label: 'Pods'),
                  NavigationDestination(icon: Icon(Icons.history_outlined), selectedIcon: Icon(Icons.history), label: 'History'),
                  NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune), label: 'Settings'),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MiniPlayer extends StatelessWidget {
  final ShamlssPlayer player;
  final DaemonClient daemon;
  final VoidCallback onTap;
  const _MiniPlayer({required this.player, required this.daemon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = player.current!;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 56,
        color: ShamlssColors.card,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          _MiniArt(artUrl: t['_art_url'] as String? ?? (t['art_hash'] != null ? daemon.artUrl(t['id'] as String) : null)),
          const SizedBox(width: 12),
          Expanded(child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t['title'] ?? 'Unknown', style: const TextStyle(color: ShamlssColors.text, fontSize: 12), overflow: TextOverflow.ellipsis),
              if (t['artist'] != null) Text(t['artist'], style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11), overflow: TextOverflow.ellipsis),
            ],
          )),
          StreamBuilder<PlayerState>(
            stream: player.stateStream,
            builder: (_, snap) {
              final playing = snap.data?.playing ?? false;
              return Row(children: [
                IconButton(icon: Icon(playing ? Icons.pause : Icons.play_arrow, color: ShamlssColors.amber), onPressed: player.playPause, iconSize: 24),
                IconButton(icon: const Icon(Icons.skip_next, color: ShamlssColors.textMuted), onPressed: player.skipNext, iconSize: 22),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}

class _MiniArt extends StatelessWidget {
  final String? artUrl;
  const _MiniArt({this.artUrl});

  @override
  Widget build(BuildContext context) {
    if (artUrl == null) return const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 18);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Image.network(artUrl!, width: 36, height: 36, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 18)),
    );
  }
}
