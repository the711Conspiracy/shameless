import 'package:flutter/material.dart';
import '../core/daemon_client.dart';
import '../core/player.dart';
import '../core/theme.dart';

class HistoryScreen extends StatefulWidget {
  final DaemonClient daemon;
  final ShamlssPlayer player;
  const HistoryScreen({super.key, required this.daemon, required this.player});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final data = await widget.daemon.get('/history?limit=100');
    if (!mounted) return;
    setState(() {
      _items = data is List ? List<Map<String, dynamic>>.from(data) : <Map<String, dynamic>>[];
      _loading = false;
    });
  }

  String _timeAgo(int? tsMs) {
    if (tsMs == null) return '';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(tsMs));
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${(diff.inDays / 30).floor()}mo ago';
  }

  void _playTrack(Map<String, dynamic> item) {
    final track = {
      'id': item['id'],
      'title': item['title'],
      'artist': item['artist'],
      'album': item['album'],
      'art_hash': item['art_hash'],
    };
    widget.player.playQueue([track], 0, widget.daemon.streamUrl, artUrlBuilder: widget.daemon.artUrl);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LISTENING HISTORY', style: TextStyle(letterSpacing: 3, fontSize: 14)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _load),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))
          : RefreshIndicator(
              color: ShamlssColors.amber,
              onRefresh: _load,
              child: _items.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 80),
                      Center(child: Icon(Icons.history, size: 48, color: ShamlssColors.divider)),
                      SizedBox(height: 16),
                      Center(child: Text('No history yet', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 14))),
                      SizedBox(height: 8),
                      Center(child: Text('Tracks you play will appear here', style: TextStyle(color: ShamlssColors.divider, fontSize: 12))),
                    ])
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final item = _items[i];
                        final id = item['id'] as String?;
                        final hasArt = item['art_hash'] != null && id != null;
                        return ListTile(
                          dense: true,
                          onTap: id == null ? null : () => _playTrack(item),
                          leading: Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(
                              color: ShamlssColors.surface,
                              border: Border.all(color: ShamlssColors.divider),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: hasArt
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: Image.network(
                                      widget.daemon.artUrl(id),
                                      width: 40, height: 40, fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 18),
                                    ),
                                  )
                                : const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 18),
                          ),
                          title: Text(
                            item['title'] as String? ?? 'Unknown',
                            style: const TextStyle(color: ShamlssColors.text, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            item['artist'] as String? ?? '—',
                            style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            _timeAgo(item['played_ts'] as int?),
                            style: const TextStyle(color: ShamlssColors.amberDim, fontSize: 11),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
