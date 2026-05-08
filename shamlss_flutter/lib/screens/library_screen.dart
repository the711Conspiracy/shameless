import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/daemon_client.dart';
import '../core/player.dart';
import '../core/theme.dart';
class LibraryScreen extends StatefulWidget {
  final DaemonClient daemon;
  final ShamlssPlayer player;
  const LibraryScreen({super.key, required this.daemon, required this.player});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

const int _kTracks = 0;

class _LibraryScreenState extends State<LibraryScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  StreamSubscription? _librarySub;
  List<Map<String, dynamic>> _tracks = [];
  List<String> _folders = [];
  List<Map<String, dynamic>> _history = [];
  bool _loading = false;
  bool _searching = false;
  bool _showHistory = false;
  final _folderController = TextEditingController();
  final _searchController = TextEditingController();
  String _query = '';
  final bool _isMobile = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() => setState(() {}));
    _searchController.addListener(() => setState(() => _query = _searchController.text));
    _librarySub = widget.daemon.onLibraryUpdated.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    _librarySub?.cancel();
    _tabController.dispose();
    _folderController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      widget.daemon.getTracks(),
      if (!_isMobile) widget.daemon.getFolders() else Future.value(<String>[]),
      widget.daemon.getHistory(limit: 10),
    ]);
    if (mounted) setState(() {
      _tracks = results[0] as List<Map<String, dynamic>>;
      _folders = results[1] as List<String>;
      _history = results[2] as List<Map<String, dynamic>>;
      _loading = false;
    });
  }

  Future<void> _addFolder() async {
    final p = _folderController.text.trim();
    if (p.isEmpty) return;
    setState(() => _loading = true);
    try {
      final result = await widget.daemon.addFolder(p);
      _folderController.clear();
      final indexed = result['indexed'] ?? 0;
      final found = result['files_found'] ?? 0;
      final skipped = result['skipped'] ?? 0;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Indexed $indexed of $found files${skipped > 0 ? " ($skipped skipped)" : ""}'),
          backgroundColor: indexed > 0 ? const Color(0xFF166534) : const Color(0xFF78350f),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Scan failed: $e'),
          backgroundColor: Colors.red.shade900,
        ));
        setState(() => _loading = false);
        return;
      }
    }
    await _load();
  }

  Future<void> _onLongPress(Map<String, dynamic> track) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ShamlssColors.card,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(track['title'] as String? ?? 'Unknown', style: const TextStyle(color: ShamlssColors.text, fontSize: 13, fontWeight: FontWeight.w600)),
              if (track['artist'] != null) Text(track['artist'] as String, style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11)),
            ])),
          ]),
        ),
        const Divider(height: 1),
        ListTile(dense: true, leading: const Icon(Icons.playlist_add, color: ShamlssColors.amberDim, size: 18),
          title: const Text('Add to playlist', style: TextStyle(color: ShamlssColors.text, fontSize: 13)),
          onTap: () => Navigator.pop(context, 'playlist')),
        ListTile(dense: true, leading: const Icon(Icons.add_to_queue, color: ShamlssColors.amberDim, size: 18),
          title: const Text('Add to shared queue', style: TextStyle(color: ShamlssColors.text, fontSize: 13)),
          onTap: () => Navigator.pop(context, 'shared_queue')),
        ListTile(dense: true, leading: const Icon(Icons.skip_next_outlined, color: ShamlssColors.textMuted, size: 18),
          title: const Text('Play next', style: TextStyle(color: ShamlssColors.text, fontSize: 13)),
          onTap: () => Navigator.pop(context, 'play_next')),
        ListTile(dense: true, leading: const Icon(Icons.podcasts_outlined, color: ShamlssColors.textMuted, size: 18),
          title: Text(track['type'] == 'podcast' ? 'Unmark podcast' : 'Mark as Podcast', style: const TextStyle(color: ShamlssColors.text, fontSize: 13)),
          onTap: () => Navigator.pop(context, 'mark_podcast')),
        ListTile(dense: true, leading: const Icon(Icons.menu_book_outlined, color: ShamlssColors.textMuted, size: 18),
          title: Text(track['type'] == 'audiobook' ? 'Unmark audiobook' : 'Mark as Audiobook', style: const TextStyle(color: ShamlssColors.text, fontSize: 13)),
          onTap: () => Navigator.pop(context, 'mark_audiobook')),
        const SizedBox(height: 8),
      ]),
    );
    if (action == null || !mounted) return;

    if (action == 'play_next') {
      await widget.player.addToQueue(track, widget.daemon.streamUrl(track['id'] as String));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to queue'), duration: Duration(seconds: 2)));
      return;
    }

    if (action == 'mark_podcast' || action == 'mark_audiobook') {
      final targetType = action == 'mark_podcast' ? 'podcast' : 'audiobook';
      final newType = track['type'] == targetType ? null : targetType;
      final res = await widget.daemon.patch('/library/tracks/${track['id']}', {'type': newType});
      if (!mounted) return;
      if (res != null) {
        setState(() { track['type'] = newType; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(newType == null ? 'Type cleared' : 'Marked as $newType'),
          duration: const Duration(seconds: 2),
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Update failed'),
          duration: Duration(seconds: 2),
        ));
      }
      return;
    }

    if (action == 'shared_queue') {
      final ok = await widget.daemon.addToCollabQueue(track['id'] as String, addedBy: widget.daemon.nodeName);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Added to shared queue' : 'Failed to add to shared queue'),
        duration: const Duration(seconds: 2),
      ));
      return;
    }

    if (action == 'playlist') {
      final playlists = await widget.daemon.getPlaylists();
      if (!mounted) return;
      if (playlists.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No playlists — create one in the Playlists tab')));
        return;
      }
      final chosen = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        backgroundColor: ShamlssColors.card,
        builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('ADD TO PLAYLIST', style: TextStyle(color: ShamlssColors.amberDim, fontSize: 11, letterSpacing: 2))),
          ...playlists.map((pl) => ListTile(
            dense: true,
            leading: const Icon(Icons.queue_music, color: ShamlssColors.amberDim, size: 18),
            title: Text(pl['name'] as String, style: const TextStyle(color: ShamlssColors.text, fontSize: 13)),
            onTap: () => Navigator.pop(context, pl),
          )),
          const SizedBox(height: 16),
        ]),
      );
      if (chosen == null || !mounted) return;
      await widget.daemon.addTrackToPlaylist(chosen['id'] as String, track['id'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added to ${chosen['name']}')));
    }
  }

  void _play(int indexInFiltered) {
    final filtered = _filteredTracks();
    final track = filtered[indexInFiltered];
    final globalIndex = _tracks.indexWhere((t) => t['id'] == track['id']);
    widget.player.playQueue(_tracks, globalIndex >= 0 ? globalIndex : 0, widget.daemon.streamUrl, artUrlBuilder: widget.daemon.artUrl);
  }

  List<Map<String, dynamic>> _filteredTracks() {
    if (_query.isEmpty) return _tracks;
    final q = _query.toLowerCase();
    return _tracks.where((t) {
      return (t['title'] as String? ?? '').toLowerCase().contains(q) ||
             (t['artist'] as String? ?? '').toLowerCase().contains(q) ||
             (t['album'] as String? ?? '').toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredTracks();
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: ShamlssColors.text, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'Search tracks…',
                  hintStyle: TextStyle(color: ShamlssColors.textMuted),
                  border: InputBorder.none,
                ),
              )
            : Row(children: [
                const Text('LIBRARY', style: TextStyle(letterSpacing: 3, fontSize: 14)),
                const SizedBox(width: 12),
                Text('${_tracks.length} tracks', style: const TextStyle(color: ShamlssColors.amberDim, fontSize: 12, fontWeight: FontWeight.normal)),
              ]),
        bottom: _searching ? null : TabBar(
          controller: _tabController,
          labelColor: ShamlssColors.amber,
          unselectedLabelColor: ShamlssColors.textMuted,
          indicatorColor: ShamlssColors.amber,
          labelStyle: const TextStyle(fontSize: 11, letterSpacing: 1.5),
          tabs: const [Tab(text: 'TRACKS'), Tab(text: 'ARTISTS'), Tab(text: 'ALBUMS')],
        ),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search, size: 18),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) { _searchController.clear(); _query = ''; }
            }),
          ),
          if (!_searching) IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _load),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.daemon,
        builder: (context, child) {
          final activePod = widget.daemon.activePod;
          return Column(children: [
            if (activePod != null) _PodContextBanner(podName: activePod['name'] as String),
            child!,
          ]);
        },
        child: Column(children: [
        if (!_isMobile) _FolderBar(controller: _folderController, folders: _folders, onAdd: _addFolder, onRemove: (f) async {
          try {
            await widget.daemon.removeFolder(f);
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Removed: $f'), duration: const Duration(seconds: 2)));
          } catch (e) {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Remove failed: $e'), backgroundColor: Colors.red.shade900));
          }
          _load();
        }),
        if (!_isMobile) const Divider(),
        if (_history.isNotEmpty && !_searching && _tabController.index == _kTracks) _HistoryBar(
          history: _history, daemon: widget.daemon, show: _showHistory,
          onToggle: () => setState(() => _showHistory = !_showHistory),
          onTap: (t) {
            final globalIndex = _tracks.indexWhere((tr) => tr['id'] == t['id']);
            if (globalIndex >= 0) widget.player.playQueue(_tracks, globalIndex, widget.daemon.streamUrl);
          },
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))
              : _searching
                  ? (filtered.isEmpty
                      ? _Empty(isMobile: _isMobile, isSearch: true)
                      : _TrackList(tracks: filtered, currentId: widget.player.current?['id'], daemon: widget.daemon, onTap: _play, onLongPress: _onLongPress))
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        // TRACKS
                        _tracks.isEmpty
                            ? _Empty(isMobile: _isMobile, isSearch: false)
                            : _TrackList(tracks: _tracks, currentId: widget.player.current?['id'], daemon: widget.daemon, onTap: (i) => widget.player.playQueue(_tracks, i, widget.daemon.streamUrl, artUrlBuilder: widget.daemon.artUrl), onLongPress: _onLongPress),
                        // ARTISTS
                        _ArtistView(tracks: _tracks, daemon: widget.daemon, player: widget.player),
                        // ALBUMS
                        _AlbumView(tracks: _tracks, daemon: widget.daemon, player: widget.player),
                      ],
                    ),
        ),
      ]),
      ),
    );
  }
}

