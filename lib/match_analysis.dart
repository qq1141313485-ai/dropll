class MatchAnalysisData {
  const MatchAnalysisData({
    required this.matchId,
    required this.homeTeam,
    required this.awayTeam,
    required this.headToHead,
    required this.standings,
    required this.homeRecent,
    required this.awayRecent,
    required this.keyPlayers,
    required this.injuries,
    required this.future,
    required this.stale,
  });

  final String matchId;
  final String homeTeam;
  final String awayTeam;
  final MatchRecordGroup headToHead;
  final MatchStandings standings;
  final TeamRecentForm homeRecent;
  final TeamRecentForm awayRecent;
  final TeamPlayerSides keyPlayers;
  final TeamPlayerSides injuries;
  final TeamFutureSchedules future;
  final bool stale;

  bool get hasContent =>
      headToHead.matches.isNotEmpty ||
      standings.hasContent ||
      homeRecent.matches.isNotEmpty ||
      awayRecent.matches.isNotEmpty ||
      keyPlayers.hasContent ||
      injuries.hasContent ||
      future.hasContent;

  factory MatchAnalysisData.fromJson(Map<String, dynamic> json) {
    final teams = _map(json['teams']);
    final recent = _map(json['recent']);
    return MatchAnalysisData(
      matchId: _string(json['matchId']),
      homeTeam: _string(teams['home']),
      awayTeam: _string(teams['away']),
      headToHead: MatchRecordGroup.fromJson(_map(json['headToHead'])),
      standings: MatchStandings.fromJson(_map(json['standings'])),
      homeRecent: TeamRecentForm.fromJson(_map(recent['home'])),
      awayRecent: TeamRecentForm.fromJson(_map(recent['away'])),
      keyPlayers: TeamPlayerSides.fromJson(_map(json['keyPlayers'])),
      injuries: TeamPlayerSides.fromJson(_map(json['injuries'])),
      future: TeamFutureSchedules.fromJson(_map(json['future'])),
      stale: json['stale'] == true,
    );
  }
}

class TeamFutureSchedules {
  const TeamFutureSchedules({required this.home, required this.away});

  final TeamFutureSchedule home;
  final TeamFutureSchedule away;

  bool get hasContent => home.matches.isNotEmpty || away.matches.isNotEmpty;

  factory TeamFutureSchedules.fromJson(Map<String, dynamic> json) {
    return TeamFutureSchedules(
      home: TeamFutureSchedule.fromJson(_map(json['home'])),
      away: TeamFutureSchedule.fromJson(_map(json['away'])),
    );
  }
}

class TeamFutureSchedule {
  const TeamFutureSchedule({required this.team, required this.matches});

  final String team;
  final List<FutureMatch> matches;

  factory TeamFutureSchedule.fromJson(Map<String, dynamic> json) {
    return TeamFutureSchedule(
      team: _string(json['team']),
      matches: _maps(json['matches'])
          .map(FutureMatch.fromJson)
          .toList(growable: false),
    );
  }
}

class FutureMatch {
  const FutureMatch({
    required this.id,
    required this.date,
    required this.league,
    required this.home,
    required this.away,
  });

  final String id;
  final String date;
  final String league;
  final String home;
  final String away;

  factory FutureMatch.fromJson(Map<String, dynamic> json) {
    return FutureMatch(
      id: _string(json['id']),
      date: _string(json['date']),
      league: _string(json['league']),
      home: _string(json['home']),
      away: _string(json['away']),
    );
  }
}

class TeamPlayerSides {
  const TeamPlayerSides({required this.home, required this.away});

  final TeamPlayerGroup home;
  final TeamPlayerGroup away;

  bool get hasContent => home.players.isNotEmpty || away.players.isNotEmpty;

  factory TeamPlayerSides.fromJson(Map<String, dynamic> json) {
    return TeamPlayerSides(
      home: TeamPlayerGroup.fromJson(_map(json['home'])),
      away: TeamPlayerGroup.fromJson(_map(json['away'])),
    );
  }
}

class TeamPlayerGroup {
  const TeamPlayerGroup({required this.team, required this.players});

  final String team;
  final List<MatchPlayer> players;

  factory TeamPlayerGroup.fromJson(Map<String, dynamic> json) {
    return TeamPlayerGroup(
      team: _string(json['team']),
      players: _maps(json['players'])
          .map(MatchPlayer.fromJson)
          .toList(growable: false),
    );
  }
}

class MatchPlayer {
  const MatchPlayer({
    required this.id,
    required this.name,
    required this.number,
    required this.position,
    required this.appearances,
    required this.starts,
    required this.substitutes,
    required this.goals,
    required this.assists,
    required this.injured,
    required this.suspended,
  });

