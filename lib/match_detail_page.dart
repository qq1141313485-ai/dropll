import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'api_client.dart';
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
  int _tab = 0;
  bool _followed = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<_DetailData> _load() async {
    if (!_client.isConfigured) {
      return _DetailData(match: widget.match, error: '数据加载失败，请重试');
    }
    try {
      final values = await Future.wait<Object>([
        _client.fetchMatch(widget.match.id),
        _client.fetchMatchPredictions(widget.match.id),
      ]);
      return _DetailData(
        match: values[0] as MatchItem,
        predictions: values[1] as List<Map<String, dynamic>>,
        loadedAt: DateTime.now(),
      );
    } catch (_) {
      return _DetailData(match: widget.match, error: '数据加载失败，请重试');
    }
  }

  Future<void> _reload() async {
    setState(() => _future = _load());
    await _future;
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
        final data = snapshot.data ?? _DetailData(match: widget.match);
        final match = data.match;
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
                tooltip: '关注',
                onPressed: () => setState(() => _followed = !_followed),
                icon: Icon(
                  _followed ? Icons.star_rounded : Icons.star_border_rounded,
                  size: 25,
                  color: _followed ? const Color(0xffffae24) : _ink,
                ),
              ),
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
                  child: _MatchHero(match: match),
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
                  value: _tab,
                  onChanged: (value) => setState(() => _tab = value),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 22),
                  child: switch (_tab) {
                    0 => _OverviewTab(match: match, loadedAt: data.loadedAt),
                    1 => _OddsTab(match: match, loadedAt: data.loadedAt),
                    2 => _DataTab(match: match),
                    _ => _AnalysisTab(
                        match: match,
                        predictions: data.predictions,
                      ),
                  },
                ),
              ],
            ),
          ),
          bottomNavigationBar: _BottomActions(
            followed: _followed,
            match: match,
            onFollow: () => setState(() => _followed = !_followed),
          ),
        );
      },
    );
  }
}

class _DetailData {
  const _DetailData({
    required this.match,
    this.predictions = const [],
    this.loadedAt,
    this.error,
  });

  final MatchItem match;
  final List<Map<String, dynamic>> predictions;
  final DateTime? loadedAt;
  final String? error;
}

class _MatchHero extends StatelessWidget {
  const _MatchHero({required this.match});

  final MatchItem match;

  @override
  Widget build(BuildContext context) {
    final score = _displayScore(match);
    final half = (match.halfTimeScore ?? '').trim();
    return Container(
      height: 154,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xffedf0ef)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0a000000),
            blurRadius: 14,
            offset: Offset(0, 5),
          ),
        ],
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
          const SizedBox(height: 11),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _HeroTeam(team: match.home, home: true)),
                SizedBox(
                  width: 84,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        score ?? 'VS',
                        style: TextStyle(
                          fontSize: score == null ? 25 : 23,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          color: score == null
                              ? const Color(0xff666b70)
                              : _statusColor(match),
                        ),
                      ),
                      const SizedBox(height: 7),
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
                        Text('半场 $half',
                            style: const TextStyle(fontSize: 9, color: _muted)),
                      ],
                    ],
                  ),
                ),
                Expanded(child: _HeroTeam(team: match.away, home: false)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Meta(
                icon: Icons.storefront_outlined,
                text: match.bettingStatus == BettingStatus.open
                    ? '竞彩销售中'
                    : '竞彩已停售',
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
  const _HeroTeam({required this.team, required this.home});

  final String team;
  final bool home;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: home ? MainAxisAlignment.start : MainAxisAlignment.end,
      children: [
        if (home) _TeamEmblem(team: team),
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
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(home ? '（主队）' : '（客队）',
                  style: const TextStyle(fontSize: 10, color: _muted)),
            ],
          ),
        ),
        if (!home) const SizedBox(width: 8),
        if (!home) _TeamEmblem(team: team),
      ],
    );
  }
}