class _PodContextBanner extends StatelessWidget {
  final String podName;
  const _PodContextBanner({required this.podName});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: ShamlssColors.amberDim.withOpacity(0.12),
      child: Row(children: [
        const Icon(Icons.group, color: ShamlssColors.amber, size: 14),
        const SizedBox(width: 8),
        Expanded(child: Text('Pod: $podName', style: const TextStyle(color: ShamlssColors.amber, fontSize: 12, letterSpacing: 0.5))),
      ]),
    );
  }
}

class _FolderBar extends StatelessWidget {
  final TextEditingController controller;
  final List<String> folders;
  final VoidCallback onAdd;
  final Function(String) onRemove;
  const _FolderBar({required this.controller, required this.folders, required this.onAdd, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ShamlssColors.navy,
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: TextField(
            controller: controller,
            style: const TextStyle(color: ShamlssColors.text, fontSize: 13, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: 'C:\\Users\\you\\Music',
              hintStyle: TextStyle(color: ShamlssColors.textMuted, fontSize: 12),
              prefixIcon: Icon(Icons.folder_outlined, color: ShamlssColors.amberDim, size: 18),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            ),
            onSubmitted: (_) => onAdd(),
          )),
          const SizedBox(width: 8),
          FilledButton(onPressed: onAdd, style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)), child: const Text('ADD', style: TextStyle(fontSize: 12, letterSpacing: 1.5))),
        ]),
        if (folders.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: folders.map((f) => _Chip(path: f, onRemove: () => onRemove(f))).toList()),
        ],
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final String path;
  final VoidCallback onRemove;
  const _Chip({required this.path, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: ShamlssColors.surface, border: Border.all(color: ShamlssColors.amberDim.withOpacity(0.4)), borderRadius: BorderRadius.circular(4)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.folder, color: ShamlssColors.amberDim, size: 12),
        const SizedBox(width: 6),
        Text(path.length > 28 ? '...${path.substring(path.length - 28)}' : path, style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11, fontFamily: 'monospace')),
        const SizedBox(width: 6),
        GestureDetector(onTap: onRemove, child: const Icon(Icons.close, color: ShamlssColors.textMuted, size: 12)),
      ]),
    );
  }
}

