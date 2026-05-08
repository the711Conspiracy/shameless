import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

const _kQueue = 'shamlss_queue';
const _kIndex = 'shamlss_queue_index';
const _kPosition = 'shamlss_queue_position_ms';
const _kHost = 'shamlss_last_host';

class QueuePersistence {
  static Future<void> save({
    required List<Map<String, dynamic>> queue,
    required int index,
    required int positionMs,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQueue, jsonEncode(queue));
    await prefs.setInt(_kIndex, index);
    await prefs.setInt(_kPosition, positionMs);
  }

  static Future<({List<Map<String, dynamic>> queue, int index, int positionMs})?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kQueue);
    if (raw == null) return null;
    try {
      final queue = List<Map<String, dynamic>>.from(jsonDecode(raw) as List);
      final index = prefs.getInt(_kIndex) ?? 0;
      final posMs = prefs.getInt(_kPosition) ?? 0;
      return (queue: queue, index: index.clamp(0, queue.length - 1), positionMs: posMs);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveHost(String host) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHost, host);
  }

  static Future<String?> loadHost() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kHost);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kQueue);
    await prefs.remove(_kIndex);
    await prefs.remove(_kPosition);
  }
}
