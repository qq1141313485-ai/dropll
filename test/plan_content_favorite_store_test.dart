import 'package:cai_tool_app/plan_content_favorite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

PlanContentFavorite favorite(String id, DateTime savedAt) =>
    PlanContentFavorite(
      id: id,
      name: '客厅方案',
      sourceId: '12',
      sourceName: '原文合集',
      updateId: '31',
      updateTitle: '今日更新',
      sourceUpdatedAt: DateTime(2026, 8, 22),
      savedAt: savedAt,
      images: const [
        PlanContentFavoriteImage(
          imageUrl: 'https://api.cclloo.com/media/plans/a.jpg',
          thumbnailUrl: 'https://api.cclloo.com/media/plans/a_thumb.jpg',
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('favorite snapshot round-trips with its selected images', () async {
    final item = favorite('one', DateTime(2026, 8, 23, 10));
    await const PlanContentFavoriteStore().save(item);

    final loaded = await const PlanContentFavoriteStore().load();

    expect(loaded, hasLength(1));
    expect(loaded.single.name, '客厅方案');
    expect(loaded.single.images.single.imageUrl, endsWith('/a.jpg'));
  });

  test('saving same id replaces snapshot without creating a duplicate',
      () async {
    final store = const PlanContentFavoriteStore();
    final first = favorite('same', DateTime(2026, 8, 23, 10));
    final renamed = PlanContentFavorite(
      id: first.id,
      name: '重新命名',
      sourceId: first.sourceId,
      sourceName: first.sourceName,
      updateId: first.updateId,
      updateTitle: first.updateTitle,
      sourceUpdatedAt: first.sourceUpdatedAt,
      savedAt: DateTime(2026, 8, 23, 11),
      images: first.images,
    );

    await store.save(first);
    await store.save(renamed);

    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.name, '重新命名');
  });

  test('damaged entries do not hide valid favorites', () {
    final valid = favorite('valid', DateTime(2026, 8, 23));
    final decoded = decodePlanContentFavorites([
      '{broken',
      '{"id":"empty","images":[]}',
      // Use the store-compatible JSON representation.
      '{"id":"${valid.id}","name":"${valid.name}",'
          '"sourceId":"12","sourceName":"原文合集",'
          '"updateId":"31","updateTitle":"今日更新",'
          '"sourceUpdatedAt":"2026-08-22T00:00:00.000",'
          '"savedAt":"2026-08-23T00:00:00.000",'
          '"images":[{"imageUrl":"https://example.com/a.jpg",'
          '"thumbnailUrl":"https://example.com/a.jpg"}]}',
    ]);

    expect(decoded.map((item) => item.id), ['valid']);
  });
}
