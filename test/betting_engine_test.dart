import 'package:cai_tool_app/betting_engine.dart';
import 'package:flutter_test/flutter_test.dart';

MatchPick pick(String id, List<double> odds, {bool banker = false}) =>
    MatchPick(
      matchId: id,
      number: id,
      home: '主$id',
      away: '客$id',
      play: FootballPlay.had,
      banker: banker,
      options: [
        for (var i = 0; i < odds.length; i++)
          BetOption(label: '$i', sp: odds[i])
      ],
    );

void main() {
  const engine = BettingEngine();

  test('2串1复式注数与金额正确', () {
    final result = engine.calculate(
      picks: [
        pick('001', [1.5, 3.0]),
        pick('002', [2.0, 4.0])
      ],
      pass: PassMethod.simple.first,
      multiple: 2,
    );
    expect(result.atomicBets.length, 4);
    expect(result.notes, 8);
    expect(result.amount, 16);
  });

  test('4串11正确拆为6个2串、4个3串、1个4串', () {
    final method =
        PassMethod.compound.firstWhere((item) => item.label == '4串11');
    final result = engine.calculate(
      picks: [
        pick('1', [2]),
        pick('2', [2]),
        pick('3', [2]),
        pick('4', [2])
      ],
      pass: method,
    );
    expect(result.atomicBets.length, 11);
    expect(result.amount, 22);
  });

  test('胆码进入每个有效组合', () {
    final result = engine.calculate(
      picks: [
        pick('胆', [2], banker: true),
        pick('2', [2]),
        pick('3', [2])
      ],
      pass: const PassMethod(3, 3, [2]),
    );
    expect(result.atomicBets.length, 2);
    expect(result.atomicBets.every((bet) => bet.description.contains('胆')),
        isTrue);
  });

  test('奖金优化遵守预算及50倍上限', () {
    final result = engine.optimize(
      picks: [
        pick('1', [1.5, 4]),
        pick('2', [2])
      ],
      pass: PassMethod.simple.first,
      budget: 100,
    );
    expect(result.amount, lessThanOrEqualTo(100));
    expect(result.tickets.every((ticket) => ticket.multiple <= 50), isTrue);
  });

  test('方案10000倍默认保持汇总，不自动拆票', () {
    final result = engine.calculate(
      picks: [
        pick('1', [2]),
        pick('2', [2])
      ],
      pass: PassMethod.simple.first,
      multiple: 10000,
    );
    expect(result.notes, 10000);
    expect(result.tickets.length, 1);
    expect(result.tickets.single.multiple, 10000);
    expect(result.isSplit, isFalse);

    final split = engine.split(result);
    expect(split.tickets.length, 200);
    expect(split.tickets.every((ticket) => ticket.multiple == 50), isTrue);
    expect(split.isSplit, isTrue);
  });

  test('同一场不同玩法按替代选项展开且每个组合只占一场', () {
    const mixed = MatchPick(
      matchId: '001',
      number: '001',
      home: '主队',
      away: '客队',
      play: FootballPlay.had,
      options: [
        BetOption(label: '胜', sp: 1.8, play: FootballPlay.had),
        BetOption(label: '让平', sp: 3.2, play: FootballPlay.hhad),
      ],
    );
    final result = engine.calculate(
      picks: [
        mixed,
        pick('002', [2])
      ],
      pass: PassMethod.simple.first,
    );
    expect(result.atomicBets.length, 2);
    expect(result.notes, 2);
    expect(result.amount, 4);
    expect(
        result.atomicBets.every((bet) =>
            bet.picks.map((item) => item.match.matchId).toSet().length == 2),
        isTrue);
    expect(result.atomicBets.map((bet) => bet.picks.first.option.play).toSet(),
        {FootballPlay.had, FootballPlay.hhad});
  });

  test('选6场可按最高4串1展开为15个组合', () {
    final method = PassMethod.free(6, 4);
    final result = engine.calculate(
      picks: [
        for (var i = 1; i <= 6; i++) pick('$i', [2])
      ],
      pass: method,
    );
    expect(method.label, '4串1');
    expect(result.atomicBets.length, 15);
    expect(result.notes, 15);
    expect(result.amount, 30);
  });

  test('多子串同时命中时最高奖金按可共同中奖组合相加', () {
    final result = engine.calculate(
      picks: [
        pick('1', [2]),
        pick('2', [2]),
        pick('3', [2])
      ],
      pass: PassMethod.free(3, 2),
    );
    expect(result.minReturn, 8);
    expect(result.maxReturn, 24);
  });

  test('博热博冷先保本，再放大目标组合奖金', () {
    final picks = [
      pick('1', [1.5, 4]),
      pick('2', [1])
    ];
    final hot = engine.optimize(
        picks: picks,
        pass: PassMethod.simple.first,
        budget: 100,
        mode: OptimizeMode.hot);
    final cold = engine.optimize(
        picks: picks,
        pass: PassMethod.simple.first,
        budget: 100,
        mode: OptimizeMode.cold);
    expect(hot.principalProtected, isTrue);
    expect(cold.principalProtected, isTrue);
    expect(
        hot.returnsByCombination.values.every((value) => value >= hot.amount),
        isTrue);
    expect(
        cold.returnsByCombination.values.every((value) => value >= cold.amount),
        isTrue);
    expect(
        hot.returnsByCombination.entries
            .reduce((a, b) => a.value > b.value ? a : b)
            .key
            .unitReturn,
        3);
    expect(
        cold.returnsByCombination.entries
            .reduce((a, b) => a.value > b.value ? a : b)
            .key
            .unitReturn,
        8);
  });

  test('预算不足时博热博冷明确提示无法保本', () {
    expect(
      () => engine.optimize(
        picks: [
          pick('1', [1.5, 4]),
          pick('2', [1]),
        ],
        pass: PassMethod.simple.first,
        budget: 10,
        mode: OptimizeMode.hot,
      ),
      throwsArgumentError,
    );
  });

  test('奖金区间按互斥组合取最小最大值而不是相加', () {
    final result = engine.calculate(
      picks: [
        pick('1', [1.5, 4]),
        pick('2', [1])
      ],
      pass: PassMethod.simple.first,
    );
    expect(result.minReturn, 3);
    expect(result.maxReturn, 8);
  });

  test('8场可以同时选择2串1至8串1并累计注数', () {
    final picks = [
      for (var i = 1; i <= 8; i++) pick('$i', [2])
    ];
    final passes = [
      for (var size = 2; size <= 8; size++) PassMethod.free(8, size)
    ];
    final result =
        engine.calculateMultiple(picks: picks, passes: passes, multiple: 1);
    expect(result.atomicBets.length, 247);
    expect(result.notes, 247);
    expect(result.amount, 494);
  });

  test('多过关博热将保本后的剩余注数集中到最低SP组合', () {
    final result = engine.optimizeMultiple(
      picks: [
        pick('1', [1.5, 4]),
        pick('2', [1])
      ],
      passes: [PassMethod.free(2, 2)],
      budget: 100,
      mode: OptimizeMode.hot,
    );
    final entries = result.returnsByCombination.keys.toList();
    final lowest =
        entries.reduce((a, b) => a.unitReturn < b.unitReturn ? a : b);
    final highest =
        entries.reduce((a, b) => a.unitReturn > b.unitReturn ? a : b);
    int multiple(AtomicBet bet) => result.tickets
        .where((ticket) => identical(ticket.bet, bet))
        .fold(0, (sum, ticket) => sum + ticket.multiple);
    expect(multiple(lowest) * lowest.unitReturn,
        greaterThan(multiple(highest) * highest.unitReturn));
    expect(
        result.returnsByCombination.values
            .every((value) => value >= result.amount),
        isTrue);
    expect(result.principalProtected, isTrue);
  });

  test('多过关博冷将保本后的剩余注数集中到最高SP组合', () {
    final result = engine.optimizeMultiple(
      picks: [
        pick('1', [1.5, 4]),
        pick('2', [1])
      ],
      passes: [PassMethod.free(2, 2)],
      budget: 100,
      mode: OptimizeMode.cold,
    );
    final entries = result.returnsByCombination.keys.toList();
    final lowest =
        entries.reduce((a, b) => a.unitReturn < b.unitReturn ? a : b);
    final highest =
        entries.reduce((a, b) => a.unitReturn > b.unitReturn ? a : b);
    int multiple(AtomicBet bet) => result.tickets
        .where((ticket) => identical(ticket.bet, bet))
        .fold(0, (sum, ticket) => sum + ticket.multiple);
    expect(multiple(highest) * highest.unitReturn,
        greaterThan(multiple(lowest) * lowest.unitReturn));
    expect(
        result.returnsByCombination.values
            .every((value) => value >= result.amount),
        isTrue);
    expect(result.principalProtected, isTrue);
  });
}
