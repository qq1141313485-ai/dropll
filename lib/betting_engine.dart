import 'dart:math' as math;

enum FootballPlay { had, hhad, ttg, crs, hafu }

extension FootballPlayText on FootballPlay {
  String get label => switch (this) {
        FootballPlay.had => '胜平负',
        FootballPlay.hhad => '让球胜平负',
        FootballPlay.ttg => '总进球',
        FootballPlay.crs => '比分',
        FootballPlay.hafu => '半全场',
      };

  String get poolCode => switch (this) {
        FootballPlay.had => 'HAD',
        FootballPlay.hhad => 'HHAD',
        FootballPlay.ttg => 'TTG',
        FootballPlay.crs => 'CRS',
        FootballPlay.hafu => 'HAFU',
      };

  int get maxPass => switch (this) {
        FootballPlay.had || FootballPlay.hhad => 8,
        FootballPlay.ttg => 6,
        FootballPlay.crs || FootballPlay.hafu => 4,
      };
}

class BetOption {
  const BetOption({required this.label, required this.sp, this.play});
  final String label;
  final double sp;
  final FootballPlay? play;
}

class MatchPick {
  const MatchPick({
    required this.matchId,
    required this.number,
    required this.home,
    required this.away,
    required this.play,
    required this.options,
    this.league = '',
    this.kickoff,
    this.banker = false,
    this.availableOdds = const {},
    this.handicap = '',
    this.singleSupported = true,
  });

  final String matchId;
  final String number;
  final String home;
  final String away;
  final String league;
  final DateTime? kickoff;
  final FootballPlay play;
  final List<BetOption> options;
  final bool banker;
  final Map<FootballPlay, Map<String, double>> availableOdds;
  final String handicap;
  final bool singleSupported;
}

class PassMethod {
  const PassMethod(
    this.matches,
    this.tickets,
    this.subPassSizes, {
    this.displayLabel,
  });
  final int matches;
  final int tickets;
  final List<int> subPassSizes;
  final String? displayLabel;
  String get label => displayLabel ?? '$matches串$tickets';

  static const single = PassMethod(
    1,
    1,
    [1],
    displayLabel: '单场',
  );

  static const simple = [
    PassMethod(2, 1, [2]),
    PassMethod(3, 1, [3]),
    PassMethod(4, 1, [4]),
    PassMethod(5, 1, [5]),
    PassMethod(6, 1, [6]),
    PassMethod(7, 1, [7]),
    PassMethod(8, 1, [8]),
  ];

  static const compound = [
    PassMethod(3, 3, [2]),
    PassMethod(3, 4, [2, 3]),
    PassMethod(4, 4, [3]),
    PassMethod(4, 5, [3, 4]),
    PassMethod(4, 6, [2]),
    PassMethod(4, 11, [2, 3, 4]),
    PassMethod(5, 5, [4]),
    PassMethod(5, 6, [4, 5]),
    PassMethod(5, 10, [2]),
    PassMethod(5, 16, [3, 4, 5]),
    PassMethod(5, 20, [2, 3]),
    PassMethod(5, 26, [2, 3, 4, 5]),
    PassMethod(6, 6, [5]),
    PassMethod(6, 7, [5, 6]),
    PassMethod(6, 15, [2]),
    PassMethod(6, 20, [3]),
    PassMethod(6, 22, [4, 5, 6]),
    PassMethod(6, 35, [2, 3]),
    PassMethod(6, 42, [3, 4, 5, 6]),
    PassMethod(6, 50, [2, 3, 4]),
    PassMethod(6, 57, [2, 3, 4, 5, 6]),
    PassMethod(7, 7, [6]),
    PassMethod(7, 8, [6, 7]),
    PassMethod(7, 21, [5]),
    PassMethod(7, 35, [4]),
    PassMethod(7, 120, [2, 3, 4, 5, 6, 7]),
    PassMethod(8, 8, [7]),
    PassMethod(8, 9, [7, 8]),
    PassMethod(8, 28, [6]),
    PassMethod(8, 56, [5]),
    PassMethod(8, 70, [4]),
    PassMethod(8, 247, [2, 3, 4, 5, 6, 7, 8]),
  ];

  bool get isSingle => subPassSizes.length == 1 && subPassSizes.first == 1;

  static PassMethod singleFor(int selectedCount) {
    if (selectedCount == 1) return single;
    return PassMethod(
      selectedCount,
      selectedCount,
      const [1],
      displayLabel: '单场',
    );
  }

