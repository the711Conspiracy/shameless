import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
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

// Tab index for tracks (artists and albums are 1 and 2, accessed by TabController directly)
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
  final bool _isMobile = defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

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
      final found   = result['files_found'] ?? 0;
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
    final tints = SleeveTintsProvider.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: tints.surface,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(track['title'] as String? ?? 'Unknown',
                  style: GoogleFonts.interTight(color: tints.text, fontSize: 13, fontWeight: FontWeight.w600)),
              if (track['artist'] != null)
                Text(track['artist'] as String,
                    style: GoogleFonts.interTight(color: tints.textMute, fontSize: 11)),
            ])),
          ]),
        ),
        Divider(height: 1, color: tints.line),
        ListTile(dense: true,
          leading: Icon(Icons.playlist_add, color: tints.accent, size: 18),
          title: Text('Add to playlist', style: GoogleFonts.interTight(color: tints.text, fontSize: 13)),
          onTap: () => Navigator.pop(context, 'playlist')),
        ListTile(dense: true,
          leading: Icon(Icons.add_to_queue, color: tints.accent, size: 18),
          title: Text('Add to shared queue', style: GoogleFonts.interTight(color: tints.text, fontSize: 13)),
          onTap: () => Navigator.pop(context, 'shared_queue')),
        ListTile(dense: true,
          leading: Icon(Icons.skip_next_outlined, color: tints.textMute, size: 18),
          title: Text('Play next', style: GoogleFonts.interTight(color: tints.text, fontSize: 13)),
          onTap: () => Navigator.pop(context, 'play_next')),
        ListTile(dense: true,
          leading: Icon(Icons.podcasts_outlined, color: tints.textMute, size: 18),
          title: Text(
            track['type'] == 'podcast' ? 'Unmark podcast' : 'Mark as Podcast',
            style: GoogleFonts.interTight(color: tints.text, fontSize: 13),
          ),
          onTap: () => Navigator.pop(context, 'mark_podcast')),
        ListTile(dense: true,
          leading: Icon(Icons.menu_book_outlined, color: tints.textMute, size: 18),
          title: Text(
            track['type'] == 'audiobook' ? 'Unmark audiobook' : 'Mark as Audiobook',
            style: GoogleFonts.interTight(color: tints.text, fontSize: 13),
          ),
          onTap: () => Navigator.pop(context, 'mark_audiobook')),
        const SizedBox(height: 8),
      ]),
    );
    if (action == null || !mounted) return;

    if (action == 'play_next') {
      await widget.player.addToQueue(track, widget.daemon.streamUrl(track['id'] as String));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Added to queue'), duration: Duration(seconds: 2)));
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
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Update failed'), duration: Duration(seconds: 2)));
      }
      return;
    }

    if (action == 'shared_queue') {
      final ok = await widget.daemon.addToCollabQueue(
          track['id'] as String, addedBy: widget.daemon.nodeName);
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
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No playlists — create one in the Playlists tab')));
        return;
      }
      final tints2 = SleeveTintsProvider.of(context);
      final chosen = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        backgroundColor: tints2.surface,
        builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('ADD TO PLAYLIST',
                style: GoogleFonts.jetBrainsMono(color: tints2.textMute, fontSize: 11, letterSpacing: 0.18)),
          ),
          ...playlists.map((pl) => ListTile(
            dense: true,
            leading: Icon(Icons.queue_music, color: tints2.accent, size: 18),
            title: Text(pl['name'] as String,
                style: GoogleFonts.interTight(color: tints2.text, fontSize: 13)),
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
    widget.player.playQueue(
        _tracks, globalIndex >= 0 ? globalIndex : 0, widget.daemon.streamUrl,
        artUrlBuilder: widget.daemon.artUrl);
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
    final tints = SleeveTintsProvider.of(context);
    final filtered = _filteredTracks();

    return Scaffold(
      backgroundColor: tints.base,
      appBar: AppBar(
        backgroundColor: tints.base,
        elevation: 0,
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: GoogleFonts.interTight(color: tints.text, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search tracks…',
                  hintStyle: GoogleFonts.interTight(color: tints.textMute),
                  border: InputBorder.none,
                ),
              )
            : null,
        bottom: _searching
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Container(height: 1, color: tints.line),
              ),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search, size: 18, color: tints.textMute),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) { _searchController.clear(); _query = ''; }
            }),
          ),
          if (!_searching)
            IconButton(
                icon: Icon(Icons.refresh, size: 18, color: tints.textMute),
                onPressed: _load),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.daemon,
        builder: (context, child) {
          final activePod = widget.daemon.activePod;
          return Column(children: [
            if (activePod != null)
              _PodContextBanner(podName: activePod['name'] as String, tints: tints),
            Expanded(child: child!),
          ]);
        },
        child: Column(children: [
          // ── Sleeve editorial header ──
          if (!_searching)
            _LibraryHeader(trackCount: _tracks.length, tints: tints),

          // ── Desktop folder bar ──
          if (!_isMobile)
            _FolderBar(
              controller: _folderController,
              folders: _folders,
              tints: tints,
              onAdd: _addFolder,
              onRemove: (f) async {
                try {
                  await widget.daemon.removeFolder(f);
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Removed: $f'), duration: const Duration(seconds: 2)));
                } catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Remove failed: $e'), backgroundColor: Colors.red.shade900));
                }
                _load();
              },
            ),

          if (!_isMobile)
            Divider(height: 1, color: tints.line),

          // ── Mono filter tabs ──
          if (!_searching)
            _FilterTabs(tabController: _tabController, tints: tints),

          // ── History bar ──
          if (_history.isNotEmpty && !_searching && _tabController.index == _kTracks)
            _HistoryBar(
              history: _history,
              daemon: widget.daemon,
              show: _showHistory,
              tints: tints,
              onToggle: () => setState(() => _showHistory = !_showHistory),
              onTap: (t) {
                final globalIndex = _tracks.indexWhere((tr) => tr['id'] == t['id']);
                if (globalIndex >= 0)
                  widget.player.playQueue(_tracks, globalIndex, widget.daemon.streamUrl);
              },
            ),

          // ── Tab content ──
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: tints.accent, strokeWidth: 2))
                : _searching
                    ? (filtered.isEmpty
                        ? _Empty(isMobile: _isMobile, isSearch: true, tints: tints)
                        : _TrackList(
                            tracks: filtered,
                            currentId: widget.player.current?['id'],
                            daemon: widget.daemon,
                            tints: tints,
                            onTap: _play,
                            onLongPress: _onLongPress))
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          // TRACKS
                          _tracks.isEmpty
                              ? _Empty(isMobile: _isMobile, isSearch: false, tints: tints)
                              : _TrackList(
                                  tracks: _tracks,
                                  currentId: widget.player.current?['id'],
                                  daemon: widget.daemon,
                                  tints: tints,
                                  onTap: (i) => widget.player.playQueue(
                                      _tracks, i, widget.daemon.streamUrl,
                                      artUrlBuilder: widget.daemon.artUrl),
                                  onLongPress: _onLongPress),
                          // ARTISTS
                          _ArtistView(tracks: _tracks, daemon: widget.daemon, player: widget.player, tints: tints),
                          // ALBUMS
                          _AlbumGrid(tracks: _tracks, daemon: widget.daemon, player: widget.player, tints: tints),
                        ],
                      ),
          ),
        ]),
      ),
    );
  }
}

