import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'api_client.dart';
import 'models.dart';
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

// 濠电儑绲藉ú锔炬崲閸曨垰姹查柍褜鍓涢埀顒侇問閸犳帡宕戦幘缁樼厱婵炲棙鍔曢悘杈ㄣ亜閺囨娅婄€殿喚澧楅幆鏃堟晲閸モ晝鍘戝┑鐐差嚟婵潧锕㈤崷顓燁偨闁汇垹鐏氱€氼剟鏌涢幇闈涘箻婵″弶鎮傞弻锟犲礃椤撶偟鍘繛瀵稿閸犳顕ラ崟顐悑闊洦娲滈ˇ顔尖攽椤旂晫绠扮紒鑼櫕濡叉劙鍩勯崘璺ㄧ＞闂佸搫绋侀崢褰掑焵椤掆偓椤︽壆绮欐径濠庡悑闁告侗鍨辩紞宀€绱撴担鎻掍壕闂佽鍘藉濠氬磻?
// ignore: unused_element
class _DevHelpButton extends StatelessWidget {
  const _DevHelpButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const SizedBox(
          width: 38,
          height: 38,
          child: Icon(Icons.menu_book_outlined,
              size: 20, color: Color(0xff079669)),
        ),
      ),
    );
  }
}

// ignore: unused_element
class _DevHelpSheet extends StatelessWidget {
  const _DevHelpSheet();

  @override
  Widget build(BuildContext context) {
    final items = [
      ('spec.md', '项目目标、页面边界、开发原则'),
      ('api.md', '鍓嶇闇€瑕佺殑鎺ュ彛濂戠害'),
      ('db.md', 'SQLite 琛ㄧ粨鏋勫拰瀛楁鍘熷垯'),
      ('field_map.md', '数据字段对齐原则'),
      ('changes.md', '已确认需求、取消项、待确认项'),
    ];
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xfff6f7f8),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                      color: const Color(0xffd0d4d7),
                      borderRadius: BorderRadius.circular(999)),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '开发说明入口',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                '以后继续开发时，优先看这里，能明显减少来回解释。',
                style: TextStyle(color: Color(0xff757b82), height: 1.4),
              ),
              const SizedBox(height: 14),
              ...items.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xffe5e7e9))),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                              color: const Color(0xffeefaf6),
                              borderRadius: BorderRadius.circular(10)),
                          alignment: Alignment.center,
                          child: const Icon(Icons.description_outlined,
                              size: 18, color: Color(0xff079669)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.$1,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 3),
                              Text(item.$2,
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xff757b82))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: const Color(0xfffff8e9),
                    borderRadius: BorderRadius.circular(16)),
                child: const Text(
                  '后续如果你只说“改首页列表”或“改接口字段”，我会先按这套文档对齐、再动代码。',
                  style: TextStyle(color: Color(0xff8a6418), height: 1.45),
                ),
              ),
            ],
          ),
        ),
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