class _TeamEmblem extends StatelessWidget {
  const _TeamEmblem({required this.team});

  final String team;

  @override
  Widget build(BuildContext context) {
    final clean = team.trim();
    final initials =
        clean.isEmpty ? '队' : clean.substring(0, math.min(clean.length, 2));
    return Container(
      width: 48,
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff163b55), _green],
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(
              color: Color(0x18000000), blurRadius: 5, offset: Offset(0, 2)),
        ],
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
        Text(text,
            style: const TextStyle(fontSize: 9.5, color: Color(0xff555d61))),
      ],
    );
  }
}

class _DetailTabs extends StatelessWidget {
  const _DetailTabs({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    const labels = ['概览', '赔率', '数据', '分析'];
    return Container(
      height: 51,
      margin: const EdgeInsets.only(top: 8),
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
                  const SizedBox(height: 11),
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

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.match, required this.loadedAt});

  final MatchItem match;
  final DateTime? loadedAt;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
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
              _MoreMarkets(match: match),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _InsightPanel(match: match),
        const SizedBox(height: 10),
        _RiskPanel(match: match),
      ],
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
            Text(title,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            if (handicap != null) ...[
              const SizedBox(width: 9),
              Text('让($handicap)',
                  style: const TextStyle(fontSize: 10, color: _green)),
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
                    right: entry.key == entries.last.key ? 0 : 7),
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
  const _MoreMarkets({required this.match});

  final MatchItem match;

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
      (
        icon: Icons.apps_rounded,
        title: '更多玩法',
        subtitle: '查看全部',
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Text('更多玩法',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
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
                  Text(item.title,
                      style: const TextStyle(fontSize: 10.5, color: _ink)),
                  const SizedBox(height: 1),
                  Text(item.subtitle,
                      style: const TextStyle(fontSize: 8.5, color: _muted)),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _InsightPanel extends StatelessWidget {
  const _InsightPanel({required this.match});

  final MatchItem match;

  @override
  Widget build(BuildContext context) {
    final favorite = _favorite(match.had);
    final notes = <String>[
      if (favorite != null) '胜平负当前最低SP为${favorite.$1} ${_odd(favorite.$2)}。',
      '销售状态：${match.bettingStatusText.isEmpty ? '未知' : match.bettingStatusText}。',
      match.spfSingleSupported ? '本场胜平负支持官方单关。' : '本场胜平负未标记为官方单关。',
    ];
    return _Surface(
      color: const Color(0xfff3faf7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 7,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionIconTitle(
                  icon: Icons.bar_chart_rounded,
                  title: '数据观察',
                  color: _green,
                ),
                const SizedBox(height: 9),
                for (final note in notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Text('•  $note',
                        style: const TextStyle(fontSize: 10.5, height: 1.35)),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: SizedBox(
              height: 120,
              child: CustomPaint(
                painter: _OddsRadarPainter(match: match),
              ),
            ),
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
      '临场SP可能继续变化，请以出票时数据为准。',
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
              Text('${notes.length}项',
                  style: const TextStyle(fontSize: 10, color: _muted)),
              const Icon(Icons.chevron_right_rounded, size: 17, color: _muted),
            ],
          ),
          const SizedBox(height: 8),
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Text('•  $note',
                  style: const TextStyle(fontSize: 10.5, height: 1.35)),
            ),
        ],
      ),
    );
  }
}

class _OddsTab extends StatelessWidget {
  const _OddsTab({required this.match, required this.loadedAt});

  final MatchItem match;
  final DateTime? loadedAt;

