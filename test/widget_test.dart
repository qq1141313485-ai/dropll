// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cai_tool_app/main.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: '球镜',
      packageName: 'com.cclloo.caiToolApp',
      version: '1.0.0',
      buildNumber: '4',
      buildSignature: '',
    );
  });

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
    expect(find.text('我的数据'), findsOneWidget);
    expect(find.text('内容收藏'), findsOneWidget);
    expect(find.text('关注更新'), findsOneWidget);
    expect(find.text('保存方案'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('检查 App 更新'), 220);
    expect(find.text('检查 App 更新'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('服务中心'), 260);
    expect(find.text('数据说明'), findsOneWidget);
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.text('服务中心'), findsOneWidget);
    expect(find.text('问题反馈'), findsNothing);
    await tester.scrollUntilVisible(find.text('1.0.0（构建 4）'), 180);
    expect(find.text('1.0.0（构建 4）'), findsOneWidget);
    await tester.tap(find.text('服务中心'));
    await tester.pumpAndSettle();
    expect(find.text('在线客服'), findsOneWidget);
    expect(find.text('内容投诉与下架'), findsOneWidget);
    expect(find.text('更新交流群'), findsNothing);
    expect(find.text('官方门店'), findsNothing);
  });
}
