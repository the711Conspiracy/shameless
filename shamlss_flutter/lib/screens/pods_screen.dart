import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../core/daemon_client.dart';
import '../core/player.dart';
import '../core/theme.dart';
import 'pairing_screen.dart';
import 'peer_library_screen.dart';

class PodsScreen extends StatefulWidget {
  final DaemonClient daemon;
  final ShamlssPlayer player;
  const PodsScreen({super.key, required this.daemon, required this.player});

  @override
  State<PodsScreen> createState() => _PodsScreenState();
}

class _PodsScreenState extends State<PodsScreen> with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _pods = [];
  List<Map<String, dynamic>> _queue = [];
  List<Map<String, dynamic>> _feed = [];
  bool _loading = false;
  bool _queueLoading = false;
  bool _feedLoading = false;
  late TabController _tabs;
  late StreamSubscription _queueSub;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(_onTabChanged);
    _load();
    _queueSub = widget.daemon.onQueueUpdated.listen((_) { if (mounted) _loadQueue(); });
  }

  @override
  void dispose() {
    _queueSub.cancel();
    _tabs.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabs.indexIsChanging) return;
    if (_tabs.index == 1 && _queue.isEmpty) _loadQueue();
    if (_tabs.index == 2 && _feed.isEmpty) _loadFeed();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await http.get(Uri.parse('${widget.daemon.base}/pods'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && mounted) {
        setState(() { _pods = List<Map<String, dynamic>>.from(jsonDecode(res.body)); _loading = false; });
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadQueue() async {
    if (!mounted) return;
    setState(() => _queueLoading = true);
    final items = await widget.daemon.getCollabQueue();
    if (mounted) setState(() { _queue = items; _queueLoading = false; });
  }

  Future<void> _loadFeed() async {
    if (!mounted) return;
    setState(() => _feedLoading = true);
    final items = await widget.daemon.getFeed();
    if (mounted) setState(() { _feed = items; _feedLoading = false; });
  }

  Future<void> _createPod() async {
    final result = await showDialog<Map<String, String?>>(
      context: context,
      builder: (ctx) => _CreatePodDialog(),
    );
    if (result == null) return;
    final name = result['name']!;
    try {
      final res = await http.post(
        Uri.parse('${widget.daemon.base}/pods'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name}),
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 201) {
        await _load();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Pod "$name" created'), duration: const Duration(seconds: 2)));
      } else {
        final err = (jsonDecode(res.body) as Map)['error'] ?? 'HTTP ${res.statusCode}';
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Create failed: $err'), backgroundColor: Colors.red.shade900));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Create failed: $e'), backgroundColor: Colors.red.shade900));
    }
  }

  Future<void> _openPod(Map<String, dynamic> pod) async {
    widget.daemon.setActivePod(pod);
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => PodDetailScreen(daemon: widget.daemon, pod: pod, player: widget.player),
    ));
    widget.daemon.setActivePod(null);
    await _load();
  }

  Future<void> _scanQr() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => GuestScanScreen(daemon: widget.daemon),
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PODS', style: TextStyle(letterSpacing: 3, fontSize: 14)),
        actions: [
          if (_tabs.index == 0) ...[
            IconButton(icon: const Icon(Icons.qr_code_scanner, size: 20), tooltip: 'Scan to join', onPressed: _scanQr),
            IconButton(icon: const Icon(Icons.add, size: 20), tooltip: 'Create pod', onPressed: _createPod),
          ],
          if (_tabs.index == 1)
            IconButton(icon: const Icon(Icons.delete_sweep_outlined, size: 20), tooltip: 'Clear queue',
              onPressed: () async {
                await widget.daemon.clearCollabQueue();
                _loadQueue();
              }),
          if (_tabs.index == 2)
            IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _loadFeed),
          if (_tabs.index == 0)
            IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _load),
          const SizedBox(width: 4),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: ShamlssColors.amber,
          labelColor: ShamlssColors.amber,
          unselectedLabelColor: ShamlssColors.textMuted,
          labelStyle: const TextStyle(fontSize: 11, letterSpacing: 1.5),
          tabs: const [Tab(text: 'PODS'), Tab(text: 'QUEUE'), Tab(text: 'FEED')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_buildPodsTab(), _buildQueueTab(), _buildFeedTab()],
      ),
    );
  }

  Widget _buildPodsTab() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2));
    if (_pods.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.group_outlined, size: 48, color: ShamlssColors.divider),
        const SizedBox(height: 16),
        const Text('No pods yet', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 14)),
        const SizedBox(height: 8),
        const Text('Create a pod to share music,\nor scan a QR code to join one', textAlign: TextAlign.center, style: TextStyle(color: ShamlssColors.divider, fontSize: 12)),
        const SizedBox(height: 24),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          FilledButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('CREATE'), onPressed: _createPod),
          const SizedBox(width: 12),
          OutlinedButton.icon(icon: const Icon(Icons.qr_code_scanner, size: 16), label: const Text('SCAN QR'), onPressed: _scanQr),
        ]),
      ]));
    }
    return ListView.separated(
      itemCount: _pods.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final pod = _pods[i];
        final isHost = pod['my_role'] == 'host';
        return ListTile(
          dense: true,
          leading: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: ShamlssColors.surface,
              border: Border.all(color: isHost ? ShamlssColors.amber : ShamlssColors.amberDim),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(isHost ? Icons.star : Icons.group, color: isHost ? ShamlssColors.amber : ShamlssColors.amberDim, size: 16),
          ),
          title: Text(pod['name'] as String, style: const TextStyle(color: ShamlssColors.text, fontSize: 13)),
          subtitle: Text('${isHost ? "HOST" : "MEMBER"} · ${pod['member_count']} members',
              style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11, letterSpacing: 0.5)),
          onTap: () => _openPod(pod),
          trailing: const Icon(Icons.chevron_right, color: ShamlssColors.divider, size: 18),
        );
      },
    );
  }

  Widget _buildQueueTab() {
    if (_queueLoading) return const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2));
    if (_queue.isEmpty) {
      return RefreshIndicator(
        color: ShamlssColors.amber,
        onRefresh: _loadQueue,
        child: ListView(children: const [
          SizedBox(height: 80),
          Center(child: Icon(Icons.queue_music_outlined, size: 48, color: ShamlssColors.divider)),
          SizedBox(height: 16),
          Center(child: Text('Shared queue is empty', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 14))),
          SizedBox(height: 8),
          Center(child: Text('Long-press any track → Add to shared queue', style: TextStyle(color: ShamlssColors.divider, fontSize: 12))),
        ]),
      );
    }
    return RefreshIndicator(
      color: ShamlssColors.amber,
      onRefresh: _loadQueue,
      child: ListView.separated(
        itemCount: _queue.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final item = _queue[i];
          final addedBy = item['added_by'] as String? ?? 'local';
          return ListTile(
            dense: true,
            leading: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(color: ShamlssColors.surface, borderRadius: BorderRadius.circular(4)),
              child: Center(child: Text('${i + 1}', style: const TextStyle(color: ShamlssColors.amberDim, fontSize: 12))),
            ),
            title: Text(item['title'] as String? ?? 'Unknown', style: const TextStyle(color: ShamlssColors.text, fontSize: 13)),
            subtitle: Text('${item['artist'] ?? '—'}  ·  added by $addedBy',
                style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11)),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 16, color: ShamlssColors.textMuted),
              onPressed: () async {
                await widget.daemon.removeFromCollabQueue(item['id'] as int);
                _loadQueue();
              },
            ),
            onTap: () => widget.player.playQueue(
              [Map<String, dynamic>.from(item)..['id'] = item['track_id']],
              0,
              widget.daemon.streamUrl,
              artUrlBuilder: widget.daemon.artUrl,
            ),
          );
        },
      ),
    );
  }

  Widget _buildFeedTab() {
    if (_feedLoading) return const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2));
    if (_feed.isEmpty) {
      return RefreshIndicator(
        color: ShamlssColors.amber,
        onRefresh: _loadFeed,
        child: ListView(children: const [
          SizedBox(height: 80),
          Center(child: Icon(Icons.timeline_outlined, size: 48, color: ShamlssColors.divider)),
          SizedBox(height: 16),
          Center(child: Text('No activity yet', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 14))),
        ]),
      );
    }
    return RefreshIndicator(
      color: ShamlssColors.amber,
      onRefresh: _loadFeed,
      child: ListView.separated(
        itemCount: _feed.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final item = _feed[i];
          final isPlay = item['type'] == 'play';
          final ts = item['ts'] as int? ?? 0;
          final ago = _relativeTime(ts);
          return ListTile(
            dense: true,
            leading: Icon(
              isPlay ? Icons.play_circle_outline : Icons.add_to_queue,
              color: isPlay ? ShamlssColors.amberDim : ShamlssColors.textMuted,
              size: 20,
            ),
            title: Text(item['title'] as String? ?? 'Unknown', style: const TextStyle(color: ShamlssColors.text, fontSize: 13)),
            subtitle: Text(
              isPlay
                ? '${item['artist'] ?? '—'}  ·  played $ago'
                : '${item['artist'] ?? '—'}  ·  queued $ago by ${item['added_by'] ?? 'local'}',
              style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11),
            ),
          );
        },
      ),
    );
  }

  String _relativeTime(int tsMs) {
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(tsMs));
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class PodDetailScreen extends StatefulWidget {
  final DaemonClient daemon;
  final Map<String, dynamic> pod;
  final ShamlssPlayer player;
  const PodDetailScreen({super.key, required this.daemon, required this.pod, required this.player});

  @override
  State<PodDetailScreen> createState() => _PodDetailScreenState();
}

