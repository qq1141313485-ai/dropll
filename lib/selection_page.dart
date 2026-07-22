import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'betting_engine.dart';
import 'models.dart';

enum _SelectionViewMode { mixed, score, totalGoals, halfFull }

String _prizeText(double minimum, double maximum) {
  if ((maximum - minimum).abs() < 0.005) {
    return '${minimum.toStringAsFixed(2)}元';
  }
  return '${minimum.toStringAsFixed(2)}～${maximum.toStringAsFixed(2)}元';
}

extension on _SelectionViewMode {
  String get label => switch (this) {
        _SelectionViewMode.mixed => '混合过关',
        _SelectionViewMode.score => '比分',
        _SelectionViewMode.totalGoals => '总进球',
        _SelectionViewMode.halfFull => '半全场',
      };

  FootballPlay? get play => switch (this) {
        _SelectionViewMode.mixed => null,
        _SelectionViewMode.score => FootballPlay.crs,
        _SelectionViewMode.totalGoals => FootballPlay.ttg,
        _SelectionViewMode.halfFull => FootballPlay.hafu,
      };
}

class SelectionPage extends StatefulWidget {
  const SelectionPage({super.key});
  @override
  State<SelectionPage> createState() => _SelectionPageState();
}

class _SelectionPageState extends State<SelectionPage> {
  final client = CaiApiClient();
  final drafts = <String, _Draft>{};
  List<MatchItem> matches = const [];
  bool loading = true;
  String? loadError;
  Timer? expiryTimer;
  List<PassMethod> quickPasses = const [];
  int quickMultiple = 1;
  _SelectionViewMode viewMode = _SelectionViewMode.mixed;

