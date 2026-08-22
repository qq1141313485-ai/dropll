import 'dart:convert';

import 'package:cai_tool_app/saved_scheme_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _scheme(DateTime createdAt, int id) => jsonEncode({
      'id': '$id',
      'createdAt': createdAt.toIso8601String(),
    });

void main() {
  final now = DateTime(2026, 8, 22, 15);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load removes expired, malformed, and undated schemes', () async {
    final retainedAtBoundary = _scheme(
      now.subtract(savedFootballSchemeRetention),
      1,
    );
    final expired = _scheme(
      now.subtract(savedFootballSchemeRetention).subtract(
            const Duration(microseconds: 1),
          ),
      2,
    );
    SharedPreferences.setMockInitialValues({
      savedFootballSchemesKey: <String>[
        retainedAtBoundary,
        expired,
        '{invalid',
        jsonEncode({'id': 'missing-date'}),
      ],
    });

    final result = await const SavedSchemeStore().load(now: now);
    final preferences = await SharedPreferences.getInstance();

    expect(result, [retainedAtBoundary]);
    expect(preferences.getStringList(savedFootballSchemesKey), result);
  });

  test('legacy timestamp entries remain readable for seven days', () {
    final raw =
        '${now.subtract(const Duration(days: 1)).toIso8601String()}\n旧方案';

    expect(savedSchemeCreatedAt(raw), isNotNull);
    expect(retainRecentSavedSchemes([raw], now: now), [raw]);
  });

  test('prepend persists newest first and enforces the 200 item limit',
      () async {
    final existing = List.generate(
      savedFootballSchemeLimit,
      (index) => _scheme(now.subtract(Duration(minutes: index + 1)), index),
    );
    SharedPreferences.setMockInitialValues({
      savedFootballSchemesKey: existing,
    });
    final newest = _scheme(now, 999);

    await const SavedSchemeStore().prepend(newest, now: now);
    final stored = await const SavedSchemeStore().load(now: now);

    expect(stored, hasLength(savedFootballSchemeLimit));
    expect(stored.first, newest);
    expect(stored, isNot(contains(existing.last)));
  });

  test('replace persists deletion across a new store load', () async {
    final first = _scheme(now, 1);
    final second = _scheme(now, 2);
    SharedPreferences.setMockInitialValues({
      savedFootballSchemesKey: <String>[first, second],
    });

    await const SavedSchemeStore().replace([second]);

    expect(await const SavedSchemeStore().load(now: now), [second]);
  });
}
