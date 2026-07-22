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
}

class PassMethod {
  const PassMethod(this.matches, this.tickets, this.subPassSizes,
      {this.displayLabel});
  final int matches;
  final int tickets;
  final List<int> subPassSizes;
  final String? displayLabel;
  String get label => displayLabel ?? '$matches串$tickets';

  static const single = PassMethod(1, 1, [1]);

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
      for (var size = 2; size <= highest; size++) free(count, size),
      if (count <= maxPass) ...compound.where((item) => item.matches == count),
    ];
  }
}

class AtomicBet {
  const AtomicBet({required this.picks, required this.passSize});
  final List<({MatchPick match, BetOption option})> picks;
  final int passSize;

  double get spProduct =>
      picks.fold(1, (value, item) => value * item.option.sp);
  double get unitReturn => _roundHalfEven(2 * spProduct);
  String get description => picks.map((item) {
        final match = item.match;
        final play = item.option.play ?? match.play;
        return '${match.number}${match.league.isEmpty ? '' : ' ${match.league}'} '
            '${match.home}VS${match.away} · ${play.label}[${item.option.label}]';
      }).join(' × ');
}

class SplitTicket {
  const SplitTicket({required this.bet, required this.multiple});
  final AtomicBet bet;
  final int multiple;
  double get amount => 2.0 * multiple;
  double get theoreticalReturn {
    final cap = switch (bet.passSize) {
      1 => 100000.0,
      2 || 3 => 200000.0,
      4 || 5 => 500000.0,
      _ => 1000000.0,
    };
    return math.min(bet.unitReturn, cap) * multiple;
  }
}

enum OptimizeMode { balanced, hot, cold }

class BettingResult {
  const BettingResult(this.atomicBets, this.tickets,
      {this.principalProtected, this.isSplit = false});
  final List<AtomicBet> atomicBets;
  final List<SplitTicket> tickets;
  final bool? principalProtected;
  final bool isSplit;
  int get notes => tickets.fold(0, (sum, item) => sum + item.multiple);
  double get amount => tickets.fold(0, (sum, item) => sum + item.amount);
  Map<AtomicBet, double> get returnsByCombination {
    final values = <AtomicBet, double>{};
    for (final ticket in tickets) {
      values.update(ticket.bet, (value) => value + ticket.theoreticalReturn,
          ifAbsent: () => ticket.theoreticalReturn);
    }
    return values;
  }

