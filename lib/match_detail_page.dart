import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'api_client.dart';
import 'match_analysis.dart';
import 'models.dart';
import 'selection_page.dart';

const _green = Color(0xff07885d);
const _greenDark = Color(0xff087652);
const _greenSoft = Color(0xffeef8f4);
const _ink = Color(0xff161a1c);
const _muted = Color(0xff7d8387);
const _line = Color(0xffe8ebea);
const _page = Color(0xfff7f8f8);
const _red = Color(0xffe04f5f);
const _orange = Color(0xffe8892b);

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
  bool _reloading = false;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _future = _loadAndSchedule();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _client.close();
    super.dispose();
  }

  Future<_DetailData> _loadAndSchedule() async {
    final data = await _load();
    _lastData = data;
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
      var canSelect = false;
      if (_canSelectMatch(match)) {
        try {
          final bettable = await _client.fetchBettableMatches();
          canSelect = bettable.whereType<Map<String, dynamic>>().any(
                (item) =>
                    (item['id'] ?? item['matchId'])?.toString() == match.id,
              );
        } catch (_) {}
      }
      List<Map<String, dynamic>> predictions = const [];
      List<Map<String, dynamic>> oddsHistory = const [];
      MatchAnalysisData? analysis;
      Map<String, TeamMetadata> teamMetadata = const {};
      MatchStandings? fallbackStandings;
      await Future.wait([
        () async {
          try {
            predictions = await _client.fetchMatchPredictions(widget.match.id);
          } catch (_) {}
        }(),
        () async {
          try {
            oddsHistory = await _client.fetchOddsHistory(widget.match.id);
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
        predictions: predictions,
        oddsHistory: oddsHistory,
        analysis: analysis,
        teamMetadata: teamMetadata,
        fallbackStandings: fallbackStandings,
        canSelect: canSelect,
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
        subject: '竞球镜·比赛详情',
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
        final headerStandings = data.analysis?.standings.hasContent == true
            ? data.analysis!.standings
            : data.fallbackStandings;
        final detailTabs = <String>[
          '概览',
          '基本面',
          '赔率',
          if (match.matchState == MatchState.finished) '赛果',
        ];
        final selectedTab = math.min(_tab, detailTabs.length - 1);
        return Scaffold(
          backgroundColor: _page,
          appBar: AppBar(
            toolbarHeight: 56,
            centerTitle: true,
            surfaceTintColor: Colors.white,
            backgroundColor: Colors.white,
            elevation: 0,
            title: const Text(
              '比赛详情',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              onPressed: () => Navigator.maybePop(context),
            ),
            actions: [
              IconButton(
                tooltip: '分享',
                onPressed: () => _share(match),
                icon: const Icon(Icons.ios_share_rounded, size: 21),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _reload,
            color: _green,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: _MatchHero(
                    match: match,
                    canSelect: data.canSelect,
                    homeRank: headerStandings?.home.total.ranking ?? 0,
                    awayRank: headerStandings?.away.total.ranking ?? 0,
                    homeBadgeUrl: data.teamMetadata[match.home]?.badgeUrl,
                    awayBadgeUrl: data.teamMetadata[match.away]?.badgeUrl,
                  ),
                ),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const LinearProgressIndicator(
                    minHeight: 2,
                    color: _green,
                    backgroundColor: _greenSoft,
                  ),
                if (data.error != null)
                  _LoadError(message: data.error!, onRetry: _reload),
                _DetailTabs(
                  value: selectedTab,
                  labels: detailTabs,
                  onChanged: (value) => setState(() => _tab = value),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 22),
                  child: switch (selectedTab) {
                    0 => _DetailOverview(
                        match: match,
                        analysis: data.analysis,
                        predictions: data.predictions,
                        loadedAt: data.loadedAt,
                        onOpenOdds: () => setState(() => _tab = 2),
                      ),
                    1 => _FundamentalsTab(
                        match: match,
                        analysis: data.analysis,
                        fallbackStandings: data.fallbackStandings,
                      ),
                    2 => _OddsHub(
                        match: match,
                        loadedAt: data.loadedAt,
                        history: data.oddsHistory,
                      ),
                    3 => _ResultsTab(match: match),
                    _ => const SizedBox.shrink(),
                  },
                ),
              ],
            ),
          ),
          bottomNavigationBar: _BottomActions(
            match: match,
            canSelect: data.canSelect,
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
        surfaceTintColor: Colors.white,
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          '比赛详情',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
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
    this.predictions = const [],
    this.oddsHistory = const [],
    this.analysis,
    this.teamMetadata = const {},
    this.fallbackStandings,
    this.canSelect = false,
    this.loadedAt,
    this.error,
  });

  final MatchItem match;
  final List<Map<String, dynamic>> predictions;
  final List<Map<String, dynamic>> oddsHistory;
  final MatchAnalysisData? analysis;
  final Map<String, TeamMetadata> teamMetadata;
  final MatchStandings? fallbackStandings;
  final bool canSelect;
  final DateTime? loadedAt;
  final String? error;
}

class _MatchHero extends StatelessWidget {
  const _MatchHero({
    required this.match,
    required this.canSelect,
    required this.homeRank,
    required this.awayRank,
    this.homeBadgeUrl,
    this.awayBadgeUrl,
  });

  final MatchItem match;
  final bool canSelect;
  final int homeRank;
  final int awayRank;
  final String? homeBadgeUrl;
  final String? awayBadgeUrl;

  @override
  Widget build(BuildContext context) {
    final score = _displayScore(match);
    final half = (match.halfTimeScore ?? '').trim();
    return Container(
      height: 142,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffedf0ef)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '${match.number}  ${match.league}',
                style: const TextStyle(fontSize: 12, color: Color(0xff555b60)),
              ),
              const Icon(Icons.chevron_right_rounded, size: 17, color: _muted),
              const Spacer(),
              const Icon(Icons.schedule_rounded, size: 14, color: _muted),
              const SizedBox(width: 4),
              Text(
                '${match.kickoff.month.toString().padLeft(2, '0')}-'
                '${match.kickoff.day.toString().padLeft(2, '0')} '
                '${match.kickoffDisplayTime}',
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
              const SizedBox(width: 4),
              Text(
                match.matchState == MatchState.notStarted
                    ? '开赛'
                    : _statusText(match),
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _HeroTeam(
                    team: match.home,
                    home: true,
                    ranking: homeRank,
                    badgeUrl: homeBadgeUrl,
                  ),
                ),
                SizedBox(
                  width: 76,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        score ?? 'VS',
                        style: TextStyle(
                          fontSize: score == null ? 23 : 22,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          color: score == null
                              ? const Color(0xff666b70)
                              : _statusColor(match),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _statusText(match),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _statusColor(match),
                        ),
                      ),
                      if (half.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          '半场 $half',
                          style: const TextStyle(fontSize: 9, color: _muted),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: _HeroTeam(
                    team: match.away,
                    home: false,
                    ranking: awayRank,
                    badgeUrl: awayBadgeUrl,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Meta(
                icon: Icons.storefront_outlined,
                text: canSelect ? '竞彩销售中' : '竞彩已停售',
              ),
              const SizedBox(width: 14),
              _Meta(
                icon: Icons.layers_outlined,
                text: match.canParlay ? '支持过关' : '不可过关',
              ),
              const SizedBox(width: 14),
              _Meta(
                icon: Icons.looks_one_outlined,
                text: match.spfSingleSupported ? '胜平负单关' : '非单关',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroTeam extends StatelessWidget {
  const _HeroTeam({
    required this.team,
    required this.home,
    required this.ranking,
    this.badgeUrl,
  });

  final String team;
  final bool home;
  final int ranking;
  final String? badgeUrl;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: home ? MainAxisAlignment.start : MainAxisAlignment.end,
      children: [
        if (home) _TeamEmblem(team: team, badgeUrl: badgeUrl),
        if (home) const SizedBox(width: 8),
        Flexible(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment:
                home ? CrossAxisAlignment.start : CrossAxisAlignment.end,
            children: [
              Text(
                team,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                ranking > 0
                    ? '${home ? '主队' : '客队'} · 联赛第$ranking'
                    : (home ? '主队' : '客队'),
                style: const TextStyle(fontSize: 10, color: _muted),
              ),
            ],
          ),
        ),
        if (!home) const SizedBox(width: 8),
        if (!home) _TeamEmblem(team: team, badgeUrl: badgeUrl),
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
    final clean = team.trim();
    final initials =
        clean.isEmpty ? '队' : clean.substring(0, math.min(clean.length, 2));
    final fallback = Container(
      width: 42,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _greenDark,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(9),
          topRight: Radius.circular(9),
          bottomLeft: Radius.circular(15),
          bottomRight: Radius.circular(15),
        ),
        border: Border.all(color: const Color(0xffd8eee6)),
      ),
      child: Text(
        initials,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    final url = badgeUrl?.trim() ?? '';
    if (url.isEmpty) return fallback;
    return SizedBox(
      width: 42,
      height: 46,
      child: Image.network(
        url,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: const Color(0xff5f666a)),
        const SizedBox(width: 3),
        Text(
          text,
          style: const TextStyle(fontSize: 9.5, color: Color(0xff555d61)),
        ),
      ],
    );
  }
}

class _DetailTabs extends StatelessWidget {
  const _DetailTabs({
    required this.value,
    required this.labels,
    required this.onChanged,
  });

  final int value;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 47,
      margin: const EdgeInsets.only(top: 6),
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
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    labels[index],
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? _green : const Color(0xff363c40),
                    ),
                  ),
                  const SizedBox(height: 9),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: selected ? 30 : 0,
                    height: 3,
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

class _DetailOverview extends StatelessWidget {
  const _DetailOverview({
    required this.match,
    required this.analysis,
    required this.predictions,
    required this.loadedAt,
    required this.onOpenOdds,
  });

  final MatchItem match;
  final MatchAnalysisData? analysis;
  final List<Map<String, dynamic>> predictions;
  final DateTime? loadedAt;
  final VoidCallback onOpenOdds;

  @override
  Widget build(BuildContext context) {
    final data = analysis;
    final hasFormData = data != null &&
        (data.headToHead.matches.isNotEmpty ||
            data.homeRecent.matches.isNotEmpty ||
            data.awayRecent.matches.isNotEmpty);
    return Column(
      children: [
        if (hasFormData) ...[
          _DataSummaryPanel(
            homeName: data.homeTeam.isEmpty ? match.home : data.homeTeam,
            awayName: data.awayTeam.isEmpty ? match.away : data.awayTeam,
            home: data.homeRecent,
            away: data.awayRecent,
            headToHead: data.headToHead,
          ),
          const SizedBox(height: 10),
        ],
        _OverviewTab(
          match: match,
          loadedAt: loadedAt,
          onOpenOdds: onOpenOdds,
        ),
        const SizedBox(height: 10),
        if (predictions.isNotEmpty) ...[
          _AnalysisTab(
            match: match,
            predictions: predictions,
          ),
        ] else
          _RiskPanel(match: match),
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
}

class _FundamentalsTab extends StatefulWidget {
  const _FundamentalsTab({
    required this.match,
    required this.analysis,
    required this.fallbackStandings,
  });

  final MatchItem match;
  final MatchAnalysisData? analysis;
  final MatchStandings? fallbackStandings;

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
        _DetailSubTabs(
          labels: const ['战绩', '排名', '状态', '阵容', '赛程'],
          value: _section,
          onChanged: (value) => setState(() => _section = value),
        ),
        const SizedBox(height: 10),
        ...switch (_section) {
          0 => _recordContent(data),
          1 => [
              if (standings?.hasContent == true)
                _StandingsPanel(standings: standings!)
              else
                const _Surface(child: _Empty(text: '暂无排名数据')),
            ],
          2 => [
              if (hasFormData)
                _DataSummaryPanel(
                  homeName:
                      data.homeTeam.isEmpty ? widget.match.home : data.homeTeam,
                  awayName:
                      data.awayTeam.isEmpty ? widget.match.away : data.awayTeam,
                  home: data.homeRecent,
                  away: data.awayRecent,
                  headToHead: data.headToHead,
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

  List<Widget> _recordContent(MatchAnalysisData? data) {
    if (data == null ||
        (data.headToHead.matches.isEmpty &&
            data.homeRecent.matches.isEmpty &&
            data.awayRecent.matches.isEmpty)) {
      return const [_Surface(child: _Empty(text: '暂无战绩数据'))];
    }
    return [
      if (data.headToHead.matches.isNotEmpty) ...[
        _RecordPanel(
          title: '历史交锋',
          group: data.headToHead,
          perspective:
              data.homeTeam.isEmpty ? widget.match.home : data.homeTeam,
          currentLeague: widget.match.league,
          filterKind: _RecordFilterKind.headToHead,
        ),
        const SizedBox(height: 10),
      ],
      if (data.homeRecent.matches.isNotEmpty) ...[
        _RecordPanel(
          title: '主队近期战绩',
          group: MatchRecordGroup(
            summary: data.homeRecent.summary,
            matches: data.homeRecent.matches,
          ),
          perspective: data.homeRecent.team.isEmpty
              ? widget.match.home
              : data.homeRecent.team,
          team: data.homeRecent.team.isEmpty
              ? widget.match.home
              : data.homeRecent.team,
          currentLeague: widget.match.league,
          filterKind: _RecordFilterKind.homeRecent,
        ),
        const SizedBox(height: 10),
      ],
      if (data.awayRecent.matches.isNotEmpty)
        _RecordPanel(
          title: '客队近期战绩',
          group: MatchRecordGroup(
            summary: data.awayRecent.summary,
            matches: data.awayRecent.matches,
          ),
          perspective: data.awayRecent.team.isEmpty
              ? widget.match.away
              : data.awayRecent.team,
          team: data.awayRecent.team.isEmpty
              ? widget.match.away
              : data.awayRecent.team,
          currentLeague: widget.match.league,
          filterKind: _RecordFilterKind.awayRecent,
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
      height: 39,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xffeef1f0),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: List.generate(labels.length, (index) {
          final selected = index == value;
          return Expanded(
            child: InkWell(
              onTap: () => onChanged(index),
              borderRadius: BorderRadius.circular(6),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: selected ? Border.all(color: _line) : null,
                ),
                child: Text(
                  labels[index],
                  style: TextStyle(
                    fontSize: 12,
                    color: selected ? _greenDark : const Color(0xff555d61),
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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
    return _Surface(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 9),
            child: _SectionTitle(title: '未来赛程', trailing: '体能与轮换参考'),
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
    final matches = schedule.matches.take(2).toList(growable: false);
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
    return _Surface(
      padding: EdgeInsets.zero,
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _TeamPersonnel(
                  group: sides.home,
                  fallbackTeam: '主队',
                  injuries: injuries,
                ),
              ),
              const SizedBox(
                height: 112,
                child: VerticalDivider(width: 1, color: _line),
              ),
              Expanded(
                child: _TeamPersonnel(
                  group: sides.away,
                  fallbackTeam: '客队',
                  injuries: injuries,
                ),
              ),
            ],
          ),
        ],
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
        ? (player.suspended ? '停赛' : '伤缺')
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
          child: Text(
            player.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10.5, color: _ink),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          detail,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: injuries ? FontWeight.w600 : FontWeight.w500,
            color: injuries ? (player.suspended ? _orange : _red) : _muted,
          ),
        ),
      ],
    );
  }
}

class _DataSummaryPanel extends StatelessWidget {
  const _DataSummaryPanel({
    required this.homeName,
    required this.awayName,
    required this.home,
    required this.away,
    required this.headToHead,
  });

  final String homeName;
  final String awayName;
  final TeamRecentForm home;
  final TeamRecentForm away;
  final MatchRecordGroup headToHead;

  String _average(double value) => value.toStringAsFixed(1);
  String _percent(double value) => '${(value * 100).round()}%';

  List<String> _observations(
    TeamFormMetrics homeMetrics,
    TeamFormMetrics awayMetrics,
  ) {
    final values = <String>[];
    if (homeMetrics.matches > 0 && awayMetrics.matches > 0) {
      final winDifference = homeMetrics.winRate - awayMetrics.winRate;
      if (winDifference.abs() >= 0.2) {
        values.add(
          winDifference > 0 ? '$homeName近期胜率更高' : '$awayName近期胜率更高',
        );
      } else {
        values.add('双方近期胜率接近');
      }
      final attackDifference =
          homeMetrics.goalsForAverage - awayMetrics.goalsForAverage;
      if (attackDifference.abs() >= 0.4) {
        values.add(
          attackDifference > 0 ? '$homeName近期场均进球更多' : '$awayName近期场均进球更多',
        );
      }
      final defenseDifference =
          homeMetrics.goalsAgainstAverage - awayMetrics.goalsAgainstAverage;
      if (defenseDifference.abs() >= 0.4) {
        values.add(
          defenseDifference < 0 ? '$homeName近期场均失球更少' : '$awayName近期场均失球更少',
        );
      }
    }
    final sample = headToHead.matches.length;
    if (sample == 1) {
      values.add('历史交锋仅1场，样本较少');
    } else if (sample > 1 && sample < 5) {
      values.add('历史交锋共$sample场，样本有限');
    }
    return values.take(3).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final homeMetrics = home.metrics();
    final awayMetrics = away.metrics();
    final homeVenue = home.metrics(venue: TeamVenue.home);
    final awayVenue = away.metrics(venue: TeamVenue.away);
    final observations = _observations(homeMetrics, awayMetrics);
    return _Surface(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 9),
            child: _SectionTitle(
              title: '数据摘要',
              trailing: '按最近有效比赛计算',
            ),
          ),
          const Divider(height: 1, color: _line),
          _SummaryHeader(home: homeName, away: awayName),
          _SummaryRow(
            label: '近况',
            home: homeMetrics.matches == 0 ? '--' : homeMetrics.record,
            away: awayMetrics.matches == 0 ? '--' : awayMetrics.record,
          ),
          _SummaryRow(
            label: '场均进球',
            home: homeMetrics.matches == 0
                ? '--'
                : _average(homeMetrics.goalsForAverage),
            away: awayMetrics.matches == 0
                ? '--'
                : _average(awayMetrics.goalsForAverage),
          ),
          _SummaryRow(
            label: '场均失球',
            home: homeMetrics.matches == 0
                ? '--'
                : _average(homeMetrics.goalsAgainstAverage),
            away: awayMetrics.matches == 0
                ? '--'
                : _average(awayMetrics.goalsAgainstAverage),
          ),
          _SummaryRow(
            label: '大2.5球',
            home: homeMetrics.matches == 0
                ? '--'
                : _percent(homeMetrics.overTwoAndHalfRate),
            away: awayMetrics.matches == 0
                ? '--'
                : _percent(awayMetrics.overTwoAndHalfRate),
          ),
          _SummaryRow(
            label: '双方进球',
            home: homeMetrics.matches == 0
                ? '--'
                : _percent(homeMetrics.bothTeamsScoredRate),
            away: awayMetrics.matches == 0
                ? '--'
                : _percent(awayMetrics.bothTeamsScoredRate),
          ),
          _SummaryRow(
            label: '主/客场',
            home: homeVenue.matches == 0 ? '--' : homeVenue.record,
            away: awayVenue.matches == 0 ? '--' : awayVenue.record,
          ),
          if (observations.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 11),
              color: const Color(0xfffafbfb),
              child: Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  for (final value in observations)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.circle,
                          size: 5,
                          color: _green,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          value,
                          style: const TextStyle(
                            color: Color(0xff596063),
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

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
    return _Surface(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 9),
            child: _SectionTitle(
              title: '积分排名',
              trailing: [
                standings.league,
                standings.season,
              ].where((item) => item.isNotEmpty).join(' '),
            ),
          ),
          const Divider(height: 1, color: _line),
          const _StandingTableRow(header: true),
          for (final row in rows) _StandingTableRow(row: row),
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
      height: header ? 32 : 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
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
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 58,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  date,
                  style: const TextStyle(fontSize: 10, color: _muted),
                ),
                const SizedBox(height: 2),
                Text(
                  record.league,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9, color: _green),
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
                fontSize: 11,
                fontWeight: record.home == perspective
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 58,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  record.fullScore.isEmpty ? '--' : record.fullScore,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (record.halfScore.isNotEmpty)
                  Text(
                    '半 ${record.halfScore}',
                    style: const TextStyle(fontSize: 8.5, color: _muted),
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
                fontSize: 11,
                fontWeight: record.away == perspective
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 22,
            child: record.result.isEmpty
                ? null
                : Text(
                    record.result,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11,
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
        if (match.matchState != MatchState.finished &&
            match.had.isNotEmpty) ...[
          _OddsProbabilityPanel(match: match),
          const SizedBox(height: 10),
        ],
        _Surface(
          padding: const EdgeInsets.fromLTRB(10, 11, 10, 10),
          child: Column(
            children: [
              _SectionTitle(
                title: '核心赔率',
                trailing:
                    loadedAt == null ? null : '数据更新：${_mdhm(loadedAt!)}  ⟳',
              ),
              const SizedBox(height: 9),
              if (match.had.isNotEmpty)
                _CoreMarket(
                  title: '胜平负',
                  values: match.had,
                  single: match.spfSingleSupported,
                ),
              if (match.had.isNotEmpty && match.hhad.isNotEmpty)
                const Divider(height: 13, color: _line),
              if (match.hhad.isNotEmpty)
                _CoreMarket(
                  title: '让球胜平负',
                  values: Map<String, dynamic>.from(match.hhad)..remove('让球'),
                  handicap: match.hhad['让球']?.toString(),
                  single: _poolSingle(match, 'HHAD'),
                ),
              if (match.had.isEmpty && match.hhad.isEmpty)
                const _Empty(text: '暂无核心赔率'),
              const Divider(height: 17, color: _line),
              _MoreMarkets(match: match, onOpenOdds: onOpenOdds),
            ],
          ),
        ),
      ],
    );
  }
}

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
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
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
    required this.single,
    this.handicap,
  });

  final String title;
  final Map<String, dynamic> values;
  final bool single;
  final String? handicap;

  @override
  Widget build(BuildContext context) {
    final entries = _orderedOutcomes(values);
    final valid = entries
        .map((entry) => double.tryParse(entry.value.toString()))
        .whereType<double>()
        .where((value) => value > 0)
        .toList();
    final lowest = valid.isEmpty ? null : valid.reduce(math.min);
    return Column(
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            if (handicap != null) ...[
              const SizedBox(width: 9),
              Text(
                '让($handicap)',
                style: const TextStyle(fontSize: 10, color: _green),
              ),
            ],
            const Spacer(),
            if (single) const _Badge(text: '单关'),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: entries.map((entry) {
            final odd = double.tryParse(entry.value.toString());
            final emphasized = odd != null && lowest != null && odd == lowest;
            return Expanded(
              child: Container(
                height: 55,
                margin: EdgeInsets.only(
                  right: entry.key == entries.last.key ? 0 : 7,
                ),
                decoration: BoxDecoration(
                  color: emphasized ? _green : const Color(0xfff7f8f8),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: emphasized ? _green : const Color(0xffeef0ef),
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${_outcomeLabel(entry.key)}  ${_odd(entry.value)}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: emphasized ? Colors.white : _ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      emphasized ? '当前最低SP' : '即时SP',
                      style: TextStyle(
                        fontSize: 9,
                        color: emphasized ? Colors.white70 : _muted,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

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
  });

  final MatchItem match;
  final DateTime? loadedAt;
  final List<Map<String, dynamic>> history;

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
          1 => const _ExternalOddsEmpty(
              icon: Icons.public_rounded,
              title: '暂无欧赔数据',
            ),
          2 => const _ExternalOddsEmpty(
              icon: Icons.swap_horiz_rounded,
              title: '暂无亚赔数据',
            ),
          3 => const _ExternalOddsEmpty(
              icon: Icons.unfold_more_rounded,
              title: '暂无大小球数据',
            ),
          _ => const SizedBox.shrink(),
        },
      ],
    );
  }
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
          _Surface(
            child: Column(
              children: [
                _SectionTitle(
                  title: '赔率变化',
                  trailing:
                      loadedAt == null ? null : '数据更新 ${_mdhm(loadedAt!)}',
                ),
                const SizedBox(height: 12),
                _ChangeTable(match: match, history: history),
              ],
            ),
          ),
        if (markets.isNotEmpty) const SizedBox(height: 10),
        _Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(title: '玩法赔率'),
              const SizedBox(height: 10),
              for (var index = 0; index < markets.length; index++) ...[
                _OddsMarketTable(
                  title: markets[index].title,
                  values: markets[index].values,
                  handicap: markets[index].handicap,
                  initialValues: _initialValues(markets[index].historyKey),
                ),
                if (index != markets.length - 1)
                  const Divider(height: 22, color: _line),
              ],
              if (markets.isEmpty) const _Empty(text: '暂无官方赔率'),
            ],
          ),
        ),
      ],
    );
  }

  Map<String, dynamic> _initialValues(String historyKey) {
    final values = _historyMarket(
      history.isEmpty ? null : history.first,
      historyKey,
    );
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
    final first = history.isEmpty ? null : history.first;
    final initialHad = _historyMarket(first, 'had');
    final initialHhad = _historyMarket(first, 'hhad')..remove('让球');
    final initialTime = _historyTime(first);
    return Column(
      children: [
        const _ChangeRow(label: '时间', values: ['胜', '平', '负']),
        _ChangeRow(
          label: initialTime == null ? '初始' : _mdhm(initialTime),
          values: _historyOdds(initialHad),
        ),
        if (had.isNotEmpty)
          _ChangeRow(
            label: '即时',
            values: had.map((e) => _odd(e.value)).toList(),
            strong: true,
          ),
        if (hhad.isNotEmpty)
          _ChangeRow(
            label: '让${match.hhad['让球'] ?? ''}',
            values: hhad.map((e) => _odd(e.value)).toList(),
          ),
        if (hhad.isNotEmpty && initialHhad.isNotEmpty)
          _ChangeRow(label: '让球初始', values: _historyOdds(initialHhad)),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              history.isEmpty
                  ? '历史赔率正在积累中'
                  : '已记录 ${history.length} 次赔率变化，仅在官方 SP 变动时保存',
              style: const TextStyle(fontSize: 9, color: _muted),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    required this.label,
    required this.values,
    this.strong = false,
  });

  final String label;
  final List<String> values;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 54,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: strong ? _green : _muted,
                fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
          for (final value in values.take(3))
            Expanded(
              child: Center(
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
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
        const SizedBox(height: 8),
        const Row(
          children: [
            SizedBox(
              width: 94,
              child: Text('选项', style: TextStyle(fontSize: 9, color: _muted)),
            ),
            Expanded(
              child: Center(
                child: Text('即时', style: TextStyle(fontSize: 9, color: _muted)),
              ),
            ),
            Expanded(
              child: Center(
                child: Text('初始', style: TextStyle(fontSize: 9, color: _muted)),
              ),
            ),
            Expanded(
              child: Center(
                child: Text('变化', style: TextStyle(fontSize: 9, color: _muted)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final entry in _orderedMarket(title, values))
          Builder(
            builder: (_) {
              final initial = initialValues[entry.key];
              final change = _oddChange(entry.value, initial);
              return Container(
                height: 34,
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _line)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 94,
                      child: Text(
                        _marketLabel(title, entry.key),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10.5),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          _odd(entry.value),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          initial == null ? '--' : _odd(initial),
                          style: const TextStyle(fontSize: 10, color: _muted),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          change.label,
                          style: TextStyle(
                            fontSize: 10,
                            color: change.color,
                            fontWeight: change.emphasized
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

// Kept as reusable result-market content while the standalone result tab is hidden.
// ignore: unused_element
class _ResultsTab extends StatelessWidget {
  const _ResultsTab({required this.match});

  final MatchItem match;

  @override
  Widget build(BuildContext context) {
    final full = _scoreParts(match.finalScore ?? match.score);
    final half = _scoreParts(match.halfTimeScore);
    final officialRows = _officialResultRows(match.officialResults);
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
        _Surface(
          color: const Color(0xfffff7f7),
          child: Column(
            children: [
              const Row(
                children: [
                  Icon(Icons.emoji_events_outlined, size: 17, color: _red),
                  SizedBox(width: 5),
                  Text(
                    '官方赛果',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  Spacer(),
                  _Badge(text: '已完场'),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '${full.$1} : ${full.$2}',
                style: const TextStyle(
                  fontSize: 34,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  color: _red,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                '${match.home}  ${_normalOutcome(full.$1, full.$2)}  ${match.away}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                alignment: WrapAlignment.center,
                children: [
                  _ResultStat(
                    label: '半场',
                    value: _scoreText(match.halfTimeScore),
                  ),
                  if ((match.extraTimeScore ?? '').trim().isNotEmpty)
                    _ResultStat(
                      label: '加时',
                      value: match.extraTimeScore!.trim(),
                    ),
                  if ((match.penaltyScore ?? '').trim().isNotEmpty)
                    _ResultStat(label: '点球', value: match.penaltyScore!.trim()),
                ],
              ),
            ],
          ),
        ),
        if (markets.isNotEmpty) ...[
          const SizedBox(height: 10),
          _ResultSpStrip(markets: markets),
        ],
        if (match.had.isNotEmpty) ...[
          const SizedBox(height: 10),
          _ResultReview(
            match: match,
            actualOutcome: _normalOutcome(full.$1, full.$2),
          ),
        ],
        const SizedBox(height: 10),
        _Surface(
          padding: const EdgeInsets.fromLTRB(11, 11, 11, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(title: '竞彩开奖结果'),
              const SizedBox(height: 10),
              if (markets.isEmpty)
                const _Empty(text: '未保留本场开奖玩法')
              else
                for (final market in markets) _ResolvedMarket(data: market),
            ],
          ),
        ),
        if (officialRows.isNotEmpty) ...[
          const SizedBox(height: 10),
          _Surface(
            padding: const EdgeInsets.fromLTRB(11, 11, 11, 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionTitle(title: '官方开奖明细'),
                const SizedBox(height: 7),
                for (final row in officialRows) _OfficialResultRow(row: row),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        const _ResultRuleNotice(),
      ],
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
    return _Surface(
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.confirmation_number_outlined, size: 16, color: _red),
              SizedBox(width: 5),
              Text(
                '赛果 SP',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              Spacer(),
              Text('以官方固定奖金为准', style: TextStyle(fontSize: 9, color: _muted)),
            ],
          ),
          const SizedBox(height: 9),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var index = 0; index < markets.length; index++) ...[
                  _ResultSpItem(
                    title: _shortTitle(markets[index].title),
                    outcome: _marketLabel(
                      markets[index].title,
                      markets[index].selectedKey,
                    ),
                    odd: _odd(markets[index].selectedOdd),
                    note: markets[index].note,
                  ),
                  if (index != markets.length - 1) const SizedBox(width: 7),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultSpItem extends StatelessWidget {
  const _ResultSpItem({
    required this.title,
    required this.outcome,
    required this.odd,
    this.note,
  });

  final String title;
  final String outcome;
  final String odd;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 74),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xfffff5f6),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xffffdadd)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 9, color: _muted)),
          const SizedBox(height: 3),
          Text(
            outcome,
            style: const TextStyle(
              fontSize: 12,
              color: _red,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            'SP $odd',
            style: const TextStyle(fontSize: 10, color: Color(0xff8a4e55)),
          ),
          if (note != null)
            Text(
              note!,
              style: const TextStyle(fontSize: 8, color: Color(0xff9c777b)),
            ),
        ],
      ),
    );
  }
}

class _ResultReview extends StatelessWidget {
  const _ResultReview({required this.match, required this.actualOutcome});

  final MatchItem match;
  final String actualOutcome;

  @override
  Widget build(BuildContext context) {
    final favorite = _favorite(match.had);
    if (favorite == null) return const SizedBox.shrink();
    final matched = favorite.$1 == actualOutcome;
    final label = matched ? '打出赛前最低 SP 倾向' : '未打出赛前最低 SP 倾向';
    return _Surface(
      color: matched ? const Color(0xfff3faf7) : const Color(0xfffffaf3),
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            matched ? Icons.task_alt_rounded : Icons.compare_arrows_rounded,
            size: 17,
            color: matched ? _green : _orange,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '赛果复盘 · $label',
                  style: TextStyle(
                    fontSize: 12,
                    color: matched ? _greenDark : const Color(0xff9b6419),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '赛前最低 SP：${_outcomeLabel(favorite.$1)} ${_odd(favorite.$2)}  ·  实际赛果：$actualOutcome',
                  style: const TextStyle(fontSize: 10.5, color: _muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResolvedMarket extends StatelessWidget {
  const _ResolvedMarket({required this.data});

  final _ResolvedMarketData data;

  @override
  Widget build(BuildContext context) {
    final entries = _orderedMarket(data.title, data.values);
    final selectedKey = data.selectedKey;
    return Container(
      padding: const EdgeInsets.only(bottom: 11),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                data.title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (data.note != null) ...[
                const SizedBox(width: 7),
                Text(
                  data.note!,
                  style: const TextStyle(fontSize: 10, color: _muted),
                ),
              ],
              const Spacer(),
              Text(
                '开奖结果：${data.winner}',
                style: const TextStyle(
                  fontSize: 11,
                  color: _red,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: entries.map((entry) {
              final selected = entry.key == selectedKey;
              return _ResultOption(
                label: _marketLabel(data.title, entry.key),
                odd: _odd(entry.value),
                selected: selected,
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _ResultOption extends StatelessWidget {
  const _ResultOption({
    required this.label,
    required this.odd,
    required this.selected,
  });

  final String label;
  final String odd;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 66),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? const Color(0xffffe9eb) : const Color(0xfff7f8f8),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: selected ? const Color(0xffeeaab2) : _line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) ...[
            const Icon(Icons.check_circle_rounded, size: 13, color: _red),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? _red : _ink,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            odd,
            style: TextStyle(fontSize: 10, color: selected ? _red : _muted),
          ),
        ],
      ),
    );
  }
}

class _ResultStat extends StatelessWidget {
  const _ResultStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xffffdadd)),
      ),
      child: Text(
        '$label  $value',
        style: const TextStyle(fontSize: 10, color: Color(0xff6d454b)),
      ),
    );
  }
}

class _OfficialResultRow extends StatelessWidget {
  const _OfficialResultRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final label = _firstText(row, const [
      'combinationDesc',
      'combination',
      'resultName',
      'name',
      'code',
    ]);
    final code = _firstText(row, const ['code', 'poolCode']);
    final handicap = _firstText(row, const ['goalLine', 'handicap']);
    final odds = _firstText(row, const ['odds', 'sp']);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.isEmpty ? '--' : label,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
          if (handicap.isNotEmpty)
            Text(
              '让$handicap  ',
              style: const TextStyle(fontSize: 10, color: _muted),
            ),
          if (odds.isNotEmpty)
            Text(
              'SP $odds',
              style: const TextStyle(fontSize: 10, color: _muted),
            ),
          if (code.isNotEmpty && odds.isEmpty)
            Text(code, style: const TextStyle(fontSize: 10, color: _muted)),
        ],
      ),
    );
  }
}

class _ResultRuleNotice extends StatelessWidget {
  const _ResultRuleNotice();

  @override
  Widget build(BuildContext context) {
    return const _Surface(
      color: Color(0xfffffaf3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: _orange),
          SizedBox(width: 7),
          Expanded(
            child: Text(
              '竞彩赛果以官方公布为准。90分钟内（含伤停补时）比分用于胜平负、让球胜平负、总进球、比分和半全场开奖。',
              style: TextStyle(
                fontSize: 10,
                height: 1.4,
                color: Color(0xff6f5a39),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffedf0ef)),
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
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
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
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

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

class _BottomActions extends StatelessWidget {
  const _BottomActions({required this.match, required this.canSelect});

  final MatchItem match;
  final bool canSelect;

  @override
  Widget build(BuildContext context) {
    final actionText = switch (match.matchState) {
      MatchState.live || MatchState.halftime => '比赛进行中',
      MatchState.finished => '比赛已结束',
      _ => canSelect ? '去选号' : '已停售',
    };
    return SafeArea(
      top: false,
      child: Container(
        height: 60,
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: _line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 45,
                child: FilledButton(
                  onPressed: canSelect
                      ? () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  SelectionPage(focusMatchId: match.id),
                            ),
                          )
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: _green,
                    disabledBackgroundColor: const Color(0xffcbd3d0),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        actionText,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
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
    MatchState.notStarted => '未开赛',
    MatchState.live => _liveStatusText(match.liveStatusText),
    MatchState.halftime => '中场',
    MatchState.finished => '完场',
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

bool _canSelectMatch(MatchItem match) {
  if (match.matchState != MatchState.notStarted ||
      match.bettingStatus != BettingStatus.open ||
      !match.kickoff.isAfter(DateTime.now())) {
    return false;
  }
  return match.canParlay || match.singleSupported;
}

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

List<Map<String, dynamic>> _officialResultRows(Map<String, dynamic>? raw) {
  final items = raw?['matchResultList'];
  if (items is! Iterable) return const [];
  return items
      .whereType<Map>()
      .map(
        (item) => item.map<String, dynamic>(
          (key, value) => MapEntry(key.toString(), value),
        ),
      )
      .toList(growable: false);
}

String _firstText(Map<String, dynamic> source, List<String> keys) {
  for (final key in keys) {
    final value = source[key]?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return '';
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

(String, dynamic)? _favorite(Map<String, dynamic> values) {
  MapEntry<String, dynamic>? selected;
  double? selectedValue;
  for (final entry in _orderedOutcomes(values)) {
    final value = double.tryParse(entry.value.toString());
    if (value == null || value <= 0) continue;
    if (selectedValue == null || value < selectedValue) {
      selected = entry;
      selectedValue = value;
    }
  }
  return selected == null ? null : (selected.key, selected.value);
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

bool _poolSingle(MatchItem match, String code) {
  final pool = match.pools[code];
  if (pool is Map) {
    final status = pool['poolStatus']?.toString().toLowerCase() ?? '';
    return pool['single'] == true && status == 'selling';
  }
  return false;
}