  @override
  void initState() {
    super.initState();
    _refresh();
    expiryTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      final expiredIds = matches
          .where((match) => !match.kickoff.isAfter(now))
          .map((match) => match.id)
          .toSet();
      if (expiredIds.isNotEmpty) {
        setState(() {
          matches = matches
              .where((match) => !expiredIds.contains(match.id))
              .toList(growable: false);
          drafts.removeWhere((id, _) => expiredIds.contains(id));
          _reconcileQuickPass();
        });
      }
      _refresh(silent: true);
    });
  }

  @override
  void dispose() {
    expiryTimer?.cancel();
    client.close();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (mounted && !silent) setState(() => loading = true);
    try {
      final data = await client.fetchBettableMatches();
      if (mounted) {
        final now = DateTime.now();
        final refreshed = data
            .whereType<Map<String, dynamic>>()
            .map(MatchItem.fromJson)
            .where((match) =>
                match.matchState == MatchState.notStarted &&
                match.bettingStatus == BettingStatus.open &&
                match.kickoff.isAfter(now) &&
                FootballPlay.values.any((play) => _enabled(match, play)))
            .toList(growable: false);
        final activeIds = refreshed.map((match) => match.id).toSet();
        setState(() {
          matches = refreshed;
          final before = drafts.length;
          drafts.removeWhere((id, _) => !activeIds.contains(id));
          if (before != drafts.length) _reconcileQuickPass();
          loadError = null;
        });
      }
    } catch (error) {
      debugPrint('选号数据加载失败: $error');
      if (mounted && !silent) {
        setState(() => loadError = error.toString());
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('比赛数据加载失败')));
      }
    } finally {
      if (mounted && !silent) setState(() => loading = false);
    }
  }

  Map<String, double> _odds(MatchItem m, FootballPlay p) => switch (p) {
        FootballPlay.had => m.had,
        FootballPlay.hhad => {
            for (final e in m.hhad.entries)
              if (e.key != '让球' && e.value is num)
                e.key: (e.value as num).toDouble()
          },
        FootballPlay.ttg => m.ttg,
        FootballPlay.crs => m.crs,
        FootballPlay.hafu => m.hafu,
      };

  bool _enabled(MatchItem m, FootballPlay p) {
    final pool = m.pools[p.poolCode];
    if (pool is! Map) return false;
    final status = '${pool['status'] ?? ''}'.trim().toLowerCase();
    final poolOpen = status == 'open' ||
        status == 'selling' ||
        status.contains('开售') ||
        status.contains('销售');
    if (!poolOpen) return false;

    final supportsParlay = pool['allUp'] == true && m.canParlay;
    final supportsSingle = pool['single'] == true && m.canSingle;
    return supportsParlay || supportsSingle;
  }

  List<MatchPick> get picks => [
        for (final m in matches)
          if (drafts[m.id] case final d? when d.hasSelection)
            MatchPick(
                matchId: m.id,
                number: m.number,
                home: m.home,
                away: m.away,
                league: m.league,
                kickoff: m.kickoff,
                play: d.firstPlay,
                banker: d.banker,
                availableOdds: {
                  for (final play in d.selected.keys) play: _odds(m, play),
                },
                handicap: m.hhad['让球']?.toString() ?? '',
                options: [
                  for (final entry in d.selected.entries)
                    for (final k in entry.value)
                      if (_odds(m, entry.key)[k] != null)
                        BetOption(
                            label: k,
                            sp: _odds(m, entry.key)[k]!,
                            play: entry.key)
                ])
      ];

  void _toggle(MatchItem m, FootballPlay p, String key) => setState(() {
        final d = drafts.putIfAbsent(m.id, _Draft.new);
        final values = d.selected.putIfAbsent(p, () => <String>{});
        if (!values.add(key)) values.remove(key);
        if (values.isEmpty) d.selected.remove(p);
        if (!d.hasSelection) drafts.remove(m.id);
        _reconcileQuickPass();
      });

  void _calculate({bool optimize = false}) {
    final selected = picks;
    if (selected.isEmpty) return;
    if (selected.length == 1) {
      final m = matches.firstWhere((x) => x.id == selected.first.matchId);
      final plays = selected.first.options
          .map((option) => option.play ?? selected.first.play)
          .toSet();
      if (!m.canSingle ||
          plays.any((play) {
            final pool = m.pools[play.poolCode];
            return pool is! Map || pool['single'] != true;
          })) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前玩法不支持单关')));
        return;
      }
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => _SchemePage(
            picks: selected,
            initialPasses: quickPasses,
            initialMultiple: quickMultiple,
            initialBudget: _quickResult(selected)?.amount,
            optimizationOnly: optimize)));
  }

  int _maxPassFor(List<MatchPick> selected) => selected
      .expand((item) =>
          item.options.map((option) => (option.play ?? item.play).maxPass))
      .reduce((a, b) => a < b ? a : b);

  bool _supportsSingle(MatchPick pick) {
    final match = matches.firstWhere((item) => item.id == pick.matchId);
    if (!match.canSingle) return false;
    return pick.options.every((option) {
      final play = option.play ?? pick.play;
      final pool = match.pools[play.poolCode];
      return pool is Map && pool['single'] == true;
    });
  }

  List<PassMethod> _quickMethods(List<MatchPick> selected) {
    if (selected.isEmpty) return const [];
    if (selected.length == 1 && !_supportsSingle(selected.first)) {
      return const [];
    }
    return PassMethod.available(selected.length, _maxPassFor(selected));
  }

  bool _samePass(PassMethod a, PassMethod b) =>
      a.label == b.label &&
      a.matches == b.matches &&
      a.subPassSizes.join(',') == b.subPassSizes.join(',');

  void _reconcileQuickPass() {
    final selected = picks;
    final methods = _quickMethods(selected);
    if (methods.isEmpty) {
      quickPasses = const [];
      return;
    }
    final retained = <PassMethod>[];
    for (final current in quickPasses) {
      final compatible = methods.where((method) => _samePass(method, current));
      if (compatible.isNotEmpty) retained.add(compatible.first);
    }
    if (retained.isNotEmpty) {
      quickPasses = retained;
      return;
    }
    final freeMethods = methods
        .where((method) =>
            method.matches == 1 || method.displayLabel?.endsWith('串1') == true)
        .toList(growable: false);
    quickPasses = [freeMethods.isEmpty ? methods.first : freeMethods.last];
  }

  Future<void> _chooseQuickPass() async {
    final selected = picks;
    final methods = _quickMethods(selected);
    if (methods.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              selected.length == 1 ? '当前选择不支持单关，请至少选择2场' : '当前玩法组合暂无可用过关方式')));
      return;
    }
    final freeMethods = methods
        .where((method) => method.matches == 1 || method.label.endsWith('串1'))
        .toList(growable: false);
    var selectedMethods = [
      for (final method in freeMethods)
        if (quickPasses.any((item) => _samePass(item, method))) method
    ];
    final chosen = await showModalBottomSheet<List<PassMethod>>(
        context: context,
        useSafeArea: true,
        builder: (sheetContext) => StatefulBuilder(builder: (_, updateSheet) {
              return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      const Text('过关方式',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Text('已选${selected.length}场，可多选',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xff7f8783)))
                    ]),
                    const SizedBox(height: 14),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final method in freeMethods)
                        FilterChip(
                            label: Text(method.label),
                            selected: selectedMethods
                                .any((item) => _samePass(item, method)),
                            onSelected: (value) => updateSheet(() {
                                  if (value) {
                                    selectedMethods = [
                                      ...selectedMethods,
                                      method
                                    ];
                                  } else {
                                    selectedMethods = selectedMethods
                                        .where(
                                            (item) => !_samePass(item, method))
                                        .toList(growable: false);
                                  }
                                }))
                    ]),
                    const SizedBox(height: 14),
                    SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                            onPressed: selectedMethods.isEmpty
                                ? null
                                : () => Navigator.pop(
                                    sheetContext, selectedMethods),
                            child: const Text('确定')))
                  ]));
            }));
    if (chosen != null && mounted) {
      setState(() {
        quickPasses = chosen;
      });
    }
  }

  BettingResult? _quickResult(List<MatchPick> selected) {
    if (quickPasses.isEmpty) return null;
    try {
      return const BettingEngine().calculateMultiple(
          picks: selected, passes: quickPasses, multiple: quickMultiple);
    } catch (_) {
      return null;
    }
  }

  String get _quickPassLabel => quickPasses.isEmpty
      ? '过关方式'
      : quickPasses.map((item) => item.label).join('、');

  void _changeQuickMultiple(int delta) => setState(() {
        quickMultiple = (quickMultiple + delta)
            .clamp(1, BettingEngine.maxSchemeMultiple)
            .toInt();
      });

  Future<void> _editQuickMultiple() async {
    // Keep the display at 1x, but let a typed value replace it rather than append.
    var input = '';
    final chosen = await showModalBottomSheet<int>(
        context: context,
        useSafeArea: true,
        builder: (sheetContext) => StatefulBuilder(
            builder: (context, updateSheet) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    const Text('方案总倍数',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Text('$input 倍',
                        style: const TextStyle(
                            fontSize: 18,
                            color: Color(0xff168f62),
                            fontWeight: FontWeight.w700))
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    for (final value in const [20, 50, 100, 500])
                      Expanded(
                          child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 3),
                              child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      minimumSize: const Size(0, 42)),
                                  onPressed: () => updateSheet(
                                      () => input = value.toString()),
                                  child: Text('$value倍',
                                      maxLines: 1,
                                      softWrap: false,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600)))))
                  ]),
                  const SizedBox(height: 8),
                  GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 3,
                      childAspectRatio: 2.25,
                      children: [
                        for (final key in const [
                          '1',
                          '2',
                          '3',
                          '4',
                          '5',
                          '6',
                          '7',
                          '8',
                          '9',
                          '清空',
                          '0',
                          '⌫'
                        ])
                          InkWell(
                              onTap: () => updateSheet(() {
                                    if (key == '清空') {
                                      input = '';
                                    } else if (key == '⌫') {
                                      if (input.isNotEmpty) {
                                        input = input.substring(
                                            0, input.length - 1);
                                      }
                                    } else {
                                      final next = '$input$key'
                                          .replaceFirst(RegExp(r'^0+'), '');
                                      final parsed = int.tryParse(next) ?? 0;
                                      if (parsed <=
                                          BettingEngine.maxSchemeMultiple) {
                                        input = next;
                                      }
                                    }
                                  }),
                              child: Container(
                                  margin: const EdgeInsets.all(2),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                      color: const Color(0xfff4f6f5),
                                      borderRadius: BorderRadius.circular(5)),
                                  child: Text(key,
                                      style: const TextStyle(fontSize: 16))))
                      ]),
                  const SizedBox(height: 8),
                  Builder(builder: (_) {
                    BettingResult? preview;
                    final multiple = int.tryParse(input) ?? 0;
                    if (multiple > 0 && quickPasses.isNotEmpty) {
                      try {
                        preview = const BettingEngine().calculateMultiple(
                            picks: picks,
                            passes: quickPasses,
                            multiple: multiple);
                      } catch (_) {}
                    }
                    return Row(children: [
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(preview == null
                                ? '金额 --'
                                : '金额 ${preview.amount.toStringAsFixed(0)}元'),
                            const SizedBox(height: 2),
                            Text(
                                preview == null
                                    ? '最高奖金 --'
                                    : '最高奖金 ${preview.maxReturn.toStringAsFixed(2)}元',
                                style: const TextStyle(
                                    color: Color(0xffdf4162), fontSize: 11))
                          ])),
                      SizedBox(
                          width: 116,
                          child: FilledButton(
                              onPressed: () {
                                final value = int.tryParse(input) ?? 0;
                                if (value >= 1 &&
                                    value <= BettingEngine.maxSchemeMultiple) {
                                  Navigator.pop(sheetContext, value);
                                }
                              },
                              child: const Text('完成')))
                    ]);
                  }),
                  const Text('输入倍数后按完成更新方案金额与奖金测算',
                      style: TextStyle(fontSize: 10, color: Color(0xff8a918e)))
                ]))));
    if (chosen != null && mounted) {
      setState(() => quickMultiple = chosen);
    }
  }

  bool _isSelected(MatchItem match, FootballPlay play, String key) =>
      drafts[match.id]?.selected[play]?.contains(key) == true;

  Widget _optionCell(
    MatchItem match,
    FootballPlay play,
    String key, {
    String? text,
    bool showSingleBadge = false,
    double spacing = 2,
  }) {
    final sp = _odds(match, play)[key];
    if (sp == null) return const SizedBox.shrink();
    final selected = _isSelected(match, play, key);
    return Expanded(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: spacing),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: _enabled(match, play) ? () => _toggle(match, play, key) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? const Color(0xff16a36a) : Colors.white,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: selected
                    ? const Color(0xff128956)
                    : const Color(0xffdfe5e2),
                width: selected ? 1.1 : 1,
              ),
            ),
            child: Stack(fit: StackFit.expand, children: [
              Center(
                  child: Text(
                text ?? '$key ${sp.toStringAsFixed(2)}',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11.25,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? Colors.white : const Color(0xff555d59),
                ),
              )),
              if (showSingleBadge)
                Positioned(
                    left: 2,
                    top: 1,
                    child: Container(
                        width: 13,
                        height: 11,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: selected
                                ? Colors.white
                                : const Color(0xffdf6574),
                            borderRadius: BorderRadius.circular(2)),
                        child: Text('单',
                            style: TextStyle(
                                fontSize: 7,
                                height: 1,
                                color: selected
                                    ? const Color(0xff168f62)
                                    : Colors.white,
                                fontWeight: FontWeight.w700))))
            ]),
          ),
        ),
      ),
    );
  }

  Widget _unavailableOptionCell(
    String key, {
    double spacing = 2,
  }) =>
      Expanded(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: spacing),
          child: Container(
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xfff4f5f5),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xffdfe5e2)),
            ),
            child: Text('$key 未受注',
                maxLines: 1,
                style:
                    const TextStyle(fontSize: 9.5, color: Color(0xffa4aaa7))),
          ),
        ),
      );

  Widget _mainOddsRow(MatchItem match, FootballPlay play) {
    final handicap = match.hhad['让球'];
    final enabled = _enabled(match, play);
    final spfSingle = play == FootballPlay.had && match.spfSingleSupported;
    const keys = ['胜', '平', '负'];
    final hasAnyOdds = keys.any((key) => _odds(match, play)[key] != null);
    return Row(children: [
      SizedBox(
          width: 42,
          child: Text(play == FootballPlay.had ? '0' : '${handicap ?? ''}',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: play == FootballPlay.hhad
                      ? const Color(0xff16a36a)
                      : const Color(0xff9aa19d)))),
      Expanded(
          child: SizedBox(
              height: 36,
              child: !enabled || !hasAnyOdds
                  ? Center(
                      child: Text(
                          play == FootballPlay.had ? '胜平负未受注' : '让球胜平负未受注',
                          style: const TextStyle(
                              fontSize: 9.5, color: Color(0xffa4aaa7))))
                  : Stack(children: [
                      Row(children: [
                        for (var index = 0; index < 3; index++) ...[
                          if (_odds(match, play)[keys[index]] == null)
                            _unavailableOptionCell(keys[index])
                          else
                            _optionCell(
                              match,
                              play,
                              keys[index],
                              showSingleBadge: spfSingle && index == 0,
                            )
                        ]
                      ]),
                      if (spfSingle)
                        Positioned.fill(
                          left: 2,
                          right: 2,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(
                                    color: const Color(0xffe89aa3), width: 1.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        )
                    ])))
    ]);
  }

  Widget _buildMatch(MatchItem match) {
    final play = viewMode.play;
    if (play != null) return _buildSinglePlayMatch(match, play);

    final draft = drafts[match.id];
    final moreSelectionCount = draft?.selected.entries
            .where((entry) =>
                entry.key != FootballPlay.had && entry.key != FootballPlay.hhad)
            .fold<int>(0, (sum, entry) => sum + entry.value.length) ??
        0;
    final showHandicap = _odds(match, FootballPlay.hhad).isNotEmpty ||
        match.pools.containsKey(FootballPlay.hhad.poolCode);
    final time =
        '${match.kickoff.hour.toString().padLeft(2, '0')}:${match.kickoff.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 10, 5),
      decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xffedf0ee)))),
      child: Column(children: [
        Row(children: [
          Text(match.number,
              style: const TextStyle(fontSize: 11, color: Color(0xff737b77))),
          const SizedBox(width: 6),
          Container(
              constraints: const BoxConstraints(maxWidth: 76),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                  color: const Color(0xffeef8f3),
                  borderRadius: BorderRadius.circular(3)),
              child: Text(match.league,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xff2f9d75),
                      fontWeight: FontWeight.w600))),
          const Spacer(),
          Text(time,
              style: const TextStyle(fontSize: 11, color: Color(0xff8a918d))),
          if (draft != null && draft.hasSelection) ...[
            const SizedBox(width: 8),
            InkWell(
                onTap: () => setState(() => draft.banker = !draft.banker),
                child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: draft.banker
                            ? const Color(0xfffff0f3)
                            : const Color(0xfff3f5f4),
                        borderRadius: BorderRadius.circular(3)),
                    child: Text(draft.banker ? '胆' : '设胆',
                        style: TextStyle(
                            fontSize: 9,
                            color: draft.banker
                                ? const Color(0xffe24b63)
                                : const Color(0xff777f7b)))))
          ]
        ]),
        const SizedBox(height: 4),
        Row(children: [
          const SizedBox(width: 42),
          Expanded(
              child: Text(match.home,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600))),
          const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('VS',
                  style: TextStyle(fontSize: 10.5, color: Color(0xffa0a6a3)))),
          Expanded(
              child: Text(match.away,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600))),
          const SizedBox(width: 54)
        ]),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: Column(children: [
            _mainOddsRow(match, FootballPlay.had),
            if (showHandicap) ...[_mainOddsRow(match, FootballPlay.hhad)]
          ])),
          const SizedBox(width: 4),
          InkWell(
              onTap: () => _openMore(match),
              child: Container(
                  width: 50,
                  height: showHandicap ? 72 : 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: moreSelectionCount > 0
                          ? const Color(0xffe6f5ed)
                          : const Color(0xfffbfdfc),
                      border: Border.all(
                          color: moreSelectionCount > 0
                              ? const Color(0xff43aa80)
                              : const Color(0xffdfe5e2),
                          width: moreSelectionCount > 0 ? 1.2 : .8)),
                  child: showHandicap
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                              Text(
                                  moreSelectionCount > 0
                                      ? '已选$moreSelectionCount项'
                                      : '更多',
                                  style: TextStyle(
                                      fontSize:
                                          moreSelectionCount > 0 ? 9 : 10.5,
                                      height: 1.15,
                                      color: const Color(0xff2f8f6d),
                                      fontWeight: FontWeight.w600)),
                              const Text('玩法',
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      height: 1.15,
                                      color: Color(0xff2f8f6d),
                                      fontWeight: FontWeight.w600)),
                              const Icon(Icons.chevron_right,
                                  size: 13, color: Color(0xff7d9b8d))
                            ])
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(
                              moreSelectionCount > 0
                                  ? '已选$moreSelectionCount项'
                                  : '更多',
                              style: const TextStyle(
                                  fontSize: 10.5,
                                  color: Color(0xff2f8f6d),
                                  fontWeight: FontWeight.w600)),
                          const Icon(Icons.chevron_right,
                              size: 13, color: Color(0xff7d9b8d))
                        ])))
        ])
      ]),
    );
  }

  String _canonicalScore(String value) => value
      .trim()
      .replaceAll('-', ':')
      .replaceAll('其它', '其他')
      .replaceAll(' ', '');

  String _playOptionLabel(FootballPlay play, String label) {
    if (play == FootballPlay.ttg) {
      return label.endsWith('球') ? label : '$label球';
    }
    if (play == FootballPlay.hafu && !label.contains('/')) {
      final compact = label.replaceAll(RegExp(r'\s+'), '');
      if (compact.length == 2) return '${compact[0]}/${compact[1]}';
    }
    return label;
  }

  List<String> _playOrder(FootballPlay play, MatchItem match) {
    if (play == FootballPlay.had || play == FootballPlay.hhad) {
      return const ['胜', '平', '负'];
    }
    if (play == FootballPlay.ttg) {
      return const ['0', '1', '2', '3', '4', '5', '6', '7+'];
    }
    if (play == FootballPlay.hafu) {
      return const ['胜胜', '胜平', '胜负', '平胜', '平平', '平负', '负胜', '负平', '负负'];
    }
    final odds = _odds(match, play);
    const scoreOrder = [
      '1:0',
      '2:0',
      '2:1',
      '3:0',
      '3:1',
      '3:2',
      '4:0',
      '4:1',
      '4:2',
      '5:0',
      '5:1',
      '5:2',
      '胜其他',
      '0:0',
      '1:1',
      '2:2',
      '3:3',
      '平其他',
      '0:1',
      '0:2',
      '1:2',
      '0:3',
      '1:3',
      '2:3',
      '0:4',
      '1:4',
      '2:4',
      '0:5',
      '1:5',
      '2:5',
      '负其他',
    ];
    final ordered = <String>[];
    for (final expected in scoreOrder) {
      for (final actual in odds.keys) {
        if (!ordered.contains(actual) &&
            _canonicalScore(actual) == _canonicalScore(expected)) {
          ordered.add(actual);
          break;
        }
      }
    }
    ordered.addAll(odds.keys.where((key) => !ordered.contains(key)));
    return ordered;
  }

  Widget _buildSinglePlayMatch(MatchItem match, FootballPlay play) {
    final odds = _odds(match, play);
    final enabled = _enabled(match, play);
    final draft = drafts[match.id];
    final time =
        '${match.kickoff.hour.toString().padLeft(2, '0')}:${match.kickoff.minute.toString().padLeft(2, '0')}';
    final order = _playOrder(play, match).where(odds.containsKey).toList();
    final columns = switch (play) {
      FootballPlay.crs => 5,
      FootballPlay.ttg => 4,
      _ => 3,
    };
    return Container(
        padding: const EdgeInsets.fromLTRB(12, 7, 10, 9),
        decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xffedf0ee)))),
        child: Column(children: [
          Row(children: [
            Text(match.number,
                style: const TextStyle(fontSize: 11, color: Color(0xff737b77))),
            const SizedBox(width: 6),
            Text(match.league,
                style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xff2f9d75),
                    fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(time,
                style: const TextStyle(fontSize: 11, color: Color(0xff8a918d))),
            if (draft != null && draft.hasSelection) ...[
              const SizedBox(width: 8),
              InkWell(
                  onTap: () => setState(() => draft.banker = !draft.banker),
                  child: Text(draft.banker ? '胆' : '设胆',
                      style: TextStyle(
                          fontSize: 9,
                          color: draft.banker
                              ? const Color(0xffe24b63)
                              : const Color(0xff777f7b))))
            ]
          ]),
          const SizedBox(height: 7),
          Row(children: [
            Expanded(
                child: Text(match.home,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600))),
            const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: Text('VS',
                    style: TextStyle(fontSize: 11, color: Color(0xffa0a6a3)))),
            Expanded(
                child: Text(match.away,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)))
          ]),
          const SizedBox(height: 8),
          if (order.isEmpty || !enabled)
            Container(
                height: 42,
                alignment: Alignment.center,
                color: const Color(0xfff3f5f4),
                child: Text(order.isEmpty ? '暂未开售（暂无官方SP）' : '未受注',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xffa1a7a4))))
          else
            GridView.count(
                crossAxisCount: columns,
                childAspectRatio: play == FootballPlay.crs ? 1.25 : 1.65,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final key in order)
                    InkWell(
                        onTap: enabled ? () => _toggle(match, play, key) : null,
                        child: Builder(builder: (_) {
                          final selected = _isSelected(match, play, key);
                          return Container(
                              alignment: Alignment.center,
                              color: selected
                                  ? const Color(0xff16a36a)
                                  : enabled
                                      ? const Color(0xfff6f7f7)
                                      : const Color(0xfff1f2f2),
                              child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(_playOptionLabel(play, key),
                                        maxLines: 1,
                                        style: TextStyle(
                                            fontSize: play == FootballPlay.crs
                                                ? 10.5
                                                : 11.5,
                                            height: 1,
                                            color: selected
                                                ? Colors.white
                                                : const Color(0xff3f4743),
                                            fontWeight: FontWeight.w600)),
                                    const SizedBox(height: 3),
                                    Text(odds[key]!.toStringAsFixed(2),
                                        maxLines: 1,
                                        style: TextStyle(
                                            fontSize: 9.5,
                                            height: 1,
                                            color: selected
                                                ? Colors.white
                                                    .withValues(alpha: .9)
                                                : const Color(0xff929995)))
                                  ]));
                        }))
                ])
        ]));
  }

  Future<void> _openMore(MatchItem match) async {
    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => StatefulBuilder(builder: (_, refreshSheet) {
              Widget section(FootballPlay play, List<String> order) {
                final odds = _odds(match, play);
                final pool = match.pools[play.poolCode];
                final supportsSingle = pool is Map && pool['single'] == true;
                final supportsParlay = pool is Map && pool['allUp'] == true;
                final enabled = _enabled(match, play);
                final poolStatus = pool is Map
                    ? '${pool['status'] ?? ''}'.trim().toLowerCase()
                    : '';
                final statusLabel = enabled
                    ? null
                    : odds.isEmpty || poolStatus.isEmpty
                        ? '暂未开售'
                        : '已停售';
                final handicap = play == FootballPlay.hhad
                    ? match.hhad['让球']?.toString()
                    : null;
                return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text(
                                handicap == null
                                    ? play.label
                                    : '${play.label}  $handicap',
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w700)),
                            if (supportsSingle) ...[
                              const SizedBox(width: 6),
                              const _PlayCapabilityTag(label: '单关')
                            ],
                            if (supportsParlay) ...[
                              const SizedBox(width: 5),
                              const _PlayCapabilityTag(label: '过关')
                            ],
                            if (statusLabel != null) ...[
                              const Spacer(),
                              Text(statusLabel,
                                  style: const TextStyle(
                                      fontSize: 10, color: Color(0xffa4aaa7)))
                            ]
                          ]),
                          const SizedBox(height: 6),
                          if (odds.isEmpty)
                            Container(
                                height: 34,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                    color: const Color(0xfff5f6f6),
                                    borderRadius: BorderRadius.circular(3)),
                                child: const Text('暂未开售（暂无官方SP）',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Color(0xffa1a7a4))))
                          else
                            GridView.count(
                                crossAxisCount: play == FootballPlay.crs ||
                                        play == FootballPlay.ttg
                                    ? 4
                                    : 3,
                                childAspectRatio:
                                    play == FootballPlay.crs ? 1.75 : 2.45,
                                mainAxisSpacing: 1.5,
                                crossAxisSpacing: 1.5,
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                children: [
                                  for (final key in order)
                                    if (odds[key] != null)
                                      Builder(builder: (_) {
                                        final selected =
                                            _isSelected(match, play, key);
                                        return InkWell(
                                            onTap: enabled
                                                ? () {
                                                    _toggle(match, play, key);
                                                    refreshSheet(() {});
                                                  }
                                                : null,
                                            child: Container(
                                                alignment: Alignment.center,
                                                decoration: BoxDecoration(
                                                    color: selected
                                                        ? const Color(
                                                            0xff16a36a)
                                                        : enabled
                                                            ? const Color(
                                                                0xfff6f7f7)
                                                            : const Color(
                                                                0xfff1f2f2),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            3)),
                                                child: Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Text(key,
                                                          maxLines: 1,
                                                          style: TextStyle(
                                                              fontSize: 10.5,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              color: selected
                                                                  ? Colors.white
                                                                  : enabled
                                                                      ? const Color(
                                                                          0xff353b38)
                                                                      : const Color(
                                                                          0xffaeb3b0))),
                                                      const SizedBox(height: 1),
                                                      Text(
                                                          odds[key]!
                                                              .toStringAsFixed(
                                                                  2),
                                                          style: TextStyle(
                                                              fontSize: 9.5,
                                                              color: selected
                                                                  ? Colors
                                                                      .white70
                                                                  : const Color(
                                                                      0xff8f9692)))
                                                    ])));
                                      })
                                ])
                        ]));
              }

              return DraggableScrollableSheet(
                  expand: false,
                  initialChildSize: .86,
                  maxChildSize: .95,
                  builder: (_, controller) => Column(children: [
                        Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                            child: Row(children: [
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text('${match.home}  VS  ${match.away}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 3),
                                    Text(
                                        '${match.number} · ${match.league} · ${match.kickoffDisplayTime}',
                                        style: const TextStyle(
                                            fontSize: 10,
                                            color: Color(0xff858d89)))
                                  ])),
                              IconButton(
                                  onPressed: () => Navigator.pop(sheetContext),
                                  icon: const Icon(Icons.close))
                            ])),
                        Expanded(
                            child: ListView(
                                controller: controller,
                                padding:
                                    const EdgeInsets.fromLTRB(12, 8, 12, 10),
                                children: [
                              section(FootballPlay.had, const ['胜', '平', '负']),
                              section(FootballPlay.hhad, const ['胜', '平', '负']),
                              section(FootballPlay.ttg, const [
                                '0',
                                '1',
                                '2',
                                '3',
                                '4',
                                '5',
                                '6',
                                '7+'
                              ]),
                              section(FootballPlay.crs,
                                  _playOrder(FootballPlay.crs, match)),
                              section(FootballPlay.hafu, const [
                                '胜胜',
                                '胜平',
                                '胜负',
                                '平胜',
                                '平平',
                                '平负',
                                '负胜',
                                '负平',
                                '负负'
                              ]),
                            ])),
                        Container(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                            decoration: const BoxDecoration(
                                color: Colors.white,
                                border: Border(
                                    top: BorderSide(color: Color(0xffe7eae8)))),
                            child: Row(children: [
                              Expanded(
                                  child: Text(
                                      '已选 ${drafts[match.id]?.selected.values.fold<int>(0, (sum, values) => sum + values.length) ?? 0} 项',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xff69716d)))),
                              SizedBox(
                                  width: 132,
                                  child: FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(sheetContext),
                                      child: const Text('确定')))
                            ]))
                      ]));
            }));
  }

  String _dateLabel(String value) {
    final date = DateTime.tryParse(value);
    if (date == null) return value;
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${weekdays[date.weekday - 1]}';
  }

  List<Widget> _matchListChildren() {
    final children = <Widget>[];
    String? currentDate;
    for (final match in matches) {
      if (match.businessDate != currentDate) {
        currentDate = match.businessDate;
        final count =
            matches.where((item) => item.businessDate == currentDate).length;
        children.add(Container(
            height: 29,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: const Color(0xfff5f7f6),
            child: Row(children: [
              Text(_dateLabel(currentDate),
                  style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff4d5551),
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('$count场比赛',
                  style:
                      const TextStyle(fontSize: 10, color: Color(0xff929995)))
            ])));
      }
      children.add(_buildMatch(match));
    }
    return children;
  }

  Future<void> _openSavedSchemes() async {
    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const _SavedSchemesSheet());
  }

  Widget _buildBottomBar(List<MatchPick> selected) {
    final hasSelection = selected.isNotEmpty;
    final optionCount =
        selected.fold<int>(0, (sum, item) => sum + item.options.length);
    final preview = _quickResult(selected);
    return Container(
        height: 104,
        padding: const EdgeInsets.fromLTRB(8, 4, 10, 6),
        decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xffe4e8e6)))),
        child: Column(children: [
          SizedBox(
              height: 38,
              child: Row(children: [
                IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '清空选号',
                    onPressed: hasSelection
                        ? () => setState(() {
                              drafts.clear();
                              quickPasses = const [];
                              quickMultiple = 1;
                            })
                        : null,
                    icon: const Icon(Icons.delete_outline,
                        size: 21, color: Color(0xff6f7773))),
                Text('已选${selected.length}场/$optionCount项',
                    style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xff4f5753),
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(
                    child: InkWell(
                        onTap: hasSelection ? _chooseQuickPass : null,
                        child: Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 9),
                            decoration: BoxDecoration(
                                border: Border.all(
                                    color: const Color(0xffdfe4e1), width: .8),
                                borderRadius: BorderRadius.circular(4)),
                            child: Row(children: [
                              Expanded(
                                  child: Text(_quickPassLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: !hasSelection
                                              ? const Color(0xffb3b9b6)
                                              : quickPasses.isEmpty
                                                  ? const Color(0xff7c8480)
                                                  : const Color(0xff216f50)))),
                              Icon(Icons.arrow_drop_down,
                                  size: 17,
                                  color: hasSelection
                                      ? const Color(0xff7e8682)
                                      : const Color(0xffc4c9c7))
                            ])))),
                const SizedBox(width: 8),
                const Text('倍数',
                    style: TextStyle(fontSize: 11, color: Color(0xff59615d))),
                IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: hasSelection && quickMultiple > 1
                        ? () => _changeQuickMultiple(-1)
                        : null,
                    icon: const Icon(Icons.remove, size: 17)),
                InkWell(
                    onTap: hasSelection ? _editQuickMultiple : null,
                    child: SizedBox(
                        width: 31,
                        height: 30,
                        child: Center(
                            child: Text('$quickMultiple',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: hasSelection
                                        ? const Color(0xff303733)
                                        : const Color(0xffb3b9b6),
                                    fontWeight: FontWeight.w600))))),
                IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed:
                        hasSelection ? () => _changeQuickMultiple(1) : null,
                    icon: const Icon(Icons.add, size: 17))
              ])),
          const SizedBox(height: 4),
          Expanded(
              child: Row(children: [
            Expanded(
                child: Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              !hasSelection
                                  ? '请选择比赛'
                                  : preview == null
                                      ? '请选择过关方式'
                                      : '${preview.notes}注  ${preview.amount.toStringAsFixed(0)}元',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xff3f4743),
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(
                              preview == null
                                  ? '预计奖金：--'
                                  : '预计奖金：${_prizeText(preview.minReturn, preview.maxReturn)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 9.5, color: Color(0xffe0526e)))
                        ]))),
            SizedBox(
                height: 38,
                child: OutlinedButton(
                    onPressed: hasSelection && quickPasses.isNotEmpty
                        ? () => _calculate(optimize: true)
                        : null,
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10)),
                    child: const Text('奖金优化', style: TextStyle(fontSize: 11)))),
            const SizedBox(width: 7),
            SizedBox(
                height: 38,
                child: FilledButton(
                    onPressed: !hasSelection
                        ? null
                        : quickPasses.isEmpty
                            ? _chooseQuickPass
                            : () => _calculate(),
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 13)),
                    child: const Text('生成方案', style: TextStyle(fontSize: 11))))
          ]))
        ]));
  }

  @override
  Widget build(BuildContext context) {
    final selected = picks;
    return Scaffold(
      backgroundColor: const Color(0xfff6f7f7),
      body: Column(children: [
        Container(
            color: Colors.white,
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(children: [
              Expanded(
                  child: Row(children: [
                const Text('竞球镜',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child:
                        Text('·', style: TextStyle(color: Color(0xffa0a6a3)))),
                PopupMenuButton<_SelectionViewMode>(
                    tooltip: '切换玩法',
                    initialValue: viewMode,
                    offset: const Offset(0, 38),
                    color: Colors.white,
                    surfaceTintColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    onSelected: (mode) => setState(() => viewMode = mode),
                    itemBuilder: (_) => [
                          for (final mode in _SelectionViewMode.values)
                            PopupMenuItem(
                                value: mode,
                                height: 42,
                                child: Row(children: [
                                  SizedBox(
                                      width: 22,
                                      child: mode == viewMode
                                          ? const Icon(Icons.check,
                                              size: 16,
                                              color: Color(0xff168f62))
                                          : null),
                                  Text(mode.label,
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: mode == viewMode
                                              ? const Color(0xff168f62)
                                              : const Color(0xff4f5753),
                                          fontWeight: FontWeight.w600))
                                ]))
                        ],
                    child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(viewMode.label,
                              style: const TextStyle(
                                  fontSize: 14,
                                  color: Color(0xff4f5753),
                                  fontWeight: FontWeight.w600)),
                          const Icon(Icons.arrow_drop_down,
                              size: 19, color: Color(0xff69716d))
                        ])))
              ])),
              TextButton.icon(
                  onPressed: _openSavedSchemes,
                  icon: const Icon(Icons.bookmarks_outlined, size: 18),
                  label: const Text('方案', style: TextStyle(fontSize: 11)))
            ])),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
            child: RefreshIndicator(
                onRefresh: _refresh,
                child: matches.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                            SizedBox(
                                height: 360,
                                child: Center(
                                    child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                      Icon(Icons.sports_soccer,
                                          size: 38,
                                          color: loading
                                              ? const Color(0xff16a36a)
                                              : const Color(0xffa5aca8)),
                                      const SizedBox(height: 10),
                                      Text(loading
                                          ? '正在加载在售场次…'
                                          : loadError == null
                                              ? '暂无在售场次'
                                              : '加载失败，请重试'),
                                      if (!loading)
                                        TextButton(
                                            onPressed: _refresh,
                                            child: const Text('重新加载'))
                                    ])))
                          ])
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 116),
                        children: _matchListChildren()))),
      ]),
      bottomSheet: _buildBottomBar(selected),
    );
  }
}