  double get minReturn => returnsByCombination.values.isEmpty
      ? 0
      : returnsByCombination.values.reduce(math.min);
  double get maxReturn {
    final returns = returnsByCombination;
    if (returns.isEmpty) return 0;
    final optionsByMatch = <String, List<BetOption?>>{};
    for (final bet in atomicBets) {
      for (final item in bet.picks) {
        final values = optionsByMatch.putIfAbsent(
            item.match.matchId, () => <BetOption?>[null]);
        if (!values.contains(item.option)) values.add(item.option);
      }
    }
    final entries = optionsByMatch.entries.toList(growable: false);
    var maximum = 0.0;
    final chosen = <String, BetOption?>{};
    void visit(int index) {
      if (index == entries.length) {
        var total = 0.0;
        for (final entry in returns.entries) {
          final wins = entry.key.picks.every(
              (item) => identical(chosen[item.match.matchId], item.option));
          if (wins) total += entry.value;
        }
        if (total > maximum) maximum = total;
        return;
      }
      final entry = entries[index];
      for (final option in entry.value) {
        chosen[entry.key] = option;
        visit(index + 1);
      }
    }

    visit(0);
    return maximum;
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
    final atomic = _expand(picks, pass);
    return BettingResult(
      atomic,
      [
        for (final bet in atomic)
          if (splitTickets)
            ..._splitByTicketLimit(bet, multiple)
          else
            SplitTicket(bet: bet, multiple: multiple)
      ],
      isSplit: splitTickets,
    );
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
      atomic.addAll(_expand(picks, pass));
    }
    return BettingResult(
      atomic,
      [
        for (final bet in atomic)
          if (splitTickets)
            ..._splitByTicketLimit(bet, multiple)
          else
            SplitTicket(bet: bet, multiple: multiple)
      ],
      isSplit: splitTickets,
    );
  }

  BettingResult split(BettingResult result) => BettingResult(
        result.atomicBets,
        [
          for (final entry in result.returnsByCombination.keys)
            ..._splitByTicketLimit(
                entry,
                result.tickets
                    .where((ticket) => identical(ticket.bet, entry))
                    .fold(0, (sum, ticket) => sum + ticket.multiple))
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
    final atomic = _expand(picks, pass);
    final units = (budget / 2).floor();
    if (units < atomic.length) {
      throw ArgumentError('预算不足，至少需要 ${atomic.length * 2} 元覆盖全部组合');
    }
    var multiples = List<int>.filled(atomic.length, 1);
    var remaining = units - atomic.length;
    var principalProtected = false;

    if (mode != OptimizeMode.balanced) {
      final protected = [
        for (final bet in atomic) math.max(1, (budget / bet.unitReturn).ceil())
      ];
      final protectedUnits =
          protected.fold<int>(0, (sum, value) => sum + value);
      if (protectedUnits <= units &&
          protected.every((value) => value <= maxSchemeMultiple)) {
        multiples = protected;
        remaining = units - protectedUnits;
        principalProtected = true;
      }
    }

    double priority(int index) {
      final bet = atomic[index];
      if (mode == OptimizeMode.balanced || !principalProtected) {
        return -bet.unitReturn * multiples[index];
      }
      final extra = math.max(1,
          multiples[index] - math.max(1, (budget / bet.unitReturn).ceil()) + 1);
      final weight =
          mode == OptimizeMode.hot ? 1 / bet.unitReturn : bet.unitReturn;
      return weight / extra;
    }

    while (remaining > 0) {
      var best = -1;
      var bestPriority = -double.infinity;
      for (var index = 0; index < atomic.length; index++) {
        if (multiples[index] >= maxSchemeMultiple) continue;
        final value = priority(index);
        if (value > bestPriority) {
          bestPriority = value;
          best = index;
        }
      }
      if (best < 0) break;
      multiples[best]++;
      remaining--;
    }
    return BettingResult(
      atomic,
      [
        for (var i = 0; i < atomic.length; i++)
          SplitTicket(bet: atomic[i], multiple: multiples[i])
      ],
      principalProtected:
          mode == OptimizeMode.balanced ? null : principalProtected,
    );
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
      atomic.addAll(_expand(picks, pass));
    }
    final units = (budget / 2).floor();
    if (units < atomic.length) {
      throw ArgumentError('预算不足，至少需要 ${atomic.length * 2} 元覆盖全部组合');
    }
    final multiples = List<int>.filled(atomic.length, 1);
    var remaining = units - atomic.length;

    if (mode == OptimizeMode.balanced) {
      while (remaining > 0) {
        var best = 0;
        var lowestReturn = double.infinity;
        for (var index = 0; index < atomic.length; index++) {
          final value = atomic[index].unitReturn * multiples[index];
          if (multiples[index] < maxSchemeMultiple && value < lowestReturn) {
            lowestReturn = value;
            best = index;
          }
        }
        multiples[best]++;
        remaining--;
      }
      return _optimizedResult(atomic, multiples, null);
    }

    var lowest = 0;
    var highest = 0;
    for (var index = 1; index < atomic.length; index++) {
      if (atomic[index].unitReturn < atomic[lowest].unitReturn) lowest = index;
      if (atomic[index].unitReturn > atomic[highest].unitReturn) {
        highest = index;
      }
    }

    final protectedIndexes = mode == OptimizeMode.hot
        ? [
            for (var i = 0; i < atomic.length; i++)
              if (i != lowest) i
          ]
        : [lowest];
    var protected = true;
    for (final index in protectedIndexes) {
      final required = math.max(1, (budget / atomic[index].unitReturn).ceil());
      final extra = required - multiples[index];
      if (extra > remaining || required > maxSchemeMultiple) {
        protected = false;
        break;
      }
      multiples[index] = required;
      remaining -= extra;
    }

    final target = mode == OptimizeMode.hot ? lowest : highest;
    final room = maxSchemeMultiple - multiples[target];
    final assigned = math.min(room, remaining);
    multiples[target] += assigned;
    remaining -= assigned;
    if (remaining > 0) protected = false;
    return _optimizedResult(atomic, multiples, protected);
  }

  BettingResult _optimizedResult(
      List<AtomicBet> atomic, List<int> multiples, bool? protected) {
    return BettingResult(
      atomic,
      [
        for (var i = 0; i < atomic.length; i++)
          SplitTicket(bet: atomic[i], multiple: multiples[i])
      ],
      principalProtected: protected,
    );
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
        .expand((item) =>
            item.options.map((option) => (option.play ?? item.play).maxPass))
        .reduce(math.min);
    if (pass.subPassSizes.any((size) => size > maxPass)) {
      throw ArgumentError('当前玩法最高支持 $maxPass 关');
    }
    final bankerCount = picks.where((item) => item.banker).length;
    if (pass.subPassSizes.any((size) => bankerCount >= size)) {
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

  List<AtomicBet> _expand(List<MatchPick> picks, PassMethod pass) {
    final bankers = picks.where((item) => item.banker).toList();
    final drags = picks.where((item) => !item.banker).toList();
    final result = <AtomicBet>[];
    for (final size in pass.subPassSizes) {
      final need = size - bankers.length;
      for (final subset in _combinations(drags, need)) {
        final matches = [...bankers, ...subset];
        for (final options
            in _cartesian(matches.map((item) => item.options).toList())) {
          result.add(AtomicBet(
            passSize: size,
            picks: [
              for (var i = 0; i < matches.length; i++)
                (match: matches[i], option: options[i])
            ],
          ));
        }
      }
    }
    return result;
  }
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
        for (final item in group) [...prefix, item]
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
