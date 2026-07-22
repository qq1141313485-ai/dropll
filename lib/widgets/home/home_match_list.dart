import 'package:flutter/material.dart';

import '../../models.dart';
import 'home_match_row.dart';

class HomeMatchList extends StatefulWidget {
  const HomeMatchList({
    required this.matches,
    required this.loadError,
    required this.onRefresh,
    required this.onMatchTap,
    this.selectedDate,
    this.onPickDate,
    this.onSelectDate,
    super.key,
  });

  final List<MatchItem> matches;
  final String? loadError;
  final Future<void> Function() onRefresh;
  final ValueChanged<MatchItem> onMatchTap;
  final DateTime? selectedDate;
  final VoidCallback? onPickDate;
  final ValueChanged<DateTime>? onSelectDate;

  bool get _hasFinishedControls =>
      selectedDate != null && onPickDate != null && onSelectDate != null;

  @override
  State<HomeMatchList> createState() => _HomeMatchListState();
}

class _HomeMatchListState extends State<HomeMatchList> {
  final Map<String, GlobalKey> dateKeys = {};
  final ScrollController dateScrollController = ScrollController();

  String dateKey(DateTime date) => '${date.year}-${date.month}-${date.day}';

  void centerSelectedDate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.selectedDate == null) return;
      final today = DateUtils.dateOnly(DateTime.now());
      final dates = List.generate(
        14,
        (index) => today.subtract(Duration(days: 13 - index)),
      );
      final selected = widget.selectedDate!;
      if (!dates.any((date) => DateUtils.isSameDay(date, selected))) {
        dates[0] = selected;
        dates.sort();
      }
      final selectedIndex =
          dates.indexWhere((date) => DateUtils.isSameDay(date, selected));
      if (selectedIndex < 0 || !dateScrollController.hasClients) return;
      final itemWidth = dateScrollController.position.viewportDimension / 4;
      final target = (selectedIndex * itemWidth) -
          (dateScrollController.position.viewportDimension / 2) +
          (itemWidth / 2);
      final max = dateScrollController.position.maxScrollExtent;
      final offset = target.clamp(0.0, max);
      dateScrollController.jumpTo(offset);
    });
  }

  @override
  void initState() {
    super.initState();
    centerSelectedDate();
  }

  @override
  void didUpdateWidget(covariant HomeMatchList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!DateUtils.isSameDay(oldWidget.selectedDate, widget.selectedDate)) {
      centerSelectedDate();
    }
  }

  @override
  void dispose() {
    dateScrollController.dispose();
    super.dispose();
  }

  Widget _buildDateStrip(BuildContext context) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final today = DateUtils.dateOnly(DateTime.now());
    final selectedDate = widget.selectedDate ?? today;
    final dates = List.generate(
      14,
      (index) => today.subtract(Duration(days: 13 - index)),
    );
    if (!dates.any((date) => DateUtils.isSameDay(date, selectedDate))) {
      dates[0] = selectedDate;
      dates.sort();
    }
    final showingAll = DateUtils.isSameDay(selectedDate, today);
    final selectedMatches = showingAll
        ? widget.matches
        : widget.matches
            .where((match) =>
                DateUtils.isSameDay(match.businessDateOnly, selectedDate))
            .toList();

    return Column(
      children: [
        SizedBox(
          height: 44,
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: InkWell(
                  onTap: widget.onPickDate,
                  child: const Icon(Icons.calendar_today_outlined, size: 18),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final itemWidth = constraints.maxWidth / 4;
                    return ListView(
                      controller: dateScrollController,
                      scrollDirection: Axis.horizontal,
                      children: dates.map((date) {
                        final key = dateKeys.putIfAbsent(
                          dateKey(date),
                          () => GlobalKey(),
                        );
                        final selected =
                            DateUtils.isSameDay(date, selectedDate);
                        final label = DateUtils.isSameDay(date, today)
                            ? '全部'
                            : '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}\n${weekdays[date.weekday - 1]}';
                        return SizedBox(
                          key: key,
                          width: itemWidth,
                          child: InkWell(
                            onTap: () => widget.onSelectDate?.call(date),
                            child: Stack(
                              children: [
                                Center(
                                  child: Text(
                                    label,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      height: 1.08,
                                      color: selected
                                          ? const Color(0xff12a15d)
                                          : const Color(0xff777d82),
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ),
                                if (selected)
                                  Align(
                                    alignment: Alignment.bottomCenter,
                                    child: Container(
                                      width: 32,
                                      height: 2,
                                      color: const Color(0xff12a15d),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: _buildList(selectedMatches),
        ),
      ],
    );
  }

  Widget _buildList(List<MatchItem> matches) {
    final widgets = <Widget>[];
    String? previous;
    final orderedMatches = widget._hasFinishedControls
        ? _sortFinishedMatches(matches)
        : _sortMatchNumbersWithinBusinessDate(matches);
    for (final item in orderedMatches) {
      final date =
          '${item.businessDateOnly.year}-${item.businessDateOnly.month.toString().padLeft(2, '0')}-${item.businessDateOnly.day.toString().padLeft(2, '0')}';
      if (date != previous) {
        widgets.add(HomeDateDivider(date: item.businessDateOnly));
        previous = date;
      }
      widgets.add(
        HomeMatchRow(
          key: ValueKey(item.id.isEmpty
              ? '${item.businessDate}-${item.number}'
              : item.id),
          match: item,
          onTap: () => widget.onMatchTap(item),
        ),
      );
    }
    if (widgets.isEmpty) {
      widgets.add(const SizedBox(height: 180));
      widgets.add(Center(
        child: Text(
          widget.loadError == null ? '暂无竞彩场次' : '比赛数据加载失败',
          style: const TextStyle(color: Color(0xff8b9095)),
        ),
      ));
      if (widget.loadError != null) {
        widgets.add(const SizedBox(height: 8));
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            widget.loadError!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xffb45309)),
          ),
        ));
      }
    }
    return RefreshIndicator(
      color: const Color(0xff079669),
      onRefresh: widget.onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 10),
        children: widgets,
      ),
    );
  }

  List<MatchItem> _sortMatchNumbersWithinBusinessDate(
    List<MatchItem> matches,
  ) {
    final groups = <String, List<MatchItem>>{};
    for (final match in matches) {
      final date =
          '${match.businessDateOnly.year}-${match.businessDateOnly.month}-${match.businessDateOnly.day}';
      groups.putIfAbsent(date, () => <MatchItem>[]).add(match);
    }
    final ordered = <MatchItem>[];
    for (final group in groups.values) {
      group.sort((a, b) {
        final stateOrder = _activeSortGroup(a).compareTo(_activeSortGroup(b));
        if (stateOrder != 0) return stateOrder;
        final aSequence = int.tryParse(
              RegExp(r'\d+$').firstMatch(a.number)?.group(0) ?? '',
            ) ??
            9999;
        final bSequence = int.tryParse(
              RegExp(r'\d+$').firstMatch(b.number)?.group(0) ?? '',
            ) ??
            9999;
        final sequenceOrder = aSequence.compareTo(bSequence);
        if (sequenceOrder != 0) return sequenceOrder;
        final numberOrder = a.number.compareTo(b.number);
        if (numberOrder != 0) return numberOrder;
        return a.id.compareTo(b.id);
      });
      ordered.addAll(group);
    }
    return ordered;
  }

  int _activeSortGroup(MatchItem match) => switch (match.matchState) {
        MatchState.live || MatchState.halftime => 0,
        MatchState.notStarted || MatchState.unknown => 1,
        _ => 2,
      };

  List<MatchItem> _sortFinishedMatches(List<MatchItem> matches) {
    final ordered = List<MatchItem>.of(matches);
    ordered.sort((a, b) {
      final dateOrder = b.businessDateOnly.compareTo(a.businessDateOnly);
      if (dateOrder != 0) return dateOrder;
      final delayedOrder = (_isDelayedFinished(b) ? 1 : 0)
          .compareTo(_isDelayedFinished(a) ? 1 : 0);
      if (delayedOrder != 0) return delayedOrder;
      final aSequence = int.tryParse(
            RegExp(r'\d+$').firstMatch(a.number)?.group(0) ?? '',
          ) ??
          9999;
      final bSequence = int.tryParse(
            RegExp(r'\d+$').firstMatch(b.number)?.group(0) ?? '',
          ) ??
          9999;
      return bSequence.compareTo(aSequence);
    });
    return ordered;
  }

  bool _isDelayedFinished(MatchItem match) {
    final source = <String>[
      match.matchStateText,
      match.liveStatusText ?? '',
      match.officialResults?.toString() ?? '',
    ].join(' ').toLowerCase();
    return const ['延期', '推迟', '延迟', '补赛', 'postpon', 'delay', 'resched']
        .any(source.contains);
  }

  @override
  Widget build(BuildContext context) {
    if (widget._hasFinishedControls) {
      return _buildDateStrip(context);
    }
    return _buildList(widget.matches);
  }
}