class _PlayCapabilityTag extends StatelessWidget {
  const _PlayCapabilityTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
            color: const Color(0xffedf8f2),
            borderRadius: BorderRadius.circular(3)),
        child: Text(label,
            style: const TextStyle(
                fontSize: 9,
                color: Color(0xff2f9d75),
                fontWeight: FontWeight.w600)),
      );
}

class _Draft {
  final selected = <FootballPlay, Set<String>>{};
  bool banker = false;
  bool get hasSelection => selected.values.any((values) => values.isNotEmpty);
  FootballPlay get firstPlay => selected.keys.first;
}

enum _SchemeMode { normal, optimize }

class _SchemePage extends StatefulWidget {
  const _SchemePage(
      {required this.picks,
      required this.initialPasses,
      this.initialMultiple = 1,
      this.initialBudget,
      this.optimizationOnly = false,
      this.initialResult,
      this.initialShowCombinations = false});

  final List<MatchPick> picks;
  final List<PassMethod> initialPasses;
  final int initialMultiple;
  final double? initialBudget;
  final bool optimizationOnly;
  final BettingResult? initialResult;
  final bool initialShowCombinations;

  @override
  State<_SchemePage> createState() => _SchemePageState();
}

class _SchemePageState extends State<_SchemePage> {
  static const _green = Color(0xff168f62);
  static const _background = Color(0xfff5f7f6);