  @override
  Widget build(BuildContext context) {
    final markets =
        <({String title, Map<String, dynamic> values, String? handicap})>[
      (
        title: '胜平负',
        values: Map<String, dynamic>.from(match.had),
        handicap: null
      ),
      (
        title: '让球胜平负',
        values: Map<String, dynamic>.from(match.hhad)..remove('让球'),
        handicap: match.hhad['让球']?.toString(),
      ),
      (
        title: '总进球',
        values: Map<String, dynamic>.from(match.ttg),
        handicap: null
      ),
      (
        title: '比分',
        values: Map<String, dynamic>.from(match.crs),
        handicap: null
      ),
      (
        title: '半全场',
        values: Map<String, dynamic>.from(match.hafu),
        handicap: null
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
                _ChangeTable(match: match),
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
}

class _ChangeTable extends StatelessWidget {
  const _ChangeTable({required this.match});

  final MatchItem match;

  @override
  Widget build(BuildContext context) {
    final had = _orderedOutcomes(match.had);
    final hhadValues = Map<String, dynamic>.from(match.hhad)..remove('让球');
    final hhad = _orderedOutcomes(hhadValues);
    return Column(
      children: [
        const _ChangeRow(label: '时间', values: ['胜', '平', '负']),
        const _ChangeRow(label: '初始', values: ['--', '--', '--']),
        if (had.isNotEmpty)
          _ChangeRow(
              label: '即时',
              values: had.map((e) => _odd(e.value)).toList(),
              strong: true),
        if (hhad.isNotEmpty)
          _ChangeRow(
            label: '让${match.hhad['让球'] ?? ''}',
            values: hhad.map((e) => _odd(e.value)).toList(),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('当前数据源暂未提供初始SP与涨跌历史',
                style: TextStyle(fontSize: 9, color: _muted)),
          ),
        ),
      ],
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow(
      {required this.label, required this.values, this.strong = false});

  final String label;
  final List<String> values;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration:
          const BoxDecoration(border: Border(bottom: BorderSide(color: _line))),
      child: Row(
        children: [
          SizedBox(
            width: 54,
            child: Text(label,
                style: TextStyle(
                  fontSize: 10,
                  color: strong ? _green : _muted,
                  fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
                )),
          ),
          for (final value in values.take(3))
            Expanded(
              child: Center(
                child: Text(value,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
                    )),
              ),
            ),
        ],
      ),
    );
  }
}

class _OddsMarketTable extends StatelessWidget {
  const _OddsMarketTable(
      {required this.title, required this.values, this.handicap});

  final String title;
  final Map<String, dynamic> values;
  final String? handicap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: _green)),
            if (handicap != null) ...[
              const SizedBox(width: 8),
              Text('让($handicap)',
                  style: const TextStyle(fontSize: 10, color: _green)),
            ],
          ],
        ),
        const SizedBox(height: 8),
        const Row(
          children: [
            SizedBox(
                width: 94,
                child:
                    Text('选项', style: TextStyle(fontSize: 9, color: _muted))),
            Expanded(
                child: Center(
                    child: Text('即时',
                        style: TextStyle(fontSize: 9, color: _muted)))),
            Expanded(
                child: Center(
                    child: Text('初始',
                        style: TextStyle(fontSize: 9, color: _muted)))),
            Expanded(
                child: Center(
                    child: Text('变化',
                        style: TextStyle(fontSize: 9, color: _muted)))),
          ],
        ),
        const SizedBox(height: 4),
        for (final entry in _orderedMarket(title, values))
          Container(
            height: 34,
            decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: _line))),
            child: Row(
              children: [
                SizedBox(
                  width: 94,
                  child: Text(_marketLabel(title, entry.key),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5)),
                ),
                Expanded(
                  child: Center(
                    child: Text(_odd(entry.value),
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w600)),
                  ),
                ),
                const Expanded(
                    child: Center(
                        child: Text('--',
                            style: TextStyle(fontSize: 10, color: _muted)))),
                const Expanded(
                    child: Center(
                        child: Text('--',
                            style: TextStyle(fontSize: 10, color: _muted)))),
              ],
            ),
          ),
      ],
    );
  }
}

class _DataTab extends StatelessWidget {
  const _DataTab({required this.match});