class _TrackList extends StatelessWidget {
  final List<Map<String, dynamic>> tracks;
  final String? currentId;
  final DaemonClient daemon;
  final Function(int) onTap;
  final Function(Map<String, dynamic>)? onLongPress;
  const _TrackList({required this.tracks, required this.currentId, required this.daemon, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: tracks.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = tracks[i];
        final active = t['id'] == currentId;
        final hasArt = t['art_hash'] != null;
        return ListTile(
          dense: true,
          onTap: () => onTap(i),
          onLongPress: onLongPress != null ? () => onLongPress!(t) : null,
          leading: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: active ? ShamlssColors.amberDim.withOpacity(0.2) : ShamlssColors.surface,
              border: Border.all(color: active ? ShamlssColors.amber : ShamlssColors.divider),
              borderRadius: BorderRadius.circular(4),
            ),
            child: hasArt
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Image.network(daemon.artUrl(t['id'] as String), fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(active ? Icons.graphic_eq : Icons.music_note, color: active ? ShamlssColors.amber : ShamlssColors.amberDim, size: 16)),
                  )
                : Icon(active ? Icons.graphic_eq : Icons.music_note, color: active ? ShamlssColors.amber : ShamlssColors.amberDim, size: 16),
          ),
          title: Text(t['title'] ?? 'Unknown', style: TextStyle(color: active ? ShamlssColors.amber : ShamlssColors.text, fontSize: 13), overflow: TextOverflow.ellipsis),
          subtitle: Text([t['artist'], t['album']].where((x) => x != null).join(' — '), style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11), overflow: TextOverflow.ellipsis),
          trailing: Text(t['format']?.toString().toUpperCase() ?? '', style: const TextStyle(color: ShamlssColors.amberDim, fontSize: 10, letterSpacing: 1)),
        );
      },
    );
  }
}

