import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'api_client.dart';
import 'match_analysis.dart';
import 'models.dart';

const _green = Color(0xff07885d);
const _greenDark = Color(0xff087652);
const _greenSoft = Color(0xffeef8f4);
const _ink = Color(0xff161a1c);
const _muted = Color(0xff7d8387);
const _line = Color(0xffe8ebea);
const _page = Color(0xfff7f8f8);
const _red = Color(0xffe04f5f);
const _orange = Color(0xffe8892b);

// Match detail overview-only visual tokens. They intentionally do not alter
// the app theme or the other detail tabs.
const _overviewInset = 13.0;
const _overviewSectionGap = 5.0;
const _overviewGrid = Color(0xffe3e7e6);
const _overviewHeaderFill = Color(0xfff4f6f5);
const _overviewLabelWidth = 70.0;
const _overviewTitleStyle = TextStyle(
  fontSize: 15.5,
  fontWeight: FontWeight.w800,
  color: _ink,
);
const _overviewBodyStyle = TextStyle(
  fontSize: 11.5,
  fontWeight: FontWeight.w600,
  color: _ink,
  fontFeatures: [FontFeature.tabularFigures()],
);

class MatchDetailV2Page extends StatefulWidget {
  const MatchDetailV2Page({required this.match, super.key});

  final MatchItem match;

  @override
  State<MatchDetailV2Page> createState() => _MatchDetailV2PageState();
}

class _MatchDetailV2PageState extends State<MatchDetailV2Page> {
  final CaiApiClient _client = CaiApiClient();
  late Future<_DetailData> _future;
  _DetailData? _lastData;
  Timer? _refreshTimer;
  final ScrollController _contentScrollController = ScrollController();
  bool _reloading = false;
  int _tab = 0;
  bool _initialTabResolved = false;

  @override
  void initState() {
    super.initState();
    _tab = widget.match.matchState == MatchState.finished ? 3 : 0;
    // The match list already owns enough real data to render the fixed header.
    // Show it immediately instead of blocking the whole route on the slower
    // odds, analysis, badge and standings requests.
    _lastData = _DetailData(match: widget.match);
    _future = _loadAndSchedule();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _contentScrollController.dispose();
    _client.close();
    super.dispose();
  }

  void _selectTab(int value) {
    if (_tab == value) return;
    setState(() => _tab = value);
    if (_contentScrollController.hasClients) {
      _contentScrollController.jumpTo(0);
    }
  }

  Future<_DetailData> _loadAndSchedule() async {
    final data = await _load();
    _lastData = data;
    if (mounted && !_initialTabResolved) {
      _initialTabResolved = true;
      final defaultTab = data.match.matchState == MatchState.finished ? 3 : 0;
      if (_tab != defaultTab) setState(() => _tab = defaultTab);
    }
    if (mounted) _scheduleRefresh(data.match);
    return data;
  }

  void _scheduleRefresh(MatchItem match) {
    _refreshTimer?.cancel();
    if (match.matchState != MatchState.live &&
        match.matchState != MatchState.halftime) {
      return;
    }
    _refreshTimer = Timer(const Duration(seconds: 10), _reload);
  }

  Future<_DetailData> _load() async {
    if (!_client.isConfigured) {
      return _DetailData(match: widget.match, error: '数据加载失败，请重试');
    }
    try {
      final match = await _client.fetchMatch(widget.match.id);
      List<Map<String, dynamic>> oddsHistory = const [];
      Map<String, dynamic> marketOdds = const {};
      MatchAnalysisData? analysis;
      Map<String, TeamMetadata> teamMetadata = const {};
      MatchStandings? fallbackStandings;
      await Future.wait([
        () async {
          try {
            oddsHistory = await _client.fetchOddsHistory(widget.match.id);
          } catch (_) {}
        }(),
        () async {
          try {
            marketOdds = await _client.fetchMarketOdds(widget.match.id);
          } catch (_) {}
        }(),
        () async {
          try {
            final loaded = await _client.fetchMatchAnalysis(widget.match.id);
            if (loaded.hasContent) analysis = loaded;
          } catch (_) {}
        }(),
        () async {
          try {
            teamMetadata = await _client.fetchTeamMetadata([
              match.home,
              match.away,
            ]);
          } catch (_) {}
        }(),
        () async {
          try {
            final loaded = await _client
                .fetchTeamStandings(home: match.home, away: match.away)
                .timeout(const Duration(seconds: 3));
            if (loaded.hasContent) fallbackStandings = loaded;
          } catch (_) {}
        }(),
      ]);
      if (analysis?.standings.hasContent == true) {
        fallbackStandings = null;
      }
      return _DetailData(
        match: match,
        oddsHistory: oddsHistory,
        marketOdds: marketOdds,
        analysis: analysis,
        teamMetadata: teamMetadata,
        fallbackStandings: fallbackStandings,
        loadedAt: DateTime.now(),
      );
    } catch (_) {
      return _DetailData(match: widget.match, error: '数据加载失败，请重试');
    }
  }

  Future<void> _reload() async {
    if (_reloading) return;
    _refreshTimer?.cancel();
    _reloading = true;
    final future = _loadAndSchedule();
    if (mounted) {
      setState(() {
        _future = future;
      });
    }
    try {
      await future;
    } finally {
      _reloading = false;
    }
  }

