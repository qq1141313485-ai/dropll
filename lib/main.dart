import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'match_detail_page.dart';
import 'plan_page.dart';
import 'selection_page.dart';
import 'settings_page.dart';
import 'widgets/home/home_page_container.dart';

void main() => runApp(const CaiToolApp());

class CaiToolApp extends StatelessWidget {
  const CaiToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '竞球镜',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => LayoutBuilder(
        builder: (context, constraints) {
          final content = child ?? const SizedBox.shrink();
          if (constraints.maxWidth <= 600) return content;
          return ColoredBox(
            color: const Color(0xffe9eeeb),
            child: Center(
              child: SizedBox(
                width: 560,
                height: constraints.maxHeight,
                child: content,
              ),
            ),
          );
        },
      ),
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'NotoSansSC',
        scaffoldBackgroundColor: const Color(0xfff6f7f8),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff12b981),
          surface: Colors.white,
        ),
        fontFamilyFallback: const [
          'PingFang SC',
          'Microsoft YaHei',
          'sans-serif'
        ],
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xff111315),
          elevation: 0,
          centerTitle: false,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int index = 0;
  final Set<int> _visitedPages = {0};

  static const pages = [
    ScoreBoardPage(),
    SelectionPage(),
    PlanCenterPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: index,
          children: List.generate(
            pages.length,
            (pageIndex) => _visitedPages.contains(pageIndex)
                ? pages[pageIndex]
                : const SizedBox.shrink(),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        height: 68,
        selectedIndex: index,
        onDestinationSelected: (value) {
          if (value == index) return;
          setState(() {
            index = value;
            _visitedPages.add(value);
          });
        },
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.sports_soccer_outlined),
              selectedIcon: Icon(Icons.sports_soccer),
              label: '比分'),
          NavigationDestination(
              icon: Icon(Icons.checklist_outlined),
              selectedIcon: Icon(Icons.checklist),
              label: '选号'),
          NavigationDestination(
              icon: Icon(Icons.collections_bookmark_outlined),
              selectedIcon: Icon(Icons.collections_bookmark),
              label: '计划'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置'),
        ],
      ),
    );
  }
}

class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {this.subtitle, super.key});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 0)),
          if (subtitle != null) ...[
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(subtitle!,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xff8a8f96))),
            ),
          ],
        ],
      ),
    );
  }
}

class ScoreBoardPage extends StatelessWidget {
  const ScoreBoardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return HomePageContainer(
      onMatchTap: (match) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MatchDetailV2Page(match: match)),
      ),
    );
  }
}
