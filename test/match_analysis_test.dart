import 'package:cai_tool_app/match_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses match analysis detail sections', () {
    final analysis = MatchAnalysisData.fromJson({
      'matchId': '2040634',
      'teams': {'home': '马尔默', 'away': '埃夫斯堡'},
      'headToHead': {
        'summary': {
          'matches': 2,
          'wins': 1,
          'draws': 0,
          'losses': 1,
          'goalsFor': 3,
          'goalsAgainst': 4,
        },
        'matches': [
          {
            'date': '2025-04-08',
            'league': '瑞超',
            'home': '马尔默',
            'away': '埃夫斯堡',
            'fullScore': '2:1',
            'halfScore': '0:0',
            'result': '胜',
          },
        ],
      },
      'standings': {
        'league': '瑞超',
        'season': '2026',
        'home': {
          'total': {
            'team': '马尔默',
            'played': 13,
            'wins': 6,
            'draws': 2,
            'losses': 5,
            'goalsFor': 27,
            'goalsAgainst': 22,
            'points': 20,
            'ranking': 7,
          },
        },
        'away': {
          'total': {
            'team': '埃夫斯堡',
            'played': 14,
            'wins': 4,
            'draws': 6,
            'losses': 4,
            'goalsFor': 18,
            'goalsAgainst': 17,
            'points': 18,
            'ranking': 9,
          },
        },
      },
      'recent': {
        'home': {
          'team': '马尔默',
          'summary': {'matches': 1, 'wins': 0, 'draws': 1, 'losses': 0},
          'matches': [
            {
              'home': '卡尔马',
              'away': '马尔默',
              'fullScore': '2:2',
              'result': '平',
            },
          ],
        },
        'away': {
          'team': '埃夫斯堡',
          'summary': {'matches': 1, 'wins': 0, 'draws': 0, 'losses': 1},
          'matches': [
            {
              'home': '埃夫斯堡',
              'away': '天狼星',
              'fullScore': '1:3',
              'result': '负',
            },
          ],
        },
      },
      'keyPlayers': {
        'home': {
          'team': '马尔默',
          'players': [
            {
              'id': '1',
              'name': '主队射手',
              'number': '9',
              'position': '前锋',
              'appearances': 3,
              'starts': 3,
              'goals': 2,
              'assists': 1,
            },
          ],
        },
        'away': {'team': '埃夫斯堡', 'players': []},
      },
      'injuries': {
        'home': {
          'team': '马尔默',
          'players': [
            {'id': '2', 'name': '伤停后卫', 'injured': true},
          ],
        },
        'away': {'team': '埃夫斯堡', 'players': []},
      },
      'future': {
        'home': {
          'team': '马尔默',
          'matches': [
            {
              'id': '7',
              'date': '2026-08-02 18:00:00',
              'league': '瑞超',
              'home': '马尔默',
              'away': '卡尔马',
            },
          ],
        },
        'away': {'team': '埃夫斯堡', 'matches': []},
      },
    });

    expect(analysis.hasContent, isTrue);
    expect(analysis.headToHead.summary.record, '1胜0平1负');
    expect(analysis.standings.home.total.ranking, 7);
    expect(analysis.homeRecent.matches.single.result, '平');
    expect(analysis.awayRecent.matches.single.result, '负');
    expect(analysis.keyPlayers.home.players.single.goals, 2);
    expect(analysis.injuries.home.players.single.injured, isTrue);
    expect(analysis.future.home.matches.single.away, '卡尔马');
  });

  test('sorts history and recent matches from newest to oldest', () {
    final analysis = MatchAnalysisData.fromJson({
      'headToHead': {
        'matches': [
          {'date': '2024/05/01', 'home': '旧比赛'},
          {'date': '2026-07-25 19:30:00', 'home': '新比赛'},
          {'date': '日期未知', 'home': '未知日期'},
        ],
      },
      'recent': {
        'home': {
          'matches': [
            {'date': '2025.08.01', 'home': '较早'},
            {'date': '2026-01-02', 'home': '较新'},
          ],
        },
      },
    });

    expect(
      analysis.headToHead.matches.map((item) => item.home),
      ['新比赛', '旧比赛', '未知日期'],
    );
    expect(
      analysis.homeRecent.matches.map((item) => item.home),
      ['较新', '较早'],
    );
  });

  test('calculates form, goals and venue metrics from valid scores', () {
    final form = TeamRecentForm.fromJson({
      'team': '主队',
      'matches': [
        {
          'home': '主队',
          'away': '甲',
          'fullScore': '3:1',
          'result': '胜',
        },
        {
          'home': '乙',
          'away': '主队',
          'fullScore': '0:0',
          'result': '平',
        },
        {
          'home': '主队',
          'away': '丙',
          'fullScore': '0:1',
          'result': '负',
        },
        {
          'home': '其他',
          'away': '无关',
          'fullScore': '2:2',
        },
        {
          'home': '主队',
          'away': '丁',
          'fullScore': '',
        },
      ],
    });

    final all = form.metrics();
    expect(all.matches, 3);
    expect(all.record, '1胜1平1负');
    expect(all.goalsFor, 3);
    expect(all.goalsAgainst, 2);
    expect(all.goalsForAverage, 1);
    expect(all.overTwoAndHalfRate, closeTo(1 / 3, 0.001));
    expect(all.bothTeamsScoredRate, closeTo(1 / 3, 0.001));

    final home = form.metrics(venue: TeamVenue.home);
    expect(home.matches, 2);
    expect(home.record, '1胜0平1负');

    final away = form.metrics(venue: TeamVenue.away);
    expect(away.matches, 1);
    expect(away.record, '0胜1平0负');
  });
}