  Future<void> _share(MatchItem match) async {
    final score = _displayScore(match);
    await SharePlus.instance.share(
      ShareParams(
        subject: '球镜·比赛详情',
        text: '${match.number} ${match.league}\n'
            '${match.home} vs ${match.away}\n'
            '${match.kickoffDisplayLabel}  ${_statusText(match)}'
            '${score == null ? '' : '  $score'}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DetailData>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data ?? _lastData;
        if (data == null) {
          return const _DetailLoadingScaffold();
        }
        final match = data.match;
        final detailTabs = <String>['概览', '基本面', '赔率'];
        if (match.matchState == MatchState.finished) {
          detailTabs.add('赛果');
        }
        final selectedTab = math.min(_tab, detailTabs.length - 1);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: Scaffold(
            backgroundColor: Colors.white,
            body: Column(
              children: [
                MatchHeader(
                  match: match,
                  homeBadgeUrl: data.teamMetadata[match.home]?.badgeUrl,
                  awayBadgeUrl: data.teamMetadata[match.away]?.badgeUrl,
                  onBack: () => Navigator.maybePop(context),
                  onShare: () => _share(match),
                ),
                DetailTabs(
                  value: selectedTab,
                  labels: detailTabs,
                  onChanged: _selectTab,
                ),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const LinearProgressIndicator(
                    minHeight: 2,
                    color: _green,
                    backgroundColor: _greenSoft,
                  ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _reload,
                    color: _green,
                    child: ListView(
                      key: PageStorageKey<String>('detail-scroll-$selectedTab'),
                      controller: _contentScrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.paddingOf(context).bottom + 24,
                      ),
                      children: [
                        if (data.error != null)
                          _LoadError(message: data.error!, onRetry: _reload),
                        switch (selectedTab) {
                          0 => _DetailOverview(
                              match: match,
                              analysis: data.analysis,
                              fallbackStandings: data.fallbackStandings,
                              oddsHistory: data.oddsHistory,
                              homeBadgeUrl:
                                  data.teamMetadata[match.home]?.badgeUrl,
                              awayBadgeUrl:
                                  data.teamMetadata[match.away]?.badgeUrl,
                              loadedAt: data.loadedAt,
                              onOpenOdds: () => _selectTab(2),
                            ),
                          1 => _FundamentalsTab(
                              match: match,
                              analysis: data.analysis,
                              fallbackStandings: data.fallbackStandings,
                              homeBadgeUrl:
                                  data.teamMetadata[match.home]?.badgeUrl,
                              awayBadgeUrl:
                                  data.teamMetadata[match.away]?.badgeUrl,
                            ),
                          2 => _OddsHub(
                              match: match,
                              loadedAt: data.loadedAt,
                              history: data.oddsHistory,
                              marketOdds: data.marketOdds,
                            ),
                          3 => _ResultsTab(match: match),
                          _ => const SizedBox.shrink(),
                        },
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DetailLoadingScaffold extends StatelessWidget {
  const _DetailLoadingScaffold();

  @override
  Widget build(BuildContext context) {
    Widget block(double height, {double? width}) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xffecefee),
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _page,
      appBar: AppBar(
        toolbarHeight: 56,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        backgroundColor: _greenDark,
        elevation: 0,
        title: const Text(
          '比赛详情',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
      body: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 22),
        children: [
          Container(
            height: 142,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xffedf0ef)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    block(12, width: 86),
                    const Spacer(),
                    block(12, width: 106),
                  ],
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    block(46, width: 42),
                    block(20, width: 54),
                    block(46, width: 42),
                  ],
                ),
                const Spacer(),
                block(10, width: 190),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 54,
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [block(16, width: 48), block(16, width: 48)],
            ),
          ),
          const SizedBox(height: 10),
          for (final height in const [156.0, 122.0, 138.0]) ...[
            Container(
              height: height,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  block(16, width: 92),
                  const SizedBox(height: 14),
                  block(10),
                  const SizedBox(height: 10),
                  block(10),
                  const SizedBox(height: 10),
                  block(10, width: 220),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _DetailData {
  const _DetailData({
    required this.match,
    this.oddsHistory = const [],
    this.marketOdds = const {},
    this.analysis,
    this.teamMetadata = const {},
    this.fallbackStandings,
    this.loadedAt,
    this.error,
  });

  final MatchItem match;
  final List<Map<String, dynamic>> oddsHistory;
  final Map<String, dynamic> marketOdds;
  final MatchAnalysisData? analysis;
  final Map<String, TeamMetadata> teamMetadata;
  final MatchStandings? fallbackStandings;
  final DateTime? loadedAt;
  final String? error;
}

class MatchHeader extends StatelessWidget {
  const MatchHeader({
    required this.match,
    required this.onBack,
    required this.onShare,
    this.homeBadgeUrl,
    this.awayBadgeUrl,
    super.key,
  });

  final MatchItem match;
  final VoidCallback onBack;
  final VoidCallback onShare;
  final String? homeBadgeUrl;
  final String? awayBadgeUrl;

  @override
  Widget build(BuildContext context) {
    final score = _displayScore(match);
    final topInset = MediaQuery.paddingOf(context).top;
    const designWidth = 393.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = constraints.maxWidth / designWidth;
        return Container(
          height: math.max(224 * scale, topInset + 165 * scale),
          decoration: const BoxDecoration(
            color: _greenDark,
            image: DecorationImage(
              image: AssetImage('assets/images/match_header_stadium_v2.png'),
              fit: BoxFit.cover,
              alignment: Alignment.bottomCenter,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0x42001D1A)),
              Builder(
                builder: (context) {
                  double x(double value) => value * scale;
                  // Keep the navigation row below the Dynamic Island while keeping
                  // the match block compact enough to avoid a large grass gap.
                  final infoTop = math.max(x(52), topInset + x(8));
                  return Stack(
                    children: [
                      Positioned(
                        left: x(12),
                        top: infoTop,
                        child: _HeaderAction(
                          tooltip: '返回',
                          onPressed: onBack,
                          icon: Icons.arrow_back_ios_new_rounded,
                        ),
                      ),
                      Positioned(
                        right: x(12),
                        top: infoTop,
                        child: _HeaderAction(
                          tooltip: '分享',
                          onPressed: onShare,
                          icon: Icons.ios_share_rounded,
                        ),
                      ),
                      Positioned(
                        top: infoTop,
                        left: x(76),
                        right: x(76),
                        child: Text(
                          '${match.league}  ${match.number}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 14.5,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ),
                      Positioned(
                        top: infoTop + x(24),
                        left: x(76),
                        right: x(76),
                        child: Text(
                          '${match.kickoff.month.toString().padLeft(2, '0')}-'
                          '${match.kickoff.day.toString().padLeft(2, '0')} '
                          '${match.kickoffDisplayTime}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 13.5,
                              color: Colors.white70,
                              fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ),
                      Positioned(
                        left: x(22),
                        top: infoTop + x(76),
                        width: x(112),
                        child:
                            _HeroTeam(team: match.home, badgeUrl: homeBadgeUrl),
                      ),
                      Positioned(
                        right: x(22),
                        top: infoTop + x(76),
                        width: x(112),
                        child:
                            _HeroTeam(team: match.away, badgeUrl: awayBadgeUrl),
                      ),
                      Positioned(
                        left: x(134),
                        right: x(134),
                        top: infoTop + x(94),
                        child: Column(
                          children: [
                            Text(
                              score ?? 'VS',
                              style: TextStyle(
                                  fontSize: score == null ? 32 : 36,
                                  height: 1,
                                  fontWeight: FontWeight.w800,
                                  color: score == null
                                      ? Colors.white
                                      : const Color(0xffffd166),
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ]),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _statusText(match),
                              style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.05,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HeroTeam extends StatelessWidget {
  const _HeroTeam({
    required this.team,
    this.badgeUrl,
  });

  final String team;
  final String? badgeUrl;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TeamEmblem(team: team, badgeUrl: badgeUrl),
        const SizedBox(height: 5),
        Text(
          team,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13.5,
            height: 1.1,
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _TeamEmblem extends StatelessWidget {
  const _TeamEmblem({required this.team, this.badgeUrl});

  final String team;
  final String? badgeUrl;

  @override
  Widget build(BuildContext context) {
    if ((badgeUrl ?? '').trim().isEmpty) {
      return const SizedBox(width: 50, height: 50);
    }
    final clean = team.trim();
    final initials =
        clean.isEmpty ? '队' : clean.substring(0, math.min(clean.length, 2));
    final fallback = Container(
      width: 50,
      height: 50,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xff0a694f),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(9),
          topRight: Radius.circular(9),
          bottomLeft: Radius.circular(15),
          bottomRight: Radius.circular(15),
        ),
        border: Border.all(color: Colors.white38),
      ),
      child: Text(
        initials,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    final url = badgeUrl?.trim() ?? '';
    if (url.isEmpty) return fallback;
    return SizedBox(
      width: 50,
      height: 50,
      child: Image.network(
        url,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

class DetailTabs extends StatelessWidget {
  const DetailTabs({
    required this.value,
    required this.labels,
    required this.onChanged,
    super.key,
  });

  final int value;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: List.generate(labels.length, (index) {
          final selected = index == value;
          return Expanded(
            child: InkWell(
              onTap: () => onChanged(index),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    labels[index],
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? _green : const Color(0xff363c40),
                    ),
                  ),
                  const SizedBox(height: 5),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: selected ? 20 : 0,
                    height: 2.5,
                    decoration: BoxDecoration(
                      color: _green,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        alignment: Alignment.topCenter,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        icon: Icon(icon, color: Colors.white, size: 23),
      );
}

class _DetailOverview extends StatelessWidget {
  const _DetailOverview({
    required this.match,
    required this.analysis,
    required this.fallbackStandings,
    required this.oddsHistory,
    required this.homeBadgeUrl,
    required this.awayBadgeUrl,
    required this.loadedAt,
    required this.onOpenOdds,
  });

  final MatchItem match;
  final MatchAnalysisData? analysis;
  final MatchStandings? fallbackStandings;
  final List<Map<String, dynamic>> oddsHistory;
  final String? homeBadgeUrl;
  final String? awayBadgeUrl;
  final DateTime? loadedAt;
  final VoidCallback onOpenOdds;

  @override
  Widget build(BuildContext context) {
    final data = analysis;
    final standings = data?.standings.hasContent == true
        ? data!.standings
        : fallbackStandings;
    final homeName =
        data?.homeTeam.isNotEmpty == true ? data!.homeTeam : match.home;
    final awayName =
        data?.awayTeam.isNotEmpty == true ? data!.awayTeam : match.away;
    return Column(
      children: [
        const SizedBox(height: _overviewSectionGap),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _overviewInset),
          child: _OddsSection(
            match: match,
            loadedAt: loadedAt,
            history: oddsHistory,
            onOpenOdds: onOpenOdds,
          ),
        ),
        const SizedBox(height: _overviewSectionGap),
        Container(height: _overviewSectionGap, color: _page),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _overviewInset),
          child: _FormComparisonSection(
            homeName: homeName,
            awayName: awayName,
            homeBadgeUrl: homeBadgeUrl,
            awayBadgeUrl: awayBadgeUrl,
            home: data?.homeRecent,
            away: data?.awayRecent,
            standings: standings,
          ),
        ),
        if (data?.headToHead.matches.isNotEmpty == true) ...[
          const SizedBox(height: _overviewSectionGap),
          Container(height: _overviewSectionGap, color: _page),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _overviewInset),
            child: _HeadToHeadSection(
              group: data!.headToHead,
              perspective: homeName,
            ),
          ),
        ],
        const SizedBox(height: _overviewSectionGap),
        Container(height: _overviewSectionGap, color: _page),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _overviewInset),
          child: _AbsenceSection(sides: data?.injuries),
        ),
        if (loadedAt != null) ...[
          const SizedBox(height: 14),
          Text(
            '数据更新于 ${_mdhm(loadedAt!)}',
            style: const TextStyle(fontSize: 10, color: _muted),
          ),
        ],
        const SizedBox(height: 6),
      ],
    );
  }
}

class _OddsSection extends StatelessWidget {
  const _OddsSection({
    required this.match,
    required this.loadedAt,
    required this.history,
    required this.onOpenOdds,
  });

  final MatchItem match;
  final DateTime? loadedAt;
  final List<Map<String, dynamic>> history;
  final VoidCallback onOpenOdds;

  @override
  Widget build(BuildContext context) {
    final rows = <_OddsSectionRowData>[];
    if (match.had.isNotEmpty) {
      rows.add(
        _OddsSectionRowData(
          title: '胜平负',
          values: _orderedOutcomes(match.had),
          initialValues: _earliestHistoryMarket(history, 'had'),
        ),
      );
    }
    if (match.hhad.isNotEmpty) {
      final handicap = match.hhad['让球']?.toString();
      rows.add(
        _OddsSectionRowData(
          title: handicap == null || handicap.isEmpty ? '让球' : '让球（$handicap）',
          values: _orderedOutcomes(
              Map<String, dynamic>.from(match.hhad)..remove('让球')),
          initialValues: _earliestHistoryMarket(history, 'hhad')..remove('让球'),
        ),
      );
    }
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: Row(
            children: [
              Container(width: 4, height: 18, color: _greenDark),
              const SizedBox(width: 8),
              const Text('竞彩赔率', style: _overviewTitleStyle),
              const Spacer(),
              InkWell(
                onTap: onOpenOdds,
                borderRadius: BorderRadius.circular(4),
                child: const SizedBox(
                  height: 44,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('查看赔率',
                          style: TextStyle(
                              fontSize: 11,
                              color: _greenDark,
                              fontWeight: FontWeight.w600)),
                      SizedBox(width: 2),
                      Icon(Icons.chevron_right_rounded,
                          size: 18, color: _greenDark),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: _overviewGrid),
            borderRadius: BorderRadius.circular(5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              const _OddsSectionHeader(),
              for (final row in rows) _OddsSectionRow(row: row),
            ],
          ),
        ),
        if (loadedAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 2),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text('更新 ${_mdhm(loadedAt!)}',
                  style: const TextStyle(fontSize: 9.5, color: _muted)),
            ),
          ),
      ],
    );
  }
}

class _OddsSectionHeader extends StatelessWidget {
  const _OddsSectionHeader();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 30,
      child: Row(
        children: [
          _OddsSectionCell(text: '玩法', flex: 30, fill: _overviewHeaderFill),
          _OddsSectionCell(text: '主胜', flex: 23, fill: _overviewHeaderFill),
          _OddsSectionCell(text: '平', flex: 23, fill: _overviewHeaderFill),
          _OddsSectionCell(
              text: '客胜', flex: 24, fill: _overviewHeaderFill, last: true),
        ],
      ),
    );
  }
}

class _OddsSectionRowData {
  const _OddsSectionRowData({
    required this.title,
    required this.values,
    required this.initialValues,
  });

  final String title;
  final List<MapEntry<String, dynamic>> values;
  final Map<String, dynamic> initialValues;
}

class _OddsSectionRow extends StatelessWidget {
  const _OddsSectionRow({required this.row});

  final _OddsSectionRowData row;

  @override
  Widget build(BuildContext context) {
    final values = List<MapEntry<String, dynamic>?>.generate(
      3,
      (index) => index < row.values.length ? row.values[index] : null,
    );
    return SizedBox(
      height: 41,
      child: Row(
        children: [
          _OddsSectionCell(text: row.title, flex: 30, alignLeft: true),
          for (var index = 0; index < values.length; index++)
            _OddsSectionCell(
              text: values[index] == null ? '--' : _odd(values[index]!.value),
              flex: index == values.length - 1 ? 24 : 23,
              last: index == values.length - 1,
              data: true,
              trend: values[index] == null
                  ? ''
                  : _oddsMovement(
                      values[index]!.value,
                      row.initialValues[values[index]!.key],
                      'sp',
                    ),
            ),
        ],
      ),
    );
  }
}

class _OddsSectionCell extends StatelessWidget {
  const _OddsSectionCell({
    required this.text,
    required this.flex,
    this.fill,
    this.last = false,
    this.alignLeft = false,
    this.data = false,
    this.trend = '',
  });

  final String text;
  final int flex;
  final Color? fill;
  final bool last;
  final bool alignLeft;
  final bool data;
  final String trend;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Container(
        height: double.infinity,
        padding: EdgeInsets.only(left: alignLeft ? 9 : 4, right: 4),
        alignment: alignLeft ? Alignment.centerLeft : Alignment.center,
        decoration: BoxDecoration(
          color: fill,
          border: Border(
            right:
                last ? BorderSide.none : const BorderSide(color: _overviewGrid),
            bottom: const BorderSide(color: _overviewGrid),
          ),
        ),
        child: data
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13.5,
                          color: _greenDark,
                          fontWeight: FontWeight.w700,
                          fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
                  SizedBox(
                    width: 12,
                    child: Center(
                      child: Text(
                        trend,
                        style: TextStyle(
                          fontSize: 11,
                          color: trend == '↑' ? _red : _green,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : alignLeft
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(text,
                        style: const TextStyle(fontSize: 10.5, color: _muted)),
                  )
                : Text(text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: _muted)),
      ),
    );
  }
}

class _FundamentalsTab extends StatefulWidget {
  const _FundamentalsTab({
    required this.match,
    required this.analysis,
    required this.fallbackStandings,
    required this.homeBadgeUrl,
    required this.awayBadgeUrl,
  });

  final MatchItem match;
  final MatchAnalysisData? analysis;
  final MatchStandings? fallbackStandings;
  final String? homeBadgeUrl;
  final String? awayBadgeUrl;

  @override
  State<_FundamentalsTab> createState() => _FundamentalsTabState();
}

class _FundamentalsTabState extends State<_FundamentalsTab> {
  int _section = 0;

  @override
  Widget build(BuildContext context) {
    final data = widget.analysis;
    final hasFormData = data != null &&
        (data.headToHead.matches.isNotEmpty ||
            data.homeRecent.matches.isNotEmpty ||
            data.awayRecent.matches.isNotEmpty);
    final standings = data?.standings.hasContent == true
        ? data!.standings
        : widget.fallbackStandings;
    return Column(
      children: [
        const SizedBox(height: 12),
        _DetailSubTabs(
          labels: const ['战绩', '排名', '状态', '阵容', '赛程'],
          value: _section,
          onChanged: (value) => setState(() => _section = value),
        ),
        const SizedBox(height: 10),
        ...switch (_section) {
          0 => _recordContent(data, standings),
          1 => [
              if (standings?.hasContent == true)
                _StandingsPanel(standings: standings!)
              else
                const _Surface(child: _Empty(text: '暂无排名数据')),
            ],
          2 => [
              if (hasFormData)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: _overviewInset),
                  child: _FormComparisonSection(
                    homeName: data.homeTeam.isEmpty
                        ? widget.match.home
                        : data.homeTeam,
                    awayName: data.awayTeam.isEmpty
                        ? widget.match.away
                        : data.awayTeam,
                    homeBadgeUrl: widget.homeBadgeUrl,
                    awayBadgeUrl: widget.awayBadgeUrl,
                    home: data.homeRecent,
                    away: data.awayRecent,
                    standings: standings,
                  ),
                )
              else
                const _Surface(child: _Empty(text: '暂无状态数据')),
            ],
          3 => _lineupContent(data),
          4 => [
              if (data?.future.hasContent == true)
                _FutureSchedulePanel(
                  schedules: data!.future,
                  currentKickoff: widget.match.kickoff,
                )
              else
                const _Surface(child: _Empty(text: '暂无赛程数据')),
            ],
          _ => const [],
        },
        if (data?.stale == true) ...[
          const SizedBox(height: 8),
          const Text(
            '部分资料来自最近一次成功更新',
            style: TextStyle(fontSize: 10, color: _muted),
          ),
        ],
      ],
    );
  }

  List<Widget> _recordContent(
    MatchAnalysisData? data,
    MatchStandings? standings,
  ) {
    if (data == null ||
        (data.headToHead.matches.isEmpty &&
            data.homeRecent.matches.isEmpty &&
            data.awayRecent.matches.isEmpty)) {
      return const [_Surface(child: _Empty(text: '暂无战绩数据'))];
    }
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: _overviewInset),
        child: _BasicRecordsPanel(
          match: widget.match,
          analysis: data,
          standings: standings,
          homeBadgeUrl: widget.homeBadgeUrl,
          awayBadgeUrl: widget.awayBadgeUrl,
        ),
      ),
    ];
  }

  List<Widget> _lineupContent(MatchAnalysisData? data) {
    if (data == null ||
        (!data.injuries.hasContent && !data.keyPlayers.hasContent)) {
      return const [_Surface(child: _Empty(text: '暂无阵容数据'))];
    }
    return [
      if (data.injuries.hasContent) ...[
        _PersonnelPanel(
          title: '伤停信息',
          sides: data.injuries,
          injuries: true,
        ),
        if (data.keyPlayers.hasContent) const SizedBox(height: 10),
      ],
      if (data.keyPlayers.hasContent)
        _PersonnelPanel(
          title: '关键球员',
          sides: data.keyPlayers,
          injuries: false,
        ),
    ];
  }
}

class _BasicRecordsPanel extends StatefulWidget {
  const _BasicRecordsPanel({
    required this.match,
    required this.analysis,
    required this.standings,
    required this.homeBadgeUrl,
    required this.awayBadgeUrl,
  });

  final MatchItem match;
  final MatchAnalysisData analysis;
  final MatchStandings? standings;
  final String? homeBadgeUrl;
  final String? awayBadgeUrl;

  @override
  State<_BasicRecordsPanel> createState() => _BasicRecordsPanelState();
}

class _BasicRecordsPanelState extends State<_BasicRecordsPanel> {
  var _teamIndex = 0;
  var _sameVenueOnly = false;
  var _sameLeagueOnly = false;

  List<MatchRecord> _filteredRecords(
    List<MatchRecord> source,
    String team,
    bool isHomeTeam,
  ) {
    return source.where((record) {
      final venueMatches = !_sameVenueOnly ||
          (isHomeTeam ? record.home == team : record.away == team);
      final leagueMatches = !_sameLeagueOnly ||
          record.league.trim() == widget.match.league.trim();
      return venueMatches && leagueMatches;
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final home = widget.analysis.homeRecent;
    final away = widget.analysis.awayRecent;
    final homeName = home.team.isEmpty ? widget.match.home : home.team;
    final awayName = away.team.isEmpty ? widget.match.away : away.team;
    final selectedName = _teamIndex == 0 ? homeName : awayName;
    final records = _filteredRecords(
      _teamIndex == 0 ? home.matches : away.matches,
      selectedName,
      _teamIndex == 0,
    );
    final selectedMetrics = TeamFormMetrics.fromRecords(records, selectedName);

    return Column(
      children: [
        _OverviewSectionHeader(
          title: '近期战绩',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _BasicFilterButton(
                label: '同主客',
                selected: _sameVenueOnly,
                onTap: () => setState(() => _sameVenueOnly = !_sameVenueOnly),
              ),
              const SizedBox(width: 6),
              _BasicFilterButton(
                label: '同赛事',
                selected: _sameLeagueOnly,
                onTap: () => setState(() => _sameLeagueOnly = !_sameLeagueOnly),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: _overviewGrid),
            borderRadius: BorderRadius.circular(5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _BasicTeamSummary(
                        name: homeName,
                        badgeUrl: widget.homeBadgeUrl,
                        metrics:
                            _teamIndex == 0 ? selectedMetrics : home.metrics(),
                        selected: _teamIndex == 0,
                        onTap: () => setState(() => _teamIndex = 0),
                      ),
                    ),
                    const VerticalDivider(width: 1, color: _overviewGrid),
                    Expanded(
                      child: _BasicTeamSummary(
                        name: awayName,
                        badgeUrl: widget.awayBadgeUrl,
                        metrics:
                            _teamIndex == 1 ? selectedMetrics : away.metrics(),
                        selected: _teamIndex == 1,
                        onTap: () => setState(() => _teamIndex = 1),
                      ),
                    ),
                  ],
                ),
              ),
              const _BasicRecordHeader(),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: records.isEmpty
                    ? const SizedBox(
                        height: 58,
                        child: Center(
                          child: Text('暂无近期战绩数据',
                              style: TextStyle(fontSize: 11, color: _muted)),
                        ),
                      )
                    : Column(
                        key: ValueKey(_teamIndex),
                        children: [
                          for (final record in records.take(6))
                            _BasicMatchRecordRow(
                              record: record,
                              perspective: selectedName,
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        if (widget.standings?.hasContent == true) ...[
          const SizedBox(height: _overviewSectionGap),
          _BasicRankComparison(
            standings: widget.standings!,
            homeBadgeUrl: widget.homeBadgeUrl,
            awayBadgeUrl: widget.awayBadgeUrl,
          ),
        ],
      ],
    );
  }
}

class _BasicFilterButton extends StatelessWidget {
  const _BasicFilterButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          constraints: const BoxConstraints(minWidth: 49, minHeight: 28),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? const Color(0xffedf7f2) : Colors.white,
            border: Border.all(color: selected ? _greenDark : _overviewGrid),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              color: selected ? _greenDark : _muted,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _BasicTeamSummary extends StatelessWidget {
  const _BasicTeamSummary({
    required this.name,
    required this.badgeUrl,
    required this.metrics,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final String? badgeUrl;
  final TeamFormMetrics metrics;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? const Color(0xfff7fbf9) : Colors.white,
        padding: const EdgeInsets.fromLTRB(8, 9, 8, 9),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 31,
                  height: 31,
                  child: (badgeUrl ?? '').trim().isEmpty
                      ? const SizedBox.shrink()
                      : Image.network(
                          badgeUrl!.trim(),
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: selected ? _greenDark : _ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              metrics.matches == 0
                  ? '暂无数据'
                  : '近${metrics.matches}场  ${metrics.record}',
              style: const TextStyle(fontSize: 10, color: _muted),
            ),
            const SizedBox(height: 3),
            Text(
              metrics.matches == 0
                  ? '--'
                  : '进 ${metrics.goalsForAverage.toStringAsFixed(2)}  失 ${metrics.goalsAgainstAverage.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 10, color: _ink),
            ),
          ],
        ),
      ),
    );
  }
}

class _BasicRecordHeader extends StatelessWidget {
  const _BasicRecordHeader();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 9.5, color: _muted);
    return Container(
      height: 33,
      color: _overviewHeaderFill,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Row(
        children: [
          const SizedBox(
              width: 72, child: Center(child: Text('日期/赛事', style: style))),
          const Expanded(child: Center(child: Text('主队', style: style))),
          const SizedBox(
              width: 48, child: Center(child: Text('比分', style: style))),
          const Expanded(child: Center(child: Text('客队', style: style))),
          const SizedBox(
              width: 30, child: Center(child: Text('走势', style: style))),
          const SizedBox(
              width: 26, child: Center(child: Text('进球', style: style))),
        ],
      ),
    );
  }
}

class _BasicMatchRecordRow extends StatelessWidget {
  const _BasicMatchRecordRow({required this.record, required this.perspective});

  final MatchRecord record;
  final String perspective;

  String get _totalGoals {
    final match = RegExp(r'(\d+)\s*[:\-]\s*(\d+)').firstMatch(record.fullScore);
    if (match == null) return '--';
    return '${int.parse(match.group(1)!) + int.parse(match.group(2)!)}';
  }

  @override
  Widget build(BuildContext context) {
    final resultColor = switch (record.result) {
      '胜' => _red,
      '平' => const Color(0xff2c74df),
      '负' => _greenDark,
      _ => _muted,
    };
    final date =
        record.date.length >= 10 ? record.date.substring(5, 10) : record.date;
    Text team(String value, bool current, TextAlign align) => Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: current ? FontWeight.w700 : FontWeight.w500,
          ),
        );
    return Container(
      height: 51,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _overviewGrid)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(date, style: const TextStyle(fontSize: 10, color: _muted)),
                Text(record.league,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 9, color: _greenDark)),
              ],
            ),
          ),
          Expanded(
              child: team(
                  record.home, record.home == perspective, TextAlign.right)),
          SizedBox(
            width: 48,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  record.fullScore.isEmpty ? '--' : record.fullScore,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (record.halfScore.isNotEmpty)
                  Text(
                    '(${record.halfScore})',
                    style: const TextStyle(fontSize: 9, color: _muted),
                  ),
              ],
            ),
          ),
          Expanded(
              child: team(
                  record.away, record.away == perspective, TextAlign.left)),
          SizedBox(
            width: 30,
            child: Text(
              record.result,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 10,
                  color: resultColor,
                  fontWeight: FontWeight.w700),
            ),
          ),
          SizedBox(
            width: 26,
            child: Text(
              _totalGoals,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10.5, color: _ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _BasicRankComparison extends StatelessWidget {
  const _BasicRankComparison({
    required this.standings,
    required this.homeBadgeUrl,
    required this.awayBadgeUrl,
  });

  final MatchStandings standings;
  final String? homeBadgeUrl;
  final String? awayBadgeUrl;

  @override
  Widget build(BuildContext context) {
    final home = standings.home.total;
    final away = standings.away.total;
    return Column(
      children: [
        _OverviewSectionHeader(
          title: '联赛排名',
          trailing: Text(
            [standings.league, standings.season]
                .where((value) => value.isNotEmpty)
                .join(' '),
            style: const TextStyle(fontSize: 10, color: _muted),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: _overviewGrid),
            borderRadius: BorderRadius.circular(5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              const _BasicRankHeader(),
              _BasicRankRow(
                home: home,
                away: away,
                homeBadgeUrl: homeBadgeUrl,
                awayBadgeUrl: awayBadgeUrl,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BasicRankHeader extends StatelessWidget {
  const _BasicRankHeader();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 9.5, color: _muted);
    return Container(
      height: 28,
      color: _overviewHeaderFill,
      child: const Row(
        children: [
          Expanded(child: _BasicRankHeaderCells(style: style)),
          VerticalDivider(width: 1, color: _overviewGrid),
          Expanded(child: _BasicRankHeaderCells(style: style)),
        ],
      ),
    );
  }
}

class _BasicRankHeaderCells extends StatelessWidget {
  const _BasicRankHeaderCells({required this.style});

  final TextStyle style;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: Center(child: Text('排名', style: style))),
          Expanded(child: Center(child: Text('赛', style: style))),
          Expanded(child: Center(child: Text('胜', style: style))),
          Expanded(child: Center(child: Text('平', style: style))),
          Expanded(child: Center(child: Text('负', style: style))),
          Expanded(child: Center(child: Text('进失', style: style))),
          Expanded(child: Center(child: Text('积分', style: style))),
        ],
      );
}

class _BasicRankRow extends StatelessWidget {
  const _BasicRankRow({
    required this.home,
    required this.away,
    required this.homeBadgeUrl,
    required this.awayBadgeUrl,
  });

  final StandingRow home;
  final StandingRow away;
  final String? homeBadgeUrl;
  final String? awayBadgeUrl;

  @override
  Widget build(BuildContext context) {
    Widget team(StandingRow row, String? badgeUrl) => Expanded(
          child: Column(
            children: [
              const SizedBox(height: 5),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 21,
                    height: 21,
                    child: (badgeUrl ?? '').trim().isEmpty
                        ? const SizedBox.shrink()
                        : Image.network(
                            badgeUrl!.trim(),
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(row.team,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10.5, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  for (final value in [
                    row.ranking,
                    row.played,
                    row.wins,
                    row.draws,
                    row.losses,
                    '${row.goalsFor}/${row.goalsAgainst}',
                    row.points,
                  ])
                    Expanded(
                      child: Text('$value',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 10.5, color: _ink)),
                    ),
                ],
              ),
              const SizedBox(height: 7),
            ],
          ),
        );
    return IntrinsicHeight(
      child: Row(
        children: [
          team(home, homeBadgeUrl),
          const VerticalDivider(width: 1, color: _overviewGrid),
          team(away, awayBadgeUrl),
        ],
      ),
    );
  }
}

class _DetailSubTabs extends StatelessWidget {
  const _DetailSubTabs({
    required this.labels,
    required this.value,
    required this.onChanged,
  });

  final List<String> labels;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(3),
      decoration: const BoxDecoration(
        color: Color(0xffedf1ef),
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      child: Row(
        children: List.generate(labels.length, (index) {
          final selected = index == value;
          return Expanded(
            child: InkWell(
              onTap: () => onChanged(index),
              borderRadius: BorderRadius.circular(4),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? _greenDark : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  labels[index],
                  style: TextStyle(
                    fontSize: 11.5,
                    color: selected ? Colors.white : const Color(0xff555d61),
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _FutureSchedulePanel extends StatelessWidget {
  const _FutureSchedulePanel({
    required this.schedules,
    required this.currentKickoff,
  });

  final TeamFutureSchedules schedules;
  final DateTime currentKickoff;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _overviewInset),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _overviewGrid),
          borderRadius: BorderRadius.circular(5),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 12, 12, 9),
              child: _SectionTitle(title: '未来赛程'),
            ),
            const Divider(height: 1, color: _line),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _TeamFutureSchedule(
                      schedule: schedules.home,
                      fallbackTeam: '主队',
                      currentKickoff: currentKickoff,
                    ),
                  ),
                  const VerticalDivider(width: 1, color: _line),
                  Expanded(
                    child: _TeamFutureSchedule(
                      schedule: schedules.away,
                      fallbackTeam: '客队',
                      currentKickoff: currentKickoff,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeamFutureSchedule extends StatelessWidget {
  const _TeamFutureSchedule({
    required this.schedule,
    required this.fallbackTeam,
    required this.currentKickoff,
  });

  final TeamFutureSchedule schedule;
  final String fallbackTeam;
  final DateTime currentKickoff;

  @override
  Widget build(BuildContext context) {
    final matches = schedule.matches.take(4).toList(growable: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            schedule.team.isEmpty ? fallbackTeam : schedule.team,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 7),
          if (matches.isEmpty)
            const Text(
              '暂无官方赛程',
              style: TextStyle(fontSize: 10, color: _muted),
            )
          else
            for (final item in matches) ...[
              _FutureMatchRow(item: item, currentKickoff: currentKickoff),
              if (item != matches.last) const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

class _FutureMatchRow extends StatelessWidget {
  const _FutureMatchRow({required this.item, required this.currentKickoff});

  final FutureMatch item;
  final DateTime currentKickoff;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(item.date.replaceFirst(' ', 'T'));
    final days = date?.difference(currentKickoff).inDays;
    final dateText = date == null
        ? item.date
        : '${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              dateText,
              style: const TextStyle(fontSize: 9.5, color: _muted),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                item.league,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9.5, color: _greenDark),
              ),
            ),
            if (days != null && days >= 0)
              Text(
                '${days + 1}天后',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: days <= 3 ? _orange : _muted,
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${item.home} vs ${item.away}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: _ink),
        ),
      ],
    );
  }
}

class _PersonnelPanel extends StatelessWidget {
  const _PersonnelPanel({
    required this.title,
    required this.sides,
    required this.injuries,
  });

  final String title;
  final TeamPlayerSides sides;
  final bool injuries;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _overviewInset),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _overviewGrid),
          borderRadius: BorderRadius.circular(5),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 9),
              child: _SectionTitle(
                title: title,
                trailing: injuries ? '官方伤停资料' : '近3场表现',
              ),
            ),
            const Divider(height: 1, color: _line),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _TeamPersonnel(
                      group: sides.home,
                      fallbackTeam: '主队',
                      injuries: injuries,
                    ),
                  ),
                  const VerticalDivider(width: 1, color: _line),
                  Expanded(
                    child: _TeamPersonnel(
                      group: sides.away,
                      fallbackTeam: '客队',
                      injuries: injuries,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeamPersonnel extends StatelessWidget {
  const _TeamPersonnel({
    required this.group,
    required this.fallbackTeam,
    required this.injuries,
  });

  final TeamPlayerGroup group;
  final String fallbackTeam;
  final bool injuries;

  @override
  Widget build(BuildContext context) {
    final players = group.players.take(3).toList(growable: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group.team.isEmpty ? fallbackTeam : group.team,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 7),
          if (players.isEmpty)
            const Text(
              '暂无官方记录',
              style: TextStyle(fontSize: 10, color: _muted),
            )
          else
            for (final player in players) ...[
              _PersonnelRow(player: player, injuries: injuries),
              if (player != players.last) const SizedBox(height: 7),
            ],
        ],
      ),
    );
  }
}

class _PersonnelRow extends StatelessWidget {
  const _PersonnelRow({required this.player, required this.injuries});

  final MatchPlayer player;
  final bool injuries;

  @override
  Widget build(BuildContext context) {
    final detail = injuries
        ? player.suspended
            ? '停赛'
            : player.injured
                ? '伤病'
                : '原因暂无数据'
        : '${player.appearances}场 ${player.goals}球 ${player.assists}助';
    return Row(
      children: [
        if (player.number.isNotEmpty) ...[
          SizedBox(
            width: 22,
            child: Text(
              player.number,
              style: const TextStyle(fontSize: 9, color: _muted),
            ),
          ),
        ],
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  player.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: _ink),
                ),
              ),
              if (player.position.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  player.position,
                  style: const TextStyle(fontSize: 9, color: _muted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 4),
        Text(
          detail,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: injuries ? FontWeight.w600 : FontWeight.w500,
            color: injuries
                ? player.suspended
                    ? _orange
                    : player.injured
                        ? _red
                        : _muted
                : _muted,
          ),
        ),
      ],
    );
  }
}

