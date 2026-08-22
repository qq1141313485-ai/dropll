import 'package:cai_tool_app/betting_engine.dart';
import 'package:flutter_test/flutter_test.dart';

MatchPick pick(
  String id,
  List<double> odds, {
  bool banker = false,
  bool singleSupported = true,
}) =>
    MatchPick(
      matchId: id,
      number: id,
      home: '主$id',
      away: '客$id',
      play: FootballPlay.had,
      banker: banker,
      singleSupported: singleSupported,
      options: [
        for (var i = 0; i < odds.length; i++)
          BetOption(label: '$i', sp: odds[i]),
      ],
    );

MatchPick playPick(
  String id,
  List<({FootballPlay play, double sp})> selections,
) =>
    MatchPick(
      matchId: id,
      number: id,
      home: '主$id',
      away: '客$id',
      play: selections.first.play,
      options: [
        for (var i = 0; i < selections.length; i++)
          BetOption(
            label: '$i',
            sp: selections[i].sp,
            play: selections[i].play,
          ),
      ],
    );

MatchPick screenshotPick(
  String id,
  String handicap,
  List<BetOption> options,
) =>
    MatchPick(
      matchId: id,
      number: id,
      home: '主$id',
      away: '客$id',
      play: options.first.play ?? FootballPlay.had,
      handicap: handicap,
      options: options,
    );

