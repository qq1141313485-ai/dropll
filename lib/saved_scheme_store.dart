import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const savedFootballSchemesKey = 'saved_football_schemes';
const savedFootballSchemeRetention = Duration(days: 7);
const savedFootballSchemeLimit = 200;

DateTime? savedSchemeCreatedAt(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return DateTime.tryParse(decoded['createdAt']?.toString() ?? '');
    }
  } catch (_) {
    final firstBreak = raw.indexOf('\n');
    return DateTime.tryParse(
        firstBreak > 0 ? raw.substring(0, firstBreak) : '');
  }
  return null;
}

String savedSchemeIdentity(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final id = '${decoded['id'] ?? ''}'.trim();
      if (id.isNotEmpty) return 'id:$id';
    }
  } catch (_) {
    // Older saved schemes may be plain text; their full value is the identity.
  }
  return 'raw:$raw';
}

List<String> retainRecentSavedSchemes(
  Iterable<String> values, {
  required DateTime now,
}) {
  final cutoff = now.subtract(savedFootballSchemeRetention);
  return values
      .where((raw) {
        final createdAt = savedSchemeCreatedAt(raw);
        return createdAt != null && !createdAt.isBefore(cutoff);
      })
      .take(savedFootballSchemeLimit)
      .toList(growable: false);
}

class SavedSchemeStore {
  const SavedSchemeStore();

  Future<List<String>> load({DateTime? now}) async {
    final preferences = await SharedPreferences.getInstance();
    final stored =
        preferences.getStringList(savedFootballSchemesKey) ?? const <String>[];
    final retained = retainRecentSavedSchemes(
      stored,
      now: now ?? DateTime.now(),
    );
    if (retained.length != stored.length) {
      await preferences.setStringList(savedFootballSchemesKey, retained);
    }
    return retained;
  }

  Future<void> prepend(String raw, {DateTime? now}) async {
    final retained = await load(now: now);
    await replace([raw, ...retained].take(savedFootballSchemeLimit).toList());
  }

  Future<void> replace(List<String> values) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(savedFootballSchemesKey, values);
  }
}