class _FormComparisonSection extends StatelessWidget {
  const _FormComparisonSection({
    required this.homeName,
    required this.awayName,
    required this.homeBadgeUrl,
    required this.awayBadgeUrl,
    required this.home,
    required this.away,
    required this.standings,
  });

  final String homeName;
  final String awayName;
  final String? homeBadgeUrl;
  final String? awayBadgeUrl;
  final TeamRecentForm? home;
  final TeamRecentForm? away;
  final MatchStandings? standings;

  @override
  Widget build(BuildContext context) {
    final homeAll = home?.metrics() ??
        const TeamFormMetrics(
          matches: 0,
          wins: 0,
          draws: 0,
          losses: 0,
          goalsFor: 0,
          goalsAgainst: 0,
          overTwoAndHalf: 0,
          bothTeamsScored: 0,
        );
    final awayAll = away?.metrics() ??
        const TeamFormMetrics(
          matches: 0,
          wins: 0,
          draws: 0,
          losses: 0,
          goalsFor: 0,
          goalsAgainst: 0,
          overTwoAndHalf: 0,
          bothTeamsScored: 0,
        );
    final homeVenue = home?.metrics(venue: TeamVenue.home) ??
        const TeamFormMetrics(
          matches: 0,
          wins: 0,
          draws: 0,
          losses: 0,
          goalsFor: 0,
          goalsAgainst: 0,
          overTwoAndHalf: 0,
          bothTeamsScored: 0,
        );
    final awayVenue = away?.metrics(venue: TeamVenue.away) ??
        const TeamFormMetrics(
          matches: 0,
          wins: 0,
          draws: 0,
          losses: 0,
          goalsFor: 0,
          goalsAgainst: 0,
          overTwoAndHalf: 0,
          bothTeamsScored: 0,
        );

    return Column(
      children: [
        const _OverviewSectionHeader(title: '状态对比'),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: _overviewGrid),
            borderRadius: BorderRadius.circular(5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(
                  children: [
                    SizedBox(
                      height: 42,
                      child: Row(
                        children: [
                          Expanded(
                            child: _FormTeamLabel(
                              name: homeName,
                              badgeUrl: homeBadgeUrl,
                              reverse: true,
                            ),
                          ),
                          const SizedBox(
                            width: _overviewLabelWidth,
                            child: Text(
                              '主队 / 客队',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: _ink,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                          Expanded(
                            child: _FormTeamLabel(
                              name: awayName,
                              badgeUrl: awayBadgeUrl,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _FormComparisonRow(
                      label: '联赛排名',
                      home: _rankText(standings?.home.total.ranking),
                      away: _rankText(standings?.away.total.ranking),
                    ),
                    _FormComparisonRow(
                      label: '近6场战绩',
                      home: homeAll.matches == 0 ? '--' : homeAll.record,
                      away: awayAll.matches == 0 ? '--' : awayAll.record,
                    ),
                    SizedBox(
                      height: 34,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          border: Border(top: BorderSide(color: _overviewGrid)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _FormResultChips(
                                  records: home?.matches ?? const []),
                            ),
                            const SizedBox(
                              width: _overviewLabelWidth,
                              child: Center(
                                child: Text(
                                  '近6场',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: _ink,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                            Expanded(
                              child: _FormResultChips(
                                  records: away?.matches ?? const []),
                            ),
                          ],
                        ),
                      ),
                    ),
                    _FormComparisonTextRow(
                      label: '场均数据',
                      home: _averagePair(homeAll),
                      away: _averagePair(awayAll),
                    ),
                    _FormComparisonTextRow(
                      label: '近期主/客场',
                      home: homeVenue.matches == 0 ? '--' : homeVenue.record,
                      away: awayVenue.matches == 0 ? '--' : awayVenue.record,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _rankText(int? rank) => rank == null || rank <= 0 ? '--' : '第$rank';

  String _averagePair(TeamFormMetrics metrics) {
    if (metrics.matches == 0) return '--';
    return '进 ${metrics.goalsForAverage.toStringAsFixed(2)} 失 ${metrics.goalsAgainstAverage.toStringAsFixed(2)}';
  }
}

class _FormComparisonTextRow extends StatelessWidget {
  const _FormComparisonTextRow({
    required this.label,
    required this.home,
    required this.away,
  });

  final String label;
  final String home;
  final String away;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _overviewGrid)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              home,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(
            width: _overviewLabelWidth,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 10, color: _ink, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              away,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewSectionHeader extends StatelessWidget {
  const _OverviewSectionHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Container(width: 4, height: 18, color: _greenDark),
          const SizedBox(width: 8),
          Text(title, style: _overviewTitleStyle),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _FormTeamLabel extends StatelessWidget {
  const _FormTeamLabel({
    required this.name,
    required this.badgeUrl,
    this.reverse = false,
  });

  final String name;
  final String? badgeUrl;
  final bool reverse;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      child: (badgeUrl ?? '').trim().isEmpty
          ? const SizedBox.shrink()
          : Image.network(
              badgeUrl!.trim(),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
    );
    final nameText = Expanded(
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: reverse ? TextAlign.right : TextAlign.left,
        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: reverse
          ? [nameText, const SizedBox(width: 5), badge]
          : [badge, const SizedBox(width: 5), nameText],
    );
  }
}

class _FormResultChips extends StatelessWidget {
  const _FormResultChips({required this.records});

  final List<MatchRecord> records;

  @override
  Widget build(BuildContext context) {
    final chips = records.take(6).toList(growable: false);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (chips.isEmpty)
            const Text('暂无', style: TextStyle(fontSize: 10, color: _muted))
          else
            for (var i = 0; i < chips.length; i++) ...[
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: _recentColor(chips[i].result), width: 1.2),
                ),
                child: Text(
                  _recentLabel(chips[i].result),
                  style: TextStyle(
                    fontSize: 9,
                    color: _recentColor(chips[i].result),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (i != chips.length - 1) const SizedBox(width: 2),
            ],
        ],
      ),
    );
  }
}

Color _recentColor(String result) {
  return switch (result) {
    '胜' => _red,
    '负' => _greenDark,
    _ => const Color(0xff2c74df),
  };
}

String _recentLabel(String result) => result.isEmpty ? '-' : result;

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 7),
      child: Row(
        children: [
          Container(width: 4, height: 18, color: _greenDark),
          const SizedBox(width: 9),
          Text(title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _FormComparisonRow extends StatelessWidget {
  const _FormComparisonRow(
      {required this.label, required this.home, required this.away});

  final String label;
  final String home;
  final String away;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: _overviewGrid))),
      child: Row(children: [
        Expanded(
            child: Text(home,
                textAlign: TextAlign.center, style: _overviewBodyStyle)),
        SizedBox(
            width: _overviewLabelWidth,
            child: Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 10, color: _ink, fontWeight: FontWeight.w600))),
        Expanded(
            child: Text(away,
                textAlign: TextAlign.center, style: _overviewBodyStyle)),
      ]),
    );
  }
}

class _HeadToHeadSection extends StatefulWidget {
  const _HeadToHeadSection({required this.group, required this.perspective});

  final MatchRecordGroup group;
  final String perspective;

  @override
  State<_HeadToHeadSection> createState() => _HeadToHeadSectionState();
}

class _HeadToHeadSectionState extends State<_HeadToHeadSection> {
  bool _expanded = false;

  void _toggle() {
    final position = Scrollable.maybeOf(context)?.position;
    final previousPixels = position?.pixels ?? 0;
    setState(() => _expanded = !_expanded);
    if (_expanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final next = Scrollable.maybeOf(context)?.position;
      if (next == null || previousPixels <= next.maxScrollExtent) return;
      next.animateTo(next.maxScrollExtent,
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final visible = _expanded ? group.matches : group.matches.take(3).toList();
    final canExpand = group.matches.length > 3;
    return Column(children: [
      _OverviewSectionHeader(
        title: '历史交锋',
        trailing: _HeadToHeadSummary(summary: group.summary),
      ),
      _HeadToHeadRatioBar(summary: group.summary),
      const SizedBox(height: 6),
      Container(
        decoration: BoxDecoration(
          border: Border.all(color: _overviewGrid),
          borderRadius: BorderRadius.circular(5),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          const _OverviewRecordHeader(),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: Column(
              children: [
                for (final record in visible)
                  _HeadToHeadRecordRow(
                    record: record,
                    perspective: widget.perspective,
                  ),
                if (canExpand)
                  _OverviewInlineAction(
                    label: _expanded ? '收起' : '查看全部',
                    onTap: _toggle,
                  ),
              ],
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _OverviewRecordHeader extends StatelessWidget {
  const _OverviewRecordHeader();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 10, color: _muted);
    return Container(
      height: 29,
      color: _overviewHeaderFill,
      child: const Row(children: [
        SizedBox(
            width: 74, child: Center(child: Text('日期 / 赛事', style: style))),
        Expanded(child: Center(child: Text('主队', style: style))),
        SizedBox(width: 50, child: Center(child: Text('比分', style: style))),
        Expanded(child: Center(child: Text('客队', style: style))),
        SizedBox(width: 28, child: Center(child: Text('结果', style: style))),
      ]),
    );
  }
}

class _HeadToHeadSummary extends StatelessWidget {
  const _HeadToHeadSummary({required this.summary});

  final MatchFormSummary summary;

  @override
  Widget build(BuildContext context) => Text(
        '近${summary.matches}次 ${summary.record}',
        style: const TextStyle(fontSize: 10, color: _muted),
      );
}

class _HeadToHeadRatioBar extends StatelessWidget {
  const _HeadToHeadRatioBar({required this.summary});

  final MatchFormSummary summary;

  @override
  Widget build(BuildContext context) {
    final total = summary.wins + summary.draws + summary.losses;
    if (total == 0) {
      return const SizedBox(
        height: 18,
        child: Align(
          alignment: Alignment.centerLeft,
          child:
              Text('暂无历史交锋统计', style: TextStyle(fontSize: 10, color: _muted)),
        ),
      );
    }
    Widget segment(int count, String label, Color color) {
      if (count == 0) return const SizedBox.shrink();
      final showLabel = count / total >= .16;
      return Expanded(
        flex: count,
        child: Container(
          height: 18,
          alignment: Alignment.center,
          color: color,
          child: showLabel
              ? Text(label,
                  style: const TextStyle(
                      fontSize: 9.5,
                      color: Colors.white,
                      fontWeight: FontWeight.w700))
              : null,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Row(children: [
        segment(summary.wins, '${summary.wins}胜', _red),
        segment(summary.draws, '${summary.draws}平', const Color(0xff2c74df)),
        segment(summary.losses, '${summary.losses}负', _greenDark),
      ]),
    );
  }
}

class _HeadToHeadRecordRow extends StatelessWidget {
  const _HeadToHeadRecordRow({required this.record, required this.perspective});

  final MatchRecord record;
  final String perspective;

  @override
  Widget build(BuildContext context) {
    final resultColor = switch (record.result) {
      '胜' => _red,
      '平' => const Color(0xff2c74df),
      '负' => _greenDark,
      _ => _muted,
    };
    final date =
        record.date.length >= 10 ? record.date.substring(5, 10) : record.date;
    Text team(String name, bool emphasized, TextAlign align) => Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: TextStyle(
              fontSize: 10.5,
              fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500),
        );
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _overviewGrid)),
      ),
      child: Row(children: [
        SizedBox(
          width: 68,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(date, style: const TextStyle(fontSize: 9.5, color: _muted)),
              const SizedBox(height: 2),
              Text(record.league,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 8.5, color: _green)),
            ],
          ),
        ),
        Expanded(
            child:
                team(record.home, record.home == perspective, TextAlign.right)),
        SizedBox(
          width: 50,
          child: Text(record.fullScore.isEmpty ? '--' : record.fullScore,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
        ),
        Expanded(
            child:
                team(record.away, record.away == perspective, TextAlign.left)),
        SizedBox(
          width: 28,
          child: Text(record.result,
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 10.5,
                  color: resultColor,
                  fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

class _OverviewInlineAction extends StatelessWidget {
  const _OverviewInlineAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 11.5,
                    color: _greenDark,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 2),
            Icon(
                label == '收起'
                    ? Icons.expand_less_rounded
                    : Icons.chevron_right_rounded,
                size: 18,
                color: _greenDark),
          ]),
        ),
      );
}

class _AbsenceSection extends StatefulWidget {
  const _AbsenceSection({required this.sides});

  final TeamPlayerSides? sides;

  @override
  State<_AbsenceSection> createState() => _AbsenceSectionState();
}

class _AbsenceSectionState extends State<_AbsenceSection> {
  bool _expanded = false;

  void _toggle() {
    final position = Scrollable.maybeOf(context)?.position;
    final previousPixels = position?.pixels ?? 0;
    setState(() => _expanded = !_expanded);
    if (_expanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final next = Scrollable.maybeOf(context)?.position;
      if (next == null || previousPixels <= next.maxScrollExtent) return;
      next.animateTo(
        next.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final home = widget.sides?.home.players ?? const <MatchPlayer>[];
    final away = widget.sides?.away.players ?? const <MatchPlayer>[];
    final hasContent = home.isNotEmpty || away.isNotEmpty;
    final canExpand = home.length > 2 || away.length > 2;
    final displayedHome =
        _expanded ? home : home.take(2).toList(growable: false);
    final displayedAway =
        _expanded ? away : away.take(2).toList(growable: false);
    final homeTeam = widget.sides?.home.team ?? '';
    final awayTeam = widget.sides?.away.team ?? '';

    return Column(
      children: [
        const _OverviewSectionHeader(title: '重要缺阵'),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: _overviewGrid),
            borderRadius: BorderRadius.circular(5),
          ),
          clipBehavior: Clip.antiAlias,
          child: !hasContent
              ? const SizedBox(
                  height: 44,
                  child: Align(
                    alignment: Alignment.center,
                    child: Text('暂无缺阵信息',
                        style: TextStyle(fontSize: 11, color: _muted)),
                  ),
                )
              : AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: Column(
                    children: [
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _AbsenceSide(
                                title: homeTeam.isEmpty ? '主队缺阵' : homeTeam,
                                count: home.length,
                                players: displayedHome,
                              ),
                            ),
                            const VerticalDivider(
                                width: 1, color: _overviewGrid),
                            Expanded(
                              child: _AbsenceSide(
                                title: awayTeam.isEmpty ? '客队缺阵' : awayTeam,
                                count: away.length,
                                players: displayedAway,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (canExpand)
                        _OverviewInlineAction(
                          label: _expanded ? '收起' : '查看全部',
                          onTap: _toggle,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

class _AbsenceSide extends StatelessWidget {
  const _AbsenceSide({
    required this.title,
    required this.count,
    required this.players,
  });

  final String title;
  final int count;
  final List<MatchPlayer> players;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(9, 8, 9, 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '$count人',
                style: const TextStyle(
                    fontSize: 11,
                    color: _greenDark,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 5),
          if (players.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child:
                  Text('暂无缺阵信息', style: TextStyle(fontSize: 10, color: _muted)),
            )
          else
            for (final player in players) _AbsencePlayerRow(player: player),
        ],
      ),
    );
  }
}

class _AbsencePlayerRow extends StatelessWidget {
  const _AbsencePlayerRow({required this.player});

  final MatchPlayer player;

  @override
  Widget build(BuildContext context) {
    final availability = player.suspended
        ? '停赛'
        : player.injured
            ? '伤病'
            : '';
    return Container(
      height: 24,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _overviewGrid)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              player.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: _ink),
            ),
          ),
          if (player.position.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(player.position,
                style: const TextStyle(fontSize: 9.5, color: _muted)),
          ],
          if (availability.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(availability,
                style: const TextStyle(fontSize: 9.5, color: _red)),
          ],
        ],
      ),
    );
  }
}

// ignore: unused_element
class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.home, required this.away});

  final String home;
  final String away;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: _ink,
      fontSize: 11,
      fontWeight: FontWeight.w700,
    );
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: Text(
              home,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: style,
            ),
          ),
          const SizedBox(
            width: 80,
            child: Text(
              '近10场',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: 10),
            ),
          ),
          Expanded(
            child: Text(
              away,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.home,
    required this.away,
  });

  final String label;
  final String home;
  final String away;

  @override
  Widget build(BuildContext context) {
    const valueStyle = TextStyle(
      color: _ink,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Container(
      height: 34,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(home, textAlign: TextAlign.center, style: valueStyle),
          ),
          SizedBox(
            width: 80,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, fontSize: 10),
            ),
          ),
          Expanded(
            child: Text(away, textAlign: TextAlign.center, style: valueStyle),
          ),
        ],
      ),
    );
  }
}