  late final TextEditingController multipleController;
  late final TextEditingController budgetController;
  late final List<PassMethod> methods;
  late List<PassMethod> selectedMethods;
  _SchemeMode mode = _SchemeMode.normal;
  OptimizeMode optimizeMode = OptimizeMode.balanced;
  BettingResult? result;
  String? error;
  bool showCombinations = false;
  bool isSharing = false;

  @override
  void initState() {
    super.initState();
    mode = widget.optimizationOnly ? _SchemeMode.optimize : _SchemeMode.normal;
    multipleController =
        TextEditingController(text: widget.initialMultiple.toString());
    budgetController = TextEditingController(
        text: (widget.initialBudget ?? 100).toStringAsFixed(0));
    final maxPass = widget.picks
        .expand((pick) =>
            pick.options.map((option) => (option.play ?? pick.play).maxPass))
        .reduce(math.min);
    methods = PassMethod.available(widget.picks.length, maxPass);
    selectedMethods = [
      for (final item in methods)
        if (widget.initialPasses.any((pass) => pass.label == item.label)) item
    ];
    if (selectedMethods.isEmpty) selectedMethods = [methods.last];
    showCombinations = widget.initialShowCombinations;
    if (widget.initialResult != null) {
      result = widget.initialResult;
    } else {
      _recalculate();
    }
  }

  String get _passLabel => selectedMethods.map((item) => item.label).join('、');

  @override
  void dispose() {
    multipleController.dispose();
    budgetController.dispose();
    super.dispose();
  }

  void _recalculate() {
    try {
      final next = mode == _SchemeMode.normal
          ? const BettingEngine().calculateMultiple(
              picks: widget.picks,
              passes: selectedMethods,
              multiple: (int.tryParse(multipleController.text) ?? 1)
                  .clamp(1, BettingEngine.maxSchemeMultiple))
          : const BettingEngine().optimizeMultiple(
              picks: widget.picks,
              passes: selectedMethods,
              budget: double.tryParse(budgetController.text) ?? 0,
              mode: optimizeMode);
      setState(() {
        result = next;
        error = null;
      });
    } catch (exception) {
      setState(() {
        result = null;
        error = exception.toString().replaceFirst('Invalid argument(s): ', '');
      });
    }
  }

  int _multipleFor(BettingResult value, AtomicBet bet) => value.tickets
      .where((ticket) => identical(ticket.bet, bet))
      .fold(0, (sum, ticket) => sum + ticket.multiple);

  List<String> _betLines(AtomicBet bet) => bet.picks.map((item) {
        final match = item.match;
        final play = item.option.play ?? match.play;
        final marker = play == FootballPlay.hhad && match.handicap.isNotEmpty
            ? '${match.handicap}${item.option.label}'
            : _compactOptionLabel(play, item.option.label);
        return '${match.home}（$marker）';
      }).toList(growable: false);

  void _adjustMultiple(AtomicBet bet, int delta) {
    final current = result;
    if (current == null || !widget.optimizationOnly) return;
    final oldMultiple = _multipleFor(current, bet);
    final nextMultiple = oldMultiple + delta;
    if (nextMultiple < 1 || nextMultiple > BettingEngine.maxSchemeMultiple) {
      return;
    }
    final tickets = <SplitTicket>[
      for (final entry in current.returnsByCombination.keys)
        SplitTicket(
            bet: entry,
            multiple: identical(entry, bet)
                ? nextMultiple
                : _multipleFor(current, entry))
    ];
    final draft = BettingResult(current.atomicBets, tickets);
    final nextBudget = draft.amount.toStringAsFixed(0);
    budgetController.value = TextEditingValue(
      text: nextBudget,
      selection: TextSelection.collapsed(offset: nextBudget.length),
    );
    setState(() {
      result = BettingResult(current.atomicBets, tickets);
    });
  }

  String _compactDescription(AtomicBet bet) => bet.picks.map((item) {
        final number = item.match.number.replaceAll(RegExp(r'\s+'), '');
        final play = item.option.play ?? item.match.play;
        return '$number ${play.label}[${item.option.label}]';
      }).join(' × ');

  String _schemeText(BettingResult value) {
    final buffer = StringBuffer()
      ..writeln('竞球镜｜竞彩足球计算方案（非出票凭证）')
      ..writeln(
          '$_passLabel｜${value.notes}注｜${value.amount.toStringAsFixed(0)}元')
      ..writeln('预计奖金 ${_prizeText(value.minReturn, value.maxReturn)}');
    var index = 1;
    for (final entry in value.returnsByCombination.entries) {
      buffer.writeln(
          '${index++}. ${_compactDescription(entry.key)}｜${_multipleFor(value, entry.key)}倍｜${entry.value.toStringAsFixed(2)}元');
    }
    buffer.write('SP变化后请重新计算；本方案仅供计算参考。');
    return buffer.toString();
  }

  Map<String, dynamic> _serializePick(MatchPick pick) => {
        'matchId': pick.matchId,
        'number': pick.number,
        'home': pick.home,
        'away': pick.away,
        'league': pick.league,
        'kickoff': pick.kickoff?.toIso8601String(),
        'play': pick.play.name,
        'banker': pick.banker,
        'handicap': pick.handicap,
        'options': [
          for (final option in pick.options)
            {
              'label': option.label,
              'sp': option.sp,
              'play': (option.play ?? pick.play).name,
            }
        ],
        'availableOdds': {
          for (final entry in pick.availableOdds.entries)
            entry.key.name: entry.value,
        },
      };

