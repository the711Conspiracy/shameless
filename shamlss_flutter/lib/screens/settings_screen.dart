import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../core/daemon_client.dart';
import '../core/player.dart';
import '../core/sleep_timer.dart';
import '../core/theme.dart';

class SettingsScreen extends StatefulWidget {
  final DaemonClient daemon;
  final SleepTimer sleepTimer;
  final ShamlssPlayer player;
  const SettingsScreen({super.key, required this.daemon, required this.sleepTimer, required this.player});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _settings;
  Map<String, dynamic>? _stats;
  Map<String, dynamic>? _analysisStatus;
  bool _loading = false;
  bool _showFlags = false;
  bool _analysisBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      http.get(Uri.parse('${widget.daemon.base}/settings')).timeout(const Duration(seconds: 10)).then((r) => r.statusCode == 200 ? jsonDecode(r.body) : null).catchError((_) => null),
      widget.daemon.getStats(),
      widget.daemon.getAnalysisStatus(),
    ]);
    if (mounted) setState(() {
      if (results[0] != null) _settings = Map<String, dynamic>.from(results[0] as Map);
      _stats = results[1] as Map<String, dynamic>?;
      _analysisStatus = results[2] as Map<String, dynamic>?;
      _loading = false;
    });
  }

  Future<void> _analyzeAll() async {
    setState(() => _analysisBusy = true);
    final result = await widget.daemon.triggerAnalysisScan();
    if (mounted) {
      setState(() {
        _analysisBusy = false;
        if (result != null) _analysisStatus = result;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result != null ? 'Analysis started — ${result['queued']} tracks queued' : 'Already up to date'),
        duration: const Duration(seconds: 3),
      ));
    }
  }

  Future<void> _editName() async {
    final ctrl = TextEditingController(text: _settings?['node']?['display_name'] ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ShamlssColors.card,
        title: const Text('NODE NAME', style: TextStyle(color: ShamlssColors.text, fontSize: 13, letterSpacing: 2)),
        content: TextField(controller: ctrl, autofocus: true, style: const TextStyle(color: ShamlssColors.text),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: ShamlssColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('SAVE', style: TextStyle(color: ShamlssColors.amber))),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    try {
      final res = await http.patch(Uri.parse('${widget.daemon.base}/settings/node'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({'display_name': result}))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        await _load();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Name updated'), duration: Duration(seconds: 2)));
      } else {
        final err = (jsonDecode(res.body) as Map)['error'] ?? 'HTTP ${res.statusCode}';
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: $err'), backgroundColor: Colors.red.shade900));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update failed: $e'), backgroundColor: Colors.red.shade900));
    }
  }

  Future<void> _toggleFlag(String key, bool value) async {
    try {
      final res = await http.patch(Uri.parse('${widget.daemon.base}/settings/flags'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({key: value}))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() { (_settings!['flags'] as Map)[key] = data['flags'][key]; });
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Flag update failed: HTTP ${res.statusCode}'), backgroundColor: Colors.red.shade900));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Flag update failed: $e'), backgroundColor: Colors.red.shade900));
    }
  }

  @override
  Widget build(BuildContext context) {
    final node = _settings?['node'] as Map<String, dynamic>?;
    final flagsMap = _settings?['flags'] as Map<String, dynamic>?;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SETTINGS', style: TextStyle(letterSpacing: 3, fontSize: 14)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _load),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))
          : ListView(children: [
              const SizedBox(height: 8),
              _Section('NODE IDENTITY', [
                _InfoRow('Node ID', widget.daemon.nodeId ?? node?['node_id'] ?? '—', mono: true),
                InkWell(
                  onTap: _editName,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(children: [
                      const SizedBox(width: 110, child: Text('Display Name', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 12))),
                      Expanded(child: Text(node?['display_name'] ?? widget.daemon.nodeName ?? '—', style: const TextStyle(color: ShamlssColors.text, fontSize: 12))),
                      const Icon(Icons.edit, color: ShamlssColors.divider, size: 14),
                    ]),
                  ),
                ),
                _InfoRow('Daemon', '${widget.daemon.host}:7432', mono: true),
              ]),
              const SizedBox(height: 8),
              _Section('CONNECTION', [
                ListTile(
                  dense: true,
                  title: const Text('Disconnect', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                  leading: const Icon(Icons.logout, color: Colors.redAccent, size: 18),
                  onTap: () => widget.daemon.disconnect(),
                ),
              ]),
              if (_stats != null) ...[
                const SizedBox(height: 8),
                _Section('LIBRARY STATS', [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(children: [
                      _StatChip('${_stats!['trackCount'] ?? 0}', 'tracks'),
                      const SizedBox(width: 12),
                      _StatChip('${_stats!['artistCount'] ?? 0}', 'artists'),
                      const SizedBox(width: 12),
                      _StatChip('${_stats!['albumCount'] ?? 0}', 'albums'),
                      const SizedBox(width: 12),
                      _StatChip('${_stats!['playCount'] ?? 0}', 'plays'),
                    ]),
                  ),
                  if ((_stats!['topArtists'] as List?)?.isNotEmpty == true) ...[
                    const Divider(height: 1, color: ShamlssColors.divider),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('TOP THIS WEEK', style: TextStyle(color: ShamlssColors.divider, fontSize: 10, letterSpacing: 1.5)),
                        const SizedBox(height: 6),
                        ...(_stats!['topArtists'] as List).map((a) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(children: [
                            Expanded(child: Text(a['artist'] as String? ?? '', style: const TextStyle(color: ShamlssColors.text, fontSize: 12), overflow: TextOverflow.ellipsis)),
                            Text('${a['plays']} plays', style: const TextStyle(color: ShamlssColors.amberDim, fontSize: 11)),
                          ]),
                        )),
                      ]),
                    ),
                  ],
                ]),
              ],
              if (flagsMap != null) ...[
                const SizedBox(height: 8),
                InkWell(
                  onTap: () => setState(() => _showFlags = !_showFlags),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(children: [
                      const Text('FEATURE FLAGS', style: TextStyle(color: ShamlssColors.amberDim, fontSize: 11, letterSpacing: 2)),
                      const SizedBox(width: 8),
                      const Text('(dev)', style: TextStyle(color: ShamlssColors.divider, fontSize: 10)),
                      const Spacer(),
                      Icon(_showFlags ? Icons.expand_less : Icons.expand_more, color: ShamlssColors.divider, size: 18),
                    ]),
                  ),
                ),
                if (_showFlags) _Section('', flagsMap.entries.map((e) => SwitchListTile(
                  dense: true,
                  title: Text(e.key, style: const TextStyle(color: ShamlssColors.text, fontSize: 12, fontFamily: 'monospace')),
                  value: e.value as bool? ?? false,
                  activeColor: ShamlssColors.amber,
                  onChanged: (v) => _toggleFlag(e.key, v),
                )).toList()),
              ],
              const SizedBox(height: 8),
              if (_analysisStatus != null) ...[
                _Section('TRACK ANALYSIS', [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(
                            '${_analysisStatus!['analyzed'] ?? 0} / ${_analysisStatus!['total'] ?? 0} analyzed',
                            style: const TextStyle(color: ShamlssColors.text, fontSize: 12),
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: (_analysisStatus!['total'] as int? ?? 0) > 0
                                  ? ((_analysisStatus!['analyzed'] as int? ?? 0) / (_analysisStatus!['total'] as int))
                                  : 0,
                              backgroundColor: ShamlssColors.surface,
                              valueColor: const AlwaysStoppedAnimation<Color>(ShamlssColors.amber),
                              minHeight: 4,
                            ),
                          ),
                        ])),
                        const SizedBox(width: 12),
                        _analysisBusy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2))
                            : TextButton(
                                onPressed: _analyzeAll,
                                child: const Text('ANALYZE ALL', style: TextStyle(color: ShamlssColors.amber, fontSize: 12, letterSpacing: 1)),
                              ),
                      ]),
                      if (_analysisStatus!['active'] == true) ...[
                        const SizedBox(height: 6),
                        Text('Running — ${_analysisStatus!['done'] ?? 0} done, ${_analysisStatus!['pending'] ?? 0} pending',
                            style: const TextStyle(color: ShamlssColors.amberDim, fontSize: 11)),
                      ],
                      if (_analysisStatus!['ffmpeg'] == false) ...[
                        const SizedBox(height: 8),
                        const Text('Install ffmpeg to enable BPM detection for untagged tracks',
                            style: TextStyle(color: ShamlssColors.textMuted, fontSize: 11)),
                      ],
                    ]),
                  ),
                ]),
              ],
              const SizedBox(height: 8),
              _Section('SLEEP TIMER', [
                ListenableBuilder(
                  listenable: widget.sleepTimer,
                  builder: (_, __) {
                    final active = widget.sleepTimer.active;
                    return Column(children: [
                      if (active) Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(children: [
                          const Icon(Icons.bedtime, color: ShamlssColors.amber, size: 16),
                          const SizedBox(width: 12),
                          Text('Stopping in ${widget.sleepTimer.label}', style: const TextStyle(color: ShamlssColors.text, fontSize: 13)),
                          const Spacer(),
                          TextButton(onPressed: widget.sleepTimer.cancel, child: const Text('Cancel', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 12))),
                        ]),
                      ),
                      ...[15, 30, 45, 60].map((min) => ListTile(
                        dense: true,
                        leading: Icon(Icons.bedtime_outlined, color: active ? ShamlssColors.divider : ShamlssColors.amberDim, size: 16),
                        title: Text('$min minutes', style: TextStyle(color: active ? ShamlssColors.divider : ShamlssColors.text, fontSize: 13)),
                        onTap: active ? null : () => widget.sleepTimer.set(Duration(minutes: min)),
                      )),
                    ]);
                  },
                ),
              ]),
              const SizedBox(height: 8),
              _Section('CROSSFADE', [
                ListenableBuilder(
                  listenable: widget.player,
                  builder: (_, __) {
                    final current = widget.player.crossfadeSec;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(current == 0 ? 'Off' : '$current seconds',
                            style: const TextStyle(color: ShamlssColors.text, fontSize: 13)),
                        const SizedBox(height: 8),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [0, 3, 5, 8].map((s) => GestureDetector(
                            onTap: () => widget.player.setCrossfade(s),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: current == s ? ShamlssColors.amber : ShamlssColors.surface,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: current == s ? ShamlssColors.amber : ShamlssColors.divider),
                              ),
                              child: Text(s == 0 ? 'Off' : '${s}s',
                                  style: TextStyle(color: current == s ? ShamlssColors.black : ShamlssColors.textMuted, fontSize: 12)),
                            ),
                          )).toList(),
                        ),
                      ]),
                    );
                  },
                ),
              ]),
              const SizedBox(height: 8),
              _Section('AUTO-MIX', [
                ListenableBuilder(
                  listenable: widget.player,
                  builder: (_, __) {
                    final enabled = widget.player.autoMixEnabled;
                    final hasCrossfade = widget.player.crossfadeSec > 0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(
                            'Beat-aligned crossfade',
                            style: TextStyle(
                              color: hasCrossfade ? ShamlssColors.text : ShamlssColors.divider,
                              fontSize: 13,
                            ),
                          )),
                          Switch(
                            value: enabled,
                            activeColor: ShamlssColors.amber,
                            onChanged: hasCrossfade ? (v) => widget.player.setAutoMix(v) : null,
                          ),
                        ]),
                        const SizedBox(height: 4),
                        Text(
                          hasCrossfade
                              ? 'Snaps fade start to nearest beat using BPM data'
                              : 'Enable crossfade first',
                          style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11),
                        ),
                        if (enabled && widget.player.currentBpm != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Current: ${widget.player.currentBpm!.toStringAsFixed(0)} BPM',
                              style: const TextStyle(color: ShamlssColors.amberDim, fontSize: 11),
                            ),
                          ),
                      ]),
                    );
                  },
                ),
              ]),
              const SizedBox(height: 32),
            ]),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section(this.title, this.children);

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (title.isNotEmpty) Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(title, style: const TextStyle(color: ShamlssColors.amberDim, fontSize: 11, letterSpacing: 2)),
      ),
      Container(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: ShamlssColors.divider), bottom: BorderSide(color: ShamlssColors.divider))),
        child: Column(children: children),
      ),
    ]);
  }
}

class _StatChip extends StatelessWidget {
  final String value;
  final String label;
  const _StatChip(this.value, this.label);

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(value, style: const TextStyle(color: ShamlssColors.amber, fontSize: 18, fontWeight: FontWeight.bold)),
      Text(label, style: const TextStyle(color: ShamlssColors.divider, fontSize: 10, letterSpacing: 0.5)),
    ]);
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  const _InfoRow(this.label, this.value, {this.mono = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 110, child: Text(label, style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 12))),
        Expanded(child: Text(value, style: TextStyle(color: ShamlssColors.text, fontSize: 12, fontFamily: mono ? 'monospace' : null), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}
