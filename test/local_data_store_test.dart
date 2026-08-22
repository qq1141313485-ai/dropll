import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cai_tool_app/local_data_store.dart';
import 'package:cai_tool_app/plan_content_favorite_store.dart';
import 'package:cai_tool_app/saved_scheme_store.dart';

String _contentFavorite(String id, {DateTime? savedAt}) => jsonEncode({
      'id': id,
      'name': '收藏$id',
      'sourceId': 'article:$id',
      'sourceName': '来源',
      'updateId': 'version-$id',
      'updateTitle': '版本$id',
      'sourceUpdatedAt': DateTime.now().toIso8601String(),
      'savedAt': (savedAt ?? DateTime.now()).toIso8601String(),
      'images': [
        {
          'imageUrl': 'https://example.com/$id.jpg',
          'thumbnailUrl': 'https://example.com/${id}_thumb.jpg',
        }
      ],
    });

String _savedScheme(String id, {DateTime? createdAt}) => jsonEncode({
      'id': id,
      'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      planContentFavoritesKey: [_contentFavorite('one')],
      planFavoriteSourceIdsKey: ['article:one', 'article:one', 'legacy:two'],
      savedFootballSchemesKey: [_savedScheme('one')],
    });
  });

  test('summarizes the three independent local data categories', () async {
    final summary = await const LocalDataStore().loadSummary();

    expect(summary.contentFavorites, 1);
    expect(summary.followedPlans, 2);
    expect(summary.savedSchemes, 1);
  });

  test('clearing one category preserves the other two', () async {
    const store = LocalDataStore();
    await store.clear(LocalDataKind.followedPlans);
    final summary = await store.loadSummary();

    expect(summary.contentFavorites, 1);
    expect(summary.followedPlans, 0);
    expect(summary.savedSchemes, 1);
  });

  test('backup exports normalized valid local data', () async {
    final now = DateTime(2026, 8, 23, 12);
    SharedPreferences.setMockInitialValues({
      planContentFavoritesKey: [
        _contentFavorite('one', savedAt: now),
        'damaged',
      ],
      planFavoriteSourceIdsKey: [' article:one ', '', 'article:one'],
      savedFootballSchemesKey: [
        _savedScheme('current', createdAt: now),
        _savedScheme('expired',
            createdAt: now.subtract(const Duration(days: 8))),
      ],
    });

    final raw = await const LocalDataStore().createBackupJson(exportedAt: now);
    final backup = const LocalDataStore().decodeBackup(raw, now: now);

    expect(backup.summary.contentFavorites, 1);
    expect(backup.followedPlanIds, ['article:one']);
    expect(backup.summary.savedSchemes, 1);
  });

  test('rejects files that are not a supported backup', () {
    expect(
      () => const LocalDataStore().decodeBackup('{"format":"other"}'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => const LocalDataStore().decodeBackup(jsonEncode({
        'format': LocalDataStore.backupFormat,
        'version': 2,
      })),
      throwsA(isA<FormatException>()),
    );
  });

  test('restore keeps existing data and only adds missing items', () async {
    final now = DateTime.now();
    final backup = const LocalDataStore().decodeBackup(
      jsonEncode({
        'format': LocalDataStore.backupFormat,
        'version': LocalDataStore.backupVersion,
        'contentFavorites': [
          jsonDecode(_contentFavorite('one', savedAt: now)),
          jsonDecode(_contentFavorite('two', savedAt: now)),
        ],
        'followedPlanIds': ['article:one', 'article:three'],
        'savedSchemes': [
          _savedScheme('one', createdAt: now),
          _savedScheme('two', createdAt: now),
        ],
      }),
      now: now,
    );

    final result = await const LocalDataStore().mergeBackup(backup);
    final summary = await const LocalDataStore().loadSummary();

    expect(result.addedContentFavorites, 1);
    expect(result.addedFollowedPlans, 1);
    expect(result.addedSavedSchemes, 1);
    expect(summary.contentFavorites, 2);
    expect(summary.followedPlans, 3);
    expect(summary.savedSchemes, 2);
  });
}