class _HistoryBar extends StatelessWidget {
  final List<Map<String, dynamic>> history;
  final DaemonClient daemon;
  final bool show;
  final VoidCallback onToggle;
  final Function(Map<String, dynamic>) onTap;
  const _HistoryBar({required this.history, required this.daemon, required this.show, required this.onToggle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      InkWell(
        onTap: onToggle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: ShamlssColors.surface,
          child: Row(children: [
            const Icon(Icons.history, color: ShamlssColors.amberDim, size: 14),
            const SizedBox(width: 8),
            const Text('RECENTLY PLAYED', style: TextStyle(color: ShamlssColors.amberDim, fontSize: 10, letterSpacing: 2)),
            const Spacer(),
            Icon(show ? Icons.expand_less : Icons.expand_more, color: ShamlssColors.divider, size: 16),
          ]),
        ),
      ),
      if (show) SizedBox(
        height: 80,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: history.length,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemBuilder: (_, i) {
            final t = history[i];
            return GestureDetector(
              onTap: () => onTap(t),
              child: Container(
                width: 60, margin: const EdgeInsets.only(right: 8),
                child: Column(children: [
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(color: ShamlssColors.card, borderRadius: BorderRadius.circular(4)),
                    child: t['art_hash'] != null
                        ? ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.network(daemon.artUrl(t['id'] as String), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 20)))
                        : const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 20),
                  ),
                  const SizedBox(height: 4),
                  Text(t['title'] ?? '?', style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 9), overflow: TextOverflow.ellipsis, maxLines: 1),
                ]),
              ),
            );
          },
        ),
      ),
      const Divider(height: 1),
    ]);
  }
}

class _Empty extends StatelessWidget {
  final bool isMobile;
  final bool isSearch;
  const _Empty({required this.isMobile, required this.isSearch});

