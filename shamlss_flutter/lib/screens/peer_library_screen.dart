import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../core/player.dart';
import '../core/theme.dart';

class PeerLibraryScreen extends StatefulWidget {
  final String peerBase;
  final String podId;
  final String memberName;
  final ShamlssPlayer player;

  const PeerLibraryScreen({
    super.key,
    required this.peerBase,
    required this.podId,
    required this.memberName,
    required this.player,
  });

  @override
  State<PeerLibraryScreen> createState() => _PeerLibraryScreenState();
}

class _PeerLibraryScreenState extends State<PeerLibraryScreen> {
  List<Map<String, dynamic>> _tracks = [];
  String _streamBase = '';
  bool _loading = false;
  String? _error;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text.toLowerCase()));
    _loadManifest();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadManifest() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await http.get(
        Uri.parse('${widget.peerBase}/pods/${widget.podId}/manifest'),
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _streamBase = data['stream_base'] as String? ?? widget.peerBase;
        final tracks = (data['tracks'] as List).map((t) {
          final m = Map<String, dynamic>.from(t as Map);
          m['_stream_base'] = _streamBase;
          if (m['art_hash'] != null) m['_art_url'] = '$_streamBase/library/art/${m['id']}';
          return m;
        }).toList();
        setState(() { _tracks = tracks; _loading = false; });
      } else {
        setState(() { _error = 'Server error ${res.statusCode}'; _loading = false; });
      }
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  List<Map<String, dynamic>> _filtered() {
    if (_query.isEmpty) return _tracks;
    return _tracks.where((t) =>
      (t['title'] ?? '').toLowerCase().contains(_query) ||
      (t['artist'] ?? '').toLowerCase().contains(_query) ||
      (t['album'] ?? '').toLowerCase().contains(_query)
    ).toList();
  }

  void _play(List<Map<String, dynamic>> tracks, int index) {
    if (tracks.isEmpty) return;
    final base = _streamBase;
    widget.player.playQueue(tracks, index, (id) => '$base/stream/$id');
  }

  Future<void> _addToQueue(Map<String, dynamic> track) async {
    await widget.player.addToQueue(track, '$_streamBase/stream/${track['id']}');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added: ${track['title'] ?? 'Unknown'}'), duration: const Duration(seconds: 1)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered();
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.memberName, style: const TextStyle(fontSize: 13, letterSpacing: 1)),
            if (!_loading && _error == null)
              Text('${_tracks.length} tracks', style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 10, letterSpacing: 1)),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _loadManifest),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: ShamlssColors.text, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search ${widget.memberName}\'s library…',
                hintStyle: const TextStyle(color: ShamlssColors.divider, fontSize: 12),
                prefixIcon: const Icon(Icons.search, color: ShamlssColors.divider, size: 16),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.clear, size: 16, color: ShamlssColors.textMuted), onPressed: _searchCtrl.clear)
                    : null,
                isDense: true,
                filled: true,
                fillColor: ShamlssColors.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.error_outline, color: ShamlssColors.textMuted, size: 32),
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 12), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  OutlinedButton(onPressed: _loadManifest, child: const Text('RETRY')),
                ]))
              : filtered.isEmpty
                  ? Center(child: Text(
                      _query.isNotEmpty ? 'No results' : '${widget.memberName} has no tracks in this pod',
                      style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 13),
                    ))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final t = filtered[i];
                        final artUrl = t['_art_url'] as String?;
                        final isCurrent = widget.player.current?['id'] == t['id'];
                        return ListTile(
                          dense: true,
                          leading: SizedBox(
                            width: 36, height: 36,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: artUrl != null
                                  ? Image.network(artUrl, fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const _ArtFallback())
                                  : const _ArtFallback(),
                            ),
                          ),
                          title: Text(
                            t['title'] ?? 'Unknown',
                            style: TextStyle(
                              color: isCurrent ? ShamlssColors.amber : ShamlssColors.text,
                              fontSize: 13,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [t['artist'], t['album']].where((s) => s != null && s != '').join(' · '),
                            style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            _fmtDuration(t['duration'] as int?),
                            style: const TextStyle(color: ShamlssColors.divider, fontSize: 11),
                          ),
                          onTap: () => _play(filtered, i),
                          onLongPress: () => _addToQueue(t),
                        );
                      },
                    ),
    );
  }

  static String _fmtDuration(int? ms) {
    if (ms == null) return '';
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

class _ArtFallback extends StatelessWidget {
  const _ArtFallback();
  @override
  Widget build(BuildContext context) => Container(
    color: ShamlssColors.surface,
    child: const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 16),
  );
}