class _StandingsPanel extends StatelessWidget {
  const _StandingsPanel({required this.standings});

  final MatchStandings standings;

  @override
  Widget build(BuildContext context) {
    final rows = [
      standings.home.total,
      standings.away.total,
    ].where((row) => row.hasContent).toList(growable: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      child: Column(
        children: [
          _ResultModuleTitle(
            title: '联赛排名',
            trailing: [
              standings.league,
              standings.season,
            ].where((item) => item.isNotEmpty).join(' '),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: _overviewGrid),
              borderRadius: BorderRadius.circular(6),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                const _StandingTableRow(header: true),
                for (final row in rows) _StandingTableRow(row: row),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StandingTableRow extends StatelessWidget {
  const _StandingTableRow({this.row, this.header = false});

  final StandingRow? row;
  final bool header;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: header ? 10 : 11,
      color: header ? _muted : _ink,
      fontWeight: header ? FontWeight.w500 : FontWeight.w600,
    );
    Widget cell(String text,
        {int flex = 1, TextAlign align = TextAlign.center}) {
      return Expanded(
        flex: flex,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: style,
        ),
      );
    }

    final value = row;
    return Container(
      height: header ? 31 : 43,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: header ? _overviewHeaderFill : Colors.white,
        border: const Border(bottom: BorderSide(color: _overviewGrid)),
      ),
      child: Row(
        children: [
          cell(header ? '球队' : value?.team ?? '',
              flex: 4, align: TextAlign.left),
          cell(header ? '场' : '${value?.played ?? 0}'),
          cell(
            header
                ? '胜-平-负'
                : '${value?.wins ?? 0}-${value?.draws ?? 0}-${value?.losses ?? 0}',
            flex: 3,
          ),
          cell(
            header
                ? '进失'
                : '${value?.goalsFor ?? 0}/${value?.goalsAgainst ?? 0}',
            flex: 2,
          ),
          cell(header ? '积分' : '${value?.points ?? 0}', flex: 2),
          cell(header ? '排名' : '${value?.ranking ?? 0}', flex: 2),
        ],
      ),
    );
  }
}

enum _RecordFilterKind { none, headToHead, homeRecent, awayRecent }

class _RecordPanel extends StatefulWidget {
  const _RecordPanel({
    required this.title,
    required this.group,
    required this.perspective,
    this.team,
    this.currentLeague = '',
    this.filterKind = _RecordFilterKind.none,
  });

