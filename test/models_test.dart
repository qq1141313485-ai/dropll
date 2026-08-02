import 'package:cai_tool_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('midnight kickoff is treated as an official time', () {
    final item = MatchItem.fromJson({
      'id': 'midnight',
      'number': 'D201',
      'businessDate': '2026-07-24',
      'league': 'League',
      'home': 'Home',
      'away': 'Away',
      'kickoff': '2026-07-25 00:00:00',
      'status': 'PENDING',
      'matchState': 'not_started',
      'odds': const {},
    });

    expect(item.hasOfficialKickoffTime, isTrue);
    expect(item.kickoffDisplayTime, '00:00');
  });

  test('structured official result joins home and away scores', () {
    final item = MatchItem.fromJson({
      'id': 'result',
      'number': 'D202',
      'businessDate': '2026-07-24',
      'league': 'League',
      'home': 'Home',
      'away': 'Away',
      'kickoff': '2026-07-25 18:00:00',
      'status': 'FINISHED',
      'officialResults': {
        'sectionsNo999': {'homeScore': 3, 'awayScore': 1},
      },
      'odds': const {},
    });

    expect(item.finalScore, '3:1');
  });

  test('live data becomes stale after two minutes without Titan updates', () {
    final item = MatchItem.fromJson({
      'id': 'live',
      'number': 'D203',
      'businessDate': '2026-07-24',
      'league': 'League',
      'home': 'Home',
      'away': 'Away',
      'kickoff': '2026-07-25 18:00:00',
      'status': 'LIVE',
      'matchState': 'live',
      'score': '1:0',
      'titanLastUpdated': DateTime.now()
          .subtract(const Duration(minutes: 3))
          .toIso8601String(),
      'odds': const {},
    });

    expect(item.isLiveDataStale, isTrue);
  });

  test('live data also becomes stale when only fetchedAt is old', () {
    final item = MatchItem.fromJson({
      'id': 'live-fetched',
      'number': 'D204',
      'businessDate': '2026-07-24',
      'league': 'League',
      'home': 'Home',
      'away': 'Away',
      'kickoff': '2026-07-25 18:00:00',
      'status': 'LIVE',
      'matchState': 'live',
      'score': '1:0',
      'fetchedAt': DateTime.now()
          .subtract(const Duration(minutes: 3))
          .toIso8601String(),
      'odds': const {},
    });

    expect(item.isLiveDataStale, isTrue);
  });

  test('explicit live state is reflected without requiring a score', () {
    final item = MatchItem.fromJson({
      'id': 'live-without-score',
      'number': 'D205',
      'businessDate': '2026-07-24',
      'league': 'League',
      'home': 'Home',
      'away': 'Away',
      'kickoff': '2026-07-25 18:00:00',
      'status': 'LIVE',
      'matchState': 'live',
      'odds': const {},
    });

    expect(item.status, MatchStatus.live);
    expect(item.matchState, MatchState.live);
  });
}