  @override
  Widget build(BuildContext context) {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(isSearch ? Icons.search_off : Icons.library_music_outlined, size: 48, color: ShamlssColors.divider),
      const SizedBox(height: 16),
      Text(isSearch ? 'No matches' : 'No tracks indexed', style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 14)),
      const SizedBox(height: 8),
      if (!isSearch) Text(isMobile ? 'Add folders from the PC app first' : 'Add a folder above to scan your music', style: const TextStyle(color: ShamlssColors.divider, fontSize: 12)),
    ]));
  }
}

class _ArtistView extends StatefulWidget {
  final List<Map<String, dynamic>> tracks;
  final DaemonClient daemon;
  final ShamlssPlayer player;
  const _ArtistView({required this.tracks, required this.daemon, required this.player});

  @override
  State<_ArtistView> createState() => _ArtistViewState();
}

class _ArtistViewState extends State<_ArtistView> {
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    // Group by artist
    final Map<String, List<Map<String, dynamic>>> byArtist = {};
    for (final t in widget.tracks) {
      final a = t['artist'] as String? ?? 'Unknown Artist';
      (byArtist[a] ??= []).add(t);
    }
    final artists = byArtist.keys.toList()..sort();

    return ListView.builder(
      itemCount: artists.length,
      itemBuilder: (_, i) {
        final artist = artists[i];
        final artistTracks = byArtist[artist]!;
        final expanded = _expanded.contains(artist);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: () => setState(() { expanded ? _expanded.remove(artist) : _expanded.add(artist); }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                const Icon(Icons.person, color: ShamlssColors.amberDim, size: 16),
                const SizedBox(width: 12),
                Expanded(child: Text(artist, style: const TextStyle(color: ShamlssColors.text, fontSize: 13))),
                Text('${artistTracks.length}', style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11)),
                const SizedBox(width: 8),
                Icon(expanded ? Icons.expand_less : Icons.expand_more, color: ShamlssColors.divider, size: 16),
              ]),
            ),
          ),
          if (expanded) ...artistTracks.asMap().entries.map((e) {
            final idx = e.key;
            final t = e.value;
            return ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 44, right: 16),
              leading: const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 14),
              title: Text(t['title'] ?? 'Unknown', style: const TextStyle(color: ShamlssColors.text, fontSize: 12), overflow: TextOverflow.ellipsis),
              subtitle: Text(t['album'] ?? '', style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 10), overflow: TextOverflow.ellipsis),
              onTap: () => widget.player.playQueue(artistTracks, idx, widget.daemon.streamUrl, artUrlBuilder: widget.daemon.artUrl),
            );
          }),
          const Divider(height: 1),
        ]);
      },
    );
  }
}

class _AlbumView extends StatelessWidget {
  final List<Map<String, dynamic>> tracks;
  final DaemonClient daemon;
  final ShamlssPlayer player;
  const _AlbumView({required this.tracks, required this.daemon, required this.player});

  @override
  Widget build(BuildContext context) {
    final Map<String, List<Map<String, dynamic>>> byAlbum = {};
    for (final t in tracks) {
      final a = t['album'] as String? ?? 'Unknown Album';
      (byAlbum[a] ??= []).add(t);
    }
    final albums = byAlbum.keys.toList()..sort();

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 0.85,
      ),
      itemCount: albums.length,
      itemBuilder: (_, i) {
        final album = albums[i];
        final albumTracks = byAlbum[album]!;
        final firstWithArt = albumTracks.firstWhere((t) => t['art_hash'] != null, orElse: () => albumTracks.first);
        final hasArt = firstWithArt['art_hash'] != null;

        return GestureDetector(
          onTap: () {
            player.playQueue(albumTracks, 0, daemon.streamUrl, artUrlBuilder: daemon.artUrl);
          },
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(color: ShamlssColors.surface, border: Border.all(color: ShamlssColors.divider), borderRadius: BorderRadius.circular(8)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: hasArt
                      ? Image.network(daemon.artUrl(firstWithArt['id'] as String), fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.album, color: ShamlssColors.amberDim, size: 40))
                      : const Icon(Icons.album, color: ShamlssColors.amberDim, size: 40),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(album, style: const TextStyle(color: ShamlssColors.text, fontSize: 12), overflow: TextOverflow.ellipsis, maxLines: 1),
            Text('${albumTracks.length} tracks', style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 10)),
          ]),
        );
      },
    );
  }
}