void main() {
  const engine = BettingEngine();

  test('2串1复式注数与金额正确', () {
    final result = engine.calculate(
      picks: [
        pick('001', [1.5, 3.0]),
        pick('002', [2.0, 4.0]),
      ],
      pass: PassMethod.simple.first,
      multiple: 2,
    );
    expect(result.atomicBets.length, 4);
    expect(result.notes, 8);
    expect(result.amount, 16);
  });

  test('4串11正确拆为6个2串、4个3串、1个4串', () {
    final method = PassMethod.compound.firstWhere(
      (item) => item.label == '4串11',
    );
    final result = engine.calculate(
      picks: [
        pick('1', [2]),
        pick('2', [2]),
        pick('3', [2]),
        pick('4', [2]),
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
        pick('3', [2]),
      ],
      pass: const PassMethod(3, 3, [2]),
    );
    expect(result.atomicBets.length, 2);
    expect(
      result.atomicBets.every((bet) => bet.description.contains('胆')),
      isTrue,
    );
  });

  test('多场单场按每场分别展开，且不受胆码限制', () {
    final result = engine.calculate(
      picks: [
        pick('001', [2], banker: true),
        pick('002', [3]),
        pick('003', [4]),
      ],
      pass: PassMethod.singleFor(3),
      multiple: 2,
    );

    expect(result.atomicBets.length, 3);
    expect(result.atomicBets.every((bet) => bet.passSize == 1), isTrue);
    expect(
      result.atomicBets.every((bet) => bet.picks.length == 1),
      isTrue,
    );
    expect(result.notes, 6);
    expect(result.amount, 12);
  });

  test('混合玩法单场不因其他比赛的玩法分支重复', () {
    final result = engine.calculate(
      picks: [
        playPick('001', [
          (play: FootballPlay.had, sp: 2),
          (play: FootballPlay.hhad, sp: 3),
        ]),
        playPick('002', [
          (play: FootballPlay.had, sp: 4),
          (play: FootballPlay.hhad, sp: 5),
        ]),
      ],
      pass: PassMethod.singleFor(2),
    );
    expect(result.notes, 4);
    expect(result.amount, 8);
  });

  test('单场可以和串关同时选择', () {
    final result = engine.calculateMultiple(
      picks: [
        pick('001', [2]),
        pick('002', [3]),
        pick('003', [4]),
      ],
      passes: [
        PassMethod.singleFor(3),
        PassMethod.free(3, 2),
      ],
    );

    expect(result.atomicBets.length, 6);
    expect(result.atomicBets.where((bet) => bet.passSize == 1).length, 3);
    expect(result.atomicBets.where((bet) => bet.passSize == 2).length, 3);
    expect(result.notes, 6);
    expect(result.amount, 12);
  });

  test('任一已选玩法不支持单场时拒绝单场过关', () {
    expect(
      () => engine.calculate(
        picks: [
          pick('001', [2]),
          pick('002', [3], singleSupported: false),
        ],
        pass: PassMethod.singleFor(2),
      ),
      throwsArgumentError,
    );
  });

  test('复合过关按实际子关数判断是否可用', () {
    final methods = PassMethod.available(5, 4);
    final labels = methods.map((method) => method.label).toSet();

    expect(labels, containsAll(<String>['5串5', '5串10', '5串20']));
    expect(labels, isNot(contains('5串6')));
    expect(labels, isNot(contains('5串16')));
  });

  test('奖金优化遵守预算及50倍上限', () {
    final result = engine.optimize(
      picks: [
        pick('1', [1.5, 4]),
        pick('2', [2]),
      ],
      pass: PassMethod.simple.first,
      budget: 100,
    );
    expect(result.amount, lessThanOrEqualTo(100));
    expect(result.tickets.every((ticket) => ticket.multiple <= 50), isTrue);
  });

  test('方案10000倍默认保持汇总计算', () {
    final result = engine.calculate(
      picks: [
        pick('1', [2]),
        pick('2', [2]),
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
        pick('002', [2]),
      ],
      pass: PassMethod.simple.first,
    );
    expect(result.atomicBets.length, 2);
    expect(result.notes, 2);
    expect(result.amount, 4);
    expect(
      result.atomicBets.every(
        (bet) =>
            bet.picks.map((item) => item.match.matchId).toSet().length == 2,
      ),
      isTrue,
    );
    expect(
      result.atomicBets.map((bet) => bet.picks.first.option.play).toSet(),
      {FootballPlay.had, FootballPlay.hhad},
    );
  });

  test('市场混合玩法分支复现4串1、5串1和5串26', () {
    final picks = [
      pick('5001', [1.34]),
      pick('5002', [1.5]),
      pick('5003', [6]),
      playPick('5004', [
        (play: FootballPlay.had, sp: 3.15),
        (play: FootballPlay.had, sp: 2.45),
        (play: FootballPlay.hhad, sp: 4.45),
      ]),
      playPick('5005', [
        (play: FootballPlay.had, sp: 3.95),
        (play: FootballPlay.hhad, sp: 3.70),
      ]),
    ];
    final fiveTwentySix = PassMethod.compound.firstWhere(
      (method) => method.label == '5串26',
    );
    final fourOne = engine.calculate(
      picks: picks,
      pass: PassMethod.free(5, 4),
    );
    final fiveOne = engine.calculate(
      picks: picks,
      pass: PassMethod.free(5, 5),
    );
    final fiveTwentySixResult = engine.calculate(
      picks: picks,
      pass: fiveTwentySix,
    );

    expect(fourOne.notes, 28);
    expect(fourOne.amount, 56);
    expect(fiveOne.notes, 6);
    expect(fiveOne.amount, 12);
    expect(fiveTwentySixResult.notes, 134);
    expect(fiveTwentySixResult.amount, 268);
  });

  test('红色平台截图复现5串26的玩法分支注数和最高奖金', () {
    final base = [
      screenshotPick('5003', '+2', [
        const BetOption(label: '平', sp: 6, play: FootballPlay.had),
      ]),
      screenshotPick('5004', '-1', [
        const BetOption(label: '平', sp: 3.15, play: FootballPlay.had),
      ]),
      screenshotPick('5005', '-1', [
        const BetOption(label: '平', sp: 3.95, play: FootballPlay.had),
      ]),
      screenshotPick('5006', '-1', [
        const BetOption(label: '平', sp: 4.55, play: FootballPlay.had),
        const BetOption(label: '平', sp: 3.58, play: FootballPlay.hhad),
      ]),
      screenshotPick('5007', '-1', [
        const BetOption(label: '平', sp: 3.05, play: FootballPlay.had),
      ]),
    ];
    final withExtraOption = [
      ...base.sublist(0, 3),
      screenshotPick('5006', '-1', [
        const BetOption(label: '平', sp: 4.55, play: FootballPlay.had),
        const BetOption(label: '负', sp: 5.40, play: FootballPlay.had),
        const BetOption(label: '平', sp: 3.58, play: FootballPlay.hhad),
      ]),
      base.last,
    ];
    final pass = PassMethod.compound.firstWhere(
      (method) => method.label == '5串26',
    );
    final result = engine.calculate(picks: base, pass: pass);
    final extraResult = engine.calculate(
      picks: withExtraOption,
      pass: pass,
    );

    expect(result.notes, 52);
    expect(result.amount, 104);
    expect(result.maxReturn, closeTo(7551.49, 0.01));
    expect(extraResult.notes, 67);
    expect(extraResult.amount, 134);
    expect(extraResult.maxReturn, closeTo(8539.85, 0.01));
  });

  test('混合玩法同场可同时命中时最高奖金会累计', () {
    const mixed = MatchPick(
      matchId: '001',
      number: '001',
      home: '主队',
      away: '客队',
      play: FootballPlay.had,
      options: [
        BetOption(label: '胜', sp: 1.8, play: FootballPlay.had),
        BetOption(label: '2', sp: 3.2, play: FootballPlay.ttg),
      ],
    );
    const second = MatchPick(
      matchId: '002',
      number: '002',
      home: '主队2',
      away: '客队2',
      play: FootballPlay.had,
      options: [BetOption(label: '胜', sp: 2)],
    );
    final result = engine.calculate(
      picks: const [mixed, second],
      pass: PassMethod.simple.first,
    );

    // 2:0 can hit both the home-win and total-goals tickets for match 001.
    expect(result.maxReturn, 20);
  });

  test('选6场可按最高4串1展开为15个组合', () {
    final method = PassMethod.free(6, 4);
    final result = engine.calculate(
      picks: [
        for (var i = 1; i <= 6; i++) pick('$i', [2]),
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
        pick('3', [2]),
      ],
      pass: PassMethod.free(3, 2),
    );
    expect(result.minReturn, 8);
    expect(result.maxReturn, 24);
  });

  test('博热博冷先保本，再放大目标组合奖金', () {
    final picks = [
      pick('1', [1.5, 4]),
      pick('2', [1]),
    ];
    final hot = engine.optimize(
      picks: picks,
      pass: PassMethod.simple.first,
      budget: 100,
      mode: OptimizeMode.hot,
    );
    final cold = engine.optimize(
      picks: picks,
      pass: PassMethod.simple.first,
      budget: 100,
      mode: OptimizeMode.cold,
    );
    expect(hot.principalProtected, isTrue);
    expect(cold.principalProtected, isTrue);
    expect(
      hot.returnsByCombination.values.every((value) => value >= hot.amount),
      isTrue,
    );
    expect(
      cold.returnsByCombination.values.every((value) => value >= cold.amount),
      isTrue,
    );
    expect(
      hot.returnsByCombination.entries
          .reduce((a, b) => a.value > b.value ? a : b)
          .key
          .unitReturn,
      3,
    );
    expect(
      cold.returnsByCombination.entries
          .reduce((a, b) => a.value > b.value ? a : b)
          .key
          .unitReturn,
      8,
    );
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
        pick('2', [1]),
      ],
      pass: PassMethod.simple.first,
    );
    expect(result.minReturn, 3);
    expect(result.maxReturn, 8);
  });

  test('8场可以同时选择2串1至8串1并累计注数', () {
    final picks = [
      for (var i = 1; i <= 8; i++) pick('$i', [2]),
    ];
    final passes = [
      for (var size = 2; size <= 8; size++) PassMethod.free(8, size),
    ];
    final result = engine.calculateMultiple(
      picks: picks,
      passes: passes,
      multiple: 1,
    );
    expect(result.atomicBets.length, 247);
    expect(result.notes, 247);
    expect(result.amount, 494);
  });

  test('多过关博热将保本后的剩余注数集中到最低SP组合', () {
    final result = engine.optimizeMultiple(
      picks: [
        pick('1', [1.5, 4]),
        pick('2', [1]),
      ],
      passes: [PassMethod.free(2, 2)],
      budget: 100,
      mode: OptimizeMode.hot,
    );
    final entries = result.returnsByCombination.keys.toList();
    final lowest = entries.reduce(
      (a, b) => a.unitReturn < b.unitReturn ? a : b,
    );
    final highest = entries.reduce(
      (a, b) => a.unitReturn > b.unitReturn ? a : b,
    );
    int multiple(AtomicBet bet) => result.tickets
        .where((ticket) => identical(ticket.bet, bet))
        .fold(0, (sum, ticket) => sum + ticket.multiple);
    expect(
      multiple(lowest) * lowest.unitReturn,
      greaterThan(multiple(highest) * highest.unitReturn),
    );
    expect(
      result.returnsByCombination.values.every(
        (value) => value >= result.amount,
      ),
      isTrue,
    );
    expect(result.principalProtected, isTrue);
  });

  test('多过关博冷将保本后的剩余注数集中到最高SP组合', () {
    final result = engine.optimizeMultiple(
      picks: [
        pick('1', [1.5, 4]),
        pick('2', [1]),
      ],
      passes: [PassMethod.free(2, 2)],
      budget: 100,
      mode: OptimizeMode.cold,
    );
    final entries = result.returnsByCombination.keys.toList();
    final lowest = entries.reduce(
      (a, b) => a.unitReturn < b.unitReturn ? a : b,
    );
    final highest = entries.reduce(
      (a, b) => a.unitReturn > b.unitReturn ? a : b,
    );
    int multiple(AtomicBet bet) => result.tickets
        .where((ticket) => identical(ticket.bet, bet))
        .fold(0, (sum, ticket) => sum + ticket.multiple);
    expect(
      multiple(highest) * highest.unitReturn,
      greaterThan(multiple(lowest) * lowest.unitReturn),
    );
    expect(
      result.returnsByCombination.values.every(
        (value) => value >= result.amount,
      ),
      isTrue,
    );
    expect(result.principalProtected, isTrue);
  });

  test('单注奖金先按分舍入再乘倍数', () {
    final result = engine.calculate(
      picks: [
        pick('1', [1.11]),
        pick('2', [3.33]),
      ],
      pass: PassMethod.simple.first,
      multiple: 3,
    );
    expect(result.atomicBets.single.unitReturn, 7.39);
    expect(result.returnsByCombination.values.single, 22.17);
  });

  test('单注奖金遵守过关封顶金额', () {
    expect(lotteryUnitReturn(spProduct: 150000, passSize: 2), 200000);
  });

  test('比分赛果不依赖完场接口是否仍返回赔率', () {
    expect(footballScoreResultLabel(1, 0), '1:0');
    expect(footballScoreResultLabel(6, 0), '胜其他');
    expect(footballScoreResultLabel(4, 4), '平其他');
    expect(footballScoreResultLabel(0, 6), '负其他');
  });
}
