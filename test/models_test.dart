import 'package:cai_tool_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('midnight kickoff is treated as an official time', () {
    final item = MatchItem.fromJson({
      'id': 'midnight',
      'number': '周五201',
      'businessDate': '2026-07-24',
      'league': '芬超',
      'home': '雅罗',
      'away': '塞伊奈',
      'kickoff': '2026-07-25 00:00:00',
      'status': 'PENDING',
      'matchState': 'not_started',
      'odds': const {},
    });

    expect(item.hasOfficialKickoffTime, isTrue);
    expect(item.kickoffDisplayTime, '00:00');
  });
}