// ignore: unused_element
String? _extractFinalScore(Map<String, dynamic>? source) {
  if (source == null || source.isEmpty) return null;

  String? parseScore(dynamic value) {
    if (value == null) return null;
    if (value is Map) {
      for (final key in const [
        'finalScore',
        'score',
        'result',
        'value',
        'text',
        'homeScore',
        'awayScore',
        'fullTimeScore',
        'ftScore',
        'full_score',
      ]) {
        final found = parseScore(value[key]);
        if (found != null) return found;
      }
      for (final item in value.values) {
        final found = parseScore(item);
        if (found != null) return found;
      }
    } else if (value is Iterable) {
      for (final item in value) {
        final found = parseScore(item);
        if (found != null) return found;
      }
    } else {
      final text = value.toString().trim();
      final match = RegExp(r'(\d+)\s*[:\-]\s*(\d+)').firstMatch(text);
      if (match != null) return '${match.group(1)}:${match.group(2)}';
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  return parseScore(source);
}

class MatchDetailPage extends StatefulWidget {
  const MatchDetailPage({required this.match, super.key});
  final MatchItem match;

  @override
  State<MatchDetailPage> createState() => _MatchDetailPageState();
}

class _MatchDetailPageState extends State<MatchDetailPage> {
  final CaiApiClient client = CaiApiClient();
  late Future<_MatchDetailBundle> future;

  @override
  void initState() {
    super.initState();
    future = _load();
  }

  @override
  void dispose() {
    client.close();
    super.dispose();
  }

  Future<_MatchDetailBundle> _load() async {
    if (!client.isConfigured) {
      return const _MatchDetailBundle(errorMessage: '数据加载失败，请重试');
    }
    try {
      final values = await Future.wait<Object>([
        client.fetchMatch(widget.match.id),
        client.fetchMatchPredictions(widget.match.id),
      ]);
      return _MatchDetailBundle(
        match: values[0] as MatchItem,
        predictions: values[1] as List<Map<String, dynamic>>,
      );
    } catch (_) {
      return const _MatchDetailBundle(errorMessage: '数据加载失败，请重试');
    }
  }

  Future<void> _reload() async {
    setState(() => future = _load());
    await future;
  }

  String _statusLabel(MatchItem match) {
    final liveText = (match.liveStatusText ?? '').trim();
    if (match.matchState == MatchState.finished) {
      return '完场';
    }
    if (match.matchState == MatchState.notStarted) {
      return '未赛';
    }
    if (match.matchState == MatchState.halftime) {
      return '中场';
    }
    if (match.matchState == MatchState.postponed) {
      return '延期';
    }
    if (match.matchState == MatchState.cancelled) {
      return '取消';
    }
    if (match.matchState == MatchState.suspended) {
      return '暂停';
    }
    if (match.matchState == MatchState.live) {
      return _liveMinute(liveText) ?? '进行中';
    }
    if (liveText.isEmpty) {
      return match.matchStateText.trim().isEmpty
          ? '未知'
          : match.matchStateText.trim();
    }
    if (liveText == '中场' || liveText.contains('中场')) {
      return '中场';
    }
    if (liveText.contains('下半场')) {
      return '下半场';
    }
    return liveText;
  }

  String? _liveMinute(String liveStatusText) {
    final match = RegExp(r"(\d{1,3}(?:\+\d{1,2})?)\s*(?:'|分|分钟)?")
        .firstMatch(liveStatusText);
    final value = match?.group(1)?.trim();
    return value == null || value.isEmpty ? null : "$value'";
  }

  String _scoreText(MatchItem match) {
    final score = (match.matchState == MatchState.finished
            ? match.finalScore
            : match.score) ??
        match.finalScore ??
        match.score ??
        '';
    if (score.isEmpty) {
      return '--';
    }
    return score;
  }

  Color _scoreColor(MatchItem match) {
    if (match.matchState == MatchState.finished) return const Color(0xffe23f67);
    if (match.matchState == MatchState.live ||
        match.matchState == MatchState.halftime) {
      return const Color(0xff45a900);
    }
    return const Color(0xff757b82);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.match.home} vs ${widget.match.away}')),
      body: FutureBuilder<_MatchDetailBundle>(
        future: future,
        builder: (context, snapshot) {
          final data = snapshot.data ?? const _MatchDetailBundle();
          final match = data.match ?? widget.match;
          final loading = snapshot.connectionState == ConnectionState.waiting;
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(14),
              children: [
                _RealDetailHeader(
                  match: match,
                  statusText: _statusLabel(match),
                  scoreText: _scoreText(match),
                  scoreColor: _scoreColor(match),
                ),
                if (loading) const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
                if (data.errorMessage != null) ...[
                  const SizedBox(height: 12),
                  _DetailLoadError(
                    message: data.errorMessage!,
                    onRetry: _reload,
                  ),
                ],
                const SizedBox(height: 12),
                _RealMarketOddsSection(match: match),
                if (data.predictions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _RealPredictionsSection(predictions: data.predictions),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MatchDetailBundle {
  const _MatchDetailBundle({
    this.match,
    this.predictions = const [],
    this.errorMessage,
  });

  final MatchItem? match;
  final List<Map<String, dynamic>> predictions;
  final String? errorMessage;
}

class _RealDetailHeader extends StatelessWidget {
  const _RealDetailHeader({
    required this.match,
    required this.statusText,
    required this.scoreText,
    required this.scoreColor,
  });

  final MatchItem match;
  final String statusText;
  final String scoreText;
  final Color scoreColor;

  @override
  Widget build(BuildContext context) {
    final halfTime = (match.halfTimeScore ?? '').trim();
    final liveStatus = (match.liveStatusText ?? '').trim();
    return _DetailSectionCard(
      title: match.league,
      child: Column(
        children: [
          Text(
            '${match.number}  ${match.kickoffDisplayLabel}',
            style: const TextStyle(fontSize: 12, color: Color(0xff8a8f96)),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  match.home,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(
                width: 116,
                child: Column(
                  children: [
                    Text(
                      statusText,
                      style: TextStyle(
                        color: scoreColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (match.matchState == MatchState.notStarted) ...[
                      const SizedBox(height: 5),
                      Text(
                        match.kickoffDisplayTime,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Color(0xff5f666c),
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 5),
                      Text(
                        scoreText,
                        style: TextStyle(
                          color: scoreColor,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    if (halfTime.isNotEmpty)
                      Text(
                        '半场 $halfTime',
                        style: const TextStyle(fontSize: 11, color: Color(0xff8a8f96)),
                      ),
                    if (liveStatus.isNotEmpty && liveStatus != statusText)
                      Text(
                        liveStatus,
                        style: const TextStyle(fontSize: 11, color: Color(0xff8a8f96)),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Text(
                  match.away,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RealMarketOddsSection extends StatelessWidget {
  const _RealMarketOddsSection({required this.match});

  final MatchItem match;

  Map<String, dynamic> _map(Map source) => Map<String, dynamic>.from(source);

  @override
  Widget build(BuildContext context) {
    final had = _map(match.had);
    final hhad = _map(match.hhad);
    final handicap = hhad.remove('让球')?.toString();
    final ttg = _map(match.ttg);
    final crs = _map(match.crs);
    final hafu = _map(match.hafu);
    if ([had, hhad, ttg, crs, hafu].every((market) => market.isEmpty)) {
      return const SizedBox.shrink();
    }
    return _DetailSectionCard(
      title: '官方赔率',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (had.isNotEmpty) _OddsBlock(title: '胜平负', items: had),
          if (hhad.isNotEmpty) ...[
            const SizedBox(height: 10),
            _OddsBlock(
              title: '让球胜平负',
              items: hhad,
              handicap: handicap,
            ),
          ],
          if (ttg.isNotEmpty) ...[
            const SizedBox(height: 10),
            _OddsBlock(title: '总进球', items: ttg),
          ],
          if (crs.isNotEmpty) ...[
            const SizedBox(height: 10),
            _OddsBlock(title: '比分', items: crs),
          ],
          if (hafu.isNotEmpty) ...[
            const SizedBox(height: 10),
            _OddsBlock(title: '半全场', items: hafu),
          ],
        ],
      ),
    );
  }
}

class _RealPredictionsSection extends StatelessWidget {
  const _RealPredictionsSection({required this.predictions});

  final List<Map<String, dynamic>> predictions;

  String _value(Map<String, dynamic> item, String key) {
    final value = item[key]?.toString().trim() ?? '';
    return value.isEmpty ? '--' : value;
  }

  @override
  Widget build(BuildContext context) {
    return _DetailSectionCard(
      title: '模型预测',
      child: Column(
        children: predictions
            .map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_value(item, 'model_name')),
                    ),
                    Text('方向 ${_value(item, 'predicted_direction')}'),
                    const SizedBox(width: 12),
                    Text('比分 ${_value(item, 'predicted_score')}'),
                  ],
                ),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _DetailLoadError extends StatelessWidget {
  const _DetailLoadError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(message, style: const TextStyle(color: Color(0xff8a8f96))),
        ),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh, size: 17),
          label: const Text('刷新'),
        ),
      ],
    );
  }
}

// 保留到下一轮详情页 UI 清理；当前运行链路不再引用。
// ignore: unused_element
class _DetailHeaderCard extends StatelessWidget {
  const _DetailHeaderCard({
    required this.match,
    required this.statusText,
    required this.scoreText,
    required this.scoreColor,
    required this.detail,
  });

  final MatchItem match;
  final String statusText;
  final String scoreText;
  final Color scoreColor;
  final MatchDetailSnapshot? detail;

  @override
  Widget build(BuildContext context) {
    final kickoff = match.kickoffDisplayLabel;
    final liveStatus = (detail?.liveStatusText ?? match.liveStatusText ?? '').trim();
    final halfTime = (detail?.halfTimeScore ?? match.halfTimeScore ?? '').trim();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xffe5e7e9)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(match.number,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xff757b82))),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xffeefaf6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(match.league,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xff079669))),
              ),
              const Spacer(),
              Text(statusText,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: match.matchState == MatchState.finished
                          ? const Color(0xffe23f67)
                          : (match.matchState == MatchState.live ||
                                  match.matchState == MatchState.halftime
                              ? const Color(0xffe23f67)
                              : const Color(0xff757b82)))),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(match.home,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              SizedBox(
                width: 110,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(scoreText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: scoreColor,
                            height: 1)),
                    const SizedBox(height: 4),
                    if (halfTime.isNotEmpty)
                      Text('半场 $halfTime',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xff8a8f96))),
                    if (liveStatus.isNotEmpty &&
                        (match.matchState == MatchState.live ||
                            match.matchState == MatchState.halftime))
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(liveStatus,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xff8a8f96))),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(kickoff,
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xff8a8f96))),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Text(match.away,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _MarketOddsSection extends StatelessWidget {
  const _MarketOddsSection({required this.detail});

  final MatchDetailSnapshot? detail;

  @override
  Widget build(BuildContext context) {
    if (detail == null) {
      return const _EmptyDetailCard(title: '官方赔率', text: '暂无详情数据');
    }

    final odds = detail!.odds;
    final had = (odds['had'] as Map?)?.cast<String, dynamic>() ?? const {};
    final hhad = (odds['hhad'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ttg = (odds['ttg'] as Map?)?.cast<String, dynamic>() ?? const {};
    final crs = (odds['crs'] as Map?)?.cast<String, dynamic>() ?? const {};
    final hafu = (odds['hafu'] as Map?)?.cast<String, dynamic>() ?? const {};

    return _DetailSectionCard(
      title: '官方赔率',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _OddsBlock(title: '胜平负', items: had),
          if (hhad.isNotEmpty) ...[
            const SizedBox(height: 10),
            _OddsBlock(title: '让球胜平负', items: hhad),
          ],
          if (ttg.isNotEmpty) ...[
            const SizedBox(height: 10),
            _OddsBlock(title: '总进球', items: ttg),
          ],
          if (crs.isNotEmpty) ...[
            const SizedBox(height: 10),
            _OddsBlock(title: '比分', items: crs),
          ],
          if (hafu.isNotEmpty) ...[
            const SizedBox(height: 10),
            _OddsBlock(title: '半全场', items: hafu),
          ],
        ],
      ),
    );
  }
}

// ignore: unused_element
class _OfficialResultSection extends StatelessWidget {
  const _OfficialResultSection({required this.detail});

  final MatchDetailSnapshot? detail;

  @override
  Widget build(BuildContext context) {
    if (detail == null) {
      return const _EmptyDetailCard(title: '官方赛果', text: '暂无详情数据');
    }

    final result = detail!.officialResults;
    if (result.isEmpty) {
      return const _EmptyDetailCard(title: '官方赛果', text: '暂无赛果信息');
    }

    final score = result['sectionsNo999']?.toString().trim();
    final halfScore = result['sectionsNo1']?.toString().trim();
    final matchResults = (result['matchResultList'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList(growable: false) ??
        const <Map<String, dynamic>>[];

    return _DetailSectionCard(
      title: '官方赛果',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MiniTag(
                label: '全场比分',
                value: score?.isNotEmpty == true ? score! : '--',
              ),
              _MiniTag(
                label: '半场比分',
                value: halfScore?.isNotEmpty == true ? halfScore! : '--',
              ),
              _MiniTag(
                label: '是否取消',
                value: result['isCancel']?.toString() ?? '--',
              ),
            ],
          ),
          if (matchResults.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              '赛果明细',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xff12a15d),
              ),
            ),
            const SizedBox(height: 8),
            ...matchResults.map(
              (item) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xfff7f8f8),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xffe3e6e8)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${item['code'] ?? '--'}  ${item['combinationDesc'] ?? item['combination'] ?? '--'}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '赔率 ${item['odds'] ?? '--'}  盘口 ${item['goalLine'] ?? '--'}  返奖 ${item['refundStatus'] ?? '--'}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xff5f666c),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: result.entries
                .where((entry) =>
                    entry.key != 'matchResultList' &&
                    entry.key != 'sectionsNo999' &&
                    entry.key != 'sectionsNo1' &&
                    entry.key != 'isCancel')
                .map(
                  (entry) => _MiniTag(
                    label: entry.key,
                    value: entry.value.toString(),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _AnalysisSection extends StatelessWidget {
  const _AnalysisSection({
    required this.analysis,
    required this.predictions,
  });
  final MatchAnalysisSnapshot? analysis;
  final List<Map<String, dynamic>> predictions;

  String _value(dynamic input) => input?.toString().trim().isNotEmpty == true
      ? input.toString()
      : '--';

  @override
  Widget build(BuildContext context) {
    if (analysis == null && predictions.isEmpty) {
      return const _EmptyDetailCard(title: 'AI 鍒嗘瀽', text: '鏆傛棤鍒嗘瀽鏁版嵁');
    }

    final consensus = analysis?.consensusDirection;
    final directionCounter = analysis?.directionCounter ?? const {};
    final streakSummary = analysis?.streakSummary ?? const {};

    return _DetailSectionCard(
      title: 'AI 鍒嗘瀽',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _MiniTag(label: '鍏辫瘑', value: consensus ?? '--'),
              const SizedBox(width: 8),
              _MiniTag(
                label: '样本数',
                value: '${analysis?.count ?? predictions.length}',
              ),
              const SizedBox(width: 8),
              _MiniTag(
                label: '最长连黑',
                value: _value(streakSummary['maxLosingStreak']),
              ),
              const SizedBox(width: 8),
              _MiniTag(
                label: '最长连红',
                value: _value(streakSummary['maxWinningStreak']),
              ),
            ],
          ),
          if (directionCounter.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: directionCounter.entries
                  .map((entry) => _MiniTag(
                        label: entry.key,
                        value: '${entry.value}场',
                      ))
                  .toList(),
            ),
          ],
          if (predictions.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...predictions.map((row) => _PredictionRow(row: row)),
          ],
        ],
      ),
    );
  }
}

// ignore: unused_element
class _BasicInfoSection extends StatelessWidget {
  const _BasicInfoSection({required this.basic});
  final MatchBasicSnapshot? basic;

  @override
  Widget build(BuildContext context) {
    if (basic == null) {
      return const _EmptyDetailCard(title: '鍩虹璇存槑', text: '鏆傛棤鍩虹璇存槑');
    }
    final notes = basic!.notes;
    return _DetailSectionCard(
      title: '鍩虹璇存槑',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (notes.isEmpty)
            const Text('暂无基础说明',
                style: TextStyle(color: Color(0xff8a8f96)))
          else
            ...notes.map(
              (note) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(note,
                    style: const TextStyle(
                        color: Color(0xff5f666c), height: 1.35)),
              ),
            ),
        ],
      ),
    );
  }
}