  final String id;
  final String name;
  final String number;
  final String position;
  final int appearances;
  final int starts;
  final int substitutes;
  final int goals;
  final int assists;
  final bool injured;
  final bool suspended;

  factory MatchPlayer.fromJson(Map<String, dynamic> json) {
    return MatchPlayer(
      id: _string(json['id']),
      name: _string(json['name']),
      number: _string(json['number']),
      position: _string(json['position']),
      appearances: _integer(json['appearances']),
      starts: _integer(json['starts']),
      substitutes: _integer(json['substitutes']),
      goals: _integer(json['goals']),
      assists: _integer(json['assists']),
      injured: json['injured'] == true,
      suspended: json['suspended'] == true,
    );
  }
}

class MatchRecordGroup {
  const MatchRecordGroup({required this.summary, required this.matches});

  final MatchFormSummary summary;
  final List<MatchRecord> matches;

  factory MatchRecordGroup.fromJson(Map<String, dynamic> json) {
    return MatchRecordGroup(
      summary: MatchFormSummary.fromJson(_map(json['summary'])),
      matches: _sortedRecords(json['matches']),
    );
  }
}

class TeamRecentForm {
  const TeamRecentForm({
    required this.team,
    required this.summary,
    required this.matches,
  });

  final String team;
  final MatchFormSummary summary;
  final List<MatchRecord> matches;

  factory TeamRecentForm.fromJson(Map<String, dynamic> json) {
    return TeamRecentForm(
      team: _string(json['team']),
      summary: MatchFormSummary.fromJson(_map(json['summary'])),
      matches: _sortedRecords(json['matches']),
    );
  }

  TeamFormMetrics metrics({TeamVenue venue = TeamVenue.all}) {
    final selected = matches.where((match) {
      return switch (venue) {
        TeamVenue.all => true,
        TeamVenue.home => match.home == team,
        TeamVenue.away => match.away == team,
      };
    });
    return TeamFormMetrics.fromRecords(selected, team);
  }
}

enum TeamVenue { all, home, away }

class TeamFormMetrics {
  const TeamFormMetrics({
    required this.matches,
    required this.wins,
    required this.draws,
    required this.losses,
    required this.goalsFor,
    required this.goalsAgainst,
    required this.overTwoAndHalf,
    required this.bothTeamsScored,
  });

  final int matches;
  final int wins;
  final int draws;
  final int losses;
  final int goalsFor;
  final int goalsAgainst;
  final int overTwoAndHalf;
  final int bothTeamsScored;

  double get winRate => matches == 0 ? 0 : wins / matches;
  double get goalsForAverage => matches == 0 ? 0 : goalsFor / matches;
  double get goalsAgainstAverage => matches == 0 ? 0 : goalsAgainst / matches;
  double get overTwoAndHalfRate => matches == 0 ? 0 : overTwoAndHalf / matches;
  double get bothTeamsScoredRate =>
      matches == 0 ? 0 : bothTeamsScored / matches;
  String get record => '$wins胜$draws平$losses负';

  factory TeamFormMetrics.fromRecords(
    Iterable<MatchRecord> records,
    String team,
  ) {
    var matches = 0;
    var wins = 0;
    var draws = 0;
    var losses = 0;
    var goalsFor = 0;
    var goalsAgainst = 0;
    var overTwoAndHalf = 0;
    var bothTeamsScored = 0;
    for (final record in records) {
      final score =
          RegExp(r'(\d+)\s*[:\-]\s*(\d+)').firstMatch(record.fullScore);
      if (score == null) continue;
      final homeGoals = int.parse(score.group(1)!);
      final awayGoals = int.parse(score.group(2)!);
      final isHome = record.home == team;
      final isAway = record.away == team;
      if (!isHome && !isAway) continue;
      matches++;
      final ownGoals = isHome ? homeGoals : awayGoals;
      final opponentGoals = isHome ? awayGoals : homeGoals;
      goalsFor += ownGoals;
      goalsAgainst += opponentGoals;
      if (ownGoals > opponentGoals) {
        wins++;
      } else if (ownGoals == opponentGoals) {
        draws++;
      } else {
        losses++;
      }
      if (homeGoals + awayGoals >= 3) overTwoAndHalf++;
      if (homeGoals > 0 && awayGoals > 0) bothTeamsScored++;
    }
    return TeamFormMetrics(
      matches: matches,
      wins: wins,
      draws: draws,
      losses: losses,
      goalsFor: goalsFor,
      goalsAgainst: goalsAgainst,
      overTwoAndHalf: overTwoAndHalf,
      bothTeamsScored: bothTeamsScored,
    );
  }
}

