import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class BroadcastSession {
  final DateTime startedAt;
  final DateTime? endedAt;
  final int durationSeconds;

  const BroadcastSession({
    required this.startedAt,
    this.endedAt,
    required this.durationSeconds,
  });

  Map<String, dynamic> toJson() => {
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'durationSeconds': durationSeconds,
      };

  factory BroadcastSession.fromJson(Map<String, dynamic> json) =>
      BroadcastSession(
        startedAt: DateTime.parse(json['startedAt'] as String),
        endedAt: json['endedAt'] != null
            ? DateTime.parse(json['endedAt'] as String)
            : null,
        durationSeconds: json['durationSeconds'] as int? ?? 0,
      );
}

/// Logs each broadcast session locally (start time, end time, duration) so
/// the person can see a record of past shows. Kept in Dart/shared_preferences
/// rather than native — this is purely a UI-facing record, not part of the
/// audio pipeline, so it doesn't need to live in BroadcastService.
class BroadcastHistoryService {
  static const _prefsKey = 'broadcast_history';
  static const _maxEntries = 200; // avoid unbounded growth over months of use

  Future<List<BroadcastSession>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    if (stored == null) return [];
    try {
      final decoded = jsonDecode(stored) as List;
      return decoded
          .map((e) => BroadcastSession.fromJson(e as Map<String, dynamic>))
          .toList()
          .reversed
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> recordSession(DateTime startedAt, DateTime endedAt) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await loadHistory();

    final session = BroadcastSession(
      startedAt: startedAt,
      endedAt: endedAt,
      durationSeconds: endedAt.difference(startedAt).inSeconds,
    );

    final combined = [...existing, session]
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final trimmed = combined.length > _maxEntries
        ? combined.sublist(combined.length - _maxEntries)
        : combined;

    final encoded = jsonEncode(trimmed.map((s) => s.toJson()).toList());
    await prefs.setString(_prefsKey, encoded);
  }

  Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