  static PassMethod free(int selectedCount, int passSize) => PassMethod(
        selectedCount,
        _combinationCount(selectedCount, passSize),
        [passSize],
        displayLabel: '$passSize串1',
      );

  static List<PassMethod> available(int count, int maxPass) {
    if (count <= 0) return const [];
    if (count == 1) return const [single];
    final highest = math.min(count, maxPass);
    return [
      singleFor(count),
      for (var size = 2; size <= highest; size++) free(count, size),
      ...compound.where(
        (item) =>
            item.matches == count &&
            item.subPassSizes.every((size) => size <= maxPass),
      ),
    ];
  }
}

class AtomicBet {
  const AtomicBet({required this.picks, required this.passSize});
  final List<({MatchPick match, BetOption option})> picks;
  final int passSize;

  double get spProduct =>
      picks.fold(1, (value, item) => value * item.option.sp);
  double get unitReturn =>
      lotteryUnitReturn(spProduct: spProduct, passSize: passSize);
  String get description => picks.map((item) {
        final match = item.match;
        final play = item.option.play ?? match.play;
        return '${match.number}${match.league.isEmpty ? '' : ' ${match.league}'} '
            '${match.home}VS${match.away} · ${play.label}[${item.option.label}]';
      }).join(' × ');
}

double lotteryUnitReturn({required double spProduct, required int passSize}) {
  final cap = switch (passSize) {
    1 => 100000.0,
    2 || 3 => 200000.0,
    4 || 5 => 500000.0,
    _ => 1000000.0,
  };
  return math.min(_roundHalfEven(2 * spProduct), cap);
}

const _directScoreResults = {
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
  '0:0',
  '1:1',
  '2:2',
  '3:3',
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
};

String footballScoreResultLabel(int home, int away) {
  final score = '$home:$away';
  if (_directScoreResults.contains(score)) return score;
  return home > away
      ? '胜其他'
      : home == away
          ? '平其他'
          : '负其他';
}

class SplitTicket {
  const SplitTicket({required this.bet, required this.multiple});
  final AtomicBet bet;
  final int multiple;
  double get amount => 2.0 * multiple;
  double get theoreticalReturn => _roundHalfEven(bet.unitReturn * multiple);
}

enum OptimizeMode { balanced, hot, cold }

class BettingResult {
  const BettingResult(
    this.atomicBets,
    this.tickets, {
    this.principalProtected,
    this.isSplit = false,
  });
  final List<AtomicBet> atomicBets;
  final List<SplitTicket> tickets;
  final bool? principalProtected;
  final bool isSplit;
  int get notes => tickets.fold(0, (sum, item) => sum + item.multiple);
  double get amount => tickets.fold(0, (sum, item) => sum + item.amount);
  Map<AtomicBet, double> get returnsByCombination {
    final values = <AtomicBet, double>{};
    for (final ticket in tickets) {
      values.update(
        ticket.bet,
        (value) => value + ticket.theoreticalReturn,
        ifAbsent: () => ticket.theoreticalReturn,
      );
    }
    return values;
  }

  double get minReturn => returnsByCombination.values.isEmpty
      ? 0
      : returnsByCombination.values.reduce(math.min);
  double get maxReturn {
    final returns = returnsByCombination;
    if (returns.isEmpty) return 0;
    final picksByMatch = <String, MatchPick>{};
    for (final bet in atomicBets) {
      for (final item in bet.picks) {
        picksByMatch.putIfAbsent(item.match.matchId, () => item.match);
      }
    }
    final entries = picksByMatch.entries
        .map(
          (entry) => MapEntry(
            entry.key,
            _possibleWinningOptions(entry.value),
          ),
        )
        .toList(growable: false);
    var maximum = 0.0;
    final chosen = <String, Set<BetOption>>{};
    void visit(int index) {
      if (index == entries.length) {
        var total = 0.0;
        for (final entry in returns.entries) {
          final wins = entry.key.picks.every(
            (item) => chosen[item.match.matchId]!.contains(item.option),
          );
          if (wins) total += entry.value;
        }
        if (total > maximum) maximum = total;
        return;
      }
      final entry = entries[index];
      for (final options in entry.value) {
        chosen[entry.key] = options;
        visit(index + 1);
      }
    }

    visit(0);
    return maximum;
  }
}

