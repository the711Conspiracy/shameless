import 'package:flutter/material.dart';
import '../core/daemon_client.dart';
import '../core/lan_discovery.dart';
import '../core/queue_persistence.dart';
import '../core/theme.dart';

class ConnectScreen extends StatefulWidget {
  final DaemonClient daemon;
  const ConnectScreen({super.key, required this.daemon});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _controller = TextEditingController(text: '127.0.0.1');
  bool _loading = false;
  final _discovery = LanDiscovery();

  @override
  void initState() {
    super.initState();
    _loadLastHost();
    _discovery.addListener(() => setState(() {}));
    _discovery.start();
  }

  @override
  void dispose() {
    _discovery.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadLastHost() async {
    final host = await QueuePersistence.loadHost();
    if (host != null && mounted) _controller.text = host;
  }

  Future<void> _connect([String? host]) async {
    final h = (host ?? _controller.text).trim();
    if (h.isEmpty) return;
    setState(() => _loading = true);
    await widget.daemon.connect(h);
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final discovered = _discovery.nodes;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(width: 4, height: 36, color: ShamlssColors.amber),
                const SizedBox(width: 12),
                const Text('SHAMLSS', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: ShamlssColors.text, letterSpacing: 4)),
              ]),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.only(left: 16),
                child: Text('local music. your pod.', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 13, letterSpacing: 1)),
              ),

              // ── Discovered nodes ──
              if (discovered.isNotEmpty) ...[
                const SizedBox(height: 32),
                const Text('FOUND ON NETWORK', style: TextStyle(color: ShamlssColors.amberDim, fontSize: 11, letterSpacing: 2)),
                const SizedBox(height: 10),
                ...discovered.map((node) => _DiscoveredCard(
                  node: node,
                  onTap: () => _connect(node.ip),
                  loading: _loading,
                )),
              ],

              const SizedBox(height: 32),
              const Text('DAEMON ADDRESS', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 11, letterSpacing: 2)),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                keyboardType: TextInputType.url,
                style: const TextStyle(color: ShamlssColors.text, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  hintText: '192.168.1.x',
                  suffixText: ':7432',
                  suffixStyle: TextStyle(color: ShamlssColors.amberDim),
                ),
                onSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: 12),
              if (widget.daemon.error != null)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(children: [
                    const Icon(Icons.error_outline, color: Colors.red, size: 14),
                    const SizedBox(width: 8),
                    Expanded(child: Text(widget.daemon.error!, style: const TextStyle(color: Colors.red, fontSize: 12))),
                  ]),
                ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton(
                  onPressed: _loading ? null : () => _connect(),
                  child: _loading
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: ShamlssColors.black))
                      : const Text('CONNECT', style: TextStyle(letterSpacing: 2, fontSize: 13)),
                ),
              ),

              if (discovered.isEmpty) ...[
                const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  SizedBox(width: 10, height: 10, child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: ShamlssColors.divider.withOpacity(0.6),
                  )),
                  const SizedBox(width: 8),
                  const Text('scanning network…', style: TextStyle(color: ShamlssColors.divider, fontSize: 11)),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscoveredCard extends StatelessWidget {
  final DiscoveredNode node;
  final VoidCallback onTap;
  final bool loading;
  const _DiscoveredCard({required this.node, required this.onTap, required this.loading});

  @override
  Widget build(BuildContext context) {
    final age = DateTime.now().difference(node.lastSeen).inSeconds;
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: ShamlssColors.surface,
          border: Border.all(color: ShamlssColors.amberDim.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: age < 8 ? const Color(0xFF22c55e) : ShamlssColors.amberDim,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(node.name, style: const TextStyle(color: ShamlssColors.text, fontSize: 13, fontWeight: FontWeight.w500)),
            Text(node.ip, style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11, fontFamily: 'monospace')),
          ])),
          const Icon(Icons.arrow_forward_ios, color: ShamlssColors.amberDim, size: 14),
        ]),
      ),
    );
  }
}