class _PredictionRow extends StatelessWidget {
  const _PredictionRow({required this.row});
  final Map<String, dynamic> row;

  String _text(String key, [String fallback = '--']) {
    final value = row[key];
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  @override
  Widget build(BuildContext context) {
    final hit = (row['is_hit']?.toString() ?? '-1') == '1';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xfff7f8f8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xffe3e6e8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_text('model_name'),
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
              _MiniTag(
                label: hit ? '命中' : '未中',
                value: _text('prediction_type'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '闂備礁鎼崐濠氬箠閹捐绠?${_text('predicted_direction')} 闁?婵犳鍣徊楣冨蓟閵娾晛鍨?${_text('predicted_score')} 闁?闂備礁鎲￠〃澶娾枍閺囩儐娓诲ǎ鍥︽彧 ${_text('instant_sp')}',
            style: const TextStyle(fontSize: 12, color: Color(0xff5f666c)),
          ),
          const SizedBox(height: 4),
          Text(
            '闂佸搫顦弲婵嬪磻閵堝洤鍨?${_text('current_black_streak') == '--' ? _text('losing_streak') : _text('current_black_streak')} 闁?闂佸搫顦弲婵嬪磻閻旇　鍋?${_text('current_red_streak') == '--' ? _text('winning_streak') : _text('current_red_streak')}',
            style: const TextStyle(fontSize: 12, color: Color(0xff5f666c)),
          ),
        ],
      ),
    );
  }
}

