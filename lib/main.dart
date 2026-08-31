import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'match_detail_page.dart';
import 'plan_page.dart';
import 'selection_page.dart';
import 'settings_page.dart';
import 'widgets/home/home_page_container.dart';

void main() => runApp(
      CaiToolApp(
        forceStartupSplash:
            !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
      ),
    );

class CaiToolApp extends StatelessWidget {
  const CaiToolApp({this.forceStartupSplash, super.key});

  final bool? forceStartupSplash;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '球镜',
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
      home: _AppEntry(
        showStartupSplash: forceStartupSplash ?? false,
      ),
    );
  }
}

class _AppEntry extends StatefulWidget {
  const _AppEntry({required this.showStartupSplash});

  final bool showStartupSplash;

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  Timer? _timer;
  late bool _showSplash;

  @override
  void initState() {
    super.initState();
    _showSplash = widget.showStartupSplash;
    if (_showSplash) {
      _timer = Timer(const Duration(milliseconds: 650), () {
        if (mounted) setState(() => _showSplash = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: _showSplash
          ? const _LaunchBranding(key: ValueKey('launch-branding'))
          : const AppShell(key: ValueKey('app-shell')),
    );
  }
}

class _LaunchBranding extends StatelessWidget {
  const _LaunchBranding({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff7f9f8),
      body: Center(
        child: Transform.translate(
          offset: const Offset(0, -23),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/branding/app_icon_master_1024.png',
                width: 112,
                height: 112,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 18),
              const Text(
                '球镜',
                style: TextStyle(
                  color: Color(0xff17231e),
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '看比分 · 查赔率 · 找计划',
                style: TextStyle(
                  color: Color(0xff748179),
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
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
  int _settingsRefreshVersion = 0;
  final Set<int> _visitedPages = {0};

  Widget _pageAt(int pageIndex) => switch (pageIndex) {
        0 => const ScoreBoardPage(),
        1 => const SelectionPage(),
        2 => const PlanCenterPage(),
        3 => SettingsPage(refreshVersion: _settingsRefreshVersion),
        _ => const SizedBox.shrink(),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: index,
          children: List.generate(
            4,
            (pageIndex) => _visitedPages.contains(pageIndex)
                ? _pageAt(pageIndex)
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
            if (value == 3) _settingsRefreshVersion += 1;
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