List<Set<BetOption>> _possibleWinningOptions(MatchPick pick) {
  final outcomes = <Set<BetOption>>[<BetOption>{}];
  final signatures = <String>{''};
  final recognized = <BetOption>{};

  void addOutcome(int home, int away, int halfHome, int halfAway) {
    final winners = <BetOption>{};
    for (final option in pick.options) {
      final play = option.play ?? pick.play;
      if (_optionWinsOutcome(
        option.label,
        play,
        pick.handicap,
        home,
        away,
        halfHome,
        halfAway,
      )) {
        winners.add(option);
        recognized.add(option);
      }
    }
    final signature = [
      for (var index = 0; index < pick.options.length; index++)
        if (winners.contains(pick.options[index])) index,
    ].join(',');
    if (signatures.add(signature)) outcomes.add(winners);
  }

  for (var home = 0; home <= 8; home++) {
    for (var away = 0; away <= 8; away++) {
      for (var halfHome = 0; halfHome <= home; halfHome++) {
        for (var halfAway = 0; halfAway <= away; halfAway++) {
          addOutcome(home, away, halfHome, halfAway);
        }
      }
    }
  }

  // Legacy schemes and tests may contain labels outside the official pools.
  // Preserve their former mutually-exclusive behavior instead of dropping them.
  for (final option in pick.options) {
    if (!recognized.contains(option)) outcomes.add({option});
  }
  return outcomes;
}

bool _optionWinsOutcome(
  String rawLabel,
  FootballPlay play,
  String handicap,
  int home,
  int away,
  int halfHome,
  int halfAway,
) {
  final label = rawLabel.trim().replaceAll('其它', '其他').replaceAll('-', ':');
  String outcome(int left, int right) => left > right
      ? '胜'
      : left == right
          ? '平'
          : '负';

  switch (play) {
    case FootballPlay.had:
      return label == outcome(home, away);
    case FootballPlay.hhad:
      final value = double.tryParse(handicap.trim())?.round() ?? 0;
      final winner = outcome(home + value, away);
      return label == winner || label == '让$winner';
    case FootballPlay.ttg:
      final total = home + away;
      return label.replaceAll('球', '') == (total >= 7 ? '7+' : '$total');
    case FootballPlay.crs:
      return label == footballScoreResultLabel(home, away);
    case FootballPlay.hafu:
      final compact = label.replaceAll('/', '').replaceAll(' ', '');
      return compact == '${outcome(halfHome, halfAway)}${outcome(home, away)}';
  }
}

class BettingEngine {
  const BettingEngine();

  static const int maxSchemeMultiple = 10000;
  static const int maxTicketMultiple = 50;

  BettingResult calculate({
    required List<MatchPick> picks,
    required PassMethod pass,
    int multiple = 1,
    bool splitTickets = false,
  }) {
    _validate(picks, pass, multiple);
    final atomic = [
      for (final branch in _branchesFor(picks, pass))
        ..._expand(picks, pass, branch: branch),
    ];
    return BettingResult(
        atomic,
        [
          for (final bet in atomic)
            if (splitTickets)
              ..._splitByTicketLimit(bet, multiple)
            else
              SplitTicket(bet: bet, multiple: multiple),
        ],
        isSplit: splitTickets);
  }

  BettingResult calculateMultiple({
    required List<MatchPick> picks,
    required List<PassMethod> passes,
    int multiple = 1,
    bool splitTickets = false,
  }) {
    if (passes.isEmpty) throw ArgumentError('请至少选择一种过关方式');
    final atomic = <AtomicBet>[];
    for (final pass in passes) {
      _validate(picks, pass, multiple);
      for (final branch in _branchesFor(picks, pass)) {
        atomic.addAll(_expand(picks, pass, branch: branch));
      }
    }
    return BettingResult(
        atomic,
        [
          for (final bet in atomic)
            if (splitTickets)
              ..._splitByTicketLimit(bet, multiple)
            else
              SplitTicket(bet: bet, multiple: multiple),
        ],
        isSplit: splitTickets);
  }

  BettingResult split(BettingResult result) => BettingResult(
        result.atomicBets,
        [
          for (final entry in result.returnsByCombination.keys)
            ..._splitByTicketLimit(
              entry,
              result.tickets
                  .where((ticket) => identical(ticket.bet, entry))
                  .fold(0, (sum, ticket) => sum + ticket.multiple),
            ),
        ],
        principalProtected: result.principalProtected,
        isSplit: true,
      );

  BettingResult optimize({
    required List<MatchPick> picks,
    required PassMethod pass,
    required double budget,
    OptimizeMode mode = OptimizeMode.balanced,
  }) {
    _validate(picks, pass, 1);
    final atomic = [
      for (final branch in _branchesFor(picks, pass))
        ..._expand(picks, pass, branch: branch),
    ];
    final units = (budget / 2).floor();
    if (units < atomic.length) {
      throw ArgumentError('预算不足，至少需要 ${atomic.length * 2} 元覆盖全部组合');
    }
    return _optimizeAtomic(atomic, units, mode);
  }