  final MatchItem match;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(title: '比赛数据'),
              const SizedBox(height: 8),
              _DataRow(label: '比赛状态', value: _statusText(match)),
              _DataRow(
                  label: '销售状态',
                  value: match.bettingStatusText.isEmpty
                      ? '未知'
                      : match.bettingStatusText),
              _DataRow(
                  label: '胜平负单关',
                  value: match.spfSingleSupported ? '支持' : '不支持'),
              _DataRow(label: '过关', value: match.canParlay ? '支持' : '不支持'),
              if ((match.finalScore ?? '').isNotEmpty)
                _DataRow(label: '全场比分', value: match.finalScore!),
              if ((match.halfTimeScore ?? '').isNotEmpty)
                _DataRow(label: '半场比分', value: match.halfTimeScore!),
            ],
          ),
        ),
        const SizedBox(height: 10),
        const _UnavailableBlock(
          title: '近期战绩',
          subtitle: '当前生产数据源暂未提供球队近期战绩',
          height: 155,
        ),
        const SizedBox(height: 10),
        const _UnavailableBlock(
          title: '历史交锋',
          subtitle: '当前生产数据源暂未提供历史交锋记录',
          height: 125,
        ),
        const SizedBox(height: 10),
        const _UnavailableBlock(
          title: '联赛排名',
          subtitle: '当前生产数据源暂未提供联赛排名',
          height: 105,
        ),
      ],
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
        _InsightPanel(match: match),
        const SizedBox(height: 10),
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
        const _UnavailableBlock(
          title: '关键数据对比',
          subtitle: '当前生产数据源暂未提供射门、控球率等球队统计',
          height: 118,
        ),
        const SizedBox(height: 10),
        const _UnavailableBlock(
          title: '趋势分析',
          subtitle: '当前生产数据源暂未提供历史趋势序列',
          height: 118,
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
            child: Text(value('model_name'),
                style:
                    const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          ),
          Text('方向 ${value('predicted_direction')}',
              style: const TextStyle(fontSize: 10)),
          const SizedBox(width: 12),
          Text('比分 ${value('predicted_score')}',
              style: const TextStyle(fontSize: 10)),
        ],
      ),
    );
  }
}

class _UnavailableBlock extends StatelessWidget {
  const _UnavailableBlock(
      {required this.title, required this.subtitle, required this.height});

  final String title;
  final String subtitle;
  final double height;