  final String title;
  final MatchRecordGroup group;
  final String perspective;
  final String? team;
  final String currentLeague;
  final _RecordFilterKind filterKind;

  @override
  State<_RecordPanel> createState() => _RecordPanelState();
}

class _RecordPanelState extends State<_RecordPanel> {
  bool _sameVenue = false;
  bool _sameLeague = false;

  List<MatchRecord> get _records {
    return widget.group.matches.where((record) {
      if (_sameLeague &&
          widget.currentLeague.isNotEmpty &&
          record.league != widget.currentLeague) {
        return false;
      }
      if (!_sameVenue) return true;
      return switch (widget.filterKind) {
        _RecordFilterKind.headToHead ||
        _RecordFilterKind.homeRecent =>
          record.home == widget.perspective,
        _RecordFilterKind.awayRecent => record.away == widget.perspective,
        _RecordFilterKind.none => true,
      };
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;
    final summary = _summaryForRecords(records, widget.perspective);
    return _Surface(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 9),
            child: _SectionTitle(
              title: widget.title,
              trailing: widget.team,
            ),
          ),
          const Divider(height: 1, color: _line),
          if (widget.filterKind != _RecordFilterKind.none)
            _RecordFilters(
              kind: widget.filterKind,
              sameVenue: _sameVenue,
              sameLeague: _sameLeague,
              onVenueChanged: (value) => setState(() => _sameVenue = value),
              onLeagueChanged: (value) => setState(() => _sameLeague = value),
            ),
          _FormSummary(summary: summary),
          if (records.isEmpty)
            const SizedBox(
              height: 58,
              child: Center(
                child: Text(
                  '暂无符合条件的比赛',
                  style: TextStyle(fontSize: 11, color: _muted),
                ),
              ),
            )
          else
            for (final record in records.take(5))
              _MatchRecordRow(
                record: record,
                perspective: widget.perspective,
              ),
        ],
      ),
    );
  }
}

class _RecordFilters extends StatelessWidget {
  const _RecordFilters({
    required this.kind,
    required this.sameVenue,
    required this.sameLeague,
    required this.onVenueChanged,
    required this.onLeagueChanged,
  });

  final _RecordFilterKind kind;
  final bool sameVenue;
  final bool sameLeague;
  final ValueChanged<bool> onVenueChanged;
  final ValueChanged<bool> onLeagueChanged;

  @override
  Widget build(BuildContext context) {
    final venueLabel = switch (kind) {
      _RecordFilterKind.homeRecent => '仅主场',
      _RecordFilterKind.awayRecent => '仅客场',
      _ => '同主客',
    };
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: Colors.white,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _CompactCheck(
            label: venueLabel,
            value: sameVenue,
            onChanged: onVenueChanged,
          ),
          if (kind == _RecordFilterKind.headToHead) ...[
            const SizedBox(width: 8),
            _CompactCheck(
              label: '同赛事',
              value: sameLeague,
              onChanged: onLeagueChanged,
            ),
          ],
        ],
      ),
    );
  }
}