  BettingResult optimizeMultiple({
    required List<MatchPick> picks,
    required List<PassMethod> passes,
    required double budget,
    OptimizeMode mode = OptimizeMode.balanced,
  }) {
    if (passes.isEmpty) throw ArgumentError('请至少选择一种过关方式');
    final atomic = <AtomicBet>[];
    for (final pass in passes) {
      _validate(picks, pass, 1);
      for (final branch in _branchesFor(picks, pass)) {
        atomic.addAll(_expand(picks, pass, branch: branch));
      }
    }
    final units = (budget / 2).floor();
    if (units < atomic.length) {
      throw ArgumentError('预算不足，至少需要 ${atomic.length * 2} 元覆盖全部组合');
    }
    return _optimizeAtomic(atomic, units, mode);
  }

  BettingResult _optimizeAtomic(
    List<AtomicBet> atomic,
    int units,
    OptimizeMode mode,
  ) {
    final multiples = List<int>.filled(atomic.length, 1);
    if (mode == OptimizeMode.balanced) {
      _allocateAverage(atomic, multiples, units - atomic.length);
      return _optimizedResult(atomic, multiples, null);
    }

    // 博热/博冷先让每个可能命中的单注返奖不少于本次实际投入，
    // 再将剩余注数集中给目标组合。
    final protectedAmount = units * 2.0;
    for (var index = 0; index < atomic.length; index++) {
      final required = (protectedAmount / atomic[index].unitReturn).ceil();
      multiples[index] = math.max(1, required);
      if (multiples[index] > maxSchemeMultiple) {
        throw ArgumentError('当前预算超过单个组合$maxSchemeMultiple倍上限，无法保本优化');
      }
    }
    final protectedUnits = multiples.fold(0, (sum, value) => sum + value);
    if (protectedUnits > units) {
      throw ArgumentError('当前预算无法保证所有组合保本，至少需要${protectedUnits * 2}元');
    }

    final target = _targetIndex(atomic, mode);
    var remaining = units - protectedUnits;
    while (remaining > 0 && multiples[target] < maxSchemeMultiple) {
      multiples[target]++;
      remaining--;
    }
    if (remaining > 0) {
      throw ArgumentError('目标组合已达到$maxSchemeMultiple倍上限，请提高分配范围');
    }
    return _optimizedResult(atomic, multiples, true);
  }

  void _allocateAverage(
    List<AtomicBet> atomic,
    List<int> multiples,
    int remaining,
  ) {
    while (remaining > 0) {
      var best = 0;
      var bestReturn = double.infinity;
      for (var index = 0; index < atomic.length; index++) {
        if (multiples[index] >= maxSchemeMultiple) continue;
        final value = atomic[index].unitReturn * multiples[index];
        if (value < bestReturn) {
          bestReturn = value;
          best = index;
        }
      }
      if (multiples[best] >= maxSchemeMultiple) {
        throw ArgumentError('所有组合已达到$maxSchemeMultiple倍上限');
      }
      multiples[best]++;
      remaining--;
    }
  }

  int _targetIndex(List<AtomicBet> atomic, OptimizeMode mode) {
    var target = 0;
    for (var index = 1; index < atomic.length; index++) {
      final current = atomic[index].unitReturn;
      final selected = atomic[target].unitReturn;
      if ((mode == OptimizeMode.hot && current < selected) ||
          (mode == OptimizeMode.cold && current > selected)) {
        target = index;
      }
    }
    return target;
  }

  BettingResult _optimizedResult(
    List<AtomicBet> atomic,
    List<int> multiples,
    bool? protected,
  ) {
    return BettingResult(
        atomic,
        [
          for (var i = 0; i < atomic.length; i++)
            SplitTicket(bet: atomic[i], multiple: multiples[i]),
        ],
        principalProtected: protected);
  }

