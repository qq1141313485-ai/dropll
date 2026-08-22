import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cai_tool_app/local_data_store.dart';
import 'package:cai_tool_app/plan_content_favorite_store.dart';
import 'package:cai_tool_app/saved_scheme_store.dart';

String _contentFavorite(String id) => jsonEncode({
      'id': id,
      'name': '收藏$id',
      'sourceId': 'article:$id',
      'sourceName': '来源',
      'updateId': 'version-$id',
      'updateTitle': '版本$id',
      'sourceUpdatedAt': DateTime.now().toIso8601String(),
      'savedAt': DateTime.now().toIso8601String(),
      'images': [
        {
          'imageUrl': 'https://example.com/$id.jpg',
          'thumbnailUrl': 'https://example.com/${id}_thumb.jpg',
        }
      ],
    });

String _savedScheme(String id) => jsonEncode({
      'id': id,
      'createdAt': DateTime.now().toIso8601String(),
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
}