  @override
  Widget build(BuildContext context) {
    return _Surface(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle(title: title),
            const Spacer(),
            Center(
              child: Column(
                children: [
                  const Icon(Icons.inbox_outlined,
                      size: 25, color: Color(0xffc2c8c5)),
                  const SizedBox(height: 7),
                  Text(subtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 10, color: _muted)),
                ],
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _OddsRadarPainter extends CustomPainter {
  const _OddsRadarPainter({required this.match});

  final MatchItem match;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 4);
    final radius = math.min(size.width, size.height) * .31;
    const labels = ['主胜', '平局', '客胜', '过关', '单关'];
    final probs = _normalizedProbabilities(match.had);
    final values = <double>[
      probs.$1,
      probs.$2,
      probs.$3,
      match.canParlay ? .85 : .2,
      match.spfSingleSupported ? .85 : .2,
    ];
    final gridPaint = Paint()
      ..color = const Color(0xffd8e4df)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final fillPaint = Paint()
      ..color = const Color(0x2207885d)
      ..style = PaintingStyle.fill;
    final linePaint = Paint()
      ..color = _green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (var level = 1; level <= 3; level++) {
      final path = Path();
      for (var i = 0; i < 5; i++) {
        final angle = -math.pi / 2 + i * math.pi * 2 / 5;
        final point = center +
            Offset(math.cos(angle), math.sin(angle)) * radius * (level / 3);
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      path.close();
      canvas.drawPath(path, gridPaint);
    }
    final dataPath = Path();
    for (var i = 0; i < 5; i++) {
      final angle = -math.pi / 2 + i * math.pi * 2 / 5;
      final point = center +
          Offset(math.cos(angle), math.sin(angle)) *
              radius *
              values[i].clamp(.08, 1);
      if (i == 0) {
        dataPath.moveTo(point.dx, point.dy);
      } else {
        dataPath.lineTo(point.dx, point.dy);
      }
    }
    dataPath.close();
    canvas.drawPath(dataPath, fillPaint);
    canvas.drawPath(dataPath, linePaint);
    for (var i = 0; i < 5; i++) {
      final angle = -math.pi / 2 + i * math.pi * 2 / 5;
      final point =
          center + Offset(math.cos(angle), math.sin(angle)) * (radius + 13);
      final painter = TextPainter(
        text: TextSpan(
            text: labels[i],
            style: const TextStyle(fontSize: 8, color: Color(0xff4f575b))),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
          canvas, point - Offset(painter.width / 2, painter.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _OddsRadarPainter oldDelegate) =>
      oldDelegate.match != match;
}

class _Surface extends StatelessWidget {
  const _Surface(
      {required this.child,
      this.padding = const EdgeInsets.all(12),
      this.color = Colors.white});

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
        borderRadius: BorderRadius.circular(11),
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
        Text(title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const Spacer(),
        if (trailing != null)
          Text(trailing!, style: const TextStyle(fontSize: 9, color: _muted)),
      ],
    );
  }
}

class _SectionIconTitle extends StatelessWidget {
  const _SectionIconTitle(
      {required this.icon, required this.title, required this.color});

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
        Text(title,
            style: TextStyle(
                fontSize: 13, color: color, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _DataRow extends StatelessWidget {
  const _DataRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 37,
      decoration:
          const BoxDecoration(border: Border(bottom: BorderSide(color: _line))),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: _muted)),
          const Spacer(),
          Text(value,
              style:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
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
          color: _greenSoft, borderRadius: BorderRadius.circular(5)),
      child: Text(text,
          style: const TextStyle(
              fontSize: 9, color: _green, fontWeight: FontWeight.w600)),
    );
  }
}

class _BottomActions extends StatelessWidget {
  const _BottomActions({
    required this.followed,
    required this.match,
    required this.onFollow,
  });

  final bool followed;
  final MatchItem match;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    final open = match.bettingStatus == BettingStatus.open;
    return SafeArea(
      top: false,
      child: Container(
        height: 68,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: _line)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 105,
              height: 49,
              child: OutlinedButton.icon(
                onPressed: onFollow,
                icon: Icon(
                    followed ? Icons.star_rounded : Icons.star_border_rounded,
                    size: 21),
                label: Text(followed ? '已关注' : '关注比赛'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _green,
                  side: const BorderSide(color: Color(0xffd9e3df)),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  textStyle: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 49,
                child: FilledButton(
                  onPressed: open
                      ? () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const SelectionPage()),
                          )
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: _green,
                    disabledBackgroundColor: const Color(0xffcbd3d0),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(open ? '加入方案' : '已停售',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      if (open)
                        const Text('已选 0 场',
                            style:
                                TextStyle(fontSize: 9, color: Colors.white70)),
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
            child: Text(message,
                style: const TextStyle(fontSize: 10, color: Color(0xff9a5a1f))),
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
          child:
              Text(text, style: const TextStyle(fontSize: 10, color: _muted))),
    );
  }
}

String _mdhm(DateTime time) =>
    '${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String _statusText(MatchItem match) {
  return switch (match.matchState) {
    MatchState.notStarted => '未开赛',
    MatchState.live => (match.liveStatusText ?? '').trim().isEmpty
        ? '进行中'
        : match.liveStatusText!.trim(),
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

List<MapEntry<String, dynamic>> _orderedMarket(
    String title, Map<String, dynamic> source) {
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