// ─── Library header ────────────────────────────────────────────────────────

class _LibraryHeader extends StatelessWidget {
  final int trackCount;
  final SleeveTints tints;
  const _LibraryHeader({required this.trackCount, required this.tints});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Eyebrow mono
        Text(
          '──── COLLECTION',
          style: GoogleFonts.jetBrainsMono(
            color: tints.textDim,
            fontSize: 10,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.18,
          ),
        ),
        const SizedBox(height: 6),
        // Newsreader 42 title
        Text(
          'The Library',
          style: GoogleFonts.newsreader(
            color: tints.text,
            fontSize: 42,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.022,
          ),
        ),
        const SizedBox(height: 4),
        // Italic body subtitle
        Text(
          '$trackCount tracks in collection',
          style: GoogleFonts.interTight(
            color: tints.textMute,
            fontSize: 14,
            fontStyle: FontStyle.italic,
          ),
        ),
      ]),
    );
  }
}

// ─── Filter tabs ──────────────────────────────────────────────────────────

class _FilterTabs extends StatelessWidget {
  final TabController tabController;
  final SleeveTints tints;
  const _FilterTabs({required this.tabController, required this.tints});

  static const _tabs = ['TRACKS', 'ARTISTS', 'ALBUMS'];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tints.line, width: 1)),
      ),
      child: TabBar(
        controller: tabController,
        isScrollable: true,
        labelColor: tints.accent,
        unselectedLabelColor: tints.textDim,
        indicatorColor: tints.accent,
        indicatorWeight: 2,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: GoogleFonts.jetBrainsMono(
          fontSize: 9,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.14,
        ),
        unselectedLabelStyle: GoogleFonts.jetBrainsMono(
          fontSize: 9,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.14,
        ),
        tabs: _tabs.map((t) => Tab(text: t, height: 36)).toList(),
      ),
    );
  }
}

