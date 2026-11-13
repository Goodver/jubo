import 'package:flutter_test/flutter_test.dart';
import 'package:hgonly/models.dart';

void main() {
  test('目录页解析', () {
    final page = CatalogPage.fromJson({
      'items': [
        {'id': 'hongguo:1', 'title': '测试剧', 'episodes': 12, 'cover': 'x'},
      ],
      'hasMore': true,
      'page': 2,
    });
    expect(page.items.single.title, '测试剧');
    expect(page.items.single.episodeCount, 12);
    expect(page.hasMore, isTrue);
    expect(page.page, 2);
  });

  test('播放计划解析', () {
    final plan = PlaybackPlan.fromJson({
      'url': 'http://127.0.0.1:1/a.mp4',
      'headers': {'Referer': 'r'},
      'decryptionKey': 'k',
      'quality': 720,
      'routeCount': 4,
    });
    expect(plan.quality, 720);
    expect(plan.headers['Referer'], 'r');
    expect(plan.routeCount, 4);
  });
}
