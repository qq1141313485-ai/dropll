import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'api_client.dart';
import 'match_detail_page.dart';
import 'selection_page.dart';
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
      theme: ThemeData(
        useMaterial3: true,
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

  static const pages = [
    ScoreBoardPage(),
    SelectionPage(),
    ScenarioPage(),
    RankingPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: pages[index]),
      bottomNavigationBar: NavigationBar(
        height: 68,
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
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
              icon: Icon(Icons.calculate_outlined),
              selectedIcon: Icon(Icons.calculate),
              label: '情景'),
          NavigationDestination(
              icon: Icon(Icons.leaderboard_outlined),
              selectedIcon: Icon(Icons.leaderboard),
              label: '榜单'),
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
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8)),
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

class ScenarioPage extends StatelessWidget {
  const ScenarioPage({super.key});
  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(18),
        children: const [
          PageTitle('赔率情景', subtitle: '仅作数学比较'),
          _InfoCard(
              icon: Icons.calculate,
              title: '总进球情景分析',
              body: '选择预算与进球数选项，比较不同分配下的理论回报和风险。不会生成投注指令。',
              action: '开始计算'),
          SizedBox(height: 12),
          _Notice(),
        ],
      );
}

class RankingPage extends StatefulWidget {
  const RankingPage({super.key});

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage> {
  final CaiApiClient client = CaiApiClient();
  late Future<List<Map<String, dynamic>>> future;

  @override
  void initState() {
    super.initState();
    future = client.isConfigured
        ? client.fetchModelRankings()
        : Future.value(const <Map<String, dynamic>>[]);
  }

  @override
  void dispose() {
    client.close();
    super.dispose();
  }

  Future<void> _reload() async {
    if (!client.isConfigured) return;
    setState(() {
      future = client.fetchModelRankings();
    });
    await future;
  }

  String _asPercent(dynamic value) {
    final ratio = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (ratio == null) return '--';
    return '${(ratio * 100).round()}%';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 12),
        const PageTitle('首页战绩榜', subtitle: '以命中率和连黑连红为核心'),
        const SizedBox(height: 8),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xff079669),
                    ),
                  );
                }
                final items = snapshot.data ?? const <Map<String, dynamic>>[];
                if (items.isEmpty) {
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(18),
                    children: const [
                      SizedBox(height: 120),
                      Center(
                        child: Text('暂无竞彩场次'),
                      ),
                    ],
                  );
                }
                return ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _RankingRow(
                      rank: index + 1,
                      name: item['model_name']?.toString() ?? '-',
                      samples: (item['samples'] as num?)?.toInt() ?? 0,
                      hits: (item['hits'] as num?)?.toInt() ?? 0,
                      losingStreak:
                          (item['current_black_streak'] as num?)?.toInt() ??
                              (item['losing_streak'] as num?)?.toInt() ??
                              0,
                      winningStreak:
                          (item['current_red_streak'] as num?)?.toInt() ??
                              (item['winning_streak'] as num?)?.toInt() ??
                              0,
                      hitRate: _asPercent(item['hitRate']),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _RankingRow extends StatelessWidget {
  const _RankingRow({
    required this.rank,
    required this.name,
    required this.samples,
    required this.hits,
    required this.losingStreak,
    required this.winningStreak,
    required this.hitRate,
  });

  final int rank;
  final String name;
  final int samples;
  final int hits;
  final int losingStreak;
  final int winningStreak;
  final String hitRate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xffe6e8ea)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: const Color(0xffeefaf6),
            child: Text(
              '$rank',
              style: const TextStyle(
                color: Color(0xff079669),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '闂備礁鎼粔褰掑绩閸楃儑鑰?$samples 闁?闂備礁鎲＄粙鎺楀垂濠靛鍤?$hits 闁?闂佸搫顦弲婵嬪磻閵堝洤鍨?$losingStreak 闁?闂佸搫顦弲婵嬪磻閻旇　鍋?$winningStreak',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff80878d),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            hitRate,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: Color(0xff079669),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard(
      {required this.icon,
      required this.title,
      required this.body,
      required this.action});
  final IconData icon;
  final String title;
  final String body;
  final String action;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: const Color(0xff079669)),
          const SizedBox(height: 12),
          Text(title,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(body,
              style: const TextStyle(color: Color(0xff737980), height: 1.5)),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: () {}, child: Text(action))
        ]),
      );
}

class _Notice extends StatelessWidget {
  const _Notice();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
            color: const Color(0xfffff8e9),
            borderRadius: BorderRadius.circular(14)),
        child: const Text(
            '理性购彩提示：本工具不销售彩票，不代购彩票，不承诺收益；模型观点和赔率计算仅供数据研究与娱乐参考。未成年人请勿参与彩票活动。',
            style:
                TextStyle(fontSize: 12, color: Color(0xff8a6418), height: 1.5)),
      );
}