// ─── Pod context banner ────────────────────────────────────────────────────

class _PodContextBanner extends StatelessWidget {
  final String podName;
  final SleeveTints tints;
  const _PodContextBanner({required this.podName, required this.tints});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: tints.accentSoft,
      child: Row(children: [
        Icon(Icons.group, color: tints.accent, size: 14),
        const SizedBox(width: 8),
        Expanded(child: Text('Pod: $podName',
            style: GoogleFonts.interTight(color: tints.accent, fontSize: 12))),
      ]),
    );
  }
}

// ─── Desktop folder bar ────────────────────────────────────────────────────

class _FolderBar extends StatelessWidget {
  final TextEditingController controller;
  final List<String> folders;
  final SleeveTints tints;
  final VoidCallback onAdd;
  final Function(String) onRemove;
  const _FolderBar({
    required this.controller,
    required this.folders,
    required this.tints,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: tints.surface,
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: TextField(
            controller: controller,
            style: GoogleFonts.jetBrainsMono(color: tints.text, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'C:\\Users\\you\\Music',
              hintStyle: GoogleFonts.jetBrainsMono(color: tints.textMute, fontSize: 12),
              prefixIcon: Icon(Icons.folder_outlined, color: tints.accent, size: 18),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            ),
            onSubmitted: (_) => onAdd(),
          )),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: onAdd,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            child: Text('ADD', style: GoogleFonts.jetBrainsMono(fontSize: 12, letterSpacing: 0.14)),
          ),
        ]),
        if (folders.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: folders.map((f) => _FolderChip(path: f, tints: tints, onRemove: () => onRemove(f))).toList(),
          ),
        ],
      ]),
    );
  }
}

class _FolderChip extends StatelessWidget {
  final String path;
  final SleeveTints tints;
  final VoidCallback onRemove;
  const _FolderChip({required this.path, required this.tints, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: tints.surface,
        border: Border.all(color: tints.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.folder, color: tints.accent, size: 12),
        const SizedBox(width: 6),
        Text(
          path.length > 28 ? '...${path.substring(path.length - 28)}' : path,
          style: GoogleFonts.jetBrainsMono(color: tints.textMute, fontSize: 11),
        ),
        const SizedBox(width: 6),
        GestureDetector(onTap: onRemove, child: Icon(Icons.close, color: tints.textMute, size: 12)),
      ]),
    );
  }
}

// ─── Track list ────────────────────────────────────────────────────────────

class _TrackList extends StatelessWidget {
  final List<Map<String, dynamic>> tracks;
  final String? currentId;
  final DaemonClient daemon;
  final SleeveTints tints;
  final Function(int) onTap;
  final Function(Map<String, dynamic>)? onLongPress;

  const _TrackList({
    required this.tracks,
    required this.currentId,
    required this.daemon,
    required this.tints,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: tracks.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: tints.line),
      itemBuilder: (context, i) {
        final t = tracks[i];
        final active = t['id'] == currentId;
        final hasArt = t['art_hash'] != null;
        return ListTile(
          dense: true,
          tileColor: Colors.transparent,
          onTap: () => onTap(i),
          onLongPress: onLongPress != null ? () => onLongPress!(t) : null,
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: active ? tints.accentSoft : tints.surface,
              border: Border.all(color: active ? tints.accent : tints.line),
            ),
            child: hasArt
                ? Image.network(
                    daemon.artUrl(t['id'] as String),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        Icon(active ? Icons.graphic_eq : Icons.music_note,
                            color: active ? tints.accent : tints.textDim, size: 16),
                  )
                : Icon(active ? Icons.graphic_eq : Icons.music_note,
                    color: active ? tints.accent : tints.textDim, size: 16),
          ),
          title: Text(
            t['title'] ?? 'Unknown',
            style: GoogleFonts.interTight(
              color: active ? tints.accent : tints.text,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [t['artist'], t['album']].where((x) => x != null).join(' — '),
            style: GoogleFonts.interTight(color: tints.textMute, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            t['format']?.toString().toUpperCase() ?? '',
            style: GoogleFonts.jetBrainsMono(color: tints.textDim, fontSize: 10, letterSpacing: 0.14),
          ),
        );
      },
    );
  }
}

