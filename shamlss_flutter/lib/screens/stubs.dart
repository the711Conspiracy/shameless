import 'package:flutter/material.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});
  @override
  Widget build(BuildContext context) => const _Stub('Library', Icons.library_music);
}

class PodsScreen extends StatelessWidget {
  const PodsScreen({super.key});
  @override
  Widget build(BuildContext context) => const _Stub('Pods', Icons.group);
}

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});
  @override
  Widget build(BuildContext context) => const _Stub('Now Playing', Icons.headphones);
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) => const _Stub('Settings', Icons.settings);
}

class _Stub extends StatelessWidget {
  final String label;
  final IconData icon;
  const _Stub(this.label, this.icon);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(label)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            Text(label, style: const TextStyle(color: Colors.white38)),
          ],
        ),
      ),
    );
  }
}