class _DetailSectionCard extends StatelessWidget {
  const _DetailSectionCard({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xffe5e7e9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _EmptyDetailCard extends StatelessWidget {
  const _EmptyDetailCard({required this.title, required this.text});
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return _DetailSectionCard(
      title: title,
      child: Text(text, style: const TextStyle(color: Color(0xff8a8f96))),
    );
  }
}

class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xfff4f6f5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('$label $value',
          style: const TextStyle(fontSize: 11, color: Color(0xff50575d))),
    );
  }
}

class _OddsBlock extends StatelessWidget {
  const _OddsBlock({
    required this.title,
    required this.items,
    this.handicap,
  });
  final String title;
  final Map<String, dynamic> items;
  final String? handicap;

  String _label(String key) {
    if (title == '胜平负') {
      return switch (key) {'胜' => '主胜', '平' => '平', '负' => '客胜', _ => key};
    }
    if (title == '让球胜平负') {
      final prefix = (handicap ?? '').trim();
      return '$prefix$key';
    }
    if (title == '总进球' && RegExp(r'^\d+$').hasMatch(key)) {
      return '$key球';
    }
    return key;
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final entries = items.entries.toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xff12a15d))),
        const SizedBox(height: 6),
        Wrap(
          spacing: 18,
          runSpacing: 8,
          children: entries
              .map(
                (entry) => Text(
                  '${_label(entry.key)}  ${entry.value}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xff3f464b),
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class ScenarioPage extends StatelessWidget {
  const ScenarioPage({super.key});
  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(18),
        children: const [
          PageTitle('璧旂巼鎯呮櫙', subtitle: '浠呬綔鏁板姣旇緝'),
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
    final ratio =
        value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
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
