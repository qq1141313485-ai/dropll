import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../models.dart';
import 'home_match_list.dart';
import 'home_tab_bar.dart';

class HomePageContainer extends StatefulWidget {
  const HomePageContainer({
    required this.onMatchTap,
    super.key,
  });

  final ValueChanged<MatchItem> onMatchTap;

  @override
  State<HomePageContainer> createState() => _HomePageContainerState();
}

class _HomePageContainerState extends State<HomePageContainer>
    with SingleTickerProviderStateMixin {
  final client = CaiApiClient();
  late final TabController _tabController;
  List<MatchItem> today = const [];
  List<MatchItem> finished = const [];
  DateTime finishedDate = DateUtils.dateOnly(DateTime.now());
  int _lastTabIndex = 0;
  Timer? timer;
  bool loadingToday = false;
  bool loadingFinished = false;
  String? todayError;
  String? finishedError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabChange);
    const useDemo = bool.fromEnvironment('CAIMASTER_USE_DEMO');
    if (client.isConfigured) {
      refresh();
    } else if (kDebugMode && useDemo) {
      today =
          demoMatches.where((m) => m.status != MatchStatus.finished).toList();
      finished =
          demoMatches.where((m) => m.status == MatchStatus.finished).toList();
    }
  }

  void _scheduleRefresh() {
    if (!mounted || !client.isConfigured) return;
    timer?.cancel();
    final hasLive = today.any((match) =>
        match.matchState == MatchState.live ||
        match.matchState == MatchState.halftime);
    timer = Timer(Duration(seconds: hasLive ? 5 : 30), refresh);
  }

  void _handleTabChange() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == _lastTabIndex) return;
    final enteringFinished = _tabController.index == 1;
    setState(() {
      _lastTabIndex = _tabController.index;
      if (enteringFinished) {
        finishedDate = DateUtils.dateOnly(DateTime.now());
      }
    });
    if (_tabController.index == 1) {
      refreshFinished();
    }
  }

  Future<void> refresh() async {
    if (loadingToday) return;
    if (mounted) setState(() => loadingToday = true);
    try {
      List<dynamic>? liveItems;
      List<dynamic>? resultItems;
      Object? liveError;
      Object? resultError;
      await Future.wait([
        () async {
          try {
            liveItems = await client.fetchLiveMatches(limit: 300);
          } catch (error) {
            liveError = error;
          }
        }(),
        () async {
          try {
            resultItems = await client.fetchResultMatches(limit: 300);
          } catch (error) {
            resultError = error;
          }
        }(),
      ]);
      if (!mounted) return;
      setState(() {
        if (liveItems != null) {
          today = liveItems!
              .whereType<Map<String, dynamic>>()
              .map(MatchItem.fromJson)
              .toList(growable: false);
          todayError = null;
        } else {
          debugPrint('首页进行中数据加载失败: $liveError');
          todayError = liveError?.toString();
        }
        if (resultItems != null) {
          finished = resultItems!
              .whereType<Map<String, dynamic>>()
              .map(MatchItem.fromJson)
              .toList(growable: false);
          finishedError = null;
        } else {
          debugPrint('首页完场数据加载失败: $resultError');
          finishedError = resultError?.toString();
        }
      });
    } finally {
      if (mounted) {
        setState(() => loadingToday = false);
        _scheduleRefresh();
      }
    }
  }

  Future<void> refreshFinished() async {
    if (loadingFinished) return;
    if (mounted) setState(() => loadingFinished = true);
    try {
      final todayDate = DateUtils.dateOnly(DateTime.now());
      final values = await client.fetchResultMatches(
        limit: 300,
        date:
            DateUtils.isSameDay(finishedDate, todayDate) ? null : finishedDate,
      );
      if (!mounted) return;
      setState(() {
        finished = values
            .whereType<Map<String, dynamic>>()
            .map(MatchItem.fromJson)
            .toList(growable: false);
        finishedError = null;
      });
    } catch (error) {
      if (!mounted) return;
      debugPrint('完场数据加载失败: $error');
      setState(() => finishedError = error.toString());
    } finally {
      if (mounted) setState(() => loadingFinished = false);
    }
  }

  Future<void> pickFinishedDate() async {
    final now = DateUtils.dateOnly(DateTime.now());
    final firstDate = now.subtract(const Duration(days: 60));
    final initialDate = finishedDate.isBefore(firstDate)
        ? firstDate
        : (finishedDate.isAfter(now) ? now : finishedDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: now,
      locale: const Locale('zh', 'CN'),
      helpText: '选择完场日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null || !mounted) return;
    await selectFinishedDate(picked);
  }

  Future<void> selectFinishedDate(DateTime date) async {
    final value = DateUtils.dateOnly(date);
    if (DateUtils.isSameDay(value, finishedDate)) return;
    setState(() => finishedDate = value);
    await refreshFinished();
  }

  @override
  void dispose() {
    timer?.cancel();
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 2),
        HomeTabBar(controller: _tabController),
        const SizedBox(height: 2),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity < -250 && _lastTabIndex == 0) {
                _tabController.animateTo(1);
              } else if (velocity > 250 && _lastTabIndex == 1) {
                _tabController.animateTo(0);
              }
            },
            child: IndexedStack(
              index: _lastTabIndex,
              children: [
                HomeMatchList(
                  matches: today,
                  loadError: todayError,
                  onRefresh: refresh,
                  onMatchTap: widget.onMatchTap,
                ),
                HomeMatchList(
                  matches: finished,
                  loadError: finishedError,
                  onRefresh: refreshFinished,
                  onMatchTap: widget.onMatchTap,
                  selectedDate: finishedDate,
                  onPickDate: pickFinishedDate,
                  onSelectDate: selectFinishedDate,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