  Future<void> _save(BettingResult value) async {
    final preferences = await SharedPreferences.getInstance();
    final saved =
        preferences.getStringList('saved_football_schemes') ?? <String>[];
    saved.insert(
        0,
        jsonEncode({
          'version': 5,
          'id': DateTime.now().microsecondsSinceEpoch.toString(),
          'createdAt': DateTime.now().toIso8601String(),
          'status': '已保存',
          'pass': _passLabel,
          'amount': value.amount,
          'notes': value.notes,
          'physicalTickets': value.isSplit ? value.tickets.length : 0,
          'isSplit': value.isSplit,
          'minReturn': value.minReturn,
          'maxReturn': value.maxReturn,
          'text': _schemeText(value),
          'multiple': int.tryParse(multipleController.text) ?? 1,
          'budget': double.tryParse(budgetController.text),
          'optimizationOnly': widget.optimizationOnly,
          'passes': selectedMethods.map((item) => item.label).toList(),
          'picks': widget.picks.map(_serializePick).toList(),
          'combinations': [
            for (final entry in value.returnsByCombination.entries)
              {
                'multiple': _multipleFor(value, entry.key),
                'picks': [
                  for (final item in entry.key.picks)
                    {
                      'matchId': item.match.matchId,
                      'play': (item.option.play ?? item.match.play).name,
                      'label': item.option.label,
                      'sp': item.option.sp,
                    }
                ],
              }
          ],
        }));
    await preferences.setStringList(
        'saved_football_schemes', saved.take(30).toList());
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('方案已保存到本机')));
    }
  }

  Future<void> _shareSchemeImage(BettingResult value) async {
    if (isSharing) return;
    setState(() => isSharing = true);
    try {
      const width = 1080.0;
      const horizontal = 72.0;
      final body = TextPainter(
        text: TextSpan(
          text: _schemeText(value),
          style: const TextStyle(
            color: Color(0xff202522),
            fontSize: 30,
            height: 1.55,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width - horizontal * 2);
      final height = math.max(1200.0, body.height + 360).ceil();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.white, BlendMode.src);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, width, 190),
        Paint()..color = const Color(0xff168f62),
      );
      final title = TextPainter(
        text: const TextSpan(
          text: '竞球镜·方案分享',
          style: TextStyle(
            color: Colors.white,
            fontSize: 48,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width - horizontal * 2);
      title.paint(canvas, const Offset(horizontal, 62));
      body.paint(canvas, const Offset(horizontal, 250));
      final picture = recorder.endRecording();
      final image = await picture.toImage(width.ceil(), height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('分享图片生成失败');
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}/jingqiujing_scheme_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: '竞球镜·方案分享',
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('分享图片生成失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => isSharing = false);
    }
  }

  Widget _parameters() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          if (!widget.optimizationOnly) ...[
            InputDecorator(
                decoration: const InputDecoration(
                    labelText: '过关方式', border: OutlineInputBorder()),
                child: Text(_passLabel)),
            const SizedBox(height: 12),
          ],
          if (mode == _SchemeMode.normal)
            TextField(
                controller: multipleController,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => _recalculate(),
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                decoration: const InputDecoration(
                    isDense: true,
                    labelText: '方案倍数',
                    suffixText: '倍（最高10000）',
                    border: OutlineInputBorder()))
          else ...[
            TextField(
                controller: budgetController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.done,
                onChanged: (_) => _recalculate(),
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                decoration: const InputDecoration(
                    isDense: true,
                    labelText: '优化预算',
                    suffixText: '元',
                    border: OutlineInputBorder())),
            const SizedBox(height: 10),
            Row(children: [
              _optimizeButton(OptimizeMode.balanced, '平均'),
              _optimizeButton(OptimizeMode.hot, '博热'),
              _optimizeButton(OptimizeMode.cold, '博冷'),
            ]),
            const SizedBox(height: 7),
            Text(
                switch (optimizeMode) {
                  OptimizeMode.balanced => '尽量让各组合中奖回报接近',
                  OptimizeMode.hot => '将预算增量集中到低SP组合',
                  OptimizeMode.cold => '将预算增量集中到高SP组合',
                },
                style: const TextStyle(fontSize: 11, color: Color(0xff858d89)))
          ]
        ]),
      );

  Widget _optimizeButton(OptimizeMode value, String label) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: ChoiceChip(
              label: SizedBox(
                  width: double.infinity,
                  child: Text(label, textAlign: TextAlign.center)),
              selected: optimizeMode == value,
              selectedColor: const Color(0xffdff3e9),
              labelStyle: TextStyle(
                  color:
                      optimizeMode == value ? _green : const Color(0xff656d69)),
              onSelected: (_) {
                setState(() => optimizeMode = value);
                _recalculate();
              }),
        ),
      );

  String _kickoffLabel(MatchPick pick) {
    final value = pick.kickoff;
    if (value == null) return '--';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
  }

  String _earliestKickoff() {
    final values = widget.picks
        .map((pick) => pick.kickoff)
        .whereType<DateTime>()
        .toList(growable: false)
      ..sort();
    if (values.isEmpty) return '--';
    final value = values.first;
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
  }

  String _compactOptionLabel(FootballPlay play, String label) {
    if (play == FootballPlay.ttg) {
      return label.endsWith('球') ? label : '$label球';
    }
    if (play == FootballPlay.hafu && !label.contains('/')) {
      final compact = label.replaceAll(RegExp(r'\s+'), '');
      if (compact.length == 2) {
        return '${compact[0]}/${compact[1]}';
      }
    }
    return label;
  }

  Set<String> _selectedLabels(MatchPick pick, FootballPlay play) => pick.options
      .where((option) => (option.play ?? pick.play) == play)
      .map((option) => option.label)
      .toSet();

  Widget _resultOddsRow(MatchPick pick, FootballPlay play) {
    final odds = pick.availableOdds[play] ?? const <String, double>{};
    if (odds.isEmpty) return const SizedBox.shrink();
    final selected = _selectedLabels(pick, play);
    final marker = play == FootballPlay.hhad
        ? (pick.handicap.isEmpty ? '让' : pick.handicap)
        : '0';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        SizedBox(
            width: 30,
            child: Text(marker,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11,
                    color: play == FootballPlay.hhad
                        ? const Color(0xff168f62)
                        : const Color(0xff8a918e),
                    fontWeight: FontWeight.w600))),
        for (final label in const ['胜', '平', '负'])
          Expanded(
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Container(
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: selected.contains(label)
                            ? const Color(0xff168f62)
                            : const Color(0xfff3f5f4),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                            color: selected.contains(label)
                                ? const Color(0xff168f62)
                                : const Color(0xffe3e7e5))),
                    child: Text(
                        '$label ${odds[label]?.toStringAsFixed(2) ?? '--'}',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: selected.contains(label)
                                ? Colors.white
                                : const Color(0xff8b928f),
                            fontWeight: selected.contains(label)
                                ? FontWeight.w600
                                : FontWeight.w400)),
                  )))
      ]),
    );
  }

  Widget _otherPlaySelections(MatchPick pick) {
    final options = pick.options.where((option) {
      final play = option.play ?? pick.play;
      return play != FootballPlay.had && play != FootballPlay.hhad;
    }).toList(growable: false);
    if (options.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 7, left: 30),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final option in options)
          Container(
              width: 104,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: const Color(0xff168f62),
                  border: Border.all(color: const Color(0xff168f62)),
                  borderRadius: BorderRadius.circular(4)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(
                    _compactOptionLabel(option.play ?? pick.play, option.label),
                    style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(option.sp.toStringAsFixed(2),
                    style:
                        const TextStyle(fontSize: 11, color: Color(0xffe8f7f0)))
              ]))
      ]),
    );
  }

  Widget _schemeOverview(BettingResult value) => Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          Row(children: [
            const Text('金额',
                style: TextStyle(fontSize: 12, color: Color(0xff7d8581))),
            const SizedBox(width: 7),
            Text('${value.amount.toStringAsFixed(0)}元',
                style: const TextStyle(
                    fontSize: 16,
                    color: Color(0xff303733),
                    fontWeight: FontWeight.w700)),
            const SizedBox(width: 5),
            Text('[${widget.initialMultiple}倍]',
                style: const TextStyle(fontSize: 11, color: Color(0xff7d8581))),
            const Spacer(),
            const Text('最高奖金',
                style: TextStyle(fontSize: 11, color: Color(0xff7d8581))),
            const SizedBox(width: 6),
            Text('${value.maxReturn.toStringAsFixed(2)}元',
                style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xffdf4162),
                    fontWeight: FontWeight.w700)),
          ]),
          const Divider(height: 20),
          Row(children: [
            const Text('竞彩足球',
                style: TextStyle(
                    fontSize: 12,
                    color: Color(0xff168f62),
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text('${widget.picks.length}场  $_passLabel',
                style: const TextStyle(fontSize: 12, color: Color(0xff4f5753))),
            const Spacer(),
            Text('${value.notes}注',
                style: const TextStyle(fontSize: 11, color: Color(0xff7d8581)))
          ])
        ]),
      );

  Widget _ticketCards() => Column(children: [
        for (final pick in widget.picks)
          Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.fromLTRB(13, 9, 13, 10),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              Row(children: [
                Text(pick.number,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xff7c8480))),
                const SizedBox(width: 7),
                Text(pick.league,
                    style: const TextStyle(
                        fontSize: 12,
                        color: _green,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(_kickoffLabel(pick),
                    style:
                        const TextStyle(fontSize: 12, color: Color(0xff8a918e)))
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: Text(pick.home,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700))),
                const SizedBox(
                    width: 54,
                    child: Text('VS',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(fontSize: 13, color: Color(0xff9ba19e)))),
                Expanded(
                    child: Text(pick.away,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)))
              ]),
              _resultOddsRow(pick, FootballPlay.had),
              _resultOddsRow(pick, FootballPlay.hhad),
              _otherPlaySelections(pick)
            ]),
          )
      ]);

  Widget _summary(BettingResult value) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('$_passLabel · ${value.notes}注',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const Spacer(),
            Text('${value.amount.toStringAsFixed(0)}元',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))
          ]),
          const SizedBox(height: 9),
          const Text('预计奖金',
              style: TextStyle(fontSize: 12, color: Color(0xff7d8581))),
          const SizedBox(height: 2),
          Text(_prizeText(value.minReturn, value.maxReturn),
              style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xffdf4162),
                  fontWeight: FontWeight.w700)),
          if (widget.optimizationOnly) ...[
            const SizedBox(height: 8),
            Builder(builder: (_) {
              final budget = double.tryParse(budgetController.text) ?? 0;
              final remaining = math.max(0, budget - value.amount);
              return Text(
                  '预算${budget.toStringAsFixed(0)}元  ·  已分配${value.amount.toStringAsFixed(0)}元  ·  剩余${remaining.toStringAsFixed(0)}元',
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xff7d8581)));
            })
          ],
        ]),
      );

  Widget _combinations(BettingResult value) {
    final entries = value.returnsByCombination.entries.toList();
    return Container(
      color: Colors.white,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
                widget.optimizationOnly
                    ? '${entries.length}个组合 · 共${value.notes}注'
                    : '组合明细（${entries.length}）',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700))),
        for (var index = 0; index < entries.length; index++)
          Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              decoration: const BoxDecoration(
                  border: Border(
                      top: BorderSide(color: Color(0xffedf0ee), width: .7))),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                    width: 26,
                    child: Text('${index + 1}',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xff969d99)))),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      for (final line in _betLines(entries[index].key))
                        Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(line,
                                style: const TextStyle(
                                    fontSize: 12.5, height: 1.3))),
                      if (!widget.optimizationOnly) ...[
                        const SizedBox(height: 5),
                        Text('${_multipleFor(value, entries[index].key)}倍',
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xff858d89)))
                      ]
                    ])),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (widget.optimizationOnly)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      _stepButton(Icons.remove,
                          () => _adjustMultiple(entries[index].key, -1)),
                      Container(
                          width: 48,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                              border: Border.symmetric(
                                  horizontal:
                                      BorderSide(color: Color(0xffdfe4e1)))),
                          child: Text(
                              '${_multipleFor(value, entries[index].key)}倍',
                              maxLines: 1,
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.w600))),
                      _stepButton(Icons.add,
                          () => _adjustMultiple(entries[index].key, 1)),
                    ]),
                  if (widget.optimizationOnly) const SizedBox(height: 6),
                  Text('${entries[index].value.toStringAsFixed(2)}元',
                      style: const TextStyle(
                          color: Color(0xffdf4162),
                          fontSize: 12,
                          fontWeight: FontWeight.w700))
                ])
              ]))
      ]),
    );
  }

  Widget _stepButton(IconData icon, VoidCallback onPressed) => SizedBox(
        width: 34,
        height: 30,
        child: IconButton(
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
                shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                    side: BorderSide(color: Color(0xffdfe4e1)))),
            onPressed: onPressed,
            icon: Icon(icon, size: 16)),
      );

  Widget _combinationToggle(BettingResult value) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => showCombinations = !showCombinations),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            child: Row(children: [
              const Icon(Icons.receipt_long_outlined,
                  size: 18, color: Color(0xff6f7874)),
              const SizedBox(width: 9),
              Text(showCombinations ? '收起组合明细' : '展开组合明细',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('${value.returnsByCombination.length}个组合',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xff7d8581))),
              const SizedBox(width: 3),
              Icon(
                  showCombinations
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 20,
                  color: const Color(0xff7d8581))
            ]),
          ),
        ),
      );

  Widget _validityHint() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Center(
          child: Text('最早开赛 ${_earliestKickoff()}  ·  SP以保存时为准',
              style: const TextStyle(fontSize: 11, color: Color(0xff858d89))),
        ),
      );

  Widget _bottomActions(BettingResult? value) => SafeArea(
        top: false,
        child: Container(
            height: 64,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(
                    top: BorderSide(color: Color(0xffe5e9e7), width: .7))),
            child: Row(children: [
              Expanded(
                  child: TextButton.icon(
                      onPressed: value == null || isSharing
                          ? null
                          : () => _shareSchemeImage(value),
                      icon: isSharing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.ios_share_outlined, size: 19),
                      label: Text(isSharing ? '生成中' : '分享'))),
              const SizedBox(width: 6),
              Expanded(
                  flex: 2,
                  child: FilledButton(
                      onPressed: value == null ? null : () => _save(value),
                      style: FilledButton.styleFrom(backgroundColor: _green),
                      child: const Text('保存方案')))
            ])),
      );

  Widget _optimizationBottom(BettingResult? value) => SafeArea(
        top: false,
        child: Container(
            height: 64,
            padding: const EdgeInsets.fromLTRB(80, 8, 12, 8),
            decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(
                    top: BorderSide(color: Color(0xffe5e9e7), width: .7))),
            child: FilledButton(
                onPressed: value == null
                    ? null
                    : () async {
                        await _save(value);
                        if (!mounted) return;
                        await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => _SchemePage(
                                  picks: widget.picks,
                                  initialPasses: selectedMethods,
                                  initialBudget: value.amount,
                                  initialResult: value,
                                  initialShowCombinations: true,
                                )));
                      },
                style: FilledButton.styleFrom(backgroundColor: _green),
                child: const Text('保存优化方案'))),
      );

  @override
  Widget build(BuildContext context) {
    final value = result;
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          title: Text(widget.optimizationOnly ? '奖金优化' : '竞球镜·方案分享',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
            children: [
              if (widget.optimizationOnly) _parameters(),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!,
                    style:
                        const TextStyle(fontSize: 12, color: Color(0xffdc4560)))
              ],
              if (value != null) ...[
                if (widget.optimizationOnly) ...[
                  const SizedBox(height: 10),
                  _summary(value),
                ] else ...[
                  _schemeOverview(value),
                  const SizedBox(height: 10),
                  _ticketCards(),
                  const SizedBox(height: 2),
                  _validityHint(),
                  const SizedBox(height: 8),
                  _combinationToggle(value),
                ],
                if (widget.optimizationOnly || showCombinations) ...[
                  const SizedBox(height: 10),
                  _combinations(value),
                ],
                const SizedBox(height: 10),
                const Center(
                    child: Text('预计奖金仅供参考，SP变化后请重新计算',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xff8b928f))))
              ]
            ]),
      ),
      bottomNavigationBar: widget.optimizationOnly
          ? _optimizationBottom(value)
          : _bottomActions(value),
    );
  }
}