class _PodDetailScreenState extends State<PodDetailScreen> with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _detail;
  List<Map<String, dynamic>> _activity = [];
  bool _loading = false;
  bool _activityLoading = false;
  late TabController _tabs;
  late String _podName;

  @override
  void initState() {
    super.initState();
    _podName = widget.pod['name'] as String;
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() { if (_tabs.index == 1 && _activity.isEmpty) _loadActivity(); });
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await http.get(Uri.parse('${widget.daemon.base}/pods/${widget.pod['pod_id']}'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && mounted) {
        setState(() { _detail = Map<String, dynamic>.from(jsonDecode(res.body)); _loading = false; });
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadActivity() async {
    setState(() => _activityLoading = true);
    try {
      final res = await http.get(Uri.parse('${widget.daemon.base}/pods/${widget.pod['pod_id']}/activity?limit=50'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && mounted) {
        setState(() {
          _activity = List<Map<String, dynamic>>.from(jsonDecode(res.body));
          _activityLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _activityLoading = false);
    }
  }

  Future<void> _renamePod() async {
    final ctrl = TextEditingController(text: _podName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ShamlssColors.card,
        title: const Text('RENAME POD', style: TextStyle(color: ShamlssColors.text, fontSize: 13, letterSpacing: 2)),
        content: TextField(controller: ctrl, autofocus: true, style: const TextStyle(color: ShamlssColors.text),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: ShamlssColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('RENAME', style: TextStyle(color: ShamlssColors.amber))),
        ],
      ),
    );
    if (result == null || result.isEmpty || result == _podName) return;
    try {
      final res = await http.patch(Uri.parse('${widget.daemon.base}/pods/${widget.pod['pod_id']}'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({'name': result}))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        setState(() => _podName = result);
        widget.daemon.setActivePod({...widget.pod, 'name': result});
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Renamed to "$result"'), duration: const Duration(seconds: 2)));
      } else {
        final err = (jsonDecode(res.body) as Map)['error'] ?? 'HTTP ${res.statusCode}';
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rename failed: $err'), backgroundColor: Colors.red.shade900));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rename failed: $e'), backgroundColor: Colors.red.shade900));
    }
  }

  Future<void> _deletePod() async {
    final isHost = widget.pod['my_role'] == 'host';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ShamlssColors.card,
        title: Text(isHost ? 'DISBAND POD' : 'LEAVE POD',
            style: const TextStyle(color: ShamlssColors.text, fontSize: 13, letterSpacing: 2)),
        content: Text(isHost
            ? 'Disband "$_podName"? All members will lose access.'
            : 'Leave "$_podName"?',
            style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: ShamlssColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(isHost ? 'DISBAND' : 'LEAVE', style: const TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final res = await http.delete(Uri.parse('${widget.daemon.base}/pods/${widget.pod['pod_id']}'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        if (mounted) Navigator.pop(context);
      } else {
        final err = (jsonDecode(res.body) as Map)['error'] ?? 'HTTP ${res.statusCode}';
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $err'), backgroundColor: Colors.red.shade900));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red.shade900));
    }
  }

  Future<void> _revokeMember(String nodeId, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ShamlssColors.card,
        title: const Text('REVOKE MEMBER', style: TextStyle(color: ShamlssColors.text, fontSize: 13, letterSpacing: 2)),
        content: Text('Remove $name from this pod? The pod keypair will be rotated.', style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: ShamlssColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('REVOKE', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final res = await http.delete(Uri.parse('${widget.daemon.base}/pods/${widget.pod['pod_id']}/members/$nodeId'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        await _load();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$name revoked'), duration: const Duration(seconds: 2)));
      } else {
        final err = (jsonDecode(res.body) as Map)['error'] ?? 'HTTP ${res.statusCode}';
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Revoke failed: $err'), backgroundColor: Colors.red.shade900));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Revoke failed: $e'), backgroundColor: Colors.red.shade900));
    }
  }

  Future<void> _setVisibility(String nodeId, String current) async {
    final options = ['full', 'folders', 'hidden'];
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: ShamlssColors.card,
        title: const Text('VISIBILITY', style: TextStyle(color: ShamlssColors.text, fontSize: 13, letterSpacing: 2)),
        children: options.map((o) => SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, o),
          child: Text(o.toUpperCase(), style: TextStyle(color: o == current ? ShamlssColors.amber : ShamlssColors.text, fontSize: 13)),
        )).toList(),
      ),
    );
    if (chosen == null || chosen == current) return;
    try {
      final res = await http.patch(Uri.parse('${widget.daemon.base}/pods/${widget.pod['pod_id']}/members/$nodeId'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({'visibility': chosen}))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        await _load();
      } else {
        final err = (jsonDecode(res.body) as Map)['error'] ?? 'HTTP ${res.statusCode}';
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Visibility update failed: $err'), backgroundColor: Colors.red.shade900));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Visibility update failed: $e'), backgroundColor: Colors.red.shade900));
    }
  }

  Future<void> _openPairing() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => HostPairingScreen(
        daemon: widget.daemon,
        podId: widget.pod['pod_id'] as String,
        podName: _podName,
      ),
    ));
    await _load();
  }

  void _openChat(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: ShamlssColors.card,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: PodChatSheet(daemon: widget.daemon, podId: widget.pod['pod_id'] as String),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isHost = widget.pod['my_role'] == 'host';
    final members = _detail == null ? <dynamic>[] : (_detail!['members'] as List? ?? []);

    return Scaffold(
      appBar: AppBar(
        title: Text(_podName, style: const TextStyle(letterSpacing: 2, fontSize: 13)),
        actions: [
          if (isHost) IconButton(icon: const Icon(Icons.qr_code, size: 20), tooltip: 'Add member', onPressed: _openPairing),
          IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: () { _load(); if (_tabs.index == 1) _loadActivity(); }),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            color: ShamlssColors.card,
            onSelected: (v) {
              if (v == 'rename') _renamePod();
              if (v == 'delete') _deletePod();
            },
            itemBuilder: (_) => [
              if (isHost) const PopupMenuItem(value: 'rename', child: Text('Rename', style: TextStyle(color: ShamlssColors.text, fontSize: 13))),
              PopupMenuItem(
                value: 'delete',
                child: Text(isHost ? 'Disband pod' : 'Leave pod',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: ShamlssColors.amber,
          unselectedLabelColor: ShamlssColors.textMuted,
          indicatorColor: ShamlssColors.amber,
          labelStyle: const TextStyle(fontSize: 11, letterSpacing: 1.5),
          tabs: const [Tab(text: 'MEMBERS'), Tab(text: 'ACTIVITY')],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openChat(context),
        backgroundColor: ShamlssColors.amber,
        foregroundColor: ShamlssColors.black,
        icon: const Icon(Icons.chat_bubble_outline, size: 18),
        label: const Text('CHAT', style: TextStyle(fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.w700)),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          // ── MEMBERS tab ──
          _loading
              ? const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))
              : Column(children: [
                  if (isHost) _PairBanner(onTap: _openPairing),
                  Expanded(
                    child: members.isEmpty
                        ? const Center(child: Text('No members yet', style: TextStyle(color: ShamlssColors.textMuted)))
                        : ListView.separated(
                            itemCount: members.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final m = members[i] as Map<String, dynamic>;
                              final revoked = m['revoked_ts'] != null;
                              final nodeId = m['node_id'] as String;
                              final name = m['display_name'] as String? ?? nodeId;
                              final vis = m['visibility'] as String? ?? 'full';
                              final lastSeen = m['last_seen_ts'] as int?;
                              final online = lastSeen != null && DateTime.now().millisecondsSinceEpoch - lastSeen < 60000;
                              return ListTile(
                                dense: true,
                                leading: Stack(clipBehavior: Clip.none, children: [
                                  Icon(Icons.person, color: revoked ? ShamlssColors.divider : ShamlssColors.amberDim, size: 18),
                                  if (!revoked) Positioned(right: -2, bottom: -2, child: Container(
                                    width: 7, height: 7,
                                    decoration: BoxDecoration(
                                      color: online ? const Color(0xFF22c55e) : ShamlssColors.divider,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: ShamlssColors.surface, width: 1),
                                    ),
                                  )),
                                ]),
                                title: Text(name, style: TextStyle(
                                    color: revoked ? ShamlssColors.divider : ShamlssColors.text, fontSize: 13,
                                    decoration: revoked ? TextDecoration.lineThrough : null)),
                                subtitle: Text(revoked ? 'REVOKED' : vis.toUpperCase(),
                                    style: TextStyle(color: revoked ? ShamlssColors.divider : ShamlssColors.textMuted, fontSize: 10, letterSpacing: 1)),
                                trailing: revoked ? null : Row(mainAxisSize: MainAxisSize.min, children: [
                                  if (m['last_ip'] != null) IconButton(
                                    icon: const Icon(Icons.library_music_outlined, size: 16, color: ShamlssColors.amberDim),
                                    onPressed: () => Navigator.push(context, MaterialPageRoute(
                                      builder: (_) => PeerLibraryScreen(
                                        peerBase: 'http://${m['last_ip']}:7432',
                                        podId: widget.pod['pod_id'] as String,
                                        memberName: name,
                                        player: widget.player,
                                      ),
                                    )),
                                    tooltip: 'Browse library',
                                  ),
                                  if (isHost) IconButton(
                                    icon: const Icon(Icons.visibility_outlined, size: 16, color: ShamlssColors.textMuted),
                                    onPressed: () => _setVisibility(nodeId, vis),
                                    tooltip: 'Set visibility',
                                  ),
                                  if (isHost) IconButton(
                                    icon: const Icon(Icons.person_remove_outlined, size: 16, color: ShamlssColors.textMuted),
                                    onPressed: () => _revokeMember(nodeId, name),
                                    tooltip: 'Revoke',
                                  ),
                                ]),
                              );
                            },
                          ),
                  ),
                ]),

          // ── ACTIVITY tab ──
          _activityLoading
              ? const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))
              : _activity.isEmpty
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.history, size: 40, color: ShamlssColors.divider),
                      const SizedBox(height: 12),
                      const Text('No plays yet', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 13)),
                      const SizedBox(height: 4),
                      const Text('Plays by pod members will appear here', style: TextStyle(color: ShamlssColors.divider, fontSize: 11)),
                      const SizedBox(height: 16),
                      OutlinedButton(onPressed: _loadActivity, child: const Text('LOAD')),
                    ]))
                  : RefreshIndicator(
                      color: ShamlssColors.amber,
                      onRefresh: _loadActivity,
                      child: ListView.separated(
                        itemCount: _activity.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final a = _activity[i];
                          final playedAt = DateTime.fromMillisecondsSinceEpoch(a['played_ts'] as int);
                          final now = DateTime.now();
                          final diff = now.difference(playedAt);
                          final when = diff.inMinutes < 60
                              ? '${diff.inMinutes}m ago'
                              : diff.inHours < 24
                                  ? '${diff.inHours}h ago'
                                  : '${diff.inDays}d ago';
                          return ListTile(
                            dense: true,
                            leading: a['art_hash'] != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: Image.network(
                                      '${widget.daemon.base}/library/art/${a['track_id']}',
                                      width: 36, height: 36, fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const _ActivityArtFallback(),
                                    ),
                                  )
                                : const _ActivityArtFallback(),
                            title: Text(a['title'] as String? ?? 'Unknown',
                                style: const TextStyle(color: ShamlssColors.text, fontSize: 13),
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              [a['artist'], a['album']].where((s) => s != null && s != '').join(' · '),
                              style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Text(a['member_name'] as String? ?? 'You',
                                  style: const TextStyle(color: ShamlssColors.amberDim, fontSize: 11)),
                              Text(when, style: const TextStyle(color: ShamlssColors.divider, fontSize: 10)),
                            ]),
                          );
                        },
                      ),
                    ),
        ],
      ),
    );
  }
}