class MatchFormSummary {
  const MatchFormSummary({
    required this.matches,
    required this.wins,
    required this.draws,
    required this.losses,
    required this.goalsFor,
    required this.goalsAgainst,
  });

  final int matches;
  final int wins;
  final int draws;
  final int losses;
  final int goalsFor;
  final int goalsAgainst;

  String get record => '$wins胜$draws平$losses负';

  factory MatchFormSummary.fromJson(Map<String, dynamic> json) {
    return MatchFormSummary(
      matches: _integer(json['matches']),
      wins: _integer(json['wins']),
      draws: _integer(json['draws']),
      losses: _integer(json['losses']),
      goalsFor: _integer(json['goalsFor']),
      goalsAgainst: _integer(json['goalsAgainst']),
    );
  }
}

class MatchRecord {
  const MatchRecord({
    required this.id,
    required this.date,
    required this.league,
    required this.home,
    required this.away,
    required this.fullScore,
    required this.halfScore,
    required this.result,
  });

  final String id;
  final String date;
  final String league;
  final String home;
  final String away;
  final String fullScore;
  final String halfScore;
  final String result;

  factory MatchRecord.fromJson(Map<String, dynamic> json) {
    return MatchRecord(
      id: _string(json['id']),
      date: _string(json['date']),
      league: _string(json['league']),
      home: _string(json['home']),
      away: _string(json['away']),
      fullScore: _string(json['fullScore']),
      halfScore: _string(json['halfScore']),
      result: _string(json['result']),
    );
  }
}

class MatchStandings {
  const MatchStandings({
    required this.league,
    required this.season,
    required this.home,
    required this.away,
  });

  final String league;
  final String season;
  final TeamStandingSet home;
  final TeamStandingSet away;

  bool get hasContent => home.hasContent || away.hasContent;

  factory MatchStandings.fromJson(Map<String, dynamic> json) {
    return MatchStandings(
      league: _string(json['league']),
      season: _string(json['season']),
      home: TeamStandingSet.fromJson(_map(json['home'])),
      away: TeamStandingSet.fromJson(_map(json['away'])),
    );
  }
}

class TeamStandingSet {
  const TeamStandingSet({
    required this.total,
    required this.home,
    required this.away,
  });

  final StandingRow total;
  final StandingRow home;
  final StandingRow away;

  bool get hasContent =>
      total.team.isNotEmpty || home.team.isNotEmpty || away.team.isNotEmpty;

  factory TeamStandingSet.fromJson(Map<String, dynamic> json) {
    return TeamStandingSet(
      total: StandingRow.fromJson(_map(json['total'])),
      home: StandingRow.fromJson(_map(json['home'])),
      away: StandingRow.fromJson(_map(json['away'])),
    );
  }
}

class StandingRow {
  const StandingRow({
    required this.team,
    required this.played,
    required this.wins,
    required this.draws,
    required this.losses,
    required this.goalsFor,
    required this.goalsAgainst,
    required this.points,
    required this.ranking,
  });

  final String team;
  final int played;
  final int wins;
  final int draws;
  final int losses;
  final int goalsFor;
  final int goalsAgainst;
  final int points;
  final int ranking;

  bool get hasContent => team.isNotEmpty;

  factory StandingRow.fromJson(Map<String, dynamic> json) {
    return StandingRow(
      team: _string(json['team']),
      played: _integer(json['played']),
      wins: _integer(json['wins']),
      draws: _integer(json['draws']),
      losses: _integer(json['losses']),
      goalsFor: _integer(json['goalsFor']),
      goalsAgainst: _integer(json['goalsAgainst']),
      points: _integer(json['points']),
      ranking: _integer(json['ranking']),
    );
  }
}

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

List<Map<String, dynamic>> _maps(dynamic value) {
  if (value is! Iterable) return const [];
  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

String _string(dynamic value) => value?.toString().trim() ?? '';

int _integer(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(_string(value)) ?? 0;
}

List<MatchRecord> _sortedRecords(dynamic value) {
  final records = _maps(value).map(MatchRecord.fromJson).toList();
  records.sort((left, right) {
    final leftDate = _recordDate(left.date);
    final rightDate = _recordDate(right.date);
    if (leftDate == null && rightDate == null) return 0;
    if (leftDate == null) return 1;
    if (rightDate == null) return -1;
    return rightDate.compareTo(leftDate);
  });
  return List.unmodifiable(records);
}

DateTime? _recordDate(String value) {
  final normalized = value.trim().replaceAll('/', '-').replaceAll('.', '-');
  final direct = DateTime.tryParse(normalized);
  if (direct != null) return direct;
  final match = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(normalized);
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}