class _CalcSheet extends StatefulWidget {
  const _CalcSheet(
      {required this.picks,
      required this.initialPass,
      required this.initialMultiple});
  final List<MatchPick> picks;
  final PassMethod? initialPass;
  final int initialMultiple;
  @override
  State<_CalcSheet> createState() => _CalcSheetState();
}

class _CalcSheetState extends State<_CalcSheet> {
  final budget = TextEditingController(text: '100');
  late final TextEditingController multipleController;
  final shareCardKey = GlobalKey();
  late List<PassMethod> methods;
  late PassMethod method;
  int multiple = 1;
  OptimizeMode optimizeMode = OptimizeMode.balanced;
  BettingResult? result;
  String? error;
  @override
  void initState() {
    super.initState();
    multipleController =
        TextEditingController(text: widget.initialMultiple.toString());
    final max = widget.picks
        .expand((pick) =>
            pick.options.map((option) => (option.play ?? pick.play).maxPass))
        .reduce((a, b) => a < b ? a : b);
    methods = PassMethod.available(widget.picks.length, max);
    method = widget.initialPass != null &&
            methods.any((item) => item.label == widget.initialPass!.label)
        ? methods.firstWhere((item) => item.label == widget.initialPass!.label)
        : methods.lastWhere(
            (item) =>
                item.matches == 1 || item.displayLabel?.endsWith('串1') == true,
            orElse: () => methods.first);
    _run();
  }

  @override
  void dispose() {
    budget.dispose();
    multipleController.dispose();
    super.dispose();
  }

  void _run({bool optimize = false}) {
    multiple = int.tryParse(multipleController.text) ?? 1;
    try {
      final r = optimize
          ? const BettingEngine().optimize(
              picks: widget.picks,
              pass: method,
              budget: double.tryParse(budget.text) ?? 0,
              mode: optimizeMode)
          : const BettingEngine()
              .calculate(picks: widget.picks, pass: method, multiple: multiple);
      setState(() {
        result = r;
        error = null;
      });
    } catch (e) {
      setState(() {
        result = null;
        error = e.toString().replaceFirst('Invalid argument(s): ', '');
      });
    }
  }

  List<({AtomicBet bet, int multiple, int tickets, double prize})> _groups(
      BettingResult result) {
    return [
      for (final entry in result.returnsByCombination.entries)
        (
          bet: entry.key,
          multiple: result.tickets
              .where((ticket) => identical(ticket.bet, entry.key))
              .fold(0, (sum, ticket) => sum + ticket.multiple),
          tickets: result.tickets
              .where((ticket) => identical(ticket.bet, entry.key))
              .length,
          prize: entry.value,
        )
    ];
  }

  String _splitLabel(int multiple) {
    final full = multiple ~/ BettingEngine.maxTicketMultiple;
    final rest = multiple % BettingEngine.maxTicketMultiple;
    final parts = <String>[];
    if (full > 0) parts.add('50倍×$full张');
    if (rest > 0) parts.add('$rest倍×1张');
    return parts.join('＋');
  }

  String _earliestKickoffLabel() {
    final values = widget.picks
        .map((pick) => pick.kickoff)
        .whereType<DateTime>()
        .toList(growable: false)
      ..sort();
    if (values.isEmpty) return '--';
    final value = values.first;
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
  }

  String _text(BettingResult r) {
    final b = StringBuffer(
        '竞球镜｜竞彩足球计算方案（非出票凭证）\n${method.label}｜${r.notes}注｜${r.amount.toStringAsFixed(0)}元｜${r.isSplit ? '${r.tickets.length}张票' : '汇总方案（未拆票）'}\n最早开赛：${_earliestKickoffLabel()}\n预计奖金：${r.minReturn.toStringAsFixed(2)}～${r.maxReturn.toStringAsFixed(2)}元\n');
    final groups = _groups(r);
    for (var i = 0; i < groups.length; i++) {
      final group = groups[i];
      b.writeln(
          '${i + 1}. ${group.bet.description}\n   ${group.multiple}倍${r.isSplit ? '（${_splitLabel(group.multiple)}）' : ''} 预计${group.prize.toStringAsFixed(2)}元');
    }
    b.write(r.isSplit
        ? '共拆${r.tickets.length}张票。SP为保存时快照，变化后请重新计算；本方案不是彩票或出票凭证。'
        : '当前为汇总测算方案，尚未拆票。SP为保存时快照，变化后请重新计算；本方案不是彩票或出票凭证。');
    return b.toString();
  }