  void _validate(List<MatchPick> picks, PassMethod pass, int multiple) {
    if (picks.length != pass.matches) throw ArgumentError('所选场数与过关方式不一致');
    if (multiple < 1 || multiple > maxSchemeMultiple) {
      throw ArgumentError('方案总倍数必须为1至$maxSchemeMultiple');
    }
    if (picks.any((item) => item.options.isEmpty)) {
      throw ArgumentError('每场至少选择一个结果');
    }
    final maxPass = picks
        .expand(
          (item) =>
              item.options.map((option) => (option.play ?? item.play).maxPass),
        )
        .reduce(math.min);
    if (pass.subPassSizes.any((size) => size > maxPass)) {
      throw ArgumentError('当前玩法最高支持 $maxPass 关');
    }
    if (pass.isSingle && picks.any((item) => !item.singleSupported)) {
      throw ArgumentError('当前选择中有玩法不支持单场');
    }
    final bankerCount = picks.where((item) => item.banker).length;
    if (!pass.isSingle &&
        pass.subPassSizes.any((size) => bankerCount >= size)) {
      throw ArgumentError('胆码数量必须少于最小过关关数');
    }
  }

  List<SplitTicket> _splitByTicketLimit(AtomicBet bet, int multiple) {
    final tickets = <SplitTicket>[];
    var remaining = multiple;
    while (remaining > 0) {
      final current = math.min(remaining, maxTicketMultiple);
      tickets.add(SplitTicket(bet: bet, multiple: current));
      remaining -= current;
    }
    return tickets;
  }

  List<AtomicBet> _expand(
    List<MatchPick> picks,
    PassMethod pass, {
    required Map<String, FootballPlay> branch,
  }) {
    final bankers = picks.where((item) => item.banker).toList();
    final drags = picks.where((item) => !item.banker).toList();
    final result = <AtomicBet>[];
    for (final size in pass.subPassSizes) {
      if (size == 1) {
        for (final match in picks) {
          for (final option in _branchOptions(match, branch)) {
            result.add(
              AtomicBet(
                passSize: 1,
                picks: [(match: match, option: option)],
              ),
            );
          }
        }
        continue;
      }
      final need = size - bankers.length;
      for (final subset in _combinations(drags, need)) {
        final matches = [...bankers, ...subset];
        for (final options in _cartesian(
          matches.map((item) => _branchOptions(item, branch)).toList(),
        )) {
          result.add(
            AtomicBet(
              passSize: size,
              picks: [
                for (var i = 0; i < matches.length; i++)
                  (match: matches[i], option: options[i]),
              ],
            ),
          );
        }
      }
    }
    return result;
  }

  List<BetOption> _branchOptions(
    MatchPick match,
    Map<String, FootballPlay> branch,
  ) {
    final play = branch[match.matchId];
    return play == null
        ? match.options
        : match.options
            .where((option) => (option.play ?? match.play) == play)
            .toList(growable: false);
  }

  List<Map<String, FootballPlay>> _playBranches(List<MatchPick> picks) {
    final branches = <Map<String, FootballPlay>>[<String, FootballPlay>{}];
    for (final match in picks) {
      final plays = <FootballPlay>{
        for (final option in match.options) option.play ?? match.play,
      }.toList();
      final next = <Map<String, FootballPlay>>[];
      for (final branch in branches) {
        for (final play in plays) {
          next.add({...branch, match.matchId: play});
        }
      }
      branches
        ..clear()
        ..addAll(next);
    }
    return branches;
  }

  List<Map<String, FootballPlay>> _branchesFor(
    List<MatchPick> picks,
    PassMethod pass,
  ) =>
      pass.isSingle ? [<String, FootballPlay>{}] : _playBranches(picks);
}

List<List<T>> _combinations<T>(List<T> source, int count) {
  if (count == 0) return [<T>[]];
  final result = <List<T>>[];
  void visit(int start, List<T> current) {
    if (current.length == count) {
      result.add(List.of(current));
      return;
    }
    for (var i = start; i <= source.length - (count - current.length); i++) {
      current.add(source[i]);
      visit(i + 1, current);
      current.removeLast();
    }
  }

  visit(0, []);
  return result;
}

int _combinationCount(int total, int count) {
  if (count < 0 || count > total) return 0;
  final selected = math.min(count, total - count);
  var value = 1;
  for (var i = 1; i <= selected; i++) {
    value = value * (total - selected + i) ~/ i;
  }
  return value;
}

List<List<T>> _cartesian<T>(List<List<T>> groups) {
  var result = <List<T>>[[]];
  for (final group in groups) {
    result = [
      for (final prefix in result)
        for (final item in group) [...prefix, item],
    ];
  }
  return result;
}

double _roundHalfEven(double value) {
  final scaled = value * 100;
  final floor = scaled.floor();
  final fraction = scaled - floor;
  final rounded = fraction < 0.5
      ? floor
      : fraction > 0.5
          ? floor + 1
          : (floor.isEven ? floor : floor + 1);
  return rounded / 100;
}
