import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'betting_engine.dart';
import 'models.dart';
import 'saved_scheme_store.dart';

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
  const SelectionPage({this.focusMatchId, super.key});

  /// When opened from match details, open this fixture's play sheet directly.
  final String? focusMatchId;

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
  Timer? draftSaveTimer;
  bool refreshInFlight = false;
  bool restoringDraft = false;
  Set<String>? restoredPassLabels;
  Map<String, String> selectionIssues = const {};
  List<PassMethod> quickPasses = const [];
  int quickMultiple = 1;
  _SelectionViewMode viewMode = _SelectionViewMode.mixed;
  bool didHandleFocusedMatch = false;

  @override
  void initState() {
    super.initState();
    _restoreDraft();
    _refresh();
    expiryTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      final expiredIds = matches
          .where((match) => !match.kickoff.isAfter(now))
          .map((match) => match.id)
          .toSet();
      if (expiredIds.isNotEmpty) {
        final previousIssues = selectionIssues;
        setState(() {
          matches = matches
              .where((match) => !expiredIds.contains(match.id))
              .toList(growable: false);
          selectionIssues = {
            ...selectionIssues,
            for (final id in expiredIds)
              if (drafts[id]?.hasSelection == true)
                'match:$id': '${_matchLabel(id)}已开赛或停售，原选号已暂存，请重新确认',
          };
          _reconcileQuickPass();
        });
        _announceSelectionIssues(selectionIssues, previousIssues);
      }
      _refresh(silent: true);
    });
  }

  @override
  void dispose() {
    expiryTimer?.cancel();
    draftSaveTimer?.cancel();
    client.close();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (refreshInFlight) return;
    refreshInFlight = true;
    if (mounted && !silent) setState(() => loading = true);
    try {
      final previousMatches = {
        for (final match in matches) match.id: match,
      };
      final previousIssues = selectionIssues;
      final data = await client.fetchBettableMatches();
      if (mounted) {
        final now = DateTime.now();
        final refreshed = data
            .whereType<Map<String, dynamic>>()
            .map(MatchItem.fromJson)
            .where(
              (match) =>
                  match.matchState == MatchState.notStarted &&
                  match.bettingStatus == BettingStatus.open &&
                  match.kickoff.isAfter(now) &&
                  FootballPlay.values.any((play) => _enabled(match, play)),
            )
            .toList()
          ..sort(_compareMatchNumber);
        final activeIds = refreshed.map((match) => match.id).toSet();
        final issues = await _reconcileSelectionIssues(
          previousMatches: previousMatches,
          refreshed: refreshed,
          activeIds: activeIds,
        );
        setState(() {
          matches = refreshed;
          selectionIssues = issues;
          if (restoredPassLabels != null) {
            quickPasses = _passesForLabels(
              _quickMethods(picks),
              restoredPassLabels!,
            );
            restoredPassLabels = null;
          }
          _reconcileQuickPass();
          loadError = null;
        });
        _announceSelectionIssues(issues, previousIssues);
        if (restoringDraft) {
          restoringDraft = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已恢复暂存选号')),
            );
          });
        }
        _openFocusedMatchIfNeeded(refreshed);
      }
    } catch (error) {
      debugPrint('选号数据加载失败: $error');
      if (mounted && !silent) {
        setState(() => loadError = error.toString());
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('比赛数据加载失败')));
      }
    } finally {
      if (mounted && !silent) setState(() => loading = false);
      refreshInFlight = false;
    }
  }

  String _matchLabel(String id) {
    for (final match in matches) {
      if (match.id == id) {
        return '${match.number} ${match.home} VS ${match.away}';
      }
    }
    return '该场比赛';
  }

  Future<Map<String, String>> _reconcileSelectionIssues({
    required Map<String, MatchItem> previousMatches,
    required List<MatchItem> refreshed,
    required Set<String> activeIds,
  }) async {
    final next = <String, String>{};
    final refreshedById = {for (final match in refreshed) match.id: match};
    final selectedIds = drafts.entries
        .where((entry) => entry.value.hasSelection)
        .map((entry) => entry.key)
        .toSet();
    final missingIds = selectedIds.difference(activeIds);
    for (final id in missingIds) {
      MatchItem? detail;
      try {
        detail = await client.fetchMatch(id);
      } catch (_) {
        detail = null;
      }
      final previous = previousMatches[id];
      final label = previous == null
          ? '该场比赛'
          : '${previous.number} ${previous.home} VS ${previous.away}';
      final isStillBettable = detail != null &&
          detail.matchState == MatchState.notStarted &&
          detail.bettingStatus == BettingStatus.open &&
          detail.kickoff.isAfter(DateTime.now()) &&
          FootballPlay.values.any((play) => _enabled(detail!, play));
      next['match:$id'] = isStillBettable
          ? '$label最新数据暂未返回，原选号已保留，暂不能生成方案'
          : '$label已停售或已开赛，原选号已暂存，请重新选择';
    }
    for (final entry in drafts.entries) {
      final match = refreshedById[entry.key];
      final draft = entry.value;
      if (match == null || !draft.hasSelection) continue;
      for (final selected in draft.selected.entries) {
        final odds = _odds(match, selected.key);
        final playEnabled = _enabled(match, selected.key);
        if (!playEnabled) {
          next['play:${entry.key}:${selected.key.name}'] =
              '${match.number}的${selected.key.label}已停售，原选号已暂存';
          continue;
        }
        for (final option in selected.value) {
          if (odds[option] == null) {
            next['option:${entry.key}:${selected.key.name}:$option'] =
                '${match.number}已选“${_playOptionLabel(selected.key, option)}”，但该 SP 选项已消失，请重新选择';
          }
        }
      }
    }
    return next;
  }

  void _announceSelectionIssues(
    Map<String, String> next,
    Map<String, String> previous,
  ) {
    final added = next.keys.where((key) => !previous.containsKey(key)).toList();
    if (added.isEmpty || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(next[added.first] ?? '部分选号状态已变化，请重新确认'),
            duration: const Duration(seconds: 4),
          ),
        );
    });
  }

  FootballPlay? _playFromName(Object? value) {
    final name = value?.toString();
    for (final play in FootballPlay.values) {
      if (play.name == name) return play;
    }
    return null;
  }

  List<PassMethod> _passesForLabels(
    List<PassMethod> methods,
    Set<String> labels,
  ) =>
      methods
          .where(
            (method) =>
                labels.contains(method.label) ||
                (method.isSingle && labels.contains('1串1')),
          )
          .toList(growable: false);

  Future<void> _restoreDraft() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('selection_draft_v1');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final rawMatches = decoded['matches'];
      if (rawMatches is List) {
        for (final rawMatch in rawMatches) {
          if (rawMatch is! Map) continue;
          final matchId = rawMatch['matchId']?.toString() ?? '';
          if (matchId.isEmpty) continue;
          final draft = _Draft();
          draft.banker = rawMatch['banker'] == true;
          final rawSelected = rawMatch['selected'];
          if (rawSelected is Map) {
            for (final entry in rawSelected.entries) {
              final play = _playFromName(entry.key);
              if (play == null || entry.value is! List) continue;
              final values = (entry.value as List)
                  .map((value) => value.toString())
                  .where((value) => value.isNotEmpty)
                  .toSet();
              if (values.isNotEmpty) draft.selected[play] = values;
            }
          }
          if (draft.hasSelection) drafts[matchId] = draft;
        }
      }
      final rawPasses = decoded['passes'];
      if (rawPasses is List) {
        restoredPassLabels = rawPasses.map((value) => value.toString()).toSet();
      }
      final multiple = int.tryParse(decoded['multiple']?.toString() ?? '');
      if (multiple != null && multiple > 0) {
        quickMultiple =
            multiple.clamp(1, BettingEngine.maxSchemeMultiple).toInt();
      }
      final rawViewMode = decoded['viewMode']?.toString();
      for (final mode in _SelectionViewMode.values) {
        if (mode.name == rawViewMode) viewMode = mode;
      }
      if (!mounted || drafts.isEmpty) return;
      restoringDraft = true;
      setState(() {});
      if (matches.isNotEmpty && restoredPassLabels != null) {
        final labels = restoredPassLabels!;
        setState(() {
          quickPasses = _passesForLabels(_quickMethods(picks), labels);
          restoredPassLabels = null;
          _reconcileQuickPass();
        });
        restoringDraft = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已恢复暂存选号')),
          );
        });
      }
    } catch (error) {
      debugPrint('暂存选号恢复失败: $error');
    }
  }

  Future<void> _persistDraft() async {
    final preferences = await SharedPreferences.getInstance();
    final selectedDrafts = drafts.entries
        .where((entry) => entry.value.hasSelection)
        .toList(growable: false);
    if (selectedDrafts.isEmpty) {
      await preferences.remove('selection_draft_v1');
      return;
    }
    final payload = {
      'version': 1,
      'updatedAt': DateTime.now().toIso8601String(),
      'multiple': quickMultiple,
      'passes': quickPasses.map((method) => method.label).toList(),
      'viewMode': viewMode.name,
      'matches': [
        for (final entry in selectedDrafts)
          {
            'matchId': entry.key,
            'banker': entry.value.banker,
            'selected': {
              for (final selection in entry.value.selected.entries)
                selection.key.name: selection.value.toList(),
            },
          },
      ],
    };
    await preferences.setString('selection_draft_v1', jsonEncode(payload));
  }

  void _scheduleDraftPersist() {
    draftSaveTimer?.cancel();
    draftSaveTimer = Timer(
      const Duration(milliseconds: 250),
      _persistDraft,
    );
  }

  Future<void> _persistDraftNow() async {
    draftSaveTimer?.cancel();
    await _persistDraft();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('选号已暂存到本机')));
  }

  void _clearInvalidSelections() {
    final invalidIds = selectionIssues.keys
        .map((key) => key.split(':'))
        .where((parts) => parts.length >= 2)
        .map((parts) => parts[1])
        .toSet();
    setState(() {
      drafts.removeWhere((id, _) => invalidIds.contains(id));
      selectionIssues = const {};
      _reconcileQuickPass();
    });
    _scheduleDraftPersist();
  }

  void _openFocusedMatchIfNeeded(List<MatchItem> refreshed) {
    final matchId = widget.focusMatchId;
    if (didHandleFocusedMatch || matchId == null || matchId.isEmpty) return;
    didHandleFocusedMatch = true;
    final index = refreshed.indexWhere((match) => match.id == matchId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (index < 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该比赛当前不在可选号列表，可能已停售')));
        return;
      }
      _openMore(refreshed[index]);
    });
  }

  int _compareMatchNumber(MatchItem a, MatchItem b) {
    final dateOrder = a.businessDateOnly.compareTo(b.businessDateOnly);
    if (dateOrder != 0) return dateOrder;
    final aSequence = _matchNumberSequence(a.number);
    final bSequence = _matchNumberSequence(b.number);
    final numberOrder = aSequence.compareTo(bSequence);
    if (numberOrder != 0) return numberOrder;
    final labelOrder = a.number.compareTo(b.number);
    return labelOrder != 0 ? labelOrder : a.id.compareTo(b.id);
  }

  int _matchNumberSequence(String number) =>
      int.tryParse(RegExp(r'\d+$').firstMatch(number)?.group(0) ?? '') ?? 9999;

  Map<String, double> _odds(MatchItem m, FootballPlay p) => switch (p) {
        FootballPlay.had => m.had,
        FootballPlay.hhad => {
            for (final e in m.hhad.entries)
              if (e.key != '让球' && e.value is num)
                e.key: (e.value as num).toDouble(),
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

  bool _supportsSingleForDraft(MatchItem match, _Draft draft) {
    if (!match.canSingle) return false;
    return draft.selected.keys.every((play) {
      final pool = match.pools[play.poolCode];
      return pool is Map && pool['single'] == true;
    });
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
              singleSupported: _supportsSingleForDraft(m, d),
              options: [
                for (final entry in d.selected.entries)
                  for (final k in entry.value)
                    if (_odds(m, entry.key)[k] != null)
                      BetOption(
                        label: k,
                        sp: _odds(m, entry.key)[k]!,
                        play: entry.key,
                      ),
              ],
            ),
      ];

  void _toggle(MatchItem m, FootballPlay p, String key) {
    setState(() {
      final d = drafts.putIfAbsent(m.id, _Draft.new);
      final values = d.selected.putIfAbsent(p, () => <String>{});
      if (!values.add(key)) values.remove(key);
      if (values.isEmpty) d.selected.remove(p);
      if (!d.hasSelection) drafts.remove(m.id);
      selectionIssues = {
        for (final entry in selectionIssues.entries)
          if (!entry.key.startsWith('match:${m.id}') &&
              !entry.key.startsWith('play:${m.id}:') &&
              !entry.key.startsWith('option:${m.id}:'))
            entry.key: entry.value,
      };
      _reconcileQuickPass();
    });
    _scheduleDraftPersist();
  }

  void _calculate({bool optimize = false}) {
    final selected = picks;
    final validationIssue = _quickValidationIssue(selected);
    if (validationIssue != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(validationIssue)),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SchemePage(
          picks: selected,
          initialPasses: quickPasses,
          initialMultiple: quickMultiple,
          initialBudget: _quickResult(selected)?.amount,
          optimizationOnly: optimize,
        ),
      ),
    );
  }

  int _maxPassFor(List<MatchPick> selected) => selected
      .expand(
        (item) =>
            item.options.map((option) => (option.play ?? item.play).maxPass),
      )
      .reduce((a, b) => a < b ? a : b);

  bool _supportsSingle(MatchPick pick) {
    return pick.singleSupported;
  }

  List<PassMethod> _quickMethods(List<MatchPick> selected) {
    if (selected.isEmpty) return const [];
    final methods =
        PassMethod.available(selected.length, _maxPassFor(selected));
    final allSupportSingle = selected.every(_supportsSingle);
    return methods
        .where((method) => !method.isSingle || allSupportSingle)
        .toList(growable: false);
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
    final preferredMethods = methods
        .where(
          (method) =>
              method.isSingle || method.displayLabel?.endsWith('串1') == true,
        )
        .toList(growable: false);
    quickPasses = [
      preferredMethods.isEmpty ? methods.first : preferredMethods.last,
    ];
  }

  Future<void> _chooseQuickPass() async {
    final selected = picks;
    final methods = _quickMethods(selected);
    if (methods.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            selected.length == 1 ? '当前选择不支持单关，请至少选择2场' : '当前玩法组合暂无可用过关方式',
          ),
        ),
      );
      return;
    }
    var selectedMethods = [
      for (final method in methods)
        if (quickPasses.any((item) => _samePass(item, method))) method,
    ];
    final chosen = await showModalBottomSheet<List<PassMethod>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (_, updateSheet) {
          final common = methods
              .where(
                (method) =>
                    method.isSingle ||
                    method.displayLabel?.endsWith('串1') == true,
              )
              .toList(growable: false);
          final more = methods
              .where((method) => !common.contains(method))
              .toList(growable: false);

          Widget chips(List<PassMethod> values) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final method in values)
                    FilterChip(
                      label: Text(method.label),
                      selected: selectedMethods.any(
                        (item) => _samePass(item, method),
                      ),
                      onSelected: (value) => updateSheet(() {
                        if (value) {
                          if (!selectedMethods.any(
                            (item) => _samePass(item, method),
                          )) {
                            selectedMethods = [...selectedMethods, method];
                          }
                        } else {
                          selectedMethods = selectedMethods
                              .where((item) => !_samePass(item, method))
                              .toList(growable: false);
                        }
                      }),
                    ),
                ],
              );

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * .78,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '过关方式',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '已选${selected.length}场，可多选',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xff7f8783),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            chips(common),
                            if (more.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              const Text(
                                '更多过关方式',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              chips(more),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Builder(
                      builder: (_) {
                        BettingResult? preview;
                        if (selectedMethods.isNotEmpty) {
                          try {
                            preview = const BettingEngine().calculateMultiple(
                              picks: selected,
                              passes: selectedMethods,
                              multiple: quickMultiple,
                            );
                          } catch (_) {}
                        }
                        return Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    preview == null
                                        ? '金额 --'
                                        : '金额 ${preview.amount.toStringAsFixed(0)}元',
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    preview == null
                                        ? '最高奖金 --'
                                        : '最高奖金 ${preview.maxReturn.toStringAsFixed(2)}元',
                                    style: const TextStyle(
                                      color: Color(0xffdf4162),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 116,
                              child: FilledButton(
                                onPressed: selectedMethods.isEmpty
                                    ? null
                                    : () => Navigator.pop(
                                          sheetContext,
                                          selectedMethods,
                                        ),
                                child: const Text('确定'),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    if (chosen != null && mounted) {
      setState(() {
        quickPasses = chosen;
      });
      _scheduleDraftPersist();
    }
  }

  BettingResult? _quickResult(List<MatchPick> selected) {
    if (quickPasses.isEmpty || selectionIssues.isNotEmpty) return null;
    try {
      return const BettingEngine().calculateMultiple(
        picks: selected,
        passes: quickPasses,
        multiple: quickMultiple,
      );
    } catch (_) {
      return null;
    }
  }

  int? _minimumPass(List<PassMethod> methods) {
    final sizes = methods.expand((method) => method.subPassSizes);
    if (sizes.isEmpty) return null;
    return sizes.reduce(math.min);
  }

  String? _quickValidationIssue(List<MatchPick> selected) {
    if (selectionIssues.isNotEmpty) return '请先处理失效选号后再生成方案';
    if (selected.isEmpty) return '请至少选择一场比赛';
    if (quickPasses.isEmpty) return '请选择过关方式';
    try {
      const BettingEngine().calculateMultiple(
        picks: selected,
        passes: quickPasses,
        multiple: quickMultiple,
      );
      return null;
    } on ArgumentError catch (error) {
      return error.message?.toString() ?? '当前选号暂不能生成方案';
    }
  }

  String get _quickPassLabel => quickPasses.isEmpty
      ? '过关方式'
      : quickPasses.map((item) => item.label).join('、');

  void _changeQuickMultiple(int delta) {
    setState(() {
      quickMultiple = (quickMultiple + delta)
          .clamp(1, BettingEngine.maxSchemeMultiple)
          .toInt();
    });
    _scheduleDraftPersist();
  }

  Future<void> _editQuickMultiple() async {
    // Keep the display at 1x, but let a typed value replace it rather than append.
    var input = '';
    final chosen = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text(
                    '方案总倍数',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  Text(
                    '$input 倍',
                    style: const TextStyle(
                      fontSize: 18,
                      color: Color(0xff168f62),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (final value in const [20, 50, 100, 500])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 42),
                          ),
                          onPressed: () =>
                              updateSheet(() => input = value.toString()),
                          child: Text(
                            '$value倍',
                            maxLines: 1,
                            softWrap: false,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
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
                    '⌫',
                  ])
                    InkWell(
                      onTap: () => updateSheet(() {
                        if (key == '清空') {
                          input = '';
                        } else if (key == '⌫') {
                          if (input.isNotEmpty) {
                            input = input.substring(0, input.length - 1);
                          }
                        } else {
                          final next = '$input$key'.replaceFirst(
                            RegExp(r'^0+'),
                            '',
                          );
                          final parsed = int.tryParse(next) ?? 0;
                          if (parsed <= BettingEngine.maxSchemeMultiple) {
                            input = next;
                          }
                        }
                      }),
                      child: Container(
                        margin: const EdgeInsets.all(2),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xfff4f6f5),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(key, style: const TextStyle(fontSize: 16)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Builder(
                builder: (_) {
                  BettingResult? preview;
                  final multiple = int.tryParse(input) ?? 0;
                  if (multiple > 0 && quickPasses.isNotEmpty) {
                    try {
                      preview = const BettingEngine().calculateMultiple(
                        picks: picks,
                        passes: quickPasses,
                        multiple: multiple,
                      );
                    } catch (_) {}
                  }
                  return Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              preview == null
                                  ? '金额 --'
                                  : '金额 ${preview.amount.toStringAsFixed(0)}元',
                            ),
                            const SizedBox(height: 2),
                            Text(
                              preview == null
                                  ? '最高奖金 --'
                                  : '最高奖金 ${preview.maxReturn.toStringAsFixed(2)}元',
                              style: const TextStyle(
                                color: Color(0xffdf4162),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
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
                          child: const Text('完成'),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const Text(
                '输入倍数后按完成更新方案金额与奖金测算',
                style: TextStyle(fontSize: 10, color: Color(0xff8a918e)),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null && mounted) {
      setState(() => quickMultiple = chosen);
      _scheduleDraftPersist();
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
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: Text(
                    text ?? '$key ${sp.toStringAsFixed(2)}',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11.25,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? Colors.white : const Color(0xff555d59),
                    ),
                  ),
                ),
                if (showSingleBadge)
                  Positioned(
                    left: 2,
                    top: 1,
                    child: Container(
                      width: 13,
                      height: 11,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color:
                            selected ? Colors.white : const Color(0xffdf6574),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Text(
                        '单',
                        style: TextStyle(
                          fontSize: 7,
                          height: 1,
                          color:
                              selected ? const Color(0xff168f62) : Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _unavailableOptionCell(String key, {double spacing = 2}) => Expanded(
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
            child: Text(
              '$key 未受注',
              maxLines: 1,
              style: const TextStyle(fontSize: 9.5, color: Color(0xffa4aaa7)),
            ),
          ),
        ),
      );

  Widget _mainOddsRow(MatchItem match, FootballPlay play) {
    final handicap = match.hhad['让球'];
    final enabled = _enabled(match, play);
    final spfSingle = play == FootballPlay.had && match.spfSingleSupported;
    const keys = ['胜', '平', '负'];
    final hasAnyOdds = keys.any((key) => _odds(match, play)[key] != null);
    return Row(
      children: [
        SizedBox(
          width: 42,
          child: Text(
            play == FootballPlay.had ? '0' : '${handicap ?? ''}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: play == FootballPlay.hhad
                  ? const Color(0xff16a36a)
                  : const Color(0xff9aa19d),
            ),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 36,
            child: !enabled || !hasAnyOdds
                ? Center(
                    child: Text(
                      play == FootballPlay.had ? '胜平负未受注' : '让球胜平负未受注',
                      style: const TextStyle(
                        fontSize: 9.5,
                        color: Color(0xffa4aaa7),
                      ),
                    ),
                  )
                : Stack(
                    children: [
                      Row(
                        children: [
                          for (var index = 0; index < 3; index++) ...[
                            if (_odds(match, play)[keys[index]] == null)
                              _unavailableOptionCell(keys[index])
                            else
                              _optionCell(
                                match,
                                play,
                                keys[index],
                                showSingleBadge: spfSingle && index == 0,
                              ),
                          ],
                        ],
                      ),
                      if (spfSingle)
                        Positioned.fill(
                          left: 2,
                          right: 2,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: const Color(0xffe89aa3),
                                  width: 1.1,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildMatch(MatchItem match) {
    final play = viewMode.play;
    if (play != null) return _buildSinglePlayMatch(match, play);

    final draft = drafts[match.id];
    final moreSelectionCount = draft?.selected.entries
            .where(
              (entry) =>
                  entry.key != FootballPlay.had &&
                  entry.key != FootballPlay.hhad,
            )
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
        border: Border(bottom: BorderSide(color: Color(0xffedf0ee))),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                match.number,
                style: const TextStyle(fontSize: 11, color: Color(0xff737b77)),
              ),
              const SizedBox(width: 6),
              Container(
                constraints: const BoxConstraints(maxWidth: 76),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xffeef8f3),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  match.league,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xff2f9d75),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                time,
                style: const TextStyle(fontSize: 11, color: Color(0xff8a918d)),
              ),
              if (draft != null && draft.hasSelection) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () {
                    setState(() => draft.banker = !draft.banker);
                    _scheduleDraftPersist();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: draft.banker
                          ? const Color(0xfffff0f3)
                          : const Color(0xfff3f5f4),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      draft.banker ? '胆' : '设胆',
                      style: TextStyle(
                        fontSize: 9,
                        color: draft.banker
                            ? const Color(0xffe24b63)
                            : const Color(0xff777f7b),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const SizedBox(width: 42),
              Expanded(
                child: Text(
                  match.home,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'VS',
                  style: TextStyle(fontSize: 10.5, color: Color(0xffa0a6a3)),
                ),
              ),
              Expanded(
                child: Text(
                  match.away,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 54),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    _mainOddsRow(match, FootballPlay.had),
                    if (showHandicap) ...[
                      _mainOddsRow(match, FootballPlay.hhad),
                    ],
                  ],
                ),
              ),
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
                      width: moreSelectionCount > 0 ? 1.2 : .8,
                    ),
                  ),
                  child: showHandicap
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              moreSelectionCount > 0
                                  ? '已选$moreSelectionCount项'
                                  : '更多',
                              style: TextStyle(
                                fontSize: moreSelectionCount > 0 ? 9 : 10.5,
                                height: 1.15,
                                color: const Color(0xff2f8f6d),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Text(
                              '玩法',
                              style: TextStyle(
                                fontSize: 10.5,
                                height: 1.15,
                                color: Color(0xff2f8f6d),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right,
                              size: 13,
                              color: Color(0xff7d9b8d),
                            ),
                          ],
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              moreSelectionCount > 0
                                  ? '已选$moreSelectionCount项'
                                  : '更多',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: Color(0xff2f8f6d),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right,
                              size: 13,
                              color: Color(0xff7d9b8d),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
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
        border: Border(bottom: BorderSide(color: Color(0xffedf0ee))),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                match.number,
                style: const TextStyle(fontSize: 11, color: Color(0xff737b77)),
              ),
              const SizedBox(width: 6),
              Text(
                match.league,
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xff2f9d75),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                time,
                style: const TextStyle(fontSize: 11, color: Color(0xff8a918d)),
              ),
              if (draft != null && draft.hasSelection) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () {
                    setState(() => draft.banker = !draft.banker);
                    _scheduleDraftPersist();
                  },
                  child: Text(
                    draft.banker ? '胆' : '设胆',
                    style: TextStyle(
                      fontSize: 9,
                      color: draft.banker
                          ? const Color(0xffe24b63)
                          : const Color(0xff777f7b),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: Text(
                  match.home,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  'VS',
                  style: TextStyle(fontSize: 11, color: Color(0xffa0a6a3)),
                ),
              ),
              Expanded(
                child: Text(
                  match.away,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (order.isEmpty || !enabled)
            Container(
              height: 42,
              alignment: Alignment.center,
              color: const Color(0xfff3f5f4),
              child: Text(
                order.isEmpty ? '暂未开售（暂无官方SP）' : '未受注',
                style: const TextStyle(fontSize: 11, color: Color(0xffa1a7a4)),
              ),
            )
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
                    child: Builder(
                      builder: (_) {
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
                              Text(
                                _playOptionLabel(play, key),
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize:
                                      play == FootballPlay.crs ? 10.5 : 11.5,
                                  height: 1,
                                  color: selected
                                      ? Colors.white
                                      : const Color(0xff3f4743),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                odds[key]!.toStringAsFixed(2),
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  height: 1,
                                  color: selected
                                      ? Colors.white.withValues(alpha: .9)
                                      : const Color(0xff929995),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _openMore(MatchItem match) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (_, refreshSheet) {
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
            final handicap =
                play == FootballPlay.hhad ? match.hhad['让球']?.toString() : null;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        handicap == null
                            ? play.label
                            : '${play.label}  $handicap',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (supportsSingle) ...[
                        const SizedBox(width: 6),
                        const _PlayCapabilityTag(label: '单关'),
                      ],
                      if (supportsParlay) ...[
                        const SizedBox(width: 5),
                        const _PlayCapabilityTag(label: '过关'),
                      ],
                      if (statusLabel != null) ...[
                        const Spacer(),
                        Text(
                          statusLabel,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xffa4aaa7),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (odds.isEmpty)
                    Container(
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xfff5f6f6),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const Text(
                        '暂未开售（暂无官方SP）',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xffa1a7a4),
                        ),
                      ),
                    )
                  else
                    GridView.count(
                      crossAxisCount:
                          play == FootballPlay.crs || play == FootballPlay.ttg
                              ? 4
                              : 3,
                      childAspectRatio: play == FootballPlay.crs ? 2.05 : 2.7,
                      mainAxisSpacing: 1,
                      crossAxisSpacing: 1.5,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        for (final key in order)
                          if (odds[key] != null)
                            Builder(
                              builder: (_) {
                                final selected = _isSelected(match, play, key);
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
                                          ? const Color(0xff16a36a)
                                          : enabled
                                              ? const Color(0xfff6f7f7)
                                              : const Color(0xfff1f2f2),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          key,
                                          maxLines: 1,
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                            color: selected
                                                ? Colors.white
                                                : enabled
                                                    ? const Color(0xff353b38)
                                                    : const Color(0xffaeb3b0),
                                          ),
                                        ),
                                        const SizedBox(height: 1),
                                        Text(
                                          odds[key]!.toStringAsFixed(2),
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            color: selected
                                                ? Colors.white70
                                                : const Color(0xff8f9692),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                      ],
                    ),
                ],
              ),
            );
          }

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: .86,
            maxChildSize: .95,
            builder: (_, controller) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${match.home}  VS  ${match.away}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${match.number} · ${match.league} · ${match.kickoffDisplayTime}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Color(0xff858d89),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
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
                        '7+',
                      ]),
                      section(
                        FootballPlay.crs,
                        _playOrder(FootballPlay.crs, match),
                      ),
                      section(FootballPlay.hafu, const [
                        '胜胜',
                        '胜平',
                        '胜负',
                        '平胜',
                        '平平',
                        '平负',
                        '负胜',
                        '负平',
                        '负负',
                      ]),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(top: BorderSide(color: Color(0xffe7eae8))),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '已选 ${drafts[match.id]?.selected.values.fold<int>(0, (sum, values) => sum + values.length) ?? 0} 项',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff69716d),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 132,
                        child: FilledButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: const Text('确定'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
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
        children.add(
          Container(
            height: 29,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: const Color(0xfff5f7f6),
            child: Row(
              children: [
                Text(
                  _dateLabel(currentDate),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff4d5551),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '$count场比赛',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xff929995),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      children.add(_buildMatch(match));
    }
    return children;
  }

  Widget _selectionIssueBanner() {
    if (selectionIssues.isEmpty) return const SizedBox.shrink();
    final details = selectionIssues.values.take(2).join('；');
    final suffix = selectionIssues.length > 2 ? '……' : '';
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xfffff5e6),
        border: Border.all(color: const Color(0xfff0d39d)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: Color(0xffa86f16),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '部分选号状态已变化',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xff805817),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$details$suffix',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.3,
                    color: Color(0xff8e6b35),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _clearInvalidSelections,
            child: const Text('清除'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSavedSchemes() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _SavedSchemesSheet(),
    );
  }

  Widget _buildBottomBar(List<MatchPick> selected) {
    final hasSelection = selected.isNotEmpty;
    final blocked = selectionIssues.isNotEmpty;
    final optionCount = selected.fold<int>(
      0,
      (sum, item) => sum + item.options.length,
    );
    final bankerCount = selected.where((item) => item.banker).length;
    final minimumPass = _minimumPass(quickPasses);
    final preview = _quickResult(selected);
    return Container(
      height: 104,
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 6),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xffe4e8e6))),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 38,
            child: Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '清空选号',
                  onPressed: hasSelection
                      ? () {
                          setState(() {
                            drafts.clear();
                            selectionIssues = const {};
                            quickPasses = const [];
                            quickMultiple = 1;
                          });
                          _scheduleDraftPersist();
                        }
                      : null,
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 21,
                    color: Color(0xff6f7773),
                  ),
                ),
                SizedBox(
                  width: 92,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '已选${selected.length}场/$optionCount项',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Color(0xff4f5753),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '$bankerCount胆 · 最低${minimumPass ?? '--'}关',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: Color(0xff7d8581),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: InkWell(
                    onTap: hasSelection && !blocked ? _chooseQuickPass : null,
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: const Color(0xffdfe4e1),
                          width: .8,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _quickPassLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: !hasSelection
                                    ? const Color(0xffb3b9b6)
                                    : quickPasses.isEmpty
                                        ? const Color(0xff7c8480)
                                        : const Color(0xff216f50),
                              ),
                            ),
                          ),
                          Icon(
                            Icons.arrow_drop_down,
                            size: 17,
                            color: hasSelection
                                ? const Color(0xff7e8682)
                                : const Color(0xffc4c9c7),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '倍数',
                  style: TextStyle(fontSize: 11, color: Color(0xff59615d)),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: hasSelection && quickMultiple > 1
                      ? () => _changeQuickMultiple(-1)
                      : null,
                  icon: const Icon(Icons.remove, size: 17),
                ),
                InkWell(
                  onTap: hasSelection ? _editQuickMultiple : null,
                  child: SizedBox(
                    width: 31,
                    height: 30,
                    child: Center(
                      child: Text(
                        '$quickMultiple',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: hasSelection
                              ? const Color(0xff303733)
                              : const Color(0xffb3b9b6),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed:
                      hasSelection ? () => _changeQuickMultiple(1) : null,
                  icon: const Icon(Icons.add, size: 17),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Row(
              children: [
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
                              : blocked
                                  ? '请处理失效选号'
                                  : preview == null
                                      ? '当前 -- 注'
                                      : '当前${preview.notes}注  ${preview.amount.toStringAsFixed(0)}元',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xff3f4743),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          preview == null
                              ? '预计奖金：--'
                              : '预计奖金：${_prizeText(preview.minReturn, preview.maxReturn)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 9.5,
                            color: Color(0xffe0526e),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  height: 38,
                  child: OutlinedButton(
                    onPressed:
                        hasSelection && !blocked && quickPasses.isNotEmpty
                            ? () => _calculate(optimize: true)
                            : null,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Text('奖金优化', style: TextStyle(fontSize: 11)),
                  ),
                ),
                const SizedBox(width: 7),
                SizedBox(
                  height: 38,
                  child: FilledButton(
                    onPressed: !hasSelection || blocked
                        ? null
                        : quickPasses.isEmpty
                            ? _chooseQuickPass
                            : () => _calculate(),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 13),
                    ),
                    child: const Text('生成方案', style: TextStyle(fontSize: 11)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = picks;
    return Scaffold(
      backgroundColor: const Color(0xfff6f7f7),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Container(
              color: Colors.white,
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  if (Navigator.canPop(context)) ...[
                    IconButton(
                      tooltip: '返回',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 34,
                        height: 40,
                      ),
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Row(
                      children: [
                        const Text(
                          '球镜',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            '·',
                            style: TextStyle(color: Color(0xffa0a6a3)),
                          ),
                        ),
                        PopupMenuButton<_SelectionViewMode>(
                          tooltip: '切换玩法',
                          initialValue: viewMode,
                          offset: const Offset(0, 38),
                          color: Colors.white,
                          surfaceTintColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          onSelected: (mode) {
                            setState(() => viewMode = mode);
                            _scheduleDraftPersist();
                          },
                          itemBuilder: (_) => [
                            for (final mode in _SelectionViewMode.values)
                              PopupMenuItem(
                                value: mode,
                                height: 42,
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 22,
                                      child: mode == viewMode
                                          ? const Icon(
                                              Icons.check,
                                              size: 16,
                                              color: Color(0xff168f62),
                                            )
                                          : null,
                                    ),
                                    Text(
                                      mode.label,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: mode == viewMode
                                            ? const Color(0xff168f62)
                                            : const Color(0xff4f5753),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  viewMode.label,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Color(0xff4f5753),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Icon(
                                  Icons.arrow_drop_down,
                                  size: 19,
                                  color: Color(0xff69716d),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '暂存选号',
                    visualDensity: VisualDensity.compact,
                    onPressed: picks.isEmpty ? null : _persistDraftNow,
                    icon: const Icon(Icons.save_outlined, size: 18),
                  ),
                  TextButton.icon(
                    onPressed: _openSavedSchemes,
                    icon: const Icon(Icons.bookmarks_outlined, size: 18),
                    label: const Text('方案', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
            if (loading) const LinearProgressIndicator(minHeight: 2),
            if (selectionIssues.isNotEmpty) _selectionIssueBanner(),
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
                                  Icon(
                                    Icons.sports_soccer,
                                    size: 38,
                                    color: loading
                                        ? const Color(0xff16a36a)
                                        : const Color(0xffa5aca8),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    loading
                                        ? '正在加载在售场次…'
                                        : loadError == null
                                            ? '暂无在售场次'
                                            : '加载失败，请重试',
                                  ),
                                  if (!loading)
                                    TextButton(
                                      onPressed: _refresh,
                                      child: const Text('重新加载'),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 116),
                        children: _matchListChildren(),
                      ),
              ),
            ),
          ],
        ),
      ),
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
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 9,
            color: Color(0xff2f9d75),
            fontWeight: FontWeight.w600,
          ),
        ),
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
  const _SchemePage({
    required this.picks,
    required this.initialPasses,
    this.initialMultiple = 1,
    this.initialBudget,
    this.optimizationOnly = false,
    this.initialResult,
    this.initialShowCombinations = false,
    this.savedSettlement,
  });

  final List<MatchPick> picks;
  final List<PassMethod> initialPasses;
  final int initialMultiple;
  final double? initialBudget;
  final bool optimizationOnly;
  final BettingResult? initialResult;
  final bool initialShowCombinations;
  final Map<String, dynamic>? savedSettlement;

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
    multipleController = TextEditingController(
      text: widget.initialMultiple.toString(),
    );
    budgetController = TextEditingController(
      text: (widget.initialBudget ?? 100).toStringAsFixed(0),
    );
    final maxPass = widget.picks
        .expand(
          (pick) =>
              pick.options.map((option) => (option.play ?? pick.play).maxPass),
        )
        .reduce(math.min);
    final available = PassMethod.available(widget.picks.length, maxPass);
    final canUseSingle = widget.picks.every((pick) => pick.singleSupported);
    methods = [
      for (final method in available)
        if (!method.isSingle || canUseSingle) method,
    ];
    selectedMethods = [
      for (final item in methods)
        if (widget.initialPasses.any((pass) => _samePass(item, pass))) item,
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

  bool _samePass(PassMethod a, PassMethod b) =>
      a.label == b.label &&
      a.matches == b.matches &&
      a.subPassSizes.join(',') == b.subPassSizes.join(',');

  String get _settlementState =>
      widget.savedSettlement?['state']?.toString() ?? '';

  double? get _actualPrize {
    if (_settlementState != 'won') return null;
    return num.tryParse(
      widget.savedSettlement?['prize']?.toString() ?? '',
    )?.toDouble();
  }

  bool get _isSavedScheme => widget.savedSettlement != null;

  bool get _isSettled =>
      _settlementState == 'won' || _settlementState == 'lost';

  Map<String, dynamic>? _outcomeFor(MatchPick pick) {
    final outcomes = widget.savedSettlement?['outcomes'];
    if (outcomes is! Map) return null;
    final outcome = outcomes[pick.matchId];
    return outcome is Map ? Map<String, dynamic>.from(outcome) : null;
  }

  String _scoreFor(MatchPick pick) =>
      _outcomeFor(pick)?['score']?.toString() ?? '';

  String _winnerFor(MatchPick pick, FootballPlay play) {
    final winners = _outcomeFor(pick)?['winners'];
    return winners is Map ? winners[play.name]?.toString() ?? '' : '';
  }

  bool _optionWon(String label, String winner, FootballPlay play) {
    if (label == winner) return true;
    if (play == FootballPlay.hhad) {
      return (winner == '让胜' && label == '胜') ||
          (winner == '让平' && label == '平') ||
          (winner == '让负' && label == '负');
    }
    return false;
  }

  bool _ticketWon(AtomicBet bet) => bet.picks.every((item) {
        final play = item.option.play ?? item.match.play;
        return _optionWon(
            item.option.label, _winnerFor(item.match, play), play);
      });

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
              multiple: (int.tryParse(multipleController.text) ?? 1).clamp(
                1,
                BettingEngine.maxSchemeMultiple,
              ),
            )
          : const BettingEngine().optimizeMultiple(
              picks: widget.picks,
              passes: selectedMethods,
              budget: double.tryParse(budgetController.text) ?? 0,
              mode: optimizeMode,
            );
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
        final number = match.number.replaceAll(RegExp(r'\s+'), '');
        final play = item.option.play ?? match.play;
        final marker = play == FootballPlay.hhad && match.handicap.isNotEmpty
            ? '${match.handicap}${item.option.label}'
            : _compactOptionLabel(play, item.option.label);
        return '$number ${match.home}（$marker）';
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
              : _multipleFor(current, entry),
        ),
    ];
    final draft = BettingResult(current.atomicBets, tickets);
    final protected = draft.returnsByCombination.values.every(
      (returnValue) => returnValue >= draft.amount,
    );
    final nextBudget = draft.amount.toStringAsFixed(0);
    budgetController.value = TextEditingValue(
      text: nextBudget,
      selection: TextSelection.collapsed(offset: nextBudget.length),
    );
    setState(() {
      result = BettingResult(
        current.atomicBets,
        tickets,
        principalProtected: protected,
      );
    });
  }

  String _compactDescription(AtomicBet bet) => bet.picks.map((item) {
        final number = item.match.number.replaceAll(RegExp(r'\s+'), '');
        final play = item.option.play ?? item.match.play;
        return '$number ${play.label}[${item.option.label}]';
      }).join(' × ');

  String _schemeText(BettingResult value) {
    final prize = _actualPrize;
    final settled = _isSettled;
    final buffer = StringBuffer()
      ..writeln('球镜｜足球赛事数据方案（非出票凭证）')
      ..writeln(
        '$_passLabel｜${value.notes}注｜${value.amount.toStringAsFixed(0)}元',
      )
      ..writeln(
        prize != null
            ? '实际税前奖金 ${prize.toStringAsFixed(2)}元'
            : settled
                ? '本方案未中奖'
                : '预计奖金 ${_prizeText(value.minReturn, value.maxReturn)}',
      );
    var index = 1;
    for (final entry in value.returnsByCombination.entries) {
      buffer.writeln(
        '${index++}. ${_compactDescription(entry.key)}｜${_multipleFor(value, entry.key)}倍｜${entry.value.toStringAsFixed(2)}元',
      );
    }
    buffer.write(settled ? '赛果按全场90分钟（含伤停补时）结算。' : 'SP变化后请重新计算；本方案仅供计算参考。');
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
        'singleSupported': pick.singleSupported,
        'options': [
          for (final option in pick.options)
            {
              'label': option.label,
              'sp': option.sp,
              'play': (option.play ?? pick.play).name,
            },
        ],
        'availableOdds': {
          for (final entry in pick.availableOdds.entries)
            entry.key.name: entry.value,
        },
      };

  Future<void> _save(BettingResult value) async {
    final now = DateTime.now();
    final encoded = jsonEncode({
      'version': 6,
      'id': now.microsecondsSinceEpoch.toString(),
      'createdAt': now.toIso8601String(),
      'status': '已保存',
      'settlement': const {'state': 'pending'},
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
      'optimization': widget.optimizationOnly
          ? {
              'mode': optimizeMode.name,
              'budget': value.amount,
              'principalProtected': value.principalProtected == true,
            }
          : null,
      'passes': selectedMethods.map((item) => item.label).toList(),
      'picks': widget.picks.map(_serializePick).toList(),
      'combinations': [
        for (final entry in value.returnsByCombination.entries)
          {
            'multiple': _multipleFor(value, entry.key),
            'amount': _multipleFor(value, entry.key) * 2,
            'return': entry.value,
            'passSize': entry.key.passSize,
            'description': _compactDescription(entry.key),
            'picks': [
              for (final item in entry.key.picks)
                {
                  'matchId': item.match.matchId,
                  'play': (item.option.play ?? item.match.play).name,
                  'label': item.option.label,
                  'sp': item.option.sp,
                },
            ],
          },
      ],
    });
    await const SavedSchemeStore().prepend(encoded, now: now);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('方案已保存到本机')));
    }
  }

  Rect _sharePositionOrigin() {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      return const Rect.fromLTWH(0, 0, 1, 1);
    }
    return renderBox.localToGlobal(Offset.zero) & renderBox.size;
  }

  Future<void> _shareSchemeImage(BettingResult value) async {
    if (isSharing) return;
    setState(() => isSharing = true);
    try {
      final actualPrize = _actualPrize;
      final settled = _isSettled;
      const width = 1080.0;
      const horizontal = 64.0;
      const contentWidth = width - horizontal * 2;
      TextPainter painter(
        String text, {
        required TextStyle style,
        double? maxWidth,
      }) =>
          TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: TextDirection.ltr,
            maxLines: null,
          )..layout(maxWidth: maxWidth ?? contentWidth);

      double pickCardHeight(MatchPick pick) {
        var value = 118.0;
        for (final play in FootballPlay.values) {
          final options = pick.options
              .where((option) => (option.play ?? pick.play) == play)
              .toList(growable: false);
          if (options.isEmpty) continue;
          if (play == FootballPlay.had || play == FootballPlay.hhad) {
            value += 104;
          } else {
            value += 48 + (options.length / 3).ceil() * 82;
          }
        }
        return value + 24;
      }

      final cardsHeight = widget.picks.fold<double>(
        0,
        (sum, pick) => sum + pickCardHeight(pick) + 24,
      );
      final height = math.max(1600.0, 680 + cardsHeight + 280).ceil();
      final iconData = await rootBundle.load(
        'assets/branding/app_icon_master_1024.png',
      );
      final iconCodec = await ui.instantiateImageCodec(
        iconData.buffer.asUint8List(),
        targetWidth: 96,
        targetHeight: 96,
      );
      final iconImage = (await iconCodec.getNextFrame()).image;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(const Color(0xfff3f6f4), BlendMode.src);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(horizontal, 40, 96, 96),
          const Radius.circular(14),
        ),
        Paint()..color = Colors.white,
      );
      canvas.save();
      canvas.clipRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(horizontal, 40, 96, 96),
          const Radius.circular(14),
        ),
      );
      canvas.drawImageRect(
        iconImage,
        Rect.fromLTWH(
          0,
          0,
          iconImage.width.toDouble(),
          iconImage.height.toDouble(),
        ),
        const Rect.fromLTWH(horizontal, 40, 96, 96),
        Paint(),
      );
      canvas.restore();
      final title = TextPainter(
        text: const TextSpan(
          text: '球镜',
          style: TextStyle(
            color: Color(0xff17231e),
            fontSize: 48,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width - horizontal * 2);
      title.paint(canvas, const Offset(horizontal + 122, 42));
      painter(
        '足球赛事数据与资料工具',
        style: const TextStyle(color: Color(0xff737d78), fontSize: 23),
      ).paint(canvas, const Offset(horizontal + 122, 102));

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(40, 168, width - 80, height - 460),
          const Radius.circular(10),
        ),
        Paint()..color = Colors.white,
      );
      final statusLabel = actualPrize != null
          ? '已中奖'
          : settled
              ? '未中奖'
              : '待开奖';
      final statusPainter = painter(
        statusLabel,
        style: const TextStyle(color: Color(0xff68716d), fontSize: 21),
      );
      statusPainter.paint(
        canvas,
        Offset(width - horizontal - statusPainter.width, 190),
      );

      void paintCentered(
        String text,
        Rect rect, {
        required TextStyle style,
      }) {
        final textPainter = painter(text, style: style, maxWidth: rect.width);
        textPainter.paint(
          canvas,
          Offset(
            rect.left + (rect.width - textPainter.width) / 2,
            rect.top + (rect.height - textPainter.height) / 2,
          ),
        );
      }

      void paintOptionCell(
        Rect rect, {
        required String label,
        required String odds,
        required bool selected,
        bool twoLines = false,
      }) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(8)),
          Paint()
            ..color =
                selected ? const Color(0xff168f62) : const Color(0xfff7f8f8),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(8)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color =
                selected ? const Color(0xff168f62) : const Color(0xffdce3df),
        );
        final foreground = selected ? Colors.white : const Color(0xff929995);
        if (!twoLines) {
          paintCentered(
            '$label $odds',
            rect,
            style: TextStyle(
              color: foreground,
              fontSize: 24,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          );
          return;
        }
        paintCentered(
          label,
          Rect.fromLTWH(rect.left, rect.top + 8, rect.width, 30),
          style: TextStyle(
            color: foreground,
            fontSize: 25,
            fontWeight: FontWeight.w700,
          ),
        );
        paintCentered(
          odds,
          Rect.fromLTWH(rect.left, rect.top + 39, rect.width, 28),
          style: TextStyle(
            color: selected ? const Color(0xffe5f7ef) : const Color(0xff7d8882),
            fontSize: 21,
            fontWeight: FontWeight.w500,
          ),
        );
      }

      final summaryTop = 242.0;
      final summaryWidth = contentWidth / 3;
      void paintSummary(
        int index,
        String label,
        String amount, {
        Color color = const Color(0xff17231e),
        double amountSize = 38,
      }) {
        final rect = Rect.fromLTWH(
          horizontal + summaryWidth * index,
          summaryTop,
          summaryWidth,
          116,
        );
        paintCentered(
          label,
          Rect.fromLTWH(rect.left, rect.top, rect.width, 34),
          style: const TextStyle(color: Color(0xff65706a), fontSize: 21),
        );
        paintCentered(
          amount,
          Rect.fromLTWH(rect.left, rect.top + 36, rect.width, 58),
          style: TextStyle(
            color: color,
            fontSize: amountSize,
            fontWeight: FontWeight.w700,
          ),
        );
        if (index < 2) {
          canvas.drawLine(
            Offset(rect.right, rect.top + 6),
            Offset(rect.right, rect.bottom - 12),
            Paint()
              ..color = const Color(0xffe0e5e2)
              ..strokeWidth = 1.4,
          );
        }
      }

      paintSummary(
        0,
        '投入',
        '${value.amount.toStringAsFixed(0)}元',
        color: const Color(0xff168f62),
      );
      paintSummary(
        1,
        '注数',
        '${value.notes}注',
        color: const Color(0xff168f62),
      );
      final prizeValue = actualPrize != null
          ? '${actualPrize.toStringAsFixed(2)}元'
          : settled
              ? '未中奖'
              : _prizeText(value.minReturn, value.maxReturn);
      paintSummary(
        2,
        actualPrize != null ? '实际税前奖金' : '预计税前奖金',
        prizeValue,
        color: actualPrize != null
            ? const Color(0xffc76a00)
            : settled
                ? const Color(0xff767e7a)
                : const Color(0xffc76a00),
        amountSize: prizeValue.length > 16
            ? 24
            : prizeValue.length > 11
                ? 29
                : 36,
      );
      for (var x = horizontal; x < width - horizontal; x += 18) {
        canvas.drawCircle(
          Offset(x, 382),
          2.4,
          Paint()..color = const Color(0xffd8dedb),
        );
      }
      const infoBand = Rect.fromLTWH(horizontal, 410, contentWidth, 66);
      canvas.drawRRect(
        RRect.fromRectAndRadius(infoBand, const Radius.circular(6)),
        Paint()..color = const Color(0xffeef7f3),
      );
      paintCentered(
        _passLabel,
        Rect.fromLTWH(infoBand.left, infoBand.top, infoBand.width / 3, 66),
        style: const TextStyle(
          color: Color(0xff168f62),
          fontSize: 27,
          fontWeight: FontWeight.w700,
        ),
      );
      paintCentered(
        '${widget.initialMultiple}倍',
        Rect.fromLTWH(
          infoBand.left + infoBand.width / 3,
          infoBand.top,
          infoBand.width / 3,
          66,
        ),
        style: const TextStyle(
          color: Color(0xff168f62),
          fontSize: 27,
          fontWeight: FontWeight.w700,
        ),
      );
      paintCentered(
        '共${widget.picks.length}场',
        Rect.fromLTWH(
          infoBand.left + infoBand.width * 2 / 3,
          infoBand.top,
          infoBand.width / 3,
          66,
        ),
        style: const TextStyle(
          color: Color(0xff168f62),
          fontSize: 27,
          fontWeight: FontWeight.w700,
        ),
      );
      var y = 516.0;

      for (final pick in widget.picks) {
        final cardHeight = pickCardHeight(pick);
        final cardRect = Rect.fromLTWH(
          horizontal - 18,
          y - 22,
          contentWidth + 36,
          cardHeight,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(cardRect, const Radius.circular(14)),
          Paint()..color = Colors.white,
        );
        final kickoff = pick.kickoff;
        final timeLabel = kickoff == null
            ? '--:--'
            : '${kickoff.hour.toString().padLeft(2, '0')}:${kickoff.minute.toString().padLeft(2, '0')}';
        paintCentered(
          '${pick.number} · ${pick.league} · $timeLabel',
          Rect.fromLTWH(horizontal, y, contentWidth, 34),
          style: const TextStyle(color: Color(0xff707a75), fontSize: 22),
        );
        y += 42;
        final score = _scoreFor(pick);
        paintCentered(
          '${pick.home}   ${score.isEmpty ? 'VS' : score}   ${pick.away}',
          Rect.fromLTWH(horizontal, y, contentWidth, 48),
          style: const TextStyle(
            color: Color(0xff17231e),
            fontSize: 29,
            fontWeight: FontWeight.w700,
          ),
        );
        y += 70;

        for (final play in FootballPlay.values) {
          final selectedOptions = pick.options
              .where((option) => (option.play ?? pick.play) == play)
              .toList(growable: false);
          if (selectedOptions.isEmpty) continue;
          final isMain = play == FootballPlay.had || play == FootballPlay.hhad;
          if (isMain) {
            final playTitle =
                play == FootballPlay.hhad && pick.handicap.isNotEmpty
                    ? '${play.label} ${pick.handicap}'
                    : play.label;
            painter(
              playTitle,
              style: const TextStyle(
                color: Color(0xff168f62),
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ).paint(canvas, Offset(horizontal + 62, y));
            y += 32;
            final marker = play == FootballPlay.hhad
                ? (pick.handicap.isEmpty ? '让' : pick.handicap)
                : '0';
            final markerRect = Rect.fromLTWH(horizontal, y, 62, 54);
            paintCentered(
              marker,
              markerRect,
              style: TextStyle(
                color: play == FootballPlay.hhad
                    ? const Color(0xff168f62)
                    : const Color(0xff8a918e),
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            );
            final odds = pick.availableOdds[play] ?? const <String, double>{};
            final selectedLabels =
                selectedOptions.map((option) => option.label).toSet();
            final cellWidth = (contentWidth - 62) / 3;
            for (var index = 0; index < 3; index++) {
              final label = const ['胜', '平', '负'][index];
              paintOptionCell(
                Rect.fromLTWH(
                  horizontal + 62 + index * cellWidth,
                  y,
                  cellWidth - 4,
                  54,
                ),
                label: label,
                odds: odds[label]?.toStringAsFixed(2) ?? '--',
                selected: selectedLabels.contains(label),
              );
            }
            y += 72;
            continue;
          }

          const gap = 12.0;
          final cellWidth = (contentWidth - gap * 2) / 3;
          final columns =
              selectedOptions.length <= 2 ? selectedOptions.length : 3;
          final groupWidth = columns * cellWidth + (columns - 1) * gap;
          final groupLeft = selectedOptions.length <= 2
              ? horizontal + (contentWidth - groupWidth) / 2
              : horizontal;
          painter(
            play.label,
            style: const TextStyle(
              color: Color(0xff168f62),
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ).paint(canvas, Offset(groupLeft, y));
          y += 40;
          for (var index = 0; index < selectedOptions.length; index++) {
            final option = selectedOptions[index];
            final row = index ~/ 3;
            final column = index % 3;
            final won = _optionWon(
              option.label,
              _winnerFor(pick, play),
              play,
            );
            paintOptionCell(
              Rect.fromLTWH(
                groupLeft + column * (cellWidth + gap),
                y + row * 82,
                cellWidth,
                70,
              ),
              label: _compactOptionLabel(play, option.label),
              odds: option.sp.toStringAsFixed(2),
              selected: !settled || won,
              twoLines: true,
            );
          }
          y += (selectedOptions.length / 3).ceil() * 82 + 8;
        }
        y = cardRect.bottom + 24;
      }
      canvas.drawLine(
        Offset(horizontal, y - 8),
        Offset(width - horizontal, y - 8),
        Paint()
          ..color = const Color(0xffe0e5e2)
          ..strokeWidth = 1.2,
      );
      final generatedAt = DateTime.now();
      String two(int number) => number.toString().padLeft(2, '0');
      final generatedLabel =
          '${two(generatedAt.month)}-${two(generatedAt.day)} ${two(generatedAt.hour)}:${two(generatedAt.minute)}';
      final timestamp = generatedAt.millisecondsSinceEpoch.toString();
      final schemeId =
          'JQJ-${two(generatedAt.month)}${two(generatedAt.day)}-${timestamp.substring(timestamp.length - 4)}';
      final metaValues = [
        ('方案编号', schemeId),
        ('生成时间', generatedLabel),
        ('最早开赛', _earliestKickoff()),
      ];
      for (var index = 0; index < metaValues.length; index++) {
        final rect = Rect.fromLTWH(
          horizontal + summaryWidth * index,
          y + 8,
          summaryWidth,
          76,
        );
        paintCentered(
          metaValues[index].$1,
          Rect.fromLTWH(rect.left, rect.top, rect.width, 28),
          style: const TextStyle(color: Color(0xff7b8580), fontSize: 18),
        );
        paintCentered(
          metaValues[index].$2,
          Rect.fromLTWH(rect.left, rect.top + 30, rect.width, 34),
          style: const TextStyle(color: Color(0xff3f4944), fontSize: 20),
        );
      }
      paintCentered(
        '由「球镜」App 生成',
        Rect.fromLTWH(horizontal, height - 250, contentWidth, 38),
        style: const TextStyle(
          color: Color(0xff168f62),
          fontSize: 25,
          fontWeight: FontWeight.w700,
        ),
      );
      paintCentered(
        '看比分 · 查赔率 · 找计划',
        Rect.fromLTWH(horizontal, height - 204, contentWidth, 42),
        style: const TextStyle(
          color: Color(0xff25302b),
          fontSize: 29,
          fontWeight: FontWeight.w700,
        ),
      );
      paintCentered(
        '计划单集中查看 · 每日更新状态清晰',
        Rect.fromLTWH(horizontal, height - 158, contentWidth, 32),
        style: const TextStyle(color: Color(0xff8a938e), fontSize: 20),
      );
      painter(
        settled
            ? '赛果按全场90分钟（含伤停补时）结算；SP及赛果以官方公布为准。'
            : '本方案仅供数据计算与信息参考，不构成投注建议；SP及赛果以官方公布为准。',
        style: const TextStyle(color: Color(0xff6f7974), fontSize: 19),
      ).paint(canvas, Offset(horizontal, height - 96));
      final picture = recorder.endRecording();
      final image = await picture.toImage(width.ceil(), height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('分享图片生成失败');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final shareFile = File(
        '${Directory.systemTemp.path}/caimaster-scheme-${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await shareFile.writeAsBytes(bytes, flush: true);
      if (!await shareFile.exists() || await shareFile.length() == 0) {
        throw StateError('分享图片保存失败');
      }
      if (!mounted) return;
      final shareResult = await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              shareFile.path,
              mimeType: 'image/png',
              name: '球镜方案.png',
            ),
          ],
          fileNameOverrides: const ['球镜方案.png'],
          text: '球镜·方案分享',
          subject: '球镜·方案分享',
          sharePositionOrigin: _sharePositionOrigin(),
        ),
      );
      if (shareResult.status == ShareResultStatus.unavailable) {
        throw StateError('系统分享服务不可用');
      }
    } catch (error, stackTrace) {
      debugPrint('方案图片分享失败: $error\n$stackTrace');
      var fallbackOpened = false;
      try {
        final fallbackResult = await SharePlus.instance.share(
          ShareParams(
            text: _schemeText(value),
            subject: '球镜·方案分享',
            sharePositionOrigin: _sharePositionOrigin(),
          ),
        );
        fallbackOpened = fallbackResult.status != ShareResultStatus.unavailable;
      } catch (fallbackError) {
        debugPrint('方案文字分享也失败: $fallbackError');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(fallbackOpened ? '图片分享不可用，已打开文字分享' : '分享失败，请稍后重试'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isSharing = false);
    }
  }

  Widget _parameters() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            if (mode == _SchemeMode.normal)
              TextField(
                controller: multipleController,
                readOnly: _isSavedScheme,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => _recalculate(),
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '方案倍数',
                  suffixText: '倍（最高10000）',
                  border: OutlineInputBorder(),
                ),
              )
            else ...[
              TextField(
                controller: budgetController,
                readOnly: _isSavedScheme,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.done,
                onChanged: (_) => _recalculate(),
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '优化预算',
                  suffixText: '元',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _optimizeButton(OptimizeMode.balanced, '平均'),
                  _optimizeButton(OptimizeMode.hot, '博热'),
                  _optimizeButton(OptimizeMode.cold, '博冷'),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                switch (optimizeMode) {
                  OptimizeMode.balanced => '尽量让各组合中奖回报接近',
                  OptimizeMode.hot => '先保证各组合保本，再放大低SP组合奖金',
                  OptimizeMode.cold => '先保证各组合保本，再放大高SP组合奖金',
                },
                style: const TextStyle(fontSize: 11, color: Color(0xff858d89)),
              ),
            ],
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '倍数为方案计算值，不代表实际出票票面；本应用不出票。',
                style: TextStyle(fontSize: 10.5, color: Color(0xff858d89)),
              ),
            ),
          ],
        ),
      );

  Widget _optimizeButton(OptimizeMode value, String label) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: ChoiceChip(
            label: SizedBox(
              width: double.infinity,
              child: Text(label, textAlign: TextAlign.center),
            ),
            selected: optimizeMode == value,
            selectedColor: const Color(0xffdff3e9),
            labelStyle: TextStyle(
              color: optimizeMode == value ? _green : const Color(0xff656d69),
            ),
            onSelected: (_) {
              setState(() => optimizeMode = value);
              _recalculate();
            },
          ),
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
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text(
              marker,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: play == FootballPlay.hhad
                    ? const Color(0xff168f62)
                    : const Color(0xff8a918e),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final label in const ['胜', '平', '负'])
            Builder(
              builder: (_) {
                final isSelected = selected.contains(label);
                final selectedWon = isSelected &&
                    _optionWon(label, _winnerFor(pick, play), play);
                final selectedLost = _isSettled && isSelected && !selectedWon;
                final selectedActive =
                    isSelected && (selectedWon || !_isSettled);
                final background = selectedActive
                    ? _green
                    : selectedLost
                        ? const Color(0xffe8ece9)
                        : Colors.white;
                final foreground = selectedActive
                    ? Colors.white
                    : selectedLost
                        ? const Color(0xff69716d)
                        : const Color(0xff8b928f);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Container(
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: background,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: selectedActive
                              ? _green
                              : selectedLost
                                  ? const Color(0xffd4dbd6)
                                  : const Color(0xffe3e7e5),
                        ),
                      ),
                      child: Text(
                        '$label ${odds[label]?.toStringAsFixed(2) ?? '--'}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: foreground,
                          fontWeight:
                              isSelected ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _otherPlaySelections(MatchPick pick) {
    const plays = [FootballPlay.ttg, FootballPlay.crs, FootballPlay.hafu];
    final visiblePlays = [
      for (final play in plays)
        if (pick.options.any((option) => (option.play ?? pick.play) == play))
          play,
    ];
    if (visiblePlays.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Column(
        children: [
          for (final play in visiblePlays)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 30,
                    height: 48,
                    child: Center(
                      child: Text(
                        switch (play) {
                          FootballPlay.ttg => '进球',
                          FootballPlay.crs => '比分',
                          FootballPlay.hafu => '半全',
                          _ => '',
                        },
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Color(0xff7d8581),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final cellWidth = (constraints.maxWidth - 12) / 3;
                        final options = pick.options
                            .where(
                              (option) => (option.play ?? pick.play) == play,
                            )
                            .toList(growable: false);
                        return Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final option in options)
                              Builder(
                                builder: (_) {
                                  final won = _optionWon(
                                    option.label,
                                    _winnerFor(pick, play),
                                    play,
                                  );
                                  final lost = _isSettled && !won;
                                  final active = won || !_isSettled;
                                  final background = active
                                      ? _green
                                      : lost
                                          ? const Color(0xffe8ece9)
                                          : Colors.white;
                                  final foreground = won || !_isSavedScheme
                                      ? Colors.white
                                      : const Color(0xff69716d);
                                  return Container(
                                    width: cellWidth,
                                    height: 48,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: background,
                                      border: Border.all(
                                        color: active
                                            ? _green
                                            : const Color(0xffd4dbd6),
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _compactOptionLabel(
                                            play,
                                            option.label,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            color: foreground,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          option.sp.toStringAsFixed(2),
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: active
                                                ? const Color(0xffe8f7f0)
                                                : const Color(0xff818985),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _schemeOverview(BettingResult value) {
    final actualPrize = _actualPrize;
    final currentMultiple = int.tryParse(multipleController.text) ?? 1;
    final isLost = _settlementState == 'lost';
    final isSettling = _settlementState == 'in_progress';
    final isPending = _isSavedScheme && _settlementState == 'pending';
    final finishedMatches =
        widget.savedSettlement?['finishedMatches']?.toString() ?? '0';
    final totalMatches =
        widget.savedSettlement?['totalMatches']?.toString() ?? '--';
    final statusTitle = actualPrize != null
        ? '实际奖金'
        : isLost
            ? '赛果'
            : isSettling || isPending
                ? '结算状态'
                : '最高奖金';
    final statusValue = actualPrize != null
        ? '${actualPrize.toStringAsFixed(2)}元'
        : isLost
            ? '未中奖'
            : isSettling
                ? '结算中 $finishedMatches/$totalMatches'
                : isPending
                    ? '待开赛'
                    : '${value.maxReturn.toStringAsFixed(2)}元';
    final statusColor = actualPrize != null
        ? const Color(0xffc76a00)
        : isSettling
            ? const Color(0xff9a6814)
            : isPending
                ? const Color(0xff2778ad)
                : const Color(0xff5f6863);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Text(
                '金额',
                style: TextStyle(fontSize: 12, color: Color(0xff7d8581)),
              ),
              const SizedBox(width: 7),
              Text(
                '${value.amount.toStringAsFixed(0)}元',
                style: const TextStyle(
                  fontSize: 16,
                  color: Color(0xff303733),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '[$currentMultiple倍]',
                style: const TextStyle(fontSize: 11, color: Color(0xff7d8581)),
              ),
              const Spacer(),
              Text(
                statusTitle,
                style: const TextStyle(fontSize: 11, color: Color(0xff7d8581)),
              ),
              const SizedBox(width: 6),
              Text(
                statusValue,
                style: TextStyle(
                  fontSize: 14,
                  color: statusColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          Row(
            children: [
              const Text(
                '竞彩足球',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xff168f62),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${widget.picks.length}场  $_passLabel',
                style: const TextStyle(fontSize: 12, color: Color(0xff4f5753)),
              ),
              const Spacer(),
              Text(
                '${value.notes}注',
                style: const TextStyle(fontSize: 11, color: Color(0xff7d8581)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 15,
                color: Color(0xff7d8581),
              ),
              SizedBox(width: 5),
              Expanded(
                child: Text(
                  '方案倍数为计算值，不等同于真实出票票面；本应用不出票。',
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.35,
                    color: Color(0xff858d89),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ticketCards() => Column(
        children: [
          for (final pick in widget.picks)
            Builder(
              builder: (_) {
                final score = _scoreFor(pick);
                final hasOutcome = score.isNotEmpty;
                final hasHit = pick.options.any((option) {
                  final play = option.play ?? pick.play;
                  return _optionWon(option.label, _winnerFor(pick, play), play);
                });
                final statusLabel = !_isSettled
                    ? ''
                    : hasHit
                        ? '命中'
                        : '未中';
                final statusColor = hasHit ? _green : const Color(0xff767e7a);
                return Container(
                  margin: const EdgeInsets.only(bottom: 7),
                  padding: const EdgeInsets.fromLTRB(13, 9, 13, 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text(
                            pick.number,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xff7c8480),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            pick.league,
                            style: const TextStyle(
                              fontSize: 12,
                              color: _green,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          if (statusLabel.isNotEmpty) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: hasHit
                                    ? const Color(0xffe3f3ea)
                                    : const Color(0xffeef1ef),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                statusLabel,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: statusColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            hasOutcome ? '完场' : _kickoffLabel(pick),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xff8a918e),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              pick.home,
                              textAlign: TextAlign.right,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 54,
                            child: Text(
                              hasOutcome ? score : 'VS',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: hasOutcome ? 16 : 13,
                                color: hasOutcome
                                    ? const Color(0xff303733)
                                    : const Color(0xff9ba19e),
                                fontWeight: hasOutcome
                                    ? FontWeight.w800
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              pick.away,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      _resultOddsRow(pick, FootballPlay.had),
                      _resultOddsRow(pick, FootballPlay.hhad),
                      _otherPlaySelections(pick),
                    ],
                  ),
                );
              },
            ),
        ],
      );

  Widget _summary(BettingResult value) {
    final actualPrize = _actualPrize;
    final isLost = _settlementState == 'lost';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$_passLabel · ${value.notes}注',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '${value.amount.toStringAsFixed(0)}元',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          if (actualPrize != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '实际税前奖金',
                  style: TextStyle(fontSize: 12, color: Color(0xff7d8581)),
                ),
                const SizedBox(height: 2),
                Text(
                  '${actualPrize.toStringAsFixed(2)}元',
                  style: const TextStyle(
                    fontSize: 20,
                    color: Color(0xffc76a00),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            )
          else if (isLost)
            const Text(
              '本方案未中奖',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xff767e7a),
                fontWeight: FontWeight.w700,
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '预计奖金',
                  style: TextStyle(fontSize: 12, color: Color(0xff7d8581)),
                ),
                const SizedBox(height: 2),
                Text(
                  _prizeText(value.minReturn, value.maxReturn),
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xffdf4162),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          if (widget.optimizationOnly) ...[
            const SizedBox(height: 8),
            if (value.principalProtected == true)
              const Text(
                '已按当前投入完成保本分配',
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xff168f62),
                  fontWeight: FontWeight.w600,
                ),
              ),
            Builder(
              builder: (_) {
                final budget = double.tryParse(budgetController.text) ?? 0;
                final remaining = math.max(0, budget - value.amount);
                return Text(
                  '预算${budget.toStringAsFixed(0)}元  ·  已分配${value.amount.toStringAsFixed(0)}元  ·  剩余${remaining.toStringAsFixed(0)}元',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff7d8581),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _combinations(BettingResult value) {
    final entries = value.returnsByCombination.entries.toList();
    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
              widget.optimizationOnly
                  ? '${entries.length}个组合 · 共${value.notes}注'
                  : '组合明细（${entries.length}）',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          for (var index = 0; index < entries.length; index++)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0xffedf0ee), width: .7),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 26,
                    child: Text(
                      '${index + 1}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xff969d99),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in _betLines(entries[index].key))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              line,
                              style: const TextStyle(
                                fontSize: 12.5,
                                height: 1.3,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: widget.optimizationOnly ? 100 : 48,
                    child: widget.optimizationOnly
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _stepButton(
                                Icons.remove,
                                () => _adjustMultiple(entries[index].key, -1),
                              ),
                              Container(
                                width: 44,
                                height: 30,
                                alignment: Alignment.center,
                                decoration: const BoxDecoration(
                                  border: Border.symmetric(
                                    horizontal: BorderSide(
                                      color: Color(0xffdfe4e1),
                                    ),
                                  ),
                                ),
                                child: Text(
                                  '${_multipleFor(value, entries[index].key)}倍',
                                  maxLines: 1,
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              _stepButton(
                                Icons.add,
                                () => _adjustMultiple(entries[index].key, 1),
                              ),
                            ],
                          )
                        : Text(
                            '${_multipleFor(value, entries[index].key)}倍',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xff68716c),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 78,
                    child: Builder(
                      builder: (_) {
                        final won =
                            _isSettled && _ticketWon(entries[index].key);
                        final text = _isSettled
                            ? (won
                                ? '中奖 ${entries[index].value.toStringAsFixed(2)}元'
                                : '未中')
                            : '${entries[index].value.toStringAsFixed(2)}元';
                        return Text(
                          text,
                          maxLines: 2,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: won
                                ? const Color(0xffc76a00)
                                : _isSettled
                                    ? const Color(0xff767e7a)
                                    : const Color(0xffdf4162),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _stepButton(IconData icon, VoidCallback onPressed) => SizedBox(
        width: 28,
        height: 30,
        child: IconButton(
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
              side: BorderSide(color: Color(0xffdfe4e1)),
            ),
          ),
          onPressed: onPressed,
          icon: Icon(icon, size: 15),
        ),
      );

  Widget _combinationToggle(BettingResult value) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => showCombinations = !showCombinations),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            child: Row(
              children: [
                const Icon(
                  Icons.receipt_long_outlined,
                  size: 18,
                  color: Color(0xff6f7874),
                ),
                const SizedBox(width: 9),
                Text(
                  showCombinations ? '收起组合明细' : '展开组合明细',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '${value.returnsByCombination.length}个组合',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xff7d8581)),
                ),
                const SizedBox(width: 3),
                Icon(
                  showCombinations
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 20,
                  color: const Color(0xff7d8581),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _validityHint() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Center(
          child: Text(
            '最早开赛 ${_earliestKickoff()}  ·  SP以保存时为准',
            style: const TextStyle(fontSize: 11, color: Color(0xff858d89)),
          ),
        ),
      );

  Widget _bottomActions(BettingResult? value) => SafeArea(
        top: false,
        child: Container(
          height: 64,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: const BoxDecoration(
            color: Colors.white,
            border:
                Border(top: BorderSide(color: Color(0xffe5e9e7), width: .7)),
          ),
          child: Row(
            children: [
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
                  label: Text(isSharing ? '生成中' : '分享方案'),
                ),
              ),
              if (!_isSavedScheme) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: FilledButton(
                    onPressed: value == null ? null : () => _save(value),
                    style: FilledButton.styleFrom(backgroundColor: _green),
                    child: const Text('保存方案'),
                  ),
                ),
              ],
            ],
          ),
        ),
      );

  Widget _optimizationBottom(BettingResult? value) => SafeArea(
        top: false,
        child: Container(
          height: 64,
          padding: const EdgeInsets.fromLTRB(80, 8, 12, 8),
          decoration: const BoxDecoration(
            color: Colors.white,
            border:
                Border(top: BorderSide(color: Color(0xffe5e9e7), width: .7)),
          ),
          child: FilledButton(
            onPressed: value == null
                ? null
                : () async {
                    await _save(value);
                    if (!mounted) return;
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _SchemePage(
                          picks: widget.picks,
                          initialPasses: selectedMethods,
                          initialBudget: value.amount,
                          initialResult: value,
                          initialShowCombinations: true,
                        ),
                      ),
                    );
                  },
            style: FilledButton.styleFrom(backgroundColor: _green),
            child: const Text('保存优化方案'),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final value = result;
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(
          widget.optimizationOnly
              ? '奖金优化'
              : _isSavedScheme
                  ? '方案详情'
                  : '生成方案',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
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
              Text(
                error!,
                style: const TextStyle(fontSize: 12, color: Color(0xffdc4560)),
              ),
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
              Center(
                child: Text(
                  _isSettled ? '赛果按全场90分钟（含伤停补时）结算' : '预计奖金仅供参考，SP变化后请重新计算',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff8b928f),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: widget.optimizationOnly
          ? _optimizationBottom(value)
          : _bottomActions(value),
    );
  }
}

class _SavedSchemesSheet extends StatefulWidget {
  const _SavedSchemesSheet();

  @override
  State<_SavedSchemesSheet> createState() => _SavedSchemesSheetState();
}

class _SavedSchemesSheetState extends State<_SavedSchemesSheet>
    with WidgetsBindingObserver {
  List<String> rawItems = const [];
  bool loading = true;
  bool settling = false;
  bool reloading = false;
  String statusFilter = 'all';
  DateTime? lastCheckedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    if (reloading) return;
    reloading = true;
    try {
      if (!mounted) return;
      final retained = await const SavedSchemeStore().load();
      if (!mounted) return;
      setState(() {
        rawItems = retained;
        loading = true;
      });
      await _settleSavedSchemes();
      if (mounted) {
        setState(() {
          loading = false;
          lastCheckedAt = DateTime.now();
        });
      }
    } finally {
      reloading = false;
    }
  }

  String _lastCheckedLabel() {
    final value = lastCheckedAt;
    if (value == null) return '';
    return '已检查 ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
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
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final updated = [...rawItems]..removeAt(index);
    await const SavedSchemeStore().replace(updated);
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

  String _settlementState(Map<String, dynamic> item) {
    final settlement = item['settlement'];
    return settlement is Map ? settlement['state']?.toString() ?? '' : '';
  }

  List<String> _visibleItems() => rawItems.where((raw) {
        final item = _decode(raw);
        if (!_withinLastSevenDays(item)) return false;
        return switch (statusFilter) {
          'won' || 'lost' => _settlementState(item) == statusFilter,
          'pending' => !{'won', 'lost'}.contains(_settlementState(item)),
          _ => true,
        };
      }).toList(growable: false);

  ({String label, Color background, Color foreground}) _statusStyle(
    Map<String, dynamic> item,
  ) {
    final settlement = item['settlement'];
    final state = settlement is Map ? settlement['state']?.toString() : '';
    if (state == 'won') {
      if (settlement?['legacy'] == true) {
        final legacyPrize = num.tryParse(
          settlement?['prize']?.toString() ?? '',
        );
        return (
          label: legacyPrize == null
              ? '已中奖 · 奖金待补'
              : '奖金${legacyPrize.toStringAsFixed(2)}元',
          background: const Color(0xffffedd2),
          foreground: const Color(0xffc76a00),
        );
      }
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
    if (state == 'in_progress') {
      final finished = settlement?['finishedMatches']?.toString() ?? '0';
      final total = settlement?['totalMatches']?.toString() ?? '--';
      return (
        label: '结算中 $finished/$total',
        background: const Color(0xfffff3d6),
        foreground: const Color(0xff9a6814),
      );
    }
    return (
      label: '待开赛',
      background: const Color(0xffe1f0ff),
      foreground: const Color(0xff2778ad),
    );
  }

  String _optimizationLabel(Map<String, dynamic> item) {
    final optimization = item['optimization'];
    if (optimization is! Map) {
      return item['optimizationOnly'] == true ? '奖金优化' : '';
    }
    final mode = switch (optimization['mode']?.toString()) {
      'hot' => '博热',
      'cold' => '博冷',
      'balanced' => '平均',
      _ => '奖金优化',
    };
    return optimization['principalProtected'] == true ? '$mode · 已保本' : mode;
  }

  String _schemeAmountDetail(Map<String, dynamic> item) {
    final settlement = item['settlement'];
    final state = settlement is Map ? settlement['state']?.toString() : '';
    final prize = settlement is Map
        ? num.tryParse(settlement['prize']?.toString() ?? '')
        : null;
    if (state == 'won' && prize != null) {
      return '实际奖金${prize.toStringAsFixed(2)}元';
    }
    if (state == 'lost') return '未中奖';
    final minReturn = num.tryParse(item['minReturn']?.toString() ?? '');
    final maxReturn = num.tryParse(item['maxReturn']?.toString() ?? '');
    if (minReturn == null || maxReturn == null) return '';
    return '预计奖金${minReturn.toStringAsFixed(2)}～${maxReturn.toStringAsFixed(2)}元';
  }

  String _schemeMeta(Map<String, dynamic> item) {
    final details = <String>[];
    final picks = item['picks'];
    if (picks is List && picks.isNotEmpty) details.add('${picks.length}场');
    final notes = num.tryParse(item['notes']?.toString() ?? '');
    if (notes != null) details.add('${notes.toStringAsFixed(0)}注');
    final tickets = num.tryParse(item['physicalTickets']?.toString() ?? '');
    if (tickets != null && tickets > 0) {
      details.add('${tickets.toStringAsFixed(0)}张票');
    }
    final amountDetail = _schemeAmountDetail(item);
    if (amountDetail.isNotEmpty) details.add(amountDetail);
    return details.join(' · ');
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
        options.add(
          BetOption(
            label: rawOption['label']?.toString() ?? '',
            sp: sp.toDouble(),
            play: _play(rawOption['play']) ?? play,
          ),
        );
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
      picks.add(
        MatchPick(
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
          singleSupported: raw['singleSupported'] != false,
          availableOdds: availableOdds,
        ),
      );
    }
    return picks;
  }

  bool _isFinished(MatchItem match) =>
      match.matchState == MatchState.finished ||
      match.status == MatchStatus.finished ||
      (match.finalScore?.isNotEmpty ?? false);

  ({int home, int away})? _score(String? value) {
    final found = RegExp(
      r'^(\d+)\s*[:\-]\s*(\d+)$',
    ).firstMatch(value?.trim() ?? '');
    if (found == null) return null;
    return (home: int.parse(found.group(1)!), away: int.parse(found.group(2)!));
  }

  String _outcome(
    int home,
    int away, {
    String win = '胜',
    String draw = '平',
    String lose = '负',
  }) =>
      home > away
          ? win
          : home == away
              ? draw
              : lose;

  String? _winningLabel(
    MatchItem match,
    FootballPlay play, {
    String? savedHandicap,
  }) {
    final score = _score(match.finalScore);
    if (score == null) return null;
    switch (play) {
      case FootballPlay.had:
        return _outcome(score.home, score.away);
      case FootballPlay.hhad:
        final handicap = double.tryParse(savedHandicap?.trim() ?? '') ??
            double.tryParse(match.hhad['让球']?.toString() ?? '') ??
            0;
        return _outcome(
          score.home + handicap.round(),
          score.away,
          win: '让胜',
          draw: '让平',
          lose: '让负',
        );
      case FootballPlay.ttg:
        final total = score.home + score.away;
        return total >= 7 ? '7+' : '$total';
      case FootballPlay.crs:
        return footballScoreResultLabel(score.home, score.away);
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

  double? _legacyPrizeFromText(
    Map<String, dynamic> item,
    List<dynamic> picks,
    Map<String, Map<String, String>> winners,
  ) {
    final text = item['text']?.toString() ?? '';
    if (text.isEmpty) return null;
    final matchIdsByNumber = <String, String>{
      for (final pick in picks.whereType<Map>())
        pick['number']?.toString() ?? '': pick['matchId']?.toString() ?? '',
    };
    final selectionPattern = RegExp(
      r'(周[一二三四五六日]\d+)\s+(胜平负|让球胜平负|总进球|比分|半全场)\[([^\]]+)\]',
    );
    final prizePattern = RegExp(r'｜\s*([0-9]+(?:\.[0-9]+)?)元\s*$');
    var parsed = 0;
    var prize = 0.0;
    for (final line in text.split('\n')) {
      if (!RegExp(r'^\s*\d+\.').hasMatch(line)) continue;
      final prizeMatch = prizePattern.firstMatch(line);
      final selections = selectionPattern.allMatches(line).toList();
      if (prizeMatch == null || selections.isEmpty) continue;
      final returnAmount = double.tryParse(prizeMatch.group(1)!);
      if (returnAmount == null) continue;
      parsed += 1;
      var wins = true;
      for (final selection in selections) {
        final play = switch (selection.group(2)!) {
          '胜平负' => FootballPlay.had,
          '让球胜平负' => FootballPlay.hhad,
          '总进球' => FootballPlay.ttg,
          '比分' => FootballPlay.crs,
          '半全场' => FootballPlay.hafu,
          _ => null,
        };
        final matchId = matchIdsByNumber[selection.group(1)!];
        if (play == null || matchId == null) {
          wins = false;
          break;
        }
        final winner = winners[matchId]?[play.name];
        if (winner == null || !_optionWins(selection.group(3)!, winner, play)) {
          wins = false;
          break;
        }
      }
      if (wins) prize += returnAmount;
    }
    return parsed == 0 ? null : double.parse(prize.toStringAsFixed(2));
  }

  double? _legacyPrizeFromStructure(
    Map<String, dynamic> item,
    Map<String, Map<String, String>> winners,
  ) {
    if (item['optimizationOnly'] == true) return null;
    final restoredPicks = _restorePicks(item);
    if (restoredPicks.isEmpty) return null;
    try {
      final result = const BettingEngine().calculateMultiple(
        picks: restoredPicks,
        passes: _restorePasses(item, restoredPicks),
        multiple: (int.tryParse(item['multiple']?.toString() ?? '') ?? 1).clamp(
          1,
          BettingEngine.maxSchemeMultiple,
        ),
      );
      var prize = 0.0;
      for (final entry in result.returnsByCombination.entries) {
        final won = entry.key.picks.every((pick) {
          final play = pick.option.play ?? pick.match.play;
          final winner = winners[pick.match.matchId]?[play.name] ?? '';
          return _optionWins(pick.option.label, winner, play);
        });
        if (won) prize += entry.value;
      }
      return double.parse(prize.toStringAsFixed(2));
    } catch (_) {
      return null;
    }
  }

  Future<void> _settleSavedSchemes() async {
    if (settling) return;
    if (mounted) setState(() => settling = true);
    try {
      final decoded = rawItems.map(_decode).toList(growable: false);
      final candidates = decoded
          .where((item) => item['picks'] is List && _withinLastSevenDays(item))
          .toList(growable: false);
      if (candidates.isEmpty) return;
      final ids = <String>{
        for (final item in candidates)
          for (final pick
              in (item['picks'] is List ? item['picks'] as List : const []))
            if (pick is Map && pick['matchId']?.toString().isNotEmpty == true)
              pick['matchId'].toString(),
      };
      if (ids.isEmpty) return;
      final client = CaiApiClient();
      final matches = <String, MatchItem>{};
      try {
        await Future.wait(
          ids.map((id) async {
            try {
              matches[id] = await client.fetchMatch(id);
            } catch (_) {
              // Keep this plan pending until the next time the saved list is opened.
            }
          }),
        );
      } finally {
        client.close();
      }
      var changed = false;
      final updated = <String>[];
      for (final raw in rawItems) {
        final item = _decode(raw);
        final currentSettlement = item['settlement'];
        final currentState = currentSettlement is Map
            ? currentSettlement['state']?.toString()
            : '';
        if (item['picks'] is! List || !_withinLastSevenDays(item)) {
          updated.add(raw);
          continue;
        }
        final picks = item['picks'] is List ? item['picks'] as List : const [];
        final matchIds = [
          for (final pick in picks)
            if (pick is Map) pick['matchId']?.toString() ?? '',
        ].where((id) => id.isNotEmpty).toSet();
        // Do not replace an existing settlement while one of its results
        // failed to load. The next refresh will retry the whole scheme.
        if (matchIds.isEmpty || !matchIds.every(matches.containsKey)) {
          updated.add(raw);
          continue;
        }
        final finishedMatches = matchIds
            .where((id) => matches[id] != null && _isFinished(matches[id]!))
            .length;
        final allFinished =
            matchIds.isNotEmpty && finishedMatches == matchIds.length;
        if (!allFinished) {
          final hasPassedKickoff = picks.whereType<Map>().any((pick) {
            final kickoff = DateTime.tryParse(
              pick['kickoff']?.toString() ?? '',
            );
            return kickoff != null && !kickoff.isAfter(DateTime.now());
          });
          final nextState = finishedMatches > 0 || hasPassedKickoff
              ? 'in_progress'
              : 'pending';
          final previousFinished = currentSettlement is Map
              ? currentSettlement['finishedMatches']?.toString()
              : '';
          if (currentState != nextState ||
              previousFinished != finishedMatches.toString()) {
            item['settlement'] = {
              'state': nextState,
              'finishedMatches': finishedMatches,
              'totalMatches': matchIds.length,
              'updatedAt': DateTime.now().toIso8601String(),
            };
            item['status'] = nextState == 'in_progress' ? '结算中' : '待开赛';
            updated.add(jsonEncode(item));
            changed = true;
          } else {
            updated.add(raw);
          }
          continue;
        }
        final winners = <String, Map<String, String>>{};
        var hasAllOutcomes = true;
        for (final pick in picks.whereType<Map>()) {
          final match = matches[pick['matchId']?.toString()];
          if (match == null) continue;
          final labels = <String, String>{};
          for (final rawOption in (pick['options'] is List
              ? pick['options'] as List
              : const [])) {
            if (rawOption is! Map) continue;
            final play = _play(rawOption['play']);
            if (play == null) continue;
            final winner = _winningLabel(
              match,
              play,
              savedHandicap: pick['handicap']?.toString(),
            );
            if (winner == null) {
              hasAllOutcomes = false;
            } else {
              labels[play.name] = winner;
            }
          }
          winners[pick['matchId']?.toString() ?? ''] = labels;
        }
        // A finished match may still lack half-time or official pool data.
        // Keep it in settlement instead of incorrectly marking it as a loss.
        if (!hasAllOutcomes) {
          item['settlement'] = {
            'state': 'in_progress',
            'finishedMatches': matchIds.length,
            'totalMatches': matchIds.length,
            'updatedAt': DateTime.now().toIso8601String(),
          };
          item['status'] = '结算中';
          updated.add(jsonEncode(item));
          changed = true;
          continue;
        }
        final outcomes = <String, dynamic>{
          for (final id in matchIds)
            id: {
              'score': matches[id]?.finalScore ?? matches[id]?.score ?? '--',
              'winners': winners[id] ?? const <String, String>{},
            },
        };
        if (item['combinations'] is! List) {
          final legacyPrize = _legacyPrizeFromText(item, picks, winners) ??
              _legacyPrizeFromStructure(item, winners);
          final legacyWon = legacyPrize != null && legacyPrize > 0;
          item['settlement'] = {
            'state': legacyWon ? 'won' : 'lost',
            'legacy': true,
            if (legacyPrize != null) 'prize': legacyPrize,
            'finishedMatches': matchIds.length,
            'totalMatches': matchIds.length,
            'settledAt': DateTime.now().toIso8601String(),
            'outcomes': outcomes,
          };
          item['status'] = legacyWon ? '已中奖' : '未中奖';
          updated.add(jsonEncode(item));
          changed = true;
          continue;
        }
        var prize = 0.0;
        for (final combination in item['combinations'] as List) {
          if (combination is! Map || combination['picks'] is! List) continue;
          var wins = true;
          var spProduct = 1.0;
          for (final rawPick in combination['picks'] as List) {
            if (rawPick is! Map) {
              wins = false;
              break;
            }
            final play = _play(rawPick['play']);
            if (play == null) {
              wins = false;
              break;
            }
            final winner = winners[rawPick['matchId']?.toString()]?[play.name];
            if (winner == null ||
                !_optionWins(
                  rawPick['label']?.toString() ?? '',
                  winner,
                  play,
                )) {
              wins = false;
              break;
            }
            spProduct *=
                num.tryParse(rawPick['sp']?.toString() ?? '')?.toDouble() ?? 0;
          }
          if (wins) {
            final savedReturn = num.tryParse(
              combination['return']?.toString() ?? '',
            )?.toDouble();
            if (savedReturn != null && savedReturn >= 0) {
              prize += savedReturn;
            } else {
              final multiple = num.tryParse(
                    combination['multiple']?.toString() ?? '',
                  )?.toInt() ??
                  0;
              final passSize =
                  int.tryParse(combination['passSize']?.toString() ?? '') ??
                      (combination['picks'] as List).length;
              prize +=
                  lotteryUnitReturn(spProduct: spProduct, passSize: passSize) *
                      multiple;
            }
          }
        }
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
      await const SavedSchemeStore().replace(updated);
      if (mounted) setState(() => rawItems = updated);
    } finally {
      if (mounted) setState(() => settling = false);
    }
  }

  Future<void> _openScheme(Map<String, dynamic> item) async {
    final picks = _restorePicks(item);
    if (picks.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('旧方案缺少结构化选号数据，可先复制文字查看')));
      return;
    }
    final passes = _restorePasses(item, picks);
    final restoredResult = _restoreResult(item, picks, passes);
    if (restoredResult != null) {
      final settlement = item['settlement'];
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _SchemePage(
            picks: picks,
            initialPasses: passes,
            initialMultiple:
                int.tryParse(item['multiple']?.toString() ?? '') ?? 1,
            initialBudget: num.tryParse(
              item['amount']?.toString() ?? '',
            )?.toDouble(),
            initialResult: restoredResult,
            initialShowCombinations: true,
            savedSettlement: settlement is Map
                ? Map<String, dynamic>.from(settlement)
                : const {'state': 'pending'},
          ),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _SavedSchemeDetailPage(item: item)),
    );
  }

  List<PassMethod> _restorePasses(
    Map<String, dynamic> item,
    List<MatchPick> picks,
  ) {
    final maxPass = picks
        .expand(
          (pick) =>
              pick.options.map((option) => (option.play ?? pick.play).maxPass),
        )
        .reduce(math.min);
    final available = PassMethod.available(picks.length, maxPass);
    final stored = item['passes'] is List
        ? (item['passes'] as List).map((value) => value.toString()).toSet()
        : {item['pass']?.toString() ?? ''};
    final restored = available
        .where((method) => stored.contains(method.label))
        .toList(growable: false);
    return restored.isEmpty ? [available.last] : restored;
  }

  BettingResult? _restoreResult(
    Map<String, dynamic> item,
    List<MatchPick> picks,
    List<PassMethod> passes,
  ) {
    final rawCombinations = item['combinations'];
    if (rawCombinations is! List || rawCombinations.isEmpty) {
      if (item['optimizationOnly'] == true) return null;
      try {
        final calculated = const BettingEngine().calculateMultiple(
          picks: picks,
          passes: passes,
          multiple: (int.tryParse(item['multiple']?.toString() ?? '') ?? 1)
              .clamp(1, BettingEngine.maxSchemeMultiple),
        );
        return item['isSplit'] == true
            ? const BettingEngine().split(calculated)
            : calculated;
      } catch (_) {
        return null;
      }
    }
    final matches = {for (final pick in picks) pick.matchId: pick};
    final atomicBets = <AtomicBet>[];
    final tickets = <SplitTicket>[];
    for (final rawCombination in rawCombinations) {
      if (rawCombination is! Map || rawCombination['picks'] is! List) continue;
      final legs = <({MatchPick match, BetOption option})>[];
      for (final rawLeg in rawCombination['picks'] as List) {
        if (rawLeg is! Map) continue;
        final match = matches[rawLeg['matchId']?.toString()];
        final play = _play(rawLeg['play']);
        final sp = num.tryParse(rawLeg['sp']?.toString() ?? '');
        if (match == null || play == null || sp == null || sp <= 0) continue;
        legs.add((
          match: match,
          option: BetOption(
            label: rawLeg['label']?.toString() ?? '',
            sp: sp.toDouble(),
            play: play,
          ),
        ));
      }
      if (legs.isEmpty) continue;
      final bet = AtomicBet(
        picks: legs,
        passSize: int.tryParse(rawCombination['passSize']?.toString() ?? '') ??
            legs.length,
      );
      final multiple =
          int.tryParse(rawCombination['multiple']?.toString() ?? '') ?? 0;
      if (multiple < 1) continue;
      atomicBets.add(bet);
      tickets.add(SplitTicket(bet: bet, multiple: multiple));
    }
    if (atomicBets.isEmpty) return null;
    final restored = BettingResult(atomicBets, tickets);
    return item['isSplit'] == true
        ? const BettingEngine().split(restored)
        : restored;
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .82,
        maxChildSize: .95,
        builder: (_, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '保存方案',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                    ),
                  ),
                  if (_lastCheckedLabel().isNotEmpty)
                    Text(
                      _lastCheckedLabel(),
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xff858d89),
                      ),
                    ),
                  if (_lastCheckedLabel().isNotEmpty) const SizedBox(width: 2),
                  IconButton(
                    tooltip: '刷新开奖结果',
                    onPressed: loading || settling ? null : _load,
                    icon: settling
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Color(0xff7b8580),
                  ),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '保存方案与暂存选号仅保存在本机，不同步云端；保存方案最近7天可查看，过期自动清理。',
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.35,
                        color: Color(0xff7b8580),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'all', label: Text('全部')),
                  ButtonSegment(value: 'pending', label: Text('待结算')),
                  ButtonSegment(value: 'won', label: Text('中奖')),
                  ButtonSegment(value: 'lost', label: Text('未中')),
                ],
                selected: {statusFilter},
                onSelectionChanged: (value) =>
                    setState(() => statusFilter = value.first),
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : _visibleItems().isEmpty
                      ? Center(
                          child: Text(
                            statusFilter == 'all' ? '最近7天暂无保存方案' : '暂无符合条件的方案',
                          ),
                        )
                      : ListView.separated(
                          controller: controller,
                          padding: const EdgeInsets.all(12),
                          itemCount: _visibleItems().length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (_, index) {
                            final visible = _visibleItems();
                            final raw = visible[index];
                            final item = _decode(raw);
                            final amount = item['amount'];
                            final status = _statusStyle(item);
                            final optimization = _optimizationLabel(item);
                            final schemeMeta = _schemeMeta(item);
                            return Card(
                              elevation: 0,
                              color: const Color(0xfff6f8f7),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: InkWell(
                                onTap: () => _openScheme(item),
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: status.background,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              status.label,
                                              style: TextStyle(
                                                color: status.foreground,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          const Spacer(),
                                          Text(
                                            _time(item['createdAt']),
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xff858d89),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        '${item['pass'] ?? '竞彩足球'}${amount == null ? '' : ' · ${((amount as num).toDouble()).toStringAsFixed(0)}元'}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      if (optimization.isNotEmpty)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 3),
                                          child: Text(
                                            optimization,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xff168f62),
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      if (schemeMeta.isNotEmpty)
                                        Text(
                                          schemeMeta,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Color(0xff6f7773),
                                          ),
                                        ),
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
                                                      '',
                                                ),
                                              );
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(
                                                  context,
                                                ).showSnackBar(
                                                  const SnackBar(
                                                    content: Text('方案文字已复制'),
                                                  ),
                                                );
                                              }
                                            },
                                            icon: const Icon(
                                              Icons.copy_outlined,
                                              size: 16,
                                            ),
                                            label: const Text('复制'),
                                          ),
                                          TextButton.icon(
                                            onPressed: () =>
                                                _delete(rawItems.indexOf(raw)),
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              size: 16,
                                            ),
                                            label: const Text('删除'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      );
}

class _SavedSchemeDetailPage extends StatelessWidget {
  const _SavedSchemeDetailPage({required this.item});

  final Map<String, dynamic> item;

  String _optimizationLabel() {
    final optimization = item['optimization'];
    if (optimization is! Map) {
      return item['optimizationOnly'] == true ? '奖金优化' : '';
    }
    final mode = switch (optimization['mode']?.toString()) {
      'hot' => '博热优化',
      'cold' => '博冷优化',
      'balanced' => '平均优化',
      _ => '奖金优化',
    };
    return optimization['principalProtected'] == true ? '$mode · 已保本' : mode;
  }

  String _combinationDescription(Map combination) {
    final savedPicks = item['picks'] is List ? item['picks'] as List : const [];
    final numbers = <String, String>{
      for (final raw in savedPicks.whereType<Map>())
        raw['matchId']?.toString() ?? '': raw['number']?.toString() ?? '--',
    };
    final parts = <String>[];
    for (final raw in (combination['picks'] is List
        ? combination['picks'] as List
        : const [])) {
      if (raw is! Map) continue;
      final number = numbers[raw['matchId']?.toString()] ?? '--';
      parts.add('$number ${raw['label'] ?? '--'}');
    }
    return parts.isEmpty ? '--' : parts.join(' × ');
  }

  double? _combinationReturn(Map combination) {
    final stored = num.tryParse(combination['return']?.toString() ?? '');
    if (stored != null) return stored.toDouble();
    final multiple = num.tryParse(combination['multiple']?.toString() ?? '');
    final picks = combination['picks'];
    if (multiple == null || picks is! List) return null;
    var product = 1.0;
    for (final raw in picks) {
      if (raw is! Map) return null;
      final sp = num.tryParse(raw['sp']?.toString() ?? '');
      if (sp == null) return null;
      product *= sp.toDouble();
    }
    return 2 * product * multiple.toDouble();
  }

  bool _combinationWon(Map combination, Map<String, dynamic> outcomes) {
    final picks = combination['picks'];
    if (picks is! List || picks.isEmpty) return false;
    for (final raw in picks) {
      if (raw is! Map) return false;
      final matchId = raw['matchId']?.toString() ?? '';
      final play = raw['play']?.toString() ?? '';
      final winner = _winner(outcomes, matchId, play);
      if (winner.isEmpty ||
          !_isWinningOption(raw['label']?.toString() ?? '', winner, play)) {
        return false;
      }
    }
    return true;
  }

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
    final combinations =
        item['combinations'] is List ? item['combinations'] as List : const [];
    final estimatedMin = num.tryParse(item['minReturn']?.toString() ?? '');
    final estimatedMax = num.tryParse(item['maxReturn']?.toString() ?? '');
    final optimization = _optimizationLabel();
    final statusColor = state == 'won'
        ? const Color(0xffc76a00)
        : state == 'lost'
            ? const Color(0xff767e7a)
            : state == 'in_progress'
                ? const Color(0xff9a6814)
                : const Color(0xff2778ad);
    final statusLabel = switch (state) {
      'won' when settlement?['legacy'] == true && prize != null =>
        '实际税前奖金 ${prize.toStringAsFixed(2)} 元',
      'won' when settlement?['legacy'] == true => '已中奖 · 旧方案未保存组合金额',
      'won' => '实际税前奖金 ${prize?.toStringAsFixed(2) ?? '--'} 元',
      'lost' => '未中奖',
      'in_progress' =>
        '结算中 · ${settlement?['finishedMatches'] ?? 0}/${settlement?['totalMatches'] ?? '--'} 场已完场',
      _ => '待开赛',
    };
    return Scaffold(
      backgroundColor: const Color(0xfff5f7f6),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text(
          '方案详情',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['pass']?.toString() ?? '竞彩足球',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${item['notes'] ?? '--'}注 · 投入${num.tryParse(item['amount']?.toString() ?? '')?.toStringAsFixed(0) ?? '--'}元',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff737b77),
                  ),
                ),
                if (estimatedMin != null && estimatedMax != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '预计税前奖金 ${estimatedMin.toStringAsFixed(2)}～${estimatedMax.toStringAsFixed(2)}元',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xffc83d46),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                if (optimization.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    optimization,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff168f62),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          if (combinations.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              color: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(14, 13, 14, 7),
                    child: Text(
                      '组合明细',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  for (var index = 0; index < combinations.length; index++)
                    Builder(
                      builder: (_) {
                        final raw = combinations[index];
                        if (raw is! Map) return const SizedBox.shrink();
                        final combination = Map<String, dynamic>.from(raw);
                        final multiple =
                            combination['multiple']?.toString() ?? '--';
                        final payout = _combinationReturn(combination);
                        final settled = state == 'won' || state == 'lost';
                        final won =
                            settled && _combinationWon(combination, outcomes);
                        return Container(
                          padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
                          decoration: const BoxDecoration(
                            border: Border(
                              top: BorderSide(color: Color(0xffedf0ee)),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 26,
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xff8a928e),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  _combinationDescription(combination),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    '$multiple倍',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xff68716c),
                                    ),
                                  ),
                                  if (payout != null)
                                    Text(
                                      settled
                                          ? (won
                                              ? '中奖 ${payout.toStringAsFixed(2)}元'
                                              : '未中')
                                          : '返奖 ${payout.toStringAsFixed(2)}元',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: settled && !won
                                            ? const Color(0xff7b837f)
                                            : const Color(0xffc83d46),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          for (final rawPick in picks.whereType<Map>()) ...[
            Builder(
              builder: (_) {
                final pick = Map<String, dynamic>.from(rawPick);
                final matchId = pick['matchId']?.toString() ?? '';
                final outcome = outcomes[matchId];
                final score = outcome is Map
                    ? outcome['score']?.toString() ?? '--'
                    : '--';
                final options = pick['options'] is List
                    ? pick['options'] as List
                    : const [];
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            pick['number']?.toString() ?? '--',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${pick['home'] ?? '--'}  $score  ${pick['away'] ?? '--'}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final rawOption in options.whereType<Map>())
                            Builder(
                              builder: (_) {
                                final option = Map<String, dynamic>.from(
                                  rawOption,
                                );
                                final play = option['play']?.toString() ?? '';
                                final winner = _winner(outcomes, matchId, play);
                                final won = _isWinningOption(
                                  option['label']?.toString() ?? '',
                                  winner,
                                  play,
                                );
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
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
                                              : const Color(0xffe0e4e1),
                                    ),
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
                                          : FontWeight.w500,
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
