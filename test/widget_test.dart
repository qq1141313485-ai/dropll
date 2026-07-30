// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:cai_tool_app/main.dart';

void main() {
  testWidgets('App renders scoreboard', (WidgetTester tester) async {
    await tester.pumpWidget(const CaiToolApp());
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('即时'), findsOneWidget);
    expect(find.text('完场'), findsOneWidget);
  });

  testWidgets('Plan tab does not present demo data as live content',
      (WidgetTester tester) async {
    await tester.pumpWidget(const CaiToolApp());
    await tester.pump();
    await tester.tap(find.text('计划'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('计划'), findsWidgets);
    expect(find.textContaining('当前显示演示数据'), findsNothing);
  });

  testWidgets('Settings navigation matches the destination page',
      (WidgetTester tester) async {
    await tester.pumpWidget(const CaiToolApp());
    await tester.pump();
    await tester.tap(find.text('设置'));
    await tester.pump();
    expect(find.text('数据说明'), findsOneWidget);
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.text('服务中心'), findsOneWidget);
    await tester.tap(find.text('服务中心'));
    await tester.pumpAndSettle();
    expect(find.text('在线客服'), findsOneWidget);
    expect(find.text('内容投诉与下架'), findsOneWidget);
    expect(find.text('更新交流群'), findsNothing);
    expect(find.text('官方门店'), findsNothing);
  });
}