// ─── History bar ───────────────────────────────────────────────────────────

class _HistoryBar extends StatelessWidget {
  final List<Map<String, dynamic>> history;
  final DaemonClient daemon;
  final bool show;
  final SleeveTints tints;
  final VoidCallback onToggle;
  final Function(Map<String, dynamic>) onTap;
  const _HistoryBar({
    required this.history,
    required this.daemon,
    required this.show,
    required this.tints,
    required this.onToggle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      InkWell(
        onTap: onToggle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: tints.surface,
          child: Row(children: [
            Icon(Icons.history, color: tints.textDim, size: 14),
            const SizedBox(width: 8),
            Text('RECENTLY PLAYED',
                style: GoogleFonts.jetBrainsMono(color: tints.textDim, fontSize: 10, letterSpacing: 0.18)),
            const Spacer(),
            Icon(show ? Icons.expand_less : Icons.expand_more, color: tints.textDim, size: 16),
          ]),
        ),
      ),
      if (show)
        SizedBox(
          height: 84,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: history.length,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemBuilder: (_, i) {
              final t = history[i];
              return GestureDetector(
                onTap: () => onTap(t),
                child: Container(
                  width: 60,
                  margin: const EdgeInsets.only(right: 8),
                  child: Column(children: [
                    Container(
                      width: 48,
                      height: 48,
                      color: tints.surface,
                      child: t['art_hash'] != null
                          ? Image.network(daemon.artUrl(t['id'] as String), fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  Icon(Icons.music_note, color: tints.accent, size: 20))
                          : Icon(Icons.music_note, color: tints.accent, size: 20),
                    ),
                    const SizedBox(height: 4),
                    Text(t['title'] ?? '?',
                        style: GoogleFonts.interTight(color: tints.textMute, fontSize: 9),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1),
                  ]),
                ),
              );
            },
          ),
        ),
      Divider(height: 1, color: tints.line),
    ]);
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────

class _Empty extends StatelessWidget {
  final bool isMobile;
  final bool isSearch;
  final SleeveTints tints;
  const _Empty({required this.isMobile, required this.isSearch, required this.tints});

  @override
  Widget build(BuildContext context) {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(isSearch ? Icons.search_off : Icons.library_music_outlined,
          size: 48, color: tints.textDim),
      const SizedBox(height: 16),
      Text(isSearch ? 'No matches' : 'No tracks indexed',
          style: GoogleFonts.newsreader(color: tints.textMute, fontSize: 20, fontStyle: FontStyle.italic)),
      const SizedBox(height: 8),
      if (!isSearch)
        Text(
          isMobile ? 'Add folders from the PC app first' : 'Add a folder above to scan your music',
          style: GoogleFonts.interTight(color: tints.textDim, fontSize: 12),
        ),
    ]));
  }
}

// ─── Artist view ──────────────────────────────────────────────────────────

class _ArtistView extends StatefulWidget {
  final List<Map<String, dynamic>> tracks;
  final DaemonClient daemon;
  final ShamlssPlayer player;
  final SleeveTints tints;
  const _ArtistView({required this.tracks, required this.daemon, required this.player, required this.tints});

  @override
  State<_ArtistView> createState() => _ArtistViewState();
}

class _ArtistViewState extends State<_ArtistView> {
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final Map<String, List<Map<String, dynamic>>> byArtist = {};
    for (final t in widget.tracks) {
      final a = t['artist'] as String? ?? 'Unknown Artist';
      (byArtist[a] ??= []).add(t);
    }
    final artists = byArtist.keys.toList()..sort();
    final tints = widget.tints;

