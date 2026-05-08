import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../core/daemon_client.dart';
import '../core/theme.dart';

// ─── Host side: show QR for guest to scan ───────────────────────────────────

class HostPairingScreen extends StatefulWidget {
  final DaemonClient daemon;
  final String podId;
  final String podName;
  const HostPairingScreen({super.key, required this.daemon, required this.podId, required this.podName});

  @override
  State<HostPairingScreen> createState() => _HostPairingScreenState();
}

class _HostPairingScreenState extends State<HostPairingScreen> {
  String? _qrData;
  String? _error;
  bool _loading = true;
  bool _paired = false;

  @override
  void initState() {
    super.initState();
    _openSession();
  }

  Future<void> _openSession() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await http.post(
        Uri.parse('${widget.daemon.base}/pods/${widget.podId}/pair/open'),
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() { _qrData = data['qr_payload'] as String; _loading = false; });
      } else {
        setState(() { _error = 'Server error ${res.statusCode}'; _loading = false; });
      }
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('PAIR — ${widget.podName}', style: const TextStyle(letterSpacing: 2, fontSize: 13))),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2)
            : _error != null
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error!, style: const TextStyle(color: ShamlssColors.textMuted)),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _openSession, child: const Text('RETRY')),
                  ])
                : _paired
                    ? const Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.check_circle, color: ShamlssColors.amber, size: 64),
                        SizedBox(height: 16),
                        Text('Paired!', style: TextStyle(color: ShamlssColors.text, fontSize: 18)),
                      ])
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('Guest scans this QR', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 13, letterSpacing: 1)),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                          child: QrImageView(data: _qrData!, size: 240, version: QrVersions.auto),
                        ),
                        const SizedBox(height: 24),
                        const Text('Valid for 60 seconds', style: TextStyle(color: ShamlssColors.divider, fontSize: 11, letterSpacing: 1)),
                        const SizedBox(height: 24),
                        OutlinedButton(onPressed: _openSession, child: const Text('REFRESH QR')),
                      ]),
      ),
    );
  }
}

// ─── Guest side: scan QR and complete pairing ────────────────────────────────

class GuestScanScreen extends StatefulWidget {
  final DaemonClient daemon;
  const GuestScanScreen({super.key, required this.daemon});

  @override
  State<GuestScanScreen> createState() => _GuestScanScreenState();
}

class _GuestScanScreenState extends State<GuestScanScreen> {
  bool _scanning = true;
  bool _processing = false;
  String? _error;
  String? _successMsg;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!_scanning || _processing) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;

    setState(() { _scanning = false; _processing = true; _error = null; });

    try {
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      final hostIp = _resolveHostIp(payload);
      final hostPort = payload['host_port'] as int? ?? 7432;
      final podId = payload['pod_id'] as String;
      final nonce = payload['nonce'] as String;

      final myNode = await _getMyNode();

      final res = await http.post(
        Uri.parse('http://$hostIp:$hostPort/pods/$podId/pair/complete'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'guest_node_id': myNode['node_id'],
          'guest_pubkey': myNode['pubkey'],
          'guest_cert': myNode['cert'],
          'nonce': nonce,
          'display_name': myNode['display_name'],
        }),
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        // Register pod membership in our own daemon
        try {
          await http.post(
            Uri.parse('${widget.daemon.base}/pods/join'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'pod_id': data['pod_id'],
              'pod_name': data['pod_name'],
              'pod_keypair': data['pod_keypair'],
              'host_node_id': data['host_node_id'],
              'host_ip': hostIp,
              'host_port': hostPort,
            }),
          ).timeout(const Duration(seconds: 5));
        } catch (_) {}
        setState(() { _processing = false; _successMsg = 'Joined pod: ${data['pod_name']}'; });
      } else {
        setState(() { _processing = false; _error = 'Pairing failed: ${res.statusCode}'; _scanning = true; });
      }
    } catch (e) {
      setState(() { _processing = false; _error = e.toString(); _scanning = true; });
    }
  }

  String _resolveHostIp(Map<String, dynamic> payload) {
    final qrIp = payload['host_ip'] as String?;
    if (qrIp != null && qrIp.isNotEmpty) return qrIp;
    return widget.daemon.host ?? 'localhost';
  }

  Future<Map<String, dynamic>> _getMyNode() async {
    try {
      final res = await http.get(Uri.parse('${widget.daemon.base}/identity'));
      if (res.statusCode == 200) return Map<String, dynamic>.from(jsonDecode(res.body));
    } catch (_) {}
    return {'node_id': 'unknown', 'pubkey': '', 'cert': '', 'display_name': 'Guest'};
  }

  @override
  Widget build(BuildContext context) {
    if (_successMsg != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('PAIRED', style: TextStyle(letterSpacing: 3, fontSize: 14))),
        body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle, color: ShamlssColors.amber, size: 64),
          const SizedBox(height: 16),
          Text(_successMsg!, style: const TextStyle(color: ShamlssColors.text, fontSize: 16), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('DONE')),
        ])),
      );
    }

    // Desktop platforms don't have a camera — show manual IP entry fallback
    final isMobile = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

    return Scaffold(
      appBar: AppBar(title: const Text('SCAN QR', style: TextStyle(letterSpacing: 3, fontSize: 14))),
      body: Column(children: [
        if (_error != null) Container(
          color: ShamlssColors.surface,
          padding: const EdgeInsets.all(12),
          child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ),
        Expanded(
          child: _processing
              ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(color: ShamlssColors.amber, strokeWidth: 2),
                  SizedBox(height: 16),
                  Text('Pairing…', style: TextStyle(color: ShamlssColors.textMuted)),
                ]))
              : isMobile
                  ? MobileScanner(onDetect: _onDetect)
                  : _DesktopQrEntry(onSubmit: (raw) => _onDetect(BarcodeCapture(barcodes: [Barcode(rawValue: raw)]))),
        ),
      ]),
    );
  }
}

class _DesktopQrEntry extends StatelessWidget {
  final Function(String) onSubmit;
  final _ctrl = TextEditingController();
  _DesktopQrEntry({required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Text('Paste QR payload from host', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 13)),
        const SizedBox(height: 16),
        TextField(controller: _ctrl, maxLines: 4, style: const TextStyle(color: ShamlssColors.text, fontSize: 11, fontFamily: 'monospace'),
          decoration: const InputDecoration(hintText: '{"pod_id":…}', hintStyle: TextStyle(color: ShamlssColors.divider))),
        const SizedBox(height: 16),
        FilledButton(onPressed: () => onSubmit(_ctrl.text.trim()), child: const Text('PAIR')),
      ]),
    );
  }
}