class _CompactCheck extends StatelessWidget {
  const _CompactCheck({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: value,
              onChanged: (next) => onChanged(next ?? false),
              activeColor: _green,
              side: const BorderSide(color: Color(0xff9aa19e)),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: value ? _green : const Color(0xff62696c),
              fontWeight: value ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _FormSummary extends StatelessWidget {
  const _FormSummary({required this.summary});

  final MatchFormSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: const Color(0xfffafbfb),
      child: Row(
        children: [
          Text(
            '近${summary.matches}场',
            style: const TextStyle(fontSize: 10, color: _muted),
          ),
          const Spacer(),
          _FormCount('${summary.wins}胜', _red),
          const SizedBox(width: 10),
          _FormCount('${summary.draws}平', const Color(0xff697174)),
          const SizedBox(width: 10),
          _FormCount('${summary.losses}负', const Color(0xff4875a3)),
          if (summary.goalsFor > 0 || summary.goalsAgainst > 0) ...[
            const SizedBox(width: 12),
            Text(
              '进失 ${summary.goalsFor}/${summary.goalsAgainst}',
              style: const TextStyle(fontSize: 10, color: _muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _FormCount extends StatelessWidget {
  const _FormCount(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 10,
        color: color,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

MatchFormSummary _summaryForRecords(
  List<MatchRecord> records,
  String perspective,
) {
  var wins = 0;
  var draws = 0;
  var losses = 0;
  var goalsFor = 0;
  var goalsAgainst = 0;
  for (final record in records) {
    switch (record.result) {
      case '胜':
        wins++;
      case '平':
        draws++;
      case '负':
        losses++;
    }
    final score = RegExp(r'(\d+)\s*[:\-]\s*(\d+)').firstMatch(record.fullScore);
    if (score == null) continue;
    final homeGoals = int.parse(score.group(1)!);
    final awayGoals = int.parse(score.group(2)!);
    if (record.home == perspective) {
      goalsFor += homeGoals;
      goalsAgainst += awayGoals;
    } else if (record.away == perspective) {
      goalsFor += awayGoals;
      goalsAgainst += homeGoals;
    }
  }
  return MatchFormSummary(
    matches: records.length,
    wins: wins,
    draws: draws,
    losses: losses,
    goalsFor: goalsFor,
    goalsAgainst: goalsAgainst,
  );
}

class _MatchRecordRow extends StatelessWidget {
  const _MatchRecordRow({required this.record, required this.perspective});

  final MatchRecord record;
  final String perspective;

  @override
  Widget build(BuildContext context) {
    final resultColor = switch (record.result) {
      '胜' => _red,
      '负' => const Color(0xff4875a3),
      _ => _muted,
    };
    final date =
        record.date.length >= 10 ? record.date.substring(5, 10) : record.date;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _overviewGrid)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 68,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  date,
                  style: const TextStyle(fontSize: 9.5, color: _muted),
                ),
                const SizedBox(height: 2),
                Text(
                  record.league,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 8.5, color: _green),
                ),
              ],
            ),
          ),
          Expanded(
            child: Text(
              record.home,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: record.home == perspective
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 50,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  record.fullScore.isEmpty ? '--' : record.fullScore,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (record.halfScore.isNotEmpty)
                  Text(
                    '半 ${record.halfScore}',
                    style: const TextStyle(fontSize: 8, color: _muted),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Text(
              record.away,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: record.away == perspective
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 28,
            child: record.result.isEmpty
                ? null
                : Text(
                    record.result,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: resultColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.match,
    required this.loadedAt,
    required this.onOpenOdds,
  });

  final MatchItem match;
  final DateTime? loadedAt;
  final VoidCallback onOpenOdds;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Surface(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 8, 8),
                child: Row(
                  children: [
                    const SizedBox(
                      height: 18,
                      child: VerticalDivider(
                        width: 3,
                        thickness: 3,
                        color: _green,
                      ),
                    ),
                    const SizedBox(width: 7),
                    const Text(
                      '竞彩赔率',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: onOpenOdds,
                      style: TextButton.styleFrom(
                        foregroundColor: _ink,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: const Size(0, 30),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('查看赔率', style: TextStyle(fontSize: 10.5)),
                          Icon(Icons.chevron_right_rounded, size: 16),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                height: 30,
                color: const Color(0xfff5f7f6),
                child: const Row(
                  children: [
                    SizedBox(
                        width: 82,
                        child: Center(
                            child: Text('玩法',
                                style:
                                    TextStyle(fontSize: 9.5, color: _muted)))),
                    Expanded(
                        child: Center(
                            child: Text('主胜',
                                style:
                                    TextStyle(fontSize: 9.5, color: _muted)))),
                    Expanded(
                        child: Center(
                            child: Text('平',
                                style:
                                    TextStyle(fontSize: 9.5, color: _muted)))),
                    Expanded(
                        child: Center(
                            child: Text('客胜',
                                style:
                                    TextStyle(fontSize: 9.5, color: _muted)))),
                  ],
                ),
              ),
              if (match.had.isNotEmpty)
                _CoreMarket(
                  title: '胜平负',
                  values: match.had,
                ),
              if (match.had.isNotEmpty && match.hhad.isNotEmpty)
                const Divider(height: 1, color: _line),
              if (match.hhad.isNotEmpty)
                _CoreMarket(
                  title: '让球胜平负',
                  values: Map<String, dynamic>.from(match.hhad)..remove('让球'),
                  handicap: match.hhad['让球']?.toString(),
                ),
              if (match.had.isEmpty && match.hhad.isEmpty)
                const _Empty(text: '暂无核心赔率'),
              if (loadedAt != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '更新 ${_mdhm(loadedAt!)}',
                      style: const TextStyle(fontSize: 8.5, color: _muted),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ignore: unused_element
class _OddsProbabilityPanel extends StatelessWidget {
  const _OddsProbabilityPanel({required this.match});

  final MatchItem match;

  @override
  Widget build(BuildContext context) {
    final values = _normalizedProbabilities(match.had);
    final rows = <({String label, double value, Color color})>[
      (label: '主胜', value: values.$1, color: const Color(0xffe44f61)),
      (label: '平局', value: values.$2, color: const Color(0xffe5a32d)),
      (label: '客胜', value: values.$3, color: const Color(0xff288ec7)),
    ];
    final favorite = rows.reduce((a, b) => a.value >= b.value ? a : b);
    return _Surface(
      color: const Color(0xfff4faf7),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insights_outlined, size: 17, color: _green),
              const SizedBox(width: 5),
              const Text(
                '当前 SP 倾向',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '重点 ${favorite.label}',
                style: TextStyle(
                  fontSize: 11,
                  color: favorite.color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          Row(
            children: [
              for (var index = 0; index < rows.length; index++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: index == rows.length - 1 ? 0 : 7,
                    ),
                    child: _ProbabilityCell(data: rows[index]),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '按当前胜平负 SP 归一化换算，仅反映赔率倾向，不构成赛果预测。',
            style: TextStyle(fontSize: 9.5, color: _muted),
          ),
        ],
      ),
    );
  }
}

class _ProbabilityCell extends StatelessWidget {
  const _ProbabilityCell({required this.data});

  final ({String label, double value, Color color}) data;

  @override
  Widget build(BuildContext context) {
    final percentage = (data.value * 100).round();
    return Container(
      height: 66,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xffe3ece7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(data.label, style: const TextStyle(fontSize: 10, color: _muted)),
          const SizedBox(height: 2),
          Text(
            '$percentage%',
            style: TextStyle(
              fontSize: 17,
              height: 1,
              color: data.color,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: data.value,
              minHeight: 4,
              color: data.color,
              backgroundColor: const Color(0xffe9eeeb),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoreMarket extends StatelessWidget {
  const _CoreMarket({
    required this.title,
    required this.values,
    this.handicap,
  });

  final String title;
  final Map<String, dynamic> values;
  final String? handicap;

  @override
  Widget build(BuildContext context) {
    final entries = _orderedOutcomes(values);
    return SizedBox(
      height: 43,
      child: Row(
        children: [
          SizedBox(
            width: 82,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  handicap == null ? title : '让球($handicap)',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          for (final entry in entries)
            Expanded(
              child: Center(
                child: Text(
                  _odd(entry.value),
                  style: const TextStyle(
                    fontSize: 13,
                    color: _greenDark,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _MoreMarkets extends StatelessWidget {
  const _MoreMarkets({required this.match, required this.onOpenOdds});

  final MatchItem match;
  final VoidCallback onOpenOdds;

  @override
  Widget build(BuildContext context) {
    final items = [
      (
        icon: Icons.sports_soccer_rounded,
        title: '总进球',
        subtitle: match.ttg.isEmpty ? '暂未开放' : '${match.ttg.length}个选项',
      ),
      (
        icon: Icons.grid_view_rounded,
        title: '比分',
        subtitle: match.crs.isEmpty ? '暂未开放' : '${match.crs.length}个比分',
      ),
      (
        icon: Icons.contrast_rounded,
        title: '半全场',
        subtitle: match.hafu.isEmpty ? '暂未开放' : '${match.hafu.length}种玩法',
      ),
      (icon: Icons.apps_rounded, title: '更多玩法', subtitle: '查看全部'),
    ];
    return InkWell(
      onTap: onOpenOdds,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Text(
                '更多玩法',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              Spacer(),
              Icon(Icons.chevron_right_rounded, size: 18, color: _muted),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            children: items.map((item) {
              return Expanded(
                child: Column(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: const Color(0xfff7f9f8),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xffedf0ef)),
                      ),
                      child: Icon(item.icon, color: _greenDark, size: 19),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      item.title,
                      style: const TextStyle(fontSize: 10.5, color: _ink),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      item.subtitle,
                      style: const TextStyle(fontSize: 8.5, color: _muted),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _RiskPanel extends StatelessWidget {
  const _RiskPanel({required this.match});

  final MatchItem match;

  @override
  Widget build(BuildContext context) {
    final notes = <String>[
      '临场SP可能继续变化，请以官方最终公布数据为准。',
      '比赛延期、中断或取消时以体彩官方规则为准。',
      if (match.bettingStatus != BettingStatus.open) '当前比赛已停售，不能继续选号。',
    ];
    return _Surface(
      color: const Color(0xfffffaf3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _SectionIconTitle(
                icon: Icons.warning_amber_rounded,
                title: '风险提示',
                color: _orange,
              ),
              const Spacer(),
              Text(
                '${notes.length}项',
                style: const TextStyle(fontSize: 10, color: _muted),
              ),
              const Icon(Icons.chevron_right_rounded, size: 17, color: _muted),
            ],
          ),
          const SizedBox(height: 8),
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Text(
                '•  $note',
                style: const TextStyle(fontSize: 10.5, height: 1.35),
              ),
            ),
        ],
      ),
    );
  }
}

class _OddsHub extends StatefulWidget {
  const _OddsHub({
    required this.match,
    required this.loadedAt,
    required this.history,
    required this.marketOdds,
  });

  final MatchItem match;
  final DateTime? loadedAt;
  final List<Map<String, dynamic>> history;
  final Map<String, dynamic> marketOdds;

  @override
  State<_OddsHub> createState() => _OddsHubState();
}

class _OddsHubState extends State<_OddsHub> {
  int _section = 0;

  @override
  Widget build(BuildContext context) {
    const labels = ['竞彩', '欧赔', '亚赔', '大小球'];
    return Column(
      children: [
        const SizedBox(height: 12),
        _DetailSubTabs(
          labels: labels,
          value: _section,
          onChanged: (value) => setState(() => _section = value),
        ),
        const SizedBox(height: 10),
        switch (_section) {
          0 => _OddsTab(
              match: widget.match,
              loadedAt: widget.loadedAt,
              history: widget.history,
            ),
          1 => _ExternalOddsMarket(
              payload: widget.marketOdds,
              marketKey: 'h2h',
              emptyIcon: Icons.public_rounded,
              emptyTitle: '暂无欧赔数据',
            ),
          2 => _ExternalOddsMarket(
              payload: widget.marketOdds,
              marketKey: 'spreads',
              emptyIcon: Icons.swap_horiz_rounded,
              emptyTitle: '暂无亚赔数据',
            ),
          3 => _ExternalOddsMarket(
              payload: widget.marketOdds,
              marketKey: 'totals',
              emptyIcon: Icons.unfold_more_rounded,
              emptyTitle: '暂无大小球数据',
            ),
          _ => const SizedBox.shrink(),
        },
      ],
    );
  }
}

class _ExternalOddsMarket extends StatelessWidget {
  const _ExternalOddsMarket({
    required this.payload,
    required this.marketKey,
    required this.emptyIcon,
    required this.emptyTitle,
  });

  final Map<String, dynamic> payload;
  final String marketKey;
  final IconData emptyIcon;
  final String emptyTitle;

  @override
  Widget build(BuildContext context) {
    final bookmakers = (payload['bookmakers'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) {
      final markets = item['markets'];
      return markets is Map && markets[marketKey] is List;
    }).toList(growable: false);
    if (bookmakers.isEmpty) {
      return _ExternalOddsEmpty(icon: emptyIcon, title: emptyTitle);
    }
    final generated =
        DateTime.tryParse(payload['generatedAt']?.toString() ?? '')?.toLocal();
    return _Surface(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          if (marketKey == 'h2h')
            _ExternalOddsSummary(
              bookmakers: bookmakers,
              marketKey: marketKey,
              providerHome: payload['home']?.toString() ?? '',
              providerAway: payload['away']?.toString() ?? '',
            ),
          _ExternalOddsTableHeader(
            marketKey: marketKey,
            bookmakerCount: bookmakers.length,
          ),
          for (var index = 0; index < bookmakers.length; index++) ...[
            _ExternalBookmakerRow(
              bookmaker: bookmakers[index],
              marketKey: marketKey,
              providerHome: payload['home']?.toString() ?? '',
              providerAway: payload['away']?.toString() ?? '',
              showOutcomeLabels: marketKey != 'h2h',
            ),
            if (index != bookmakers.length - 1)
              const Divider(height: 1, indent: 12, endIndent: 12, color: _line),
          ],
          if (generated != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 12, 9),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '更新 ${_mdhm(generated)}',
                  style: const TextStyle(fontSize: 9, color: _muted),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ExternalOddsTableHeader extends StatelessWidget {
  const _ExternalOddsTableHeader({
    required this.marketKey,
    required this.bookmakerCount,
  });

  final String marketKey;
  final int bookmakerCount;

  @override
  Widget build(BuildContext context) {
    final labels =
        marketKey == 'h2h' ? const ['主胜', '平', '客胜'] : const <String>[];
    return Container(
      height: 31,
      color: const Color(0xfff4f6f5),
      child: Row(
        children: [
          const SizedBox(
            width: 88,
            child: Center(
              child: Text('公司', style: TextStyle(fontSize: 10, color: _muted)),
            ),
          ),
          if (labels.isEmpty)
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(left: BorderSide(color: _overviewGrid)),
                ),
                alignment: Alignment.center,
                child: const Text(
                  '初始 / 即时',
                  style: TextStyle(fontSize: 10, color: _muted),
                ),
              ),
            )
          else
            for (final label in labels)
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    border: Border(left: BorderSide(color: _overviewGrid)),
                  ),
                  alignment: Alignment.center,
                  child: Text(label,
                      style: const TextStyle(fontSize: 10, color: _muted)),
                ),
              ),
        ],
      ),
    );
  }
}

class _ExternalOddsSummary extends StatelessWidget {
  const _ExternalOddsSummary({
    required this.bookmakers,
    required this.marketKey,
    required this.providerHome,
    required this.providerAway,
  });

  final List<Map<String, dynamic>> bookmakers;
  final String marketKey;
  final String providerHome;
  final String providerAway;

  @override
  Widget build(BuildContext context) {
    final buckets = <String, List<double>>{};
    for (final bookmaker in bookmakers) {
      final markets = bookmaker['markets'] as Map?;
      final outcomes =
          (markets?[marketKey] as List<dynamic>? ?? const []).whereType<Map>();
      for (final item in outcomes) {
        final label = _externalOutcomeLabel(
          item['name']?.toString() ?? '',
          marketKey,
          item['point'],
          providerHome,
          providerAway,
        );
        final value = double.tryParse(item['price']?.toString() ?? '');
        if (value != null) buckets.putIfAbsent(label, () => []).add(value);
      }
    }
    final labels = const ['主胜', '平', '客胜'];
    if (!buckets.values.any((values) => values.isNotEmpty))
      return const SizedBox.shrink();
    String valueFor(String label, String kind) {
      final values = buckets[label];
      if (values == null || values.isEmpty) return '--';
      final value = switch (kind) {
        '最高值' => values.reduce(math.max),
        '最低值' => values.reduce(math.min),
        _ => values.reduce((a, b) => a + b) / values.length,
      };
      return _externalPrice(value, marketKey);
    }

    return Column(
      children: [
        const _PanelHeader(title: '赔率概况'),
        Container(
          height: 30,
          color: const Color(0xfff4f6f5),
          child: Row(children: [
            const SizedBox(width: 88),
            for (final label in labels)
              Expanded(
                  child: Center(
                      child: Text(label,
                          style:
                              const TextStyle(fontSize: 10, color: _muted)))),
          ]),
        ),
        for (final kind in const ['最高值', '最低值', '平均值'])
          SizedBox(
            height: 34,
            child: Row(children: [
              SizedBox(
                  width: 88,
                  child: Center(
                      child: Text(kind,
                          style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w600)))),
              for (final label in labels)
                Expanded(
                    child: Center(
                        child: Text(valueFor(label, kind),
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                fontFeatures: [
                                  FontFeature.tabularFigures()
                                ])))),
            ]),
          ),
        const Divider(height: 1, color: _line),
      ],
    );
  }
}

class _ExternalBookmakerRow extends StatelessWidget {
  const _ExternalBookmakerRow({
    required this.bookmaker,
    required this.marketKey,
    required this.providerHome,
    required this.providerAway,
    required this.showOutcomeLabels,
  });

  final Map<String, dynamic> bookmaker;
  final String marketKey;
  final String providerHome;
  final String providerAway;
  final bool showOutcomeLabels;

  @override
  Widget build(BuildContext context) {
    final markets = bookmaker['markets'] as Map?;
    final outcomes = (markets?[marketKey] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    outcomes.sort(
      (left, right) => _externalOutcomeOrder(
        left['name']?.toString() ?? '',
        marketKey,
        providerHome,
        providerAway,
      ).compareTo(
        _externalOutcomeOrder(
          right['name']?.toString() ?? '',
          marketKey,
          providerHome,
          providerAway,
        ),
      ),
    );
    return Container(
      constraints: BoxConstraints(minHeight: showOutcomeLabels ? 68 : 54),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            child: Center(
              child: Text(
                bookmaker['title']?.toString() ??
                    bookmaker['key']?.toString() ??
                    '--',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 10.5,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          for (final outcome in outcomes)
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(left: BorderSide(color: _overviewGrid)),
                ),
                child: _ExternalOutcomeCell(
                  outcome: outcome,
                  marketKey: marketKey,
                  providerHome: providerHome,
                  providerAway: providerAway,
                  showLabel: showOutcomeLabels,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ExternalOutcomeCell extends StatelessWidget {
  const _ExternalOutcomeCell({
    required this.outcome,
    required this.marketKey,
    required this.providerHome,
    required this.providerAway,
    required this.showLabel,
  });

  final Map<String, dynamic> outcome;
  final String marketKey;
  final String providerHome;
  final String providerAway;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final opening = outcome['openingPrice'];
    final point = outcome['point'];
    return Column(
      children: [
        if (showLabel) ...[
          Text(
            _externalOutcomeLabel(
              outcome['name']?.toString() ?? '',
              marketKey,
              point,
              providerHome,
              providerAway,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 9.5, color: _muted),
          ),
          const SizedBox(height: 3),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              _externalPrice(outcome['price'], marketKey),
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 3),
            Text(
              _oddsMovement(outcome['price'], opening, marketKey),
              style: TextStyle(
                fontSize: 8,
                color: _oddsMovementColor(outcome['price'], opening),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text('初 ${_externalPrice(opening, marketKey)}',
            style: const TextStyle(
              fontSize: 8.5,
              color: _muted,
              fontFeatures: [FontFeature.tabularFigures()],
            )),
      ],
    );
  }
}

String _oddsMovement(dynamic current, dynamic opening, String marketKey) {
  final currentValue = double.tryParse(current?.toString() ?? '');
  final openingValue = double.tryParse(opening?.toString() ?? '');
  if (currentValue == null || openingValue == null) return '';
  if ((currentValue - openingValue).abs() < 0.005) return '';
  return currentValue > openingValue ? '↑' : '↓';
}

Color _oddsMovementColor(dynamic current, dynamic opening) {
  final currentValue = double.tryParse(current?.toString() ?? '');
  final openingValue = double.tryParse(opening?.toString() ?? '');
  if (currentValue == null || openingValue == null) return _muted;
  return currentValue > openingValue ? _red : _green;
}

String _externalOutcomeLabel(
  String name,
  String marketKey,
  dynamic point,
  String providerHome,
  String providerAway,
) {
  final lower = name.toLowerCase();
  final label = marketKey == 'h2h' && name == providerHome
      ? '主胜'
      : marketKey == 'h2h' && name == providerAway
          ? '客胜'
          : marketKey == 'spreads' && name == providerHome
              ? '主'
              : marketKey == 'spreads' && name == providerAway
                  ? '客'
                  : lower == 'draw'
                      ? '平'
                      : lower == 'over'
                          ? '大'
                          : lower == 'under'
                              ? '小'
                              : name;
  if (marketKey == 'h2h' || point == null) return label;
  return '$label ${point.toString()}';
}

int _externalOutcomeOrder(
  String name,
  String marketKey,
  String providerHome,
  String providerAway,
) {
  final lower = name.toLowerCase();
  if (marketKey == 'h2h') {
    if (name == providerHome) return 0;
    if (lower == 'draw') return 1;
    if (name == providerAway) return 2;
  }
  if (marketKey == 'spreads') {
    if (name == providerHome) return 0;
    if (name == providerAway) return 1;
  }
  if (marketKey == 'totals') {
    if (lower == 'over') return 0;
    if (lower == 'under') return 1;
  }
  return 9;
}

String _externalPrice(dynamic value, String marketKey) {
  final number = double.tryParse(value?.toString() ?? '');
  if (number == null) return '--';
  if (marketKey == 'h2h') return number.toStringAsFixed(2);
  return math.max(0, number - 1).toStringAsFixed(2);
}

class _ExternalOddsEmpty extends StatelessWidget {
  const _ExternalOddsEmpty({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return _Surface(
      child: SizedBox(
        height: 150,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 28, color: const Color(0xffa8afac)),
              const SizedBox(height: 9),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  color: _muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OddsTab extends StatelessWidget {
  const _OddsTab({
    required this.match,
    required this.loadedAt,
    required this.history,
  });

  final MatchItem match;
  final DateTime? loadedAt;
  final List<Map<String, dynamic>> history;

  @override
  Widget build(BuildContext context) {
    final markets = <({
      String title,
      String historyKey,
      Map<String, dynamic> values,
      String? handicap,
    })>[
      (
        title: '胜平负',
        historyKey: 'had',
        values: Map<String, dynamic>.from(match.had),
        handicap: null,
      ),
      (
        title: '让球胜平负',
        historyKey: 'hhad',
        values: Map<String, dynamic>.from(match.hhad)..remove('让球'),
        handicap: match.hhad['让球']?.toString(),
      ),
      (
        title: '总进球',
        historyKey: 'ttg',
        values: Map<String, dynamic>.from(match.ttg),
        handicap: null,
      ),
      (
        title: '比分',
        historyKey: 'crs',
        values: Map<String, dynamic>.from(match.crs),
        handicap: null,
      ),
      (
        title: '半全场',
        historyKey: 'hafu',
        values: Map<String, dynamic>.from(match.hafu),
        handicap: null,
      ),
    ].where((item) => item.values.isNotEmpty).toList();
    return Column(
      children: [
        if (match.had.isNotEmpty || match.hhad.isNotEmpty)
          Padding(
            padding:
                const EdgeInsets.fromLTRB(_overviewInset, 4, _overviewInset, 0),
            child: Column(
              children: [
                _OverviewSectionHeader(
                  title: '竞彩赔率',
                  trailing: loadedAt == null
                      ? null
                      : Text(
                          '更新 ${_mdhm(loadedAt!)}',
                          style: const TextStyle(fontSize: 10, color: _muted),
                        ),
                ),
                _ChangeTable(match: match, history: history),
              ],
            ),
          ),
        if (markets.isNotEmpty) ...[
          const SizedBox(height: 10),
          const SizedBox(
              height: _overviewSectionGap, child: ColoredBox(color: _page)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _overviewInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _OverviewSectionHeader(title: '全部玩法'),
                for (var index = 0; index < markets.length; index++) ...[
                  _OddsMarketTable(
                    title: markets[index].title,
                    values: markets[index].values,
                    handicap: markets[index].handicap,
                    initialValues: _initialValues(markets[index].historyKey),
                  ),
                  if (index != markets.length - 1)
                    const SizedBox(height: _overviewSectionGap),
                ],
              ],
            ),
          ),
        ] else
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: _Empty(text: '暂无官方赔率'),
          ),
      ],
    );
  }

  Map<String, dynamic> _initialValues(String historyKey) {
    final values = _earliestHistoryMarket(history, historyKey);
    values.remove('让球');
    return values;
  }
}

class _ChangeTable extends StatelessWidget {
  const _ChangeTable({required this.match, required this.history});

  final MatchItem match;
  final List<Map<String, dynamic>> history;

  @override
  Widget build(BuildContext context) {
    final had = _orderedOutcomes(match.had);
    final hhadValues = Map<String, dynamic>.from(match.hhad)..remove('让球');
    final hhad = _orderedOutcomes(hhadValues);
    final firstHad = _earliestHistorySnapshot(history, 'had');
    final firstHhad = _earliestHistorySnapshot(history, 'hhad');
    final initialHad = _historyMarket(firstHad, 'had');
    final initialHhad = _historyMarket(firstHhad, 'hhad')..remove('让球');
    final handicap = match.hhad['让球']?.toString() ?? '';
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _overviewGrid),
        borderRadius: BorderRadius.circular(5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          const _ChangeRow(
              label: '玩法', values: ['主胜', '平', '客胜'], header: true),
          if (had.isNotEmpty)
            _ChangeRow(
              label: '胜平负 初始',
              values: _historyOdds(initialHad),
            ),
          if (had.isNotEmpty)
            _ChangeRow(
              label: '胜平负 即时',
              values: had.map((entry) => _odd(entry.value)).toList(),
              strong: true,
            ),
          if (hhad.isNotEmpty)
            _ChangeRow(
              label: '让球($handicap) 初始',
              values: _historyOdds(initialHhad),
            ),
          if (hhad.isNotEmpty)
            _ChangeRow(
              label: '让球($handicap) 即时',
              values: hhad.map((entry) => _odd(entry.value)).toList(),
              strong: true,
            ),
        ],
      ),
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    required this.label,
    required this.values,
    this.strong = false,
    this.header = false,
  });

  final String label;
  final List<String> values;
  final bool strong;
  final bool header;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: header ? 31 : 36,
      decoration: BoxDecoration(
        color: header ? _overviewHeaderFill : Colors.white,
        border: const Border(bottom: BorderSide(color: _overviewGrid)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: header ? 10 : 10.5,
                color: header
                    ? _muted
                    : strong
                        ? _greenDark
                        : _ink,
                fontWeight: header
                    ? FontWeight.w500
                    : strong
                        ? FontWeight.w700
                        : FontWeight.w500,
              ),
            ),
          ),
          const VerticalDivider(width: 1, color: _overviewGrid),
          for (final value in values.take(3))
            Expanded(
              child: Container(
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  border: Border(left: BorderSide(color: _overviewGrid)),
                ),
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: header ? 10 : 11.5,
                    fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _OddsMarketTable extends StatelessWidget {
  const _OddsMarketTable({
    required this.title,
    required this.values,
    required this.initialValues,
    this.handicap,
  });

  final String title;
  final Map<String, dynamic> values;
  final Map<String, dynamic> initialValues;
  final String? handicap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _green,
              ),
            ),
            if (handicap != null) ...[
              const SizedBox(width: 8),
              Text(
                '让($handicap)',
                style: const TextStyle(fontSize: 10, color: _green),
              ),
            ],
          ],
        ),
        const SizedBox(height: 7),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: _overviewGrid),
            borderRadius: BorderRadius.circular(5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              const _OddsMarketRow(
                label: '选项',
                current: '即时',
                initial: '初始',
                change: '变化',
                header: true,
              ),
              for (final entry in _orderedMarket(title, values))
                Builder(
                  builder: (_) {
                    final initial = initialValues[entry.key];
                    final change = _oddChange(entry.value, initial);
                    return _OddsMarketRow(
                      label: _marketLabel(title, entry.key),
                      current: _odd(entry.value),
                      initial: initial == null ? '--' : _odd(initial),
                      change: change.label,
                      changeColor: change.color,
                      emphasized: change.emphasized,
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OddsMarketRow extends StatelessWidget {
  const _OddsMarketRow({
    required this.label,
    required this.current,
    required this.initial,
    required this.change,
    this.header = false,
    this.changeColor = _muted,
    this.emphasized = false,
  });

  final String label;
  final String current;
  final String initial;
  final String change;
  final bool header;
  final Color changeColor;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    Widget cell(String text, {Color color = _ink, bool strong = false}) {
      return Expanded(
        child: Container(
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: _overviewGrid)),
          ),
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: header ? 9.5 : 10.5,
              color: header ? _muted : color,
              fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      );
    }

    return Container(
      height: header ? 29 : 34,
      decoration: BoxDecoration(
        color: header ? _overviewHeaderFill : Colors.white,
        border: const Border(bottom: BorderSide(color: _overviewGrid)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: header ? 9.5 : 10.5,
                  color: header ? _muted : _ink,
                  fontWeight: header ? FontWeight.w500 : FontWeight.w600,
                ),
              ),
            ),
          ),
          cell(current, strong: !header),
          cell(initial, color: _muted),
          cell(change, color: changeColor, strong: emphasized),
        ],
      ),
    );
  }
}

class _ResultsTab extends StatelessWidget {
  const _ResultsTab({required this.match});

  final MatchItem match;

  @override
  Widget build(BuildContext context) {
    final full = _scoreParts(match.finalScore ?? match.score);
    final half = _scoreParts(match.halfTimeScore);
    if (full == null) {
      return const _Surface(child: _Empty(text: '官方赛果暂未回传'));
    }

    final markets = <_ResolvedMarketData>[
      if (match.had.isNotEmpty)
        _ResolvedMarketData(
          title: '胜平负',
          winner: _normalOutcome(full.$1, full.$2),
          values: match.had,
        ),
      if (match.hhad.isNotEmpty)
        _ResolvedMarketData(
          title: '让球胜平负',
          winner: _handicapOutcome(full.$1, full.$2, match.hhad['让球']),
          values: Map<String, dynamic>.from(match.hhad)..remove('让球'),
          note: '让球 ${match.hhad['让球'] ?? '--'}',
          aliases: const {'让胜': '胜', '让平': '平', '让负': '负'},
        ),
      if (match.ttg.isNotEmpty)
        _ResolvedMarketData(
          title: '总进球',
          winner: _totalGoalsOutcome(full.$1, full.$2),
          values: match.ttg,
        ),
      if (match.crs.isNotEmpty)
        _ResolvedMarketData(
          title: '比分',
          winner: _scoreOutcome(full.$1, full.$2, match.crs),
          values: match.crs,
        ),
      if (match.hafu.isNotEmpty && half != null)
        _ResolvedMarketData(
          title: '半全场',
          winner:
              '${_normalOutcome(half.$1, half.$2)}${_normalOutcome(full.$1, full.$2)}',
          values: match.hafu,
        ),
    ];

    return Column(
      children: [
        Padding(
          padding:
              const EdgeInsets.fromLTRB(_overviewInset, 14, _overviewInset, 13),
          child: Column(
            children: [
              _ResultModuleTitle(
                title: '官方赛果',
                verified: true,
                trailing: match.fetchedAt == null
                    ? null
                    : '${_mdhm(match.fetchedAt!.toLocal())} 更新',
              ),
              const SizedBox(height: 10),
              Container(
                height: 76,
                decoration: BoxDecoration(
                  border: Border.all(color: _overviewGrid),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(
                  children: [
                    _ResultSummaryCell(
                      label: '全场',
                      value: '${full.$1} : ${full.$2}',
                    ),
                    const VerticalDivider(width: 1, color: _line),
                    _ResultSummaryCell(
                      label: '半场',
                      value: _scoreText(match.halfTimeScore),
                    ),
                    const VerticalDivider(width: 1, color: _line),
                    _ResultSummaryCell(
                      label: '总进球',
                      value: '${full.$1 + full.$2}球',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (markets.isNotEmpty) ...[
          const _ResultSectionDivider(),
          _ResultSpStrip(markets: markets),
        ],
        const _ResultSectionDivider(),
        _ResultTimeline(
          kickoff: match.kickoffDisplayTime,
          half: _scoreText(match.halfTimeScore),
          full: '${full.$1}:${full.$2}',
        ),
      ],
    );
  }
}

class _ResultSectionDivider extends StatelessWidget {
  const _ResultSectionDivider();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 5, child: ColoredBox(color: _page));
}

class _ResultModuleTitle extends StatelessWidget {
  const _ResultModuleTitle({
    required this.title,
    this.trailing,
    this.verified = false,
  });

  final String title;
  final String? trailing;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 19,
          decoration: BoxDecoration(
            color: _green,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: _ink,
          ),
        ),
        if (verified) ...[
          const SizedBox(width: 5),
          const Icon(Icons.verified_rounded, size: 15, color: _greenDark),
        ],
        const Spacer(),
        if (trailing != null)
          Text(trailing!, style: const TextStyle(fontSize: 10, color: _muted)),
      ],
    );
  }
}

class _ResultSummaryCell extends StatelessWidget {
  const _ResultSummaryCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: const TextStyle(fontSize: 9.5, color: _muted)),
          const SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResolvedMarketData {
  const _ResolvedMarketData({
    required this.title,
    required this.winner,
    required this.values,
    this.note,
    this.aliases = const {},
  });

  final String title;
  final String winner;
  final Map<String, dynamic> values;
  final String? note;
  final Map<String, String> aliases;

  String get selectedKey => aliases[winner] ?? winner;

  dynamic get selectedOdd => values[selectedKey];
}

class _ResultSpStrip extends StatelessWidget {
  const _ResultSpStrip({required this.markets});

  final List<_ResolvedMarketData> markets;

  String _shortTitle(String title) => switch (title) {
        '胜平负' => '胜平负',
        '让球胜平负' => '让球',
        '总进球' => '总进球',
        '比分' => '比分',
        '半全场' => '半全场',
        _ => title,
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(_overviewInset, 14, _overviewInset, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ResultModuleTitle(title: '竞彩赛果'),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: _overviewGrid),
              borderRadius: BorderRadius.circular(5),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Container(
                  height: 32,
                  color: const Color(0xfff5f7f6),
                  child: const Row(
                    children: const [
                      _ResultTableCell(text: '玩法', header: true),
                      _ResultTableCell(text: '赛果', header: true),
                      _ResultTableCell(text: '开奖SP', header: true),
                    ],
                  ),
                ),
                for (var index = 0; index < markets.length; index++) ...[
                  SizedBox(
                    height: 42,
                    child: Row(
                      children: [
                        _ResultTableCell(
                          text: markets[index].note == null
                              ? _shortTitle(markets[index].title)
                              : '${_shortTitle(markets[index].title)}(${markets[index].note!.replaceFirst('让球 ', '')})',
                        ),
                        _ResultTableCell(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _greenSoft,
                              borderRadius: BorderRadius.circular(4),
                              border:
                                  Border.all(color: const Color(0xffb9d9cd)),
                            ),
                            child: Text(
                              _marketLabel(
                                markets[index].title,
                                markets[index].selectedKey,
                              ),
                              style: const TextStyle(
                                fontSize: 11,
                                color: _greenDark,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        _ResultTableCell(
                          text: _odd(markets[index].selectedOdd),
                          strong: true,
                        ),
                      ],
                    ),
                  ),
                  if (index != markets.length - 1)
                    const Divider(height: 1, color: _line),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultTableCell extends StatelessWidget {
  const _ResultTableCell({
    this.text,
    this.child,
    this.header = false,
    this.strong = false,
  }) : assert(text != null || child != null);

  final String? text;
  final Widget? child;
  final bool header;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final content = child ??
        Text(
          text!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: header ? 10 : 11,
            color: header ? _muted : _ink,
            fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
    return Expanded(
      child: Container(
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: _overviewGrid)),
        ),
        child: content,
      ),
    );
  }
}

class _ResultTimeline extends StatelessWidget {
  const _ResultTimeline({
    required this.kickoff,
    required this.half,
    required this.full,
  });

  final String kickoff;
  final String half;
  final String full;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(_overviewInset, 14, _overviewInset, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ResultModuleTitle(title: '比赛进程'),
          const SizedBox(height: 15),
          Row(
            children: [
              _TimelinePoint(
                  icon: Icons.play_arrow_rounded, label: '开赛', value: kickoff),
              const Expanded(
                  child: Divider(height: 1, color: Color(0xff8fa49b))),
              _TimelinePoint(label: '半场', value: half),
              const Expanded(
                  child: Divider(height: 1, color: Color(0xff8fa49b))),
              _TimelinePoint(
                  icon: Icons.sports_score_rounded, label: '全场', value: full),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimelinePoint extends StatelessWidget {
  const _TimelinePoint({required this.label, required this.value, this.icon});

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      child: Column(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration:
                const BoxDecoration(color: _greenDark, shape: BoxShape.circle),
            child: icon == null
                ? const Center(
                    child: SizedBox(
                        width: 6,
                        height: 6,
                        child: DecoratedBox(
                            decoration: BoxDecoration(
                                color: Colors.white, shape: BoxShape.circle))))
                : Icon(icon, size: 13, color: Colors.white),
          ),
          const SizedBox(height: 5),
          Text(label, style: const TextStyle(fontSize: 9.5, color: _muted)),
          Text(value,
              style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _AnalysisTab extends StatelessWidget {
  const _AnalysisTab({required this.match, required this.predictions});

  final MatchItem match;
  final List<Map<String, dynamic>> predictions;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionIconTitle(
                icon: Icons.psychology_alt_outlined,
                title: '模型预测',
                color: _green,
              ),
              const SizedBox(height: 10),
              if (predictions.isEmpty)
                const _Empty(text: '暂无真实预测数据')
              else
                for (final item in predictions) _PredictionRow(item: item),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _RiskPanel(match: match),
      ],
    );
  }
}

class _PredictionRow extends StatelessWidget {
  const _PredictionRow({required this.item});

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    String value(String key) {
      final text = item[key]?.toString().trim() ?? '';
      return text.isEmpty ? '--' : text;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xfff7f9f8),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              value('model_name'),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            '方向 ${value('predicted_direction')}',
            style: const TextStyle(fontSize: 10),
          ),
          const SizedBox(width: 12),
          Text(
            '比分 ${value('predicted_score')}',
            style: const TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.color = Colors.white,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        border: const Border(
          top: BorderSide(color: _line),
          bottom: BorderSide(color: _line),
        ),
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: _ink,
          ),
        ),
        const Spacer(),
        if (trailing != null)
          Text(trailing!, style: const TextStyle(fontSize: 9, color: _muted)),
      ],
    );
  }
}

class _SectionIconTitle extends StatelessWidget {
  const _SectionIconTitle({
    required this.icon,
    required this.title,
    required this.color,
  });

  final IconData icon;
  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 5),
        Text(
          title,
          style: TextStyle(
            fontSize: 12.5,
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

// ignore: unused_element
class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _greenSoft,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9,
          color: _green,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xfffff7ed),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 10, color: Color(0xff9a5a1f)),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Center(
        child: Text(text, style: const TextStyle(fontSize: 10, color: _muted)),
      ),
    );
  }
}

String _mdhm(DateTime time) =>
    '${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String _statusText(MatchItem match) {
  return switch (match.matchState) {
    MatchState.notStarted => '未开始',
    MatchState.live =>
      match.liveMinuteDisplay ?? _liveStatusText(match.liveStatusText),
    MatchState.halftime => '中场',
    MatchState.finished => '已结束',
    MatchState.postponed => '延期',
    MatchState.cancelled => '取消',
    MatchState.suspended => '暂停',
    MatchState.unknown => match.matchStateText.trim().isEmpty
        ? '状态未知'
        : match.matchStateText.trim(),
  };
}

String _liveStatusText(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return '进行中';
  return RegExp(r'^\d+$').hasMatch(text) ? '$text′' : text;
}

// ignore: unused_element
bool _canSelectMatch(MatchItem match) {
  if (match.matchState != MatchState.notStarted ||
      match.bettingStatus != BettingStatus.open ||
      !match.kickoff.isAfter(DateTime.now())) {
    return false;
  }
  return match.canParlay || match.singleSupported;
}

// ignore: unused_element
Color _statusColor(MatchItem match) {
  return switch (match.matchState) {
    MatchState.live || MatchState.halftime => _green,
    MatchState.finished => _red,
    MatchState.postponed ||
    MatchState.cancelled ||
    MatchState.suspended =>
      _orange,
    _ => _greenDark,
  };
}

String? _displayScore(MatchItem match) {
  final value = match.matchState == MatchState.finished
      ? (match.finalScore ?? match.score)
      : (match.score ?? match.finalScore);
  final text = value?.trim() ?? '';
  return text.isEmpty ? null : text;
}

// ignore: unused_element
bool _isFinishedMatch(MatchItem match) =>
    match.matchState == MatchState.finished ||
    match.status == MatchStatus.finished ||
    _scoreParts(match.finalScore) != null;

(int, int)? _scoreParts(String? source) {
  final match = RegExp(r'(\d+)\s*[:\-]\s*(\d+)').firstMatch(source ?? '');
  if (match == null) return null;
  return (int.parse(match.group(1)!), int.parse(match.group(2)!));
}

String _scoreText(String? source) {
  final score = _scoreParts(source);
  return score == null ? '--' : '${score.$1}:${score.$2}';
}

String _normalOutcome(int home, int away) => home > away
    ? '胜'
    : home == away
        ? '平'
        : '负';

String _handicapOutcome(int home, int away, dynamic rawHandicap) {
  final handicap = double.tryParse(rawHandicap?.toString() ?? '') ?? 0;
  return _normalOutcome(
    home + handicap.round(),
    away,
  ).replaceFirst('胜', '让胜').replaceFirst('平', '让平').replaceFirst('负', '让负');
}

String _totalGoalsOutcome(int home, int away) {
  final total = home + away;
  return total >= 7 ? '7+' : '$total';
}

String _scoreOutcome(int home, int away, Map<String, dynamic> values) {
  final score = '$home:$away';
  if (values.containsKey(score)) return score;
  return switch (_normalOutcome(home, away)) {
    '胜' => '胜其他',
    '平' => '平其他',
    _ => '负其他',
  };
}

String _odd(dynamic value) {
  if (value == null) return '--';
  if (value is num) return value.toStringAsFixed(2);
  final number = double.tryParse(value.toString());
  return number == null ? value.toString() : number.toStringAsFixed(2);
}

String _outcomeLabel(String key) {
  return switch (key) {
    '胜' => '胜',
    '平' => '平',
    '负' => '负',
    _ => key,
  };
}

String _marketLabel(String title, String key) {
  if (title == '胜平负' || title == '让球胜平负') return _outcomeLabel(key);
  if (title == '总进球' && (RegExp(r'^\d+$').hasMatch(key) || key == '7+')) {
    return '$key球';
  }
  return key.replaceAll('-', ':');
}

List<MapEntry<String, dynamic>> _orderedOutcomes(Map<String, dynamic> source) {
  final result = <MapEntry<String, dynamic>>[];
  for (final key in const ['胜', '平', '负']) {
    if (source.containsKey(key)) result.add(MapEntry(key, source[key]));
  }
  for (final entry in source.entries) {
    if (!result.any((item) => item.key == entry.key)) result.add(entry);
  }
  return result;
}

Map<String, dynamic> _historyMarket(
  Map<String, dynamic>? snapshot,
  String market,
) {
  final odds = snapshot?['odds'];
  if (odds is! Map) return <String, dynamic>{};
  final values = odds[market];
  return values is Map
      ? Map<String, dynamic>.from(values)
      : <String, dynamic>{};
}

List<Map<String, dynamic>> _sortedOddsHistory(
  Iterable<Map<String, dynamic>> history,
) {
  final snapshots = history
      .where((snapshot) => _historyTime(snapshot) != null)
      .toList(growable: false)
    ..sort(
        (left, right) => _historyTime(left)!.compareTo(_historyTime(right)!));
  return snapshots;
}

Map<String, dynamic>? _earliestHistorySnapshot(
  Iterable<Map<String, dynamic>> history,
  String market,
) {
  for (final snapshot in _sortedOddsHistory(history)) {
    if (_historyMarket(snapshot, market).isNotEmpty) return snapshot;
  }
  return null;
}

Map<String, dynamic> _earliestHistoryMarket(
  Iterable<Map<String, dynamic>> history,
  String market,
) =>
    _historyMarket(_earliestHistorySnapshot(history, market), market);

List<String> _historyOdds(Map<String, dynamic> values) {
  final entries = _orderedOutcomes(values);
  return List<String>.generate(
    3,
    (index) => index < entries.length ? _odd(entries[index].value) : '--',
  );
}

({String label, Color color, bool emphasized}) _oddChange(
  dynamic current,
  dynamic initial,
) {
  final currentValue = double.tryParse(current?.toString() ?? '');
  final initialValue = double.tryParse(initial?.toString() ?? '');
  if (currentValue == null || initialValue == null) {
    return (label: '积累中', color: _muted, emphasized: false);
  }
  final delta = currentValue - initialValue;
  if (delta.abs() < 0.005) {
    return (label: '--', color: _muted, emphasized: false);
  }
  return delta > 0
      ? (label: '↑${delta.toStringAsFixed(2)}', color: _red, emphasized: true)
      : (
          label: '↓${delta.abs().toStringAsFixed(2)}',
          color: _green,
          emphasized: true,
        );
}

DateTime? _historyTime(Map<String, dynamic>? snapshot) {
  final value = snapshot?['capturedAt']?.toString();
  return value == null ? null : DateTime.tryParse(value)?.toLocal();
}

List<MapEntry<String, dynamic>> _orderedMarket(
  String title,
  Map<String, dynamic> source,
) {
  if (title == '胜平负' || title == '让球胜平负') return _orderedOutcomes(source);
  return source.entries.toList();
}

(double, double, double) _normalizedProbabilities(Map<String, dynamic> values) {
  double inverse(String key) {
    final value = double.tryParse(values[key]?.toString() ?? '');
    return value == null || value <= 0 ? 0 : 1 / value;
  }

  final home = inverse('胜');
  final draw = inverse('平');
  final away = inverse('负');
  final total = home + draw + away;
  if (total <= 0) return (.35, .3, .35);
  return (home / total, draw / total, away / total);
}

// ignore: unused_element
bool _poolSingle(MatchItem match, String code) {
  final pool = match.pools[code];
  if (pool is Map) {
    final status = pool['poolStatus']?.toString().toLowerCase() ?? '';
    return pool['single'] == true && status == 'selling';
  }
  return false;
}
