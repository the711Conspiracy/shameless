import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class DaemonClient extends ChangeNotifier {
  String? _host;
  final int _port = 7432;
  bool _connected = false;
  String? _nodeId;
  String? _nodeName;
  String? _error;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;

  final _libraryUpdated = StreamController<void>.broadcast();
  Stream<void> get onLibraryUpdated => _libraryUpdated.stream;

  final _queueUpdated = StreamController<void>.broadcast();
  Stream<void> get onQueueUpdated => _queueUpdated.stream;

  // Error stream — all silent failures emit here so the UI can surface them
  final _errors = StreamController<String>.broadcast();
  Stream<String> get errors => _errors.stream;

  // Active pod context — set when the user opens a pod detail
  Map<String, dynamic>? _activePod;
  Map<String, dynamic>? get activePod => _activePod;

  void setActivePod(Map<String, dynamic>? pod) {
    _activePod = pod;
    notifyListeners();
  }

  bool get connected => _connected;
  String? get nodeId => _nodeId;
  String? get nodeName => _nodeName;
  String? get error => _error;
  String? get host => _host;
  String get base => 'http://$_host:$_port';
  String streamUrl(String trackId) => 'http://$_host:$_port/stream/$trackId';
  String artUrl(String trackId) => 'http://$_host:$_port/library/art/$trackId';
  String lyricsUrl(String trackId) => 'http://$_host:$_port/library/lyrics/$trackId';

  void init() {}

  void _emitError(String method, Object e) {
    final msg = '$method: $e';
    debugPrint('[DaemonClient] $msg');
    _errors.add(msg);
  }

  void _connectWs() {
    _ws = WebSocketChannel.connect(Uri.parse('ws://$_host:$_port'));
    _wsSub = _ws!.stream.listen((msg) {
      try {
        final data = jsonDecode(msg as String) as Map<String, dynamic>;
        if (data['type'] == 'library_updated') _libraryUpdated.add(null);
        if (data['type'] == 'queue_track_added' || data['type'] == 'queue_cleared') _queueUpdated.add(null);
      } catch (_) {}
    }, onDone: _reconnectWs, onError: (e) {
      debugPrint('[DaemonClient] WebSocket error: $e');
      _reconnectWs();
    });
  }

  void _reconnectWs() {
    if (!_connected) return;
    Future.delayed(const Duration(seconds: 5), () { if (_connected) _connectWs(); });
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _ws?.sink.close();
    _libraryUpdated.close();
    _queueUpdated.close();
    _errors.close();
    super.dispose();
  }

  Future<void> connect(String host) async {
    _host = host;
    _error = null;
    try {
      final res = await http.get(Uri.parse('http://$host:$_port/ping'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        _nodeId = data['node_id'];
        _nodeName = data['name'];
        _connected = true;
        _connectWs();
      } else {
        _error = 'Daemon returned ${res.statusCode}';
      }
    } on TimeoutException {
      _error = 'Connection timed out — is the daemon running on $host?';
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  void disconnect() {
    _connected = false;
    _host = null;
    _nodeId = null;
    _nodeName = null;
    _activePod = null;
    _wsSub?.cancel();
    _wsSub = null;
    _ws?.sink.close();
    _ws = null;
    notifyListeners();
  }

  // ── Read helpers (return empty/null on failure, emit to error stream) ──

  Future<List<Map<String, dynamic>>> getTracks() async {
    try {
      final res = await http.get(Uri.parse('$base/library/tracks'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      _emitError('getTracks', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('getTracks', e); }
    return [];
  }

  Future<List<String>> getFolders() async {
    try {
      final res = await http.get(Uri.parse('$base/library/folders'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return List<String>.from(jsonDecode(res.body));
      _emitError('getFolders', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('getFolders', e); }
    return [];
  }

  // Returns scan result map {indexed, files_found, skipped} — throws on failure
  Future<Map<String, dynamic>> addFolder(String path) async {
    final res = await http.post(Uri.parse('$base/library/folders'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'folder_path': path}))
        .timeout(const Duration(seconds: 120));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode == 200) return body;
    throw Exception(body['error'] ?? 'HTTP ${res.statusCode}');
  }

  // Throws on failure
  Future<void> removeFolder(String path) async {
    final res = await http.delete(Uri.parse('$base/library/folders'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'folder_path': path}))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'HTTP ${res.statusCode}');
    }
  }

  Future<List<Map<String, dynamic>>> getPlaylists() async {
    try {
      final res = await http.get(Uri.parse('$base/playlists'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      _emitError('getPlaylists', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('getPlaylists', e); }
    return [];
  }

  Future<Map<String, dynamic>?> getPlaylist(String id) async {
    try {
      final res = await http.get(Uri.parse('$base/playlists/$id'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return Map<String, dynamic>.from(jsonDecode(res.body));
      _emitError('getPlaylist', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('getPlaylist', e); }
    return null;
  }

  // Returns new playlist id — throws on failure
  Future<String> createPlaylist(String name) async {
    final res = await http.post(Uri.parse('$base/playlists'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name}))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 201) return (jsonDecode(res.body) as Map)['id'] as String;
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    throw Exception(body['error'] ?? 'HTTP ${res.statusCode}');
  }

  // Throws on failure
  Future<void> deletePlaylist(String id) async {
    final res = await http.delete(Uri.parse('$base/playlists/$id'))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
  }

  Future<void> addTrackToPlaylist(String playlistId, String trackId) async {
    try {
      final res = await http.post(Uri.parse('$base/playlists/$playlistId/tracks'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'track_id': trackId}))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200 && res.statusCode != 201) {
        _emitError('addTrackToPlaylist', 'HTTP ${res.statusCode}');
      }
    } catch (e) { _emitError('addTrackToPlaylist', e); }
  }

  Future<void> removeTrackFromPlaylist(String playlistId, String trackId) async {
    try {
      final res = await http.delete(Uri.parse('$base/playlists/$playlistId/tracks/$trackId'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        _emitError('removeTrackFromPlaylist', 'HTTP ${res.statusCode}');
      }
    } catch (e) { _emitError('removeTrackFromPlaylist', e); }
  }

  String playlistExportUrl(String playlistId) => '$base/playlists/$playlistId/export.m3u';

  Future<List<Map<String, dynamic>>> getHistory({int limit = 20}) async {
    try {
      final res = await http.get(Uri.parse('$base/history?limit=$limit'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      _emitError('getHistory', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('getHistory', e); }
    return [];
  }

  Future<Map<String, dynamic>?> getStats() async {
    try {
      final res = await http.get(Uri.parse('$base/stats'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return Map<String, dynamic>.from(jsonDecode(res.body));
      _emitError('getStats', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('getStats', e); }
    return null;
  }

  Future<Map<String, dynamic>?> getAnalysis(String trackId) async {
    try {
      final res = await http.get(Uri.parse('$base/analysis/$trackId'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return Map<String, dynamic>.from(jsonDecode(res.body));
      if (res.statusCode != 404) _emitError('getAnalysis', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('getAnalysis', e); }
    return null;
  }

  Future<Map<String, dynamic>?> getAnalysisStatus() async {
    try {
      final res = await http.get(Uri.parse('$base/analysis/status'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return Map<String, dynamic>.from(jsonDecode(res.body));
    } catch (e) { _emitError('getAnalysisStatus', e); }
    return null;
  }

  Future<Map<String, dynamic>?> triggerAnalysisScan() async {
    try {
      final res = await http.post(Uri.parse('$base/analysis/scan'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return Map<String, dynamic>.from(jsonDecode(res.body));
      _emitError('triggerAnalysisScan', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('triggerAnalysisScan', e); }
    return null;
  }

  Future<List<double>?> getTrackWaveform(String trackId) async {
    try {
      final res = await http.get(Uri.parse('$base/analysis/$trackId/waveform'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return List<double>.from((data['samples'] as List).map((v) => (v as num).toDouble()));
      }
      if (res.statusCode != 404) _emitError('getTrackWaveform', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('getTrackWaveform', e); }
    return null;
  }

  Future<List<Map<String, dynamic>>> getSimilarTracks(String trackId) async {
    try {
      final res = await http.get(Uri.parse('$base/analysis/similar/$trackId'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return List<Map<String, dynamic>>.from(jsonDecode(res.body));
    } catch (e) { _emitError('getSimilarTracks', e); }
    return [];
  }

  Future<List<Map<String, dynamic>>> getCollabQueue() async {
    try {
      final res = await http.get(Uri.parse('$base/queue/collab'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      _emitError('getCollabQueue', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('getCollabQueue', e); }
    return [];
  }

  Future<bool> addToCollabQueue(String trackId, {String? addedBy}) async {
    try {
      final res = await http.post(Uri.parse('$base/queue/collab'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'track_id': trackId, 'added_by': addedBy}))
          .timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (e) { _emitError('addToCollabQueue', e); }
    return false;
  }

  Future<void> removeFromCollabQueue(int id) async {
    try {
      await http.delete(Uri.parse('$base/queue/collab/$id'))
          .timeout(const Duration(seconds: 10));
    } catch (e) { _emitError('removeFromCollabQueue', e); }
  }

  Future<void> clearCollabQueue() async {
    try {
      await http.delete(Uri.parse('$base/queue/collab'))
          .timeout(const Duration(seconds: 10));
    } catch (e) { _emitError('clearCollabQueue', e); }
  }

  Future<List<Map<String, dynamic>>> getFeed({int limit = 50}) async {
    try {
      final res = await http.get(Uri.parse('$base/feed?limit=$limit'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      _emitError('getFeed', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('getFeed', e); }
    return [];
  }

  // ── Generic JSON helpers ──
  // Returns parsed JSON (Map or List) on 2xx, null on error. Errors are emitted to the error stream.
  Future<dynamic> get(String path) async {
    if (_host == null) return null;
    try {
      final res = await http.get(Uri.parse('$base$path'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (res.body.isEmpty) return null;
        return jsonDecode(res.body);
      }
      _emitError('get $path', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('get $path', e); }
    return null;
  }

  Future<dynamic> post(String path, [Map<String, dynamic>? body]) async {
    if (_host == null) return null;
    try {
      final res = await http.post(Uri.parse('$base$path'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body ?? const {}))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (res.body.isEmpty) return null;
        return jsonDecode(res.body);
      }
      _emitError('post $path', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('post $path', e); }
    return null;
  }

  Future<dynamic> patch(String path, [Map<String, dynamic>? body]) async {
    if (_host == null) return null;
    try {
      final res = await http.patch(Uri.parse('$base$path'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body ?? const {}))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (res.body.isEmpty) return null;
        return jsonDecode(res.body);
      }
      _emitError('patch $path', 'HTTP ${res.statusCode}');
    } catch (e) { _emitError('patch $path', e); }
    return null;
  }
}
