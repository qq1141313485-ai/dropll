import 'package:cai_tool_app/models.dart';
import 'package:cai_tool_app/widgets/home/home_match_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stale live data keeps the last valid match status', (
    tester,
  ) async {
    final match = MatchItem.fromJson({
      'id': 'live-1',
      'number': '周日201',
      'businessDate': '2026-07-26',
      'league': '测试联赛',
      'home': '主队',
      'away': '客队',
      'kickoff': '2026-07-26T16:00:00+08:00',
      'status': 'LIVE',
      'matchState': 'live',
      'matchStateText': '进行中',
      'liveStatusText': '67',
      'titanLastUpdated': DateTime.now()
          .subtract(const Duration(minutes: 5))
          .toUtc()
          .toIso8601String(),
      'score': '1:0',
      'odds': const <String, dynamic>{},
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeMatchRow(match: match),
        ),
      ),
    );

    expect(find.text('比分更新中'), findsNothing);
    expect(find.text("67'"), findsOneWidget);
  });
}
