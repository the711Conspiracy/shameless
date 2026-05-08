import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class DiscoveredNode {
  final String nodeId;
  final String name;
  final String ip;
  final int port;
  final DateTime lastSeen;

  const DiscoveredNode({
    required this.nodeId,
    required this.name,
    required this.ip,
    required this.port,
    required this.lastSeen,
  });
}

class LanDiscovery extends ChangeNotifier {
  static const _port = 7433;
  static const _ttl = Duration(seconds: 20);

  RawDatagramSocket? _socket;
  Timer? _cleanupTimer;
  final _nodes = <String, DiscoveredNode>{};

  List<DiscoveredNode> get nodes {
    final list = _nodes.values.toList();
    list.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return list;
  }

  Future<void> start() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _port,
        reuseAddress: true,
        reusePort: false,
      );
      _socket!.broadcastEnabled = true;
      _socket!.listen(_onEvent);
      _cleanupTimer = Timer.periodic(const Duration(seconds: 15), (_) => _cleanup());
    } catch (e) {
      debugPrint('[LanDiscovery] bind failed on port $_port: $e');
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    try {
      final data = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      final nodeId = data['node_id'] as String?;
      final name = data['name'] as String?;
      if (nodeId == null || name == null) return;
      _nodes[nodeId] = DiscoveredNode(
        nodeId: nodeId,
        name: name,
        ip: dg.address.address,
        port: data['port'] as int? ?? 7432,
        lastSeen: DateTime.now(),
      );
      notifyListeners();
    } catch (_) {}
  }

  void _cleanup() {
    final cutoff = DateTime.now().subtract(_ttl);
    final removed = _nodes.keys.where((k) => _nodes[k]!.lastSeen.isBefore(cutoff)).toList();
    if (removed.isEmpty) return;
    for (final k in removed) _nodes.remove(k);
    notifyListeners();
  }

  void stop() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _socket?.close();
    _socket = null;
    _nodes.clear();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
