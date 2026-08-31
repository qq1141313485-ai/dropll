import 'package:cai_tool_app/match_detail_page.dart';
import 'package:cai_tool_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('match detail renders list data before remote details finish', (
    tester,
  ) async {
    final match = MatchItem.fromJson({
      'id': 'instant-detail',
      'number': '周日001',
      'businessDate': '2026-08-31',
      'league': '测试联赛',
      'home': '主队示例',
      'away': '客队示例',
      'kickoff': '2026-08-31 18:00:00',
      'status': 'PENDING',
      'matchState': 'not_started',
      'odds': const {},
    });

    await tester.pumpWidget(MaterialApp(home: MatchDetailV2Page(match: match)));

    expect(find.text('主队示例'), findsWidgets);
    expect(find.text('客队示例'), findsWidgets);
    expect(find.textContaining('测试联赛'), findsWidgets);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
