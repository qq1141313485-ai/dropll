import 'package:cai_tool_app/plan_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote plan summary preserves server update status and image count',
      () {
    final source = PlanSource.fromSummaryJson({
      'id': 12,
      'name': '单刀',
      'uploaderName': '球镜助手',
      'latestUpdatedAt': '2026-07-25T16:20+08:00',
      'updatedToday': true,
      'aliasIds': [3, '7', '', null],
      'latestImageCount': 7,
      'latestThumbnailUrl':
          'https://api.cclloo.com/media/plans/example_thumb.jpg',
    });

    expect(source.id, '12');
    expect(source.isRemote, isTrue);
    expect(source.updatedToday, isTrue);
    expect(source.aliasIds, {'3', '7'});
    expect(source.latestUpdate.displayImageCount, 7);
    expect(source.latestUpdate.images.single.isRemote, isTrue);
  });

  test('remote update keeps original and thumbnail URLs', () {
    final update = PlanUpdate.fromJson({
      'id': 31,
      'title': '今日更新',
      'publishedAt': '2026-07-25T16:20+08:00',
      'images': [
        {
          'imageUrl': 'https://api.cclloo.com/media/plans/example.jpg',
          'thumbnailUrl':
              'https://api.cclloo.com/media/plans/example_thumb.jpg',
          'width': 900,
          'height': 1400,
        },
      ],
    });

    expect(update.images.single.imageUrl, endsWith('/example.jpg'));
    expect(update.images.single.thumbnailUrl, endsWith('/example_thumb.jpg'));
    expect(update.images.single.width, 900);
    expect(update.images.single.height, 1400);
  });

  test('remote update drops images without original URL', () {
    final update = PlanUpdate.fromJson({
      'id': 31,
      'title': '今日更新',
      'publishedAt': '2026-07-25T16:20+08:00',
      'images': [
        {'imageUrl': '', 'thumbnailUrl': ''},
        {
          'imageUrl': 'https://api.cclloo.com/media/plans/example.jpg',
          'thumbnailUrl':
              'https://api.cclloo.com/media/plans/example_thumb.jpg',
        },
      ],
    });

    expect(update.images, hasLength(1));
    expect(update.images.single.imageUrl, endsWith('/example.jpg'));
  });

  test('remote plan summary without thumbnail is treated as not displayable',
      () {
    final source = PlanSource.fromSummaryJson({
      'id': 12,
      'name': '单刀',
      'latestUpdatedAt': '2026-07-25T16:20+08:00',
      'updatedToday': true,
      'latestImageCount': 0,
      'latestThumbnailUrl': '',
    });

    expect(source.activeUpdates, isEmpty);
  });
}
