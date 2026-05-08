import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../core/daemon_client.dart';
import '../core/player.dart';
import '../core/theme.dart';

class PlaylistsScreen extends StatefulWidget {
  final DaemonClient daemon;
  final ShamlssPlayer player;
  const PlaylistsScreen({super.key, required this.daemon, required this.player});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  List<Map<String, dynamic>> _playlists = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final pl = await widget.daemon.getPlaylists();
    if (mounted) setState(() { _playlists = pl; _loading = false; });
  }

  Future<void> _create() async {
    final name = await _nameDialog(context, 'New Playlist');
    if (name == null) return;
    await widget.daemon.createPlaylist(name);
    await _load();
  }

  Future<void> _delete(String id) async {
    await widget.daemon.deletePlaylist(id);
    await _load();
  }

  Future<void> _import() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => _ImportDialog(),
    );
    if (result == null) return;
    try {
      final res = await http.post(
        Uri.parse('${widget.daemon.base}/library/import'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'csv': result['csv'], 'playlist_name': result['name']}),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final fmt = data['format'] == 'apple_music' ? 'Apple Music' : 'Spotify';
        final msg = '$fmt — ${data['indexed'] ?? 0} indexed, ${data['matched'] ?? 0} matched';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        await _load();
      }
    } catch (_) {}
  }

  Future<void> _open(Map<String, dynamic> pl) async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => PlaylistDetailScreen(
        daemon: widget.daemon, player: widget.player, playlistId: pl['id'] as String, title: pl['name'] as String,
      ),
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PLAYLISTS', style: TextStyle(letterSpacing: 3, fontSize: 14)),
        actions: [
          IconButton(icon: const Icon(Icons.upload_file_outlined, size: 20), tooltip: 'Import CSV', onPressed: _import),
          IconButton(icon: const Icon(Icons.add, size: 20), onPressed: _create),
          IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _load),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))
          : _playlists.isEmpty
              ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.queue_music_outlined, size: 48, color: ShamlssColors.divider),
                  SizedBox(height: 16),
                  Text('No playlists yet', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 14)),
                  SizedBox(height: 8),
                  Text('Tap + to create one', style: TextStyle(color: ShamlssColors.divider, fontSize: 12)),
                ]))
              : ListView.separated(
                  itemCount: _playlists.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final pl = _playlists[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.queue_music, color: ShamlssColors.amberDim, size: 20),
                      title: Text(pl['name'] as String, style: const TextStyle(color: ShamlssColors.text, fontSize: 13)),
                      subtitle: Text('${pl['track_count']} tracks', style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11)),
                      onTap: () => _open(pl),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, color: ShamlssColors.textMuted, size: 18),
                        onPressed: () => _delete(pl['id'] as String),
                      ),
                    );
                  },
                ),
    );
  }
}

class PlaylistDetailScreen extends StatefulWidget {
  final DaemonClient daemon;
  final ShamlssPlayer player;
  final String playlistId;
  final String title;
  const PlaylistDetailScreen({super.key, required this.daemon, required this.player, required this.playlistId, required this.title});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  Map<String, dynamic>? _playlist;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final pl = await widget.daemon.getPlaylist(widget.playlistId);
    if (mounted) setState(() { _playlist = pl; _loading = false; });
  }

  void _play(int index) {
    final tracks = List<Map<String, dynamic>>.from(_playlist!['tracks'] as List);
    widget.player.playQueue(tracks, index, widget.daemon.streamUrl, artUrlBuilder: widget.daemon.artUrl);
  }

  Future<void> _remove(String trackId) async {
    await widget.daemon.removeTrackFromPlaylist(widget.playlistId, trackId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _playlist == null ? <Map<String, dynamic>>[] : List<Map<String, dynamic>>.from(_playlist!['tracks'] as List);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(letterSpacing: 2, fontSize: 14)),
        actions: [
          if (tracks.isNotEmpty)
            IconButton(icon: const Icon(Icons.play_circle_outline, color: ShamlssColors.amber, size: 22), onPressed: () => _play(0)),
          if (tracks.isNotEmpty)
            IconButton(icon: const Icon(Icons.download_outlined, size: 20, color: ShamlssColors.textMuted), onPressed: () {
              final url = widget.daemon.playlistExportUrl(widget.playlistId);
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            }),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))
          : tracks.isEmpty
              ? const Center(child: Text('No tracks yet\nLong-press tracks in Library to add', textAlign: TextAlign.center, style: TextStyle(color: ShamlssColors.textMuted, fontSize: 13)))
              : ListView.separated(
                  itemCount: tracks.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final t = tracks[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 16),
                      title: Text(t['title'] ?? 'Unknown', style: const TextStyle(color: ShamlssColors.text, fontSize: 13), overflow: TextOverflow.ellipsis),
                      subtitle: Text([t['artist'], t['album']].where((x) => x != null).join(' — '), style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11), overflow: TextOverflow.ellipsis),
                      onTap: () => _play(i),
                      trailing: IconButton(icon: const Icon(Icons.remove_circle_outline, color: ShamlssColors.textMuted, size: 18), onPressed: () => _remove(t['id'] as String)),
                    );
                  },
                ),
    );
  }
}

class _ImportDialog extends StatelessWidget {
  final _csvCtrl = TextEditingController();
  final _nameCtrl = TextEditingController(text: 'Imported Playlist');
  _ImportDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: ShamlssColors.card,
      title: const Text('IMPORT CSV', style: TextStyle(color: ShamlssColors.text, fontSize: 13, letterSpacing: 2)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Supports Spotify and Apple Music exports.\nPaste CSV content below:', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 11)),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtrl,
            style: const TextStyle(color: ShamlssColors.text, fontSize: 12),
            decoration: const InputDecoration(labelText: 'Playlist name', labelStyle: TextStyle(color: ShamlssColors.textMuted, fontSize: 11)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _csvCtrl,
            maxLines: 6,
            style: const TextStyle(color: ShamlssColors.text, fontSize: 10, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: 'Paste CSV here…',
              hintStyle: TextStyle(color: ShamlssColors.divider, fontSize: 11),
              alignLabelWithHint: true,
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: ShamlssColors.textMuted))),
        TextButton(
          onPressed: () {
            final csv = _csvCtrl.text.trim();
            final name = _nameCtrl.text.trim();
            if (csv.isEmpty) return;
            Navigator.pop(context, {'csv': csv, 'name': name.isEmpty ? 'Imported Playlist' : name});
          },
          child: const Text('IMPORT', style: TextStyle(color: ShamlssColors.amber)),
        ),
      ],
    );
  }
}

Future<String?> _nameDialog(BuildContext context, String title) async {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: ShamlssColors.card,
      title: Text(title, style: const TextStyle(color: ShamlssColors.text, fontSize: 14, letterSpacing: 2)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: const TextStyle(color: ShamlssColors.text),
        decoration: const InputDecoration(hintText: 'Playlist name', hintStyle: TextStyle(color: ShamlssColors.textMuted)),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: ShamlssColors.textMuted))),
        TextButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Create', style: TextStyle(color: ShamlssColors.amber))),
      ],
    ),
  );
}