    return ListView.builder(
      itemCount: artists.length,
      itemBuilder: (_, i) {
        final artist = artists[i];
        final artistTracks = byArtist[artist]!;
        final expanded = _expanded.contains(artist);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: () => setState(() {
              expanded ? _expanded.remove(artist) : _expanded.add(artist);
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                Icon(Icons.person, color: tints.textDim, size: 16),
                const SizedBox(width: 12),
                Expanded(child: Text(artist,
                    style: GoogleFonts.newsreader(color: tints.text, fontSize: 16,
                        fontWeight: FontWeight.w600))),
                Text('${artistTracks.length}',
                    style: GoogleFonts.jetBrainsMono(color: tints.textDim, fontSize: 11)),
                const SizedBox(width: 8),
                Icon(expanded ? Icons.expand_less : Icons.expand_more, color: tints.textDim, size: 16),
              ]),
            ),
          ),
          if (expanded)
            ...artistTracks.asMap().entries.map((e) {
              final idx = e.key;
              final t = e.value;
              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 44, right: 16),
                leading: Icon(Icons.music_note, color: tints.textDim, size: 14),
                title: Text(t['title'] ?? 'Unknown',
                    style: GoogleFonts.interTight(color: tints.text, fontSize: 12),
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(t['album'] ?? '',
                    style: GoogleFonts.interTight(color: tints.textMute, fontSize: 10),
                    overflow: TextOverflow.ellipsis),
                onTap: () => widget.player.playQueue(
                    artistTracks, idx, widget.daemon.streamUrl,
                    artUrlBuilder: widget.daemon.artUrl),
              );
            }),
          Divider(height: 1, color: tints.line),
        ]);
      },
    );
  }
}

// ─── Album grid (2-col, Newsreader title, no radius) ──────────────────────

class _AlbumGrid extends StatelessWidget {
  final List<Map<String, dynamic>> tracks;
  final DaemonClient daemon;
  final ShamlssPlayer player;
  final SleeveTints tints;
  const _AlbumGrid({required this.tracks, required this.daemon, required this.player, required this.tints});

  @override
  Widget build(BuildContext context) {
    // Group by album
    final Map<String, List<Map<String, dynamic>>> byAlbum = {};
    for (final t in tracks) {
      final a = t['album'] as String? ?? 'Unknown Album';
      (byAlbum[a] ??= []).add(t);
    }

    // Group albums by decade
    final Map<String, List<String>> byDecade = {};
    for (final album in byAlbum.keys) {
      final albumTracks = byAlbum[album]!;
      final year = albumTracks.first['year'] as int?;
      final decade = year != null ? '${(year ~/ 10) * 10}s' : 'Unknown Era';
      (byDecade[decade] ??= []).add(album);
    }
    final decades = byDecade.keys.toList()..sort((a, b) {
      // Sort "Unknown Era" to end
      if (a == 'Unknown Era') return 1;
      if (b == 'Unknown Era') return -1;
      return b.compareTo(a); // newest decade first
    });

    final tints2 = tints;

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: decades.length,
      itemBuilder: (_, di) {
        final decade = decades[di];
        final decadeAlbums = byDecade[decade]!..sort();

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Decade heading — italic Newsreader
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              decade,
              style: GoogleFonts.newsreader(
                color: tints2.textMute,
                fontSize: 18,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),

          // 2-col album grid for this decade
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.82,
            ),
            itemCount: decadeAlbums.length,
            itemBuilder: (_, i) {
              final album = decadeAlbums[i];
              final albumTracks = byAlbum[album]!;
              final firstWithArt = albumTracks.firstWhere(
                  (t) => t['art_hash'] != null, orElse: () => albumTracks.first);
              final hasArt = firstWithArt['art_hash'] != null;

              return GestureDetector(
                onTap: () => player.playQueue(albumTracks, 0, daemon.streamUrl,
                    artUrlBuilder: daemon.artUrl),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Square sleeve art — no radius (sharp)
                  AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      color: tints2.surface,
                      child: hasArt
                          ? Image.network(
                              daemon.artUrl(firstWithArt['id'] as String),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  Icon(Icons.album, color: tints2.accent, size: 40))
                          : Icon(Icons.album, color: tints2.accent, size: 40),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Newsreader title
                  Text(
                    album,
                    style: GoogleFonts.newsreader(
                      color: tints2.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  // Italic muted artist
                  Text(
                    albumTracks.first['artist'] as String? ?? '',
                    style: GoogleFonts.interTight(
                      color: tints2.textMute,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ]),
              );
            },
          ),
        ]);
      },
    );
  }
}