  Future<void> _save(BettingResult value) async {
    final preferences = await SharedPreferences.getInstance();
    final saved =
        preferences.getStringList('saved_football_schemes') ?? <String>[];
    final now = DateTime.now();
    saved.insert(
        0,
        jsonEncode({
          'version': 2,
          'id': now.microsecondsSinceEpoch.toString(),
          'createdAt': now.toIso8601String(),
          'status': '已保存',
          'pass': method.label,
          'amount': value.amount,
          'notes': value.notes,
          'physicalTickets': value.isSplit ? value.tickets.length : 0,
          'isSplit': value.isSplit,
          'minReturn': value.minReturn,
          'maxReturn': value.maxReturn,
          'text': _text(value),
        }));
    await preferences.setStringList(
        'saved_football_schemes', saved.take(30).toList());
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('方案已保存到本机')));
    }
  }

  Future<void> _shareImage(BettingResult value) async {
    final boundary = shareCardKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 2.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    final directory = await getTemporaryDirectory();
    final file = File(
        '${directory.path}/football_scheme_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: '竞彩足球计算方案（非出票凭证）',
      ),
    );
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Padding(
          padding: EdgeInsets.fromLTRB(
              18, 16, 18, 18 + MediaQuery.viewInsetsOf(context).bottom),
          child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                const Text('计算、优化与拆单',
                    style:
                        TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
                const SizedBox(height: 12),
                DropdownButtonFormField<PassMethod>(
                    initialValue: method,
                    decoration: const InputDecoration(
                        labelText: '过关方式', border: OutlineInputBorder()),
                    items: [
                      for (final x in methods)
                        DropdownMenuItem(value: x, child: Text(x.label))
                    ],
                    onChanged: (x) {
                      if (x != null) {
                        method = x;
                        _run();
                      }
                    }),
                Row(children: [
                  const Text('方案倍数'),
                  const SizedBox(width: 8),
                  SizedBox(
                      width: 92,
                      child: TextField(
                          controller: multipleController,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.done,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          onSubmitted: (_) {
                            _run();
                            FocusScope.of(context).unfocus();
                          },
                          decoration: const InputDecoration(
                              isDense: true,
                              suffixText: '倍',
                              helperText: '最高10000'))),
                  const Spacer(),
                  SizedBox(
                      width: 115,
                      child: TextField(
                          controller: budget,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => FocusScope.of(context).unfocus(),
                          decoration: const InputDecoration(labelText: '优化预算')))
                ]),
                const SizedBox(height: 10),
                SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                        onPressed: _run, child: const Text('按普通倍数计算'))),
                const SizedBox(height: 8),
                Row(children: [
                  for (final item in const [
                    (OptimizeMode.balanced, '平均优化'),
                    (OptimizeMode.hot, '博热优化'),
                    (OptimizeMode.cold, '博冷优化')
                  ]) ...[
                    Expanded(
                        child: FilledButton.tonal(
                            onPressed: () {
                              optimizeMode = item.$1;
                              _run(optimize: true);
                            },
                            style: FilledButton.styleFrom(
                                backgroundColor: optimizeMode == item.$1
                                    ? const Color(0xffd9f2e6)
                                    : const Color(0xfff3f5f4),
                                foregroundColor: optimizeMode == item.$1
                                    ? const Color(0xff087a4d)
                                    : const Color(0xff656d69)),
                            child: Text(item.$2,
                                style: const TextStyle(fontSize: 12)))),
                    if (item.$1 != OptimizeMode.cold) const SizedBox(width: 6)
                  ]
                ]),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
                if (result case final r?) ...[
                  const Divider(height: 28),
                  RepaintBoundary(
                    key: shareCardKey,
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('竞彩足球计算方案',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w900)),
                            Text(
                                '${method.label} · ${r.isSplit ? '已拆${r.tickets.length}张票' : '汇总方案（未拆票）'} · ${r.notes}注 · ${r.amount.toStringAsFixed(0)}元'),
                            Text('最早开赛 ${_earliestKickoffLabel()}',
                                style: const TextStyle(
                                    fontSize: 10, color: Color(0xff7e8682))),
                            Text(
                                '预计奖金 ${r.minReturn.toStringAsFixed(2)}～${r.maxReturn.toStringAsFixed(2)} 元',
                                style: const TextStyle(
                                    color: Color(0xffe23f67),
                                    fontWeight: FontWeight.w800)),
                            if (r.principalProtected != null)
                              Text(
                                  r.principalProtected!
                                      ? '全部组合已达到保本线'
                                      : '当前预算无法覆盖保本线，已按最低回收优先分配',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: r.principalProtected!
                                          ? const Color(0xff087a4d)
                                          : const Color(0xffe16a31))),
                            const Divider(),
                            for (var i = 0;
                                i < math.min(_groups(r).length, 40);
                                i++)
                              Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(() {
                                    final group = _groups(r)[i];
                                    return '${i + 1}. ${group.bet.description}\n   ${group.multiple}倍${r.isSplit ? '（${_splitLabel(group.multiple)}）' : ''}  ${group.prize.toStringAsFixed(2)}元';
                                  }(), style: const TextStyle(fontSize: 10))),
                            if (_groups(r).length > 40)
                              Text('另有 ${_groups(r).length - 40} 个组合，请查看文字方案',
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.grey)),
                            const Text('非彩票、非出票凭证｜SP变化后请重新计算',
                                style:
                                    TextStyle(fontSize: 9, color: Colors.grey)),
                          ]),
                    ),
                  ),
                  for (final entry in r.returnsByCombination.entries)
                    ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.confirmation_number_outlined,
                            size: 18),
                        title: Text(entry.key.description,
                            style: const TextStyle(fontSize: 12)),
                        subtitle: Text(
                            '${r.tickets.where((ticket) => identical(ticket.bet, entry.key)).fold<int>(0, (sum, ticket) => sum + ticket.multiple)}倍 · ${r.isSplit ? '拆${r.tickets.where((ticket) => identical(ticket.bet, entry.key)).length}张票' : '未拆票'}'),
                        trailing: Text(entry.value.toStringAsFixed(2),
                            style: const TextStyle(
                                color: Color(0xffd9445f),
                                fontWeight: FontWeight.w800))),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (!r.isSplit)
                      OutlinedButton.icon(
                          onPressed: () => setState(
                              () => result = const BettingEngine().split(r)),
                          icon: const Icon(Icons.call_split_outlined),
                          label: const Text('拆票')),
                    OutlinedButton.icon(
                        onPressed: () => _save(r),
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: const Text('保存')),
                    OutlinedButton.icon(
                        onPressed: () => _shareImage(r),
                        icon: const Icon(Icons.image_outlined),
                        label: const Text('分享图片')),
                  ]),
                  FilledButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _text(r)));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('方案文字已复制')));
                        }
                      },
                      icon: const Icon(Icons.share_outlined),
                      label: const Text('复制分享方案')),
                  const Text('仅作计算参考，不是彩票或出票凭证。',
                      style: TextStyle(fontSize: 11, color: Color(0xff858b90)))
                ]
              ])));
}

class _SavedSchemesSheet extends StatefulWidget {
  const _SavedSchemesSheet();

  @override
  State<_SavedSchemesSheet> createState() => _SavedSchemesSheetState();
}