class _ActivityArtFallback extends StatelessWidget {
  const _ActivityArtFallback();
  @override
  Widget build(BuildContext context) => Container(
    width: 36, height: 36,
    decoration: BoxDecoration(color: ShamlssColors.surface, borderRadius: BorderRadius.circular(3)),
    child: const Icon(Icons.music_note, color: ShamlssColors.amberDim, size: 16),
  );
}

class _PairBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _PairBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: ShamlssColors.amberDim.withOpacity(0.1),
        child: const Row(children: [
          Icon(Icons.qr_code, color: ShamlssColors.amber, size: 18),
          SizedBox(width: 12),
          Expanded(child: Text('Show QR to add a member', style: TextStyle(color: ShamlssColors.amber, fontSize: 12, letterSpacing: 0.5))),
          Icon(Icons.chevron_right, color: ShamlssColors.amberDim, size: 16),
        ]),
      ),
    );
  }
}

class PodChatSheet extends StatefulWidget {
  final DaemonClient daemon;
  final String podId;
  const PodChatSheet({super.key, required this.daemon, required this.podId});

  @override
  State<PodChatSheet> createState() => _PodChatSheetState();
}

class _PodChatSheetState extends State<PodChatSheet> {
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  bool _sending = false;
  Timer? _poll;
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) setState(() => _loading = true);
    final data = await widget.daemon.get('/chat?pod_id=${widget.podId}&limit=50');
    if (!mounted) return;
    setState(() {
      _messages = data is List ? List<Map<String, dynamic>>.from(data) : <Map<String, dynamic>>[];
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final body = _ctrl.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    final res = await widget.daemon.post('/chat', {
      'pod_id': widget.podId,
      'node_id': 'local',
      'display_name': 'Me',
      'body': body,
    });
    if (!mounted) return;
    if (res != null) {
      _ctrl.clear();
      await _load();
    }
    setState(() => _sending = false);
  }

  String _timeLabel(int? tsMs) {
    if (tsMs == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(tsMs);
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(children: [
            const Icon(Icons.chat_bubble_outline, color: ShamlssColors.amber, size: 16),
            const SizedBox(width: 8),
            const Text('POD CHAT', style: TextStyle(color: ShamlssColors.amberDim, fontSize: 11, letterSpacing: 2)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close, color: ShamlssColors.textMuted, size: 18),
              onPressed: () => Navigator.pop(context),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))
              : _messages.isEmpty
                  ? const Center(child: Text('No messages yet — say hi!', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 12)))
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) {
                        final m = _messages[i];
                        final name = m['display_name'] as String? ?? (m['node_id'] as String? ?? 'unknown');
                        final body = m['body'] as String? ?? '';
                        final ts = m['ts'] as int? ?? m['created_ts'] as int?;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Text(name, style: const TextStyle(color: ShamlssColors.amber, fontSize: 12, fontWeight: FontWeight.w600)),
                              const SizedBox(width: 8),
                              Text(_timeLabel(ts), style: const TextStyle(color: ShamlssColors.divider, fontSize: 10)),
                            ]),
                            const SizedBox(height: 2),
                            Text(body, style: const TextStyle(color: ShamlssColors.text, fontSize: 13)),
                          ]),
                        );
                      },
                    ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                style: const TextStyle(color: ShamlssColors.text, fontSize: 13),
                decoration: const InputDecoration(
                  hintText: 'Message…',
                  hintStyle: TextStyle(color: ShamlssColors.textMuted, fontSize: 13),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                onSubmitted: (_) => _send(),
                textInputAction: TextInputAction.send,
              ),
            ),
            const SizedBox(width: 8),
            _sending
                ? const SizedBox(width: 36, height: 36, child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))))
                : IconButton(
                    icon: const Icon(Icons.send, color: ShamlssColors.amber, size: 20),
                    onPressed: _send,
                  ),
          ]),
        ),
      ]),
    );
  }
}

class _CreatePodDialog extends StatelessWidget {
  final _ctrl = TextEditingController();
  _CreatePodDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: ShamlssColors.card,
      title: const Text('NEW POD', style: TextStyle(color: ShamlssColors.text, fontSize: 13, letterSpacing: 2)),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        style: const TextStyle(color: ShamlssColors.text),
        decoration: const InputDecoration(hintText: 'Pod name', hintStyle: TextStyle(color: ShamlssColors.textMuted)),
        onSubmitted: (v) { if (v.trim().isNotEmpty) Navigator.pop(context, {'name': v.trim()}); },
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: ShamlssColors.textMuted))),
        TextButton(
            onPressed: () { if (_ctrl.text.trim().isNotEmpty) Navigator.pop(context, {'name': _ctrl.text.trim()}); },
            child: const Text('CREATE', style: TextStyle(color: ShamlssColors.amber))),
      ],
    );
  }
}