class _SavedSchemesSheetState extends State<_SavedSchemesSheet> {
  List<String> rawItems = const [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      rawItems =
          preferences.getStringList('saved_football_schemes') ?? const [];
      loading = false;
    });
    await _settleSavedSchemes();
  }

  Map<String, dynamic> _decode(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is Map<String, dynamic>) return value;
    } catch (_) {}
    final firstBreak = raw.indexOf('\n');
    return {
      'createdAt': firstBreak > 0 ? raw.substring(0, firstBreak) : '',
      'status': '旧方案',
      'pass': '竞彩足球',
      'amount': null,
      'text': firstBreak > 0 ? raw.substring(firstBreak + 1) : raw,
    };
  }

  Future<void> _delete(int index) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('删除方案？'),
            content: const Text('删除后无法恢复。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('删除')),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final updated = [...rawItems]..removeAt(index);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList('saved_football_schemes', updated);
    if (mounted) setState(() => rawItems = updated);
  }

  String _time(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '');
    if (date == null) return '时间未知';
    return '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  bool _withinLastSevenDays(Map<String, dynamic> item) {
    final created = DateTime.tryParse(item['createdAt']?.toString() ?? '');
    return created != null &&
        !created.isBefore(DateTime.now().subtract(const Duration(days: 7)));
  }

  ({String label, Color background, Color foreground}) _statusStyle(
      Map<String, dynamic> item) {
    final settlement = item['settlement'];
    final state = settlement is Map ? settlement['state']?.toString() : '';
    if (state == 'won') {
      final prize = num.tryParse(settlement?['prize']?.toString() ?? '') ?? 0;
      return (
        label: '奖金${prize.toStringAsFixed(2)}元',
        background: const Color(0xffffedd2),
        foreground: const Color(0xffc76a00),
      );
    }
    if (state == 'lost') {
      return (
        label: '未中奖',
        background: const Color(0xffeef1ef),
        foreground: const Color(0xff7a827e),
      );
    }
    return (
      label: '待开奖',
      background: const Color(0xffe1f0ff),
      foreground: const Color(0xff2778ad),
    );
  }

  FootballPlay? _play(dynamic value) {
    final name = value?.toString();
    for (final play in FootballPlay.values) {
      if (play.name == name) return play;
    }
    return null;
  }

  List<MatchPick> _restorePicks(Map<String, dynamic> item) {
    final rawPicks = item['picks'];
    if (rawPicks is! List) return const [];
    final picks = <MatchPick>[];
    for (final raw in rawPicks) {
      if (raw is! Map) continue;
      final play = _play(raw['play']);
      final rawOptions = raw['options'];
      if (play == null || rawOptions is! List) continue;
      final options = <BetOption>[];
      for (final rawOption in rawOptions) {
        if (rawOption is! Map) continue;
        final sp = num.tryParse(rawOption['sp']?.toString() ?? '');
        if (sp == null || sp <= 0) continue;
        options.add(BetOption(
          label: rawOption['label']?.toString() ?? '',
          sp: sp.toDouble(),
          play: _play(rawOption['play']) ?? play,
        ));
      }
      if (options.isEmpty) continue;
      final availableOdds = <FootballPlay, Map<String, double>>{};
      final rawAvailable = raw['availableOdds'];
      if (rawAvailable is Map) {
        for (final entry in rawAvailable.entries) {
          final availablePlay = _play(entry.key);
          if (availablePlay == null || entry.value is! Map) continue;
          availableOdds[availablePlay] = {
            for (final odd in (entry.value as Map).entries)
              if (num.tryParse(odd.value?.toString() ?? '') != null)
                odd.key.toString(): num.parse(odd.value.toString()).toDouble(),
          };
        }
      }
      picks.add(MatchPick(
        matchId: raw['matchId']?.toString() ?? '',
        number: raw['number']?.toString() ?? '',
        home: raw['home']?.toString() ?? '',
        away: raw['away']?.toString() ?? '',
        league: raw['league']?.toString() ?? '',
        kickoff: DateTime.tryParse(raw['kickoff']?.toString() ?? ''),
        play: play,
        options: options,
        banker: raw['banker'] == true,
        handicap: raw['handicap']?.toString() ?? '',
        availableOdds: availableOdds,
      ));
    }
    return picks;
  }

  bool _isFinished(MatchItem match) =>
      match.matchState == MatchState.finished ||
      match.status == MatchStatus.finished ||
      (match.finalScore?.isNotEmpty ?? false);

  ({int home, int away})? _score(String? value) {
    final found =
        RegExp(r'^(\d+)\s*[:\-]\s*(\d+)$').firstMatch(value?.trim() ?? '');
    if (found == null) return null;
    return (home: int.parse(found.group(1)!), away: int.parse(found.group(2)!));
  }

  String _outcome(int home, int away,
          {String win = '胜', String draw = '平', String lose = '负'}) =>
      home > away
          ? win
          : home == away
              ? draw
              : lose;

  String? _winningLabel(MatchItem match, FootballPlay play) {
    final score = _score(match.finalScore);
    if (score == null) return null;
    switch (play) {
      case FootballPlay.had:
        return _outcome(score.home, score.away);
      case FootballPlay.hhad:
        final handicap =
            double.tryParse(match.hhad['让球']?.toString() ?? '') ?? 0;
        return _outcome(score.home + handicap.round(), score.away,
            win: '让胜', draw: '让平', lose: '让负');
      case FootballPlay.ttg:
        final total = score.home + score.away;
        return total >= 7 ? '7+' : '$total';
      case FootballPlay.crs:
        final direct = '${score.home}:${score.away}';
        if (match.crs.containsKey(direct)) return direct;
        return _outcome(score.home, score.away,
            win: '胜其他', draw: '平其他', lose: '负其他');
      case FootballPlay.hafu:
        final half = _score(match.halfTimeScore);
        if (half == null) return null;
        return '${_outcome(half.home, half.away)}${_outcome(score.home, score.away)}';
    }
  }

  bool _optionWins(String option, String winner, FootballPlay play) {
    if (option == winner) return true;
    if (play == FootballPlay.hhad) {
      return switch (winner) {
        '让胜' => option == '胜',
        '让平' => option == '平',
        '让负' => option == '负',
        _ => false,
      };
    }
    return false;
  }

  Future<void> _settleSavedSchemes() async {
    final decoded = rawItems.map(_decode).toList(growable: false);
    final pending = decoded.where((item) {
      final settlement = item['settlement'];
      return item['combinations'] is List &&
          !(settlement is Map && settlement['state'] != 'pending');
    }).toList(growable: false);
    if (pending.isEmpty) return;
    final ids = <String>{
      for (final item in pending)
        for (final pick
            in (item['picks'] is List ? item['picks'] as List : const []))
          if (pick is Map && pick['matchId']?.toString().isNotEmpty == true)
            pick['matchId'].toString(),
    };
    if (ids.isEmpty) return;
    final client = CaiApiClient();
    final matches = <String, MatchItem>{};
    try {
      await Future.wait(ids.map((id) async {
        try {
          matches[id] = await client.fetchMatch(id);
        } catch (_) {
          // Keep this plan pending until the next time the saved list is opened.
        }
      }));
    } finally {
      client.close();
    }
    var changed = false;
    final updated = <String>[];
    for (final raw in rawItems) {
      final item = _decode(raw);
      if (item['combinations'] is! List ||
          (item['settlement'] is Map &&
              item['settlement']['state'] != 'pending')) {
        updated.add(raw);
        continue;
      }
      final picks = item['picks'] is List ? item['picks'] as List : const [];
      final matchIds = [
        for (final pick in picks)
          if (pick is Map) pick['matchId']?.toString() ?? '',
      ].where((id) => id.isNotEmpty).toSet();
      if (matchIds.isEmpty ||
          !matchIds.every(
              (id) => matches[id] != null && _isFinished(matches[id]!))) {
        updated.add(raw);
        continue;
      }
      final winners = <String, Map<String, String>>{};
      for (final pick in picks.whereType<Map>()) {
        final match = matches[pick['matchId']?.toString()];
        if (match == null) continue;
        final labels = <String, String>{};
        for (final rawOption
            in (pick['options'] is List ? pick['options'] as List : const [])) {
          if (rawOption is! Map) continue;
          final play = _play(rawOption['play']);
          if (play == null) continue;
          final winner = _winningLabel(match, play);
          if (winner != null) labels[play.name] = winner;
        }
        winners[pick['matchId']?.toString() ?? ''] = labels;
      }
      var prize = 0.0;
      for (final combination in item['combinations'] as List) {
        if (combination is! Map || combination['picks'] is! List) continue;
        var wins = true;
        var spProduct = 1.0;
        for (final rawPick in combination['picks'] as List) {
          if (rawPick is! Map) continue;
          final play = _play(rawPick['play']);
          if (play == null) {
            wins = false;
            break;
          }
          final winner = winners[rawPick['matchId']?.toString()]?[play.name];
          if (winner == null ||
              !_optionWins(rawPick['label']?.toString() ?? '', winner, play)) {
            wins = false;
            break;
          }
          spProduct *=
              num.tryParse(rawPick['sp']?.toString() ?? '')?.toDouble() ?? 0;
        }
        if (wins) {
          prize += 2 *
              spProduct *
              (num.tryParse(combination['multiple']?.toString() ?? '')
                      ?.toDouble() ??
                  0);
        }
      }
      final outcomes = <String, dynamic>{
        for (final id in matchIds)
          id: {
            'score': matches[id]?.finalScore ?? matches[id]?.score ?? '--',
            'winners': winners[id] ?? const <String, String>{},
          }
      };
      item['settlement'] = {
        'state': prize > 0 ? 'won' : 'lost',
        'prize': double.parse(prize.toStringAsFixed(2)),
        'settledAt': DateTime.now().toIso8601String(),
        'outcomes': outcomes,
      };
      item['status'] = prize > 0 ? '已中奖' : '未中奖';
      updated.add(jsonEncode(item));
      changed = true;
    }
    if (!changed) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList('saved_football_schemes', updated);
    if (mounted) setState(() => rawItems = updated);
  }

  Future<void> _openScheme(Map<String, dynamic> item) async {
    final picks = _restorePicks(item);
    if (picks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('旧方案缺少结构化选号数据，可先复制文字查看')),
      );
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SavedSchemeDetailPage(item: item),
    ));
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .82,
      maxChildSize: .95,
      builder: (_, controller) => Column(children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
                child: Row(children: [
                  const Expanded(
                      child: Text('保存方案',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w900))),
                  IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close))
                ])),
            const Divider(height: 1),
            Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : rawItems
                            .where((raw) => _withinLastSevenDays(_decode(raw)))
                            .isEmpty
                        ? const Center(child: Text('最近7天暂无保存方案'))
                        : ListView.separated(
                            controller: controller,
                            padding: const EdgeInsets.all(12),
                            itemCount: rawItems
                                .where(
                                    (raw) => _withinLastSevenDays(_decode(raw)))
                                .length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, index) {
                              final visible = rawItems
                                  .where((raw) =>
                                      _withinLastSevenDays(_decode(raw)))
                                  .toList(growable: false);
                              final raw = visible[index];
                              final item = _decode(raw);
                              final amount = item['amount'];
                              final status = _statusStyle(item);
                              return Card(
                                  elevation: 0,
                                  color: const Color(0xfff6f8f7),
                                  child: InkWell(
                                      onTap: () => _openScheme(item),
                                      borderRadius: BorderRadius.circular(12),
                                      child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(children: [
                                                  Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 8,
                                                          vertical: 3),
                                                      decoration: BoxDecoration(
                                                          color:
                                                              status.background,
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(
                                                                      12)),
                                                      child: Text(status.label,
                                                          style: TextStyle(
                                                              color: status
                                                                  .foreground,
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700))),
                                                  const Spacer(),
                                                  Text(_time(item['createdAt']),
                                                      style: const TextStyle(
                                                          fontSize: 11,
                                                          color: Color(
                                                              0xff858d89)))
                                                ]),
                                                const SizedBox(height: 8),
                                                Text(
                                                    '${item['pass'] ?? '竞彩足球'}${amount == null ? '' : ' · ${((amount as num).toDouble()).toStringAsFixed(0)}元'}',
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w900)),
                                                if (item['physicalTickets'] !=
                                                    null)
                                                  Text(
                                                      '${item['notes']}注 · ${item['physicalTickets']}张票 · 奖金${(item['minReturn'] as num).toStringAsFixed(2)}～${(item['maxReturn'] as num).toStringAsFixed(2)}元',
                                                      style: const TextStyle(
                                                          fontSize: 11,
                                                          color: Color(
                                                              0xff6f7773))),
                                                Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment.end,
                                                    children: [
                                                      TextButton.icon(
                                                          onPressed: () async {
                                                            await Clipboard.setData(
                                                                ClipboardData(
                                                                    text: item['text']
                                                                            ?.toString() ??
                                                                        ''));
                                                            if (context
                                                                .mounted) {
                                                              ScaffoldMessenger
                                                                      .of(
                                                                          context)
                                                                  .showSnackBar(
                                                                      const SnackBar(
                                                                          content:
                                                                              Text('方案文字已复制')));
                                                            }
                                                          },
                                                          icon: const Icon(
                                                              Icons
                                                                  .copy_outlined,
                                                              size: 16),
                                                          label:
                                                              const Text('复制')),
                                                      TextButton.icon(
                                                          onPressed: () =>
                                                              _delete(rawItems
                                                                  .indexOf(
                                                                      raw)),
                                                          icon: const Icon(
                                                              Icons
                                                                  .delete_outline,
                                                              size: 16),
                                                          label:
                                                              const Text('删除'))
                                                    ])
                                              ]))));
                            }))
          ]));
}

class _SavedSchemeDetailPage extends StatelessWidget {
  const _SavedSchemeDetailPage({required this.item});

  final Map<String, dynamic> item;

  String _winner(Map<String, dynamic> outcomes, String matchId, String play) {
    final outcome = outcomes[matchId];
    if (outcome is! Map) return '';
    final winners = outcome['winners'];
    return winners is Map ? winners[play]?.toString() ?? '' : '';
  }

  bool _isWinningOption(String label, String winner, String play) {
    if (label == winner) return true;
    if (play == FootballPlay.hhad.name) {
      return (winner == '让胜' && label == '胜') ||
          (winner == '让平' && label == '平') ||
          (winner == '让负' && label == '负');
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final settlement = item['settlement'];
    final state = settlement is Map ? settlement['state']?.toString() : '';
    final prize = settlement is Map
        ? num.tryParse(settlement['prize']?.toString() ?? '')
        : null;
    final outcomes = settlement is Map && settlement['outcomes'] is Map
        ? Map<String, dynamic>.from(settlement['outcomes'] as Map)
        : const <String, dynamic>{};
    final picks = item['picks'] is List ? item['picks'] as List : const [];
    final statusColor = state == 'won'
        ? const Color(0xffc76a00)
        : state == 'lost'
            ? const Color(0xff767e7a)
            : const Color(0xff2778ad);
    final statusLabel = state == 'won'
        ? '实际税前奖金 ${prize?.toStringAsFixed(2) ?? '--'} 元'
        : state == 'lost'
            ? '未中奖'
            : '待开奖';
    return Scaffold(
      backgroundColor: const Color(0xfff5f7f6),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('保存方案详情',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(8)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item['pass']?.toString() ?? '竞彩足球',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 5),
              Text(
                  '${item['notes'] ?? '--'}注 · 投入${num.tryParse(item['amount']?.toString() ?? '')?.toStringAsFixed(0) ?? '--'}元',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xff737b77))),
              const SizedBox(height: 10),
              Text(statusLabel,
                  style: TextStyle(
                      color: statusColor,
                      fontSize: 18,
                      fontWeight: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 12),
          for (final rawPick in picks.whereType<Map>()) ...[
            Builder(builder: (_) {
              final pick = Map<String, dynamic>.from(rawPick);
              final matchId = pick['matchId']?.toString() ?? '';
              final outcome = outcomes[matchId];
              final score =
                  outcome is Map ? outcome['score']?.toString() ?? '--' : '--';
              final options =
                  pick['options'] is List ? pick['options'] as List : const [];
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(pick['number']?.toString() ?? '--',
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(
                                '${pick['home'] ?? '--'}  $score  ${pick['away'] ?? '--'}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800))),
                      ]),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final rawOption in options.whereType<Map>())
                            Builder(builder: (_) {
                              final option =
                                  Map<String, dynamic>.from(rawOption);
                              final play = option['play']?.toString() ?? '';
                              final winner = _winner(outcomes, matchId, play);
                              final won = _isWinningOption(
                                  option['label']?.toString() ?? '',
                                  winner,
                                  play);
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: winner.isEmpty
                                      ? const Color(0xfff1f4f2)
                                      : won
                                          ? const Color(0xffffe6e6)
                                          : const Color(0xffeef1ef),
                                  border: Border.all(
                                      color: winner.isEmpty
                                          ? const Color(0xffdfe5e1)
                                          : won
                                              ? const Color(0xffdf6971)
                                              : const Color(0xffe0e4e1)),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                    '${option['label']}  ${option['sp']}',
                                    style: TextStyle(
                                        color: won
                                            ? const Color(0xffc83d46)
                                            : const Color(0xff646c68),
                                        fontWeight: won
                                            ? FontWeight.w800
                                            : FontWeight.w500)),
                              );
                            })
                        ],
                      )
                    ]),
              );
            }),
          ]
        ],
      ),
    );
  }
}
