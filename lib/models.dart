class MatchItem {
  const MatchItem({
    required this.id,
    required this.number,
    required this.businessDate,
    required this.league,
    required this.home,
    required this.away,
    required this.kickoff,
    required this.kickoffRaw,
    required this.status,
    required this.matchState,
    required this.matchStateText,
    required this.bettingStatus,
    required this.bettingStatusText,
    required this.singleSupported,
    required this.spfSingleSupported,
    required this.singlePlayTypes,
    required this.canSingle,
    required this.canParlay,
    this.score,
    this.finalScore,
    this.halfTimeScore,
    this.liveStatusText,
    this.titanLastUpdated,
    this.fetchedAt,
    this.extraTimeScore,
    this.penaltyScore,
    this.officialResults,
    required this.had,
    required this.hhad,
    required this.ttg,
    this.crs = const {},
    this.hafu = const {},
    this.pools = const {},
  });

  final String id;
  final String number;
  final String businessDate;
  final String league;
  final String home;
  final String away;
  final DateTime kickoff;
  final String kickoffRaw;
  final MatchStatus status;
  final MatchState matchState;
  final String matchStateText;
  final BettingStatus bettingStatus;
  final String bettingStatusText;
  final bool singleSupported;
  final bool spfSingleSupported;
  final List<String> singlePlayTypes;
  final bool canSingle;
  final bool canParlay;
  final String? score;
  final String? finalScore;
  final String? halfTimeScore;
  final String? liveStatusText;
  final DateTime? titanLastUpdated;
  final DateTime? fetchedAt;
  final String? extraTimeScore;
  final String? penaltyScore;
  final Map<String, dynamic>? officialResults;
  final Map<String, double> had;
  final Map<String, dynamic> hhad;
  final Map<String, double> ttg;
  final Map<String, double> crs;
  final Map<String, double> hafu;
  final Map<String, dynamic> pools;

  bool get hasOfficialKickoffTime {
    final raw = kickoffRaw.trim();
    // Midnight is a valid official kickoff. Only a date-only source value is
    // considered unfilled.
    return RegExp(r'\b\d{1,2}:\d{2}(?::\d{2})?\b').hasMatch(raw);
  }

  String get kickoffDisplayTime => hasOfficialKickoffTime
      ? '${kickoff.hour.toString().padLeft(2, '0')}:${kickoff.minute.toString().padLeft(2, '0')}'
      : '未回填';

  String get kickoffDisplayLabel {
    if (hasOfficialKickoffTime) {
      return '${businessDateOnly.year}-${businessDateOnly.month.toString().padLeft(2, '0')}-${businessDateOnly.day.toString().padLeft(2, '0')} ${kickoff.hour.toString().padLeft(2, '0')}:${kickoff.minute.toString().padLeft(2, '0')}';
    }
    final date = businessDate.isNotEmpty ? businessDate : kickoffRaw.trim();
    return date.isEmpty ? '未回填开赛时间' : '$date 未回填开赛时间';
  }

  DateTime get businessDateOnly {
    final parsed = DateTime.tryParse(businessDate);
    return parsed == null
        ? DateTime(kickoff.year, kickoff.month, kickoff.day)
        : DateTime(parsed.year, parsed.month, parsed.day);
  }

  factory MatchItem.fromJson(Map<String, dynamic> json) {
    final odds = (json['odds'] as Map?)?.cast<String, dynamic>() ?? const {};
    final officialResults =
        (json['officialResults'] as Map?)?.cast<String, dynamic>() ?? const {};

    Map<String, double> toDoubleMap(dynamic source) {
      final map = source is Map ? source : const {};
      return map.map<String, double>(
        (key, value) => MapEntry(
          key.toString(),
          value is num
              ? value.toDouble()
              : double.tryParse(value.toString()) ?? 0,
        ),
      );
    }

    String? parseScore(dynamic value) {
      if (value == null) return null;
      if (value is Map) {
        final home = value['homeScore']?.toString().trim() ?? '';
        final away = value['awayScore']?.toString().trim() ?? '';
        if (RegExp(r'^\d+$').hasMatch(home) &&
            RegExp(r'^\d+$').hasMatch(away)) {
          return '$home:$away';
        }
        for (final key in const [
          'score',
          'result',
          'value',
          'text',
          'sectionsNo999',
          'sectionsNo998',
          'sectionsNo997',
        ]) {
          final found = parseScore(value[key]);
          if (found != null) return found;
        }
      } else if (value is Iterable) {
        for (final item in value) {
          final found = parseScore(item);
          if (found != null) return found;
        }
      } else {
        final text = value.toString().trim();
        final match = RegExp(r'(\d+)\s*[:\-]\s*(\d+)').firstMatch(text);
        if (match != null) return '${match.group(1)}:${match.group(2)}';
      }
      return null;
    }

    String? findStageScore(
      Map<String, dynamic> source,
      List<String> keys, {
      List<String> codeHints = const [],
      List<String> labelHints = const [],
    }) {
      for (final key in keys) {
        final found = parseScore(source[key]);
        if (found != null) return found;
      }
      final pools = source['matchResultList'];
      if (pools is Iterable) {
        for (final raw in pools) {
          if (raw is! Map) continue;
          final pool = raw.cast<String, dynamic>();
          final code = pool['code']?.toString().toUpperCase() ?? '';
          final label = [
            pool['name'],
            pool['resultName'],
            pool['title'],
          ].whereType<Object>().join('');
          final matchesCode = codeHints.any((hint) => code.contains(hint));
          final matchesLabel = labelHints.any((hint) => label.contains(hint));
          if (matchesCode || matchesLabel) {
            final found = parseScore(pool);
            if (found != null) return found;
          }
        }
      }
      return null;
    }

    final rawStatus = json['status']?.toString().toUpperCase();
    final score = json['score']?.toString();
    final finalScore = json['finalScore']?.toString();
    final kickoff =
        DateTime.tryParse(json['kickoff']?.toString() ?? '') ?? DateTime.now();
    final isFinished = rawStatus == 'FINISHED';
    final liveStatusText = json['liveStatusText']?.toString().trim() ?? '';
    final hasLiveScore = score != null && score.isNotEmpty;
    final officialFinalScore = parseScore(officialResults['sectionsNo999']);
    final officialResultList = officialResults['matchResultList'];
    final hasOfficialResult = officialFinalScore != null ||
        (officialResultList is Iterable && officialResultList.isNotEmpty);
    final shouldTreatAsFinished = isFinished || hasOfficialResult;
    final rawMatchState = json['matchState']?.toString().trim().toLowerCase();
    final rawBettingStatus =
        json['bettingStatus']?.toString().trim().toLowerCase();
    final matchStateText = json['matchStateText']?.toString().trim() ?? '';
    final bettingStatusText =
        json['bettingStatusText']?.toString().trim() ?? '';
    final singlePlayTypesRaw = json['singlePlayTypes'];
    final explicitlyLive = rawStatus == 'LIVE' ||
        rawMatchState == 'live' ||
        rawMatchState == 'halftime' ||
        rawMatchState == 'half_time' ||
        rawMatchState == 'half-time';

    return MatchItem(
      id: json['id']?.toString() ?? '',
      number: json['number']?.toString() ?? '',
      businessDate: json['businessDate']?.toString() ?? '',
      league: json['league']?.toString() ?? '',
      home: json['home']?.toString() ?? '',
      away: json['away']?.toString() ?? '',
      kickoff: kickoff,
      kickoffRaw: json['kickoff']?.toString() ?? '',
      status: shouldTreatAsFinished
          ? MatchStatus.finished
          : (explicitlyLive || hasLiveScore || liveStatusText.isNotEmpty
              ? MatchStatus.live
              : MatchStatus.pending),
      matchState: shouldTreatAsFinished
          ? MatchState.finished
          : switch (rawMatchState) {
              'notstarted' ||
              'not_started' ||
              'pending' ||
              'not-started' =>
                MatchState.notStarted,
              'live' => MatchState.live,
              'halftime' ||
              'half_time' ||
              'half-time' ||
              'middle' =>
                MatchState.halftime,
              'finished' || 'finish' => MatchState.finished,
              'postponed' => MatchState.postponed,
              'cancelled' || 'canceled' => MatchState.cancelled,
              'suspended' => MatchState.suspended,
              _ => hasLiveScore || liveStatusText.isNotEmpty
                  ? MatchState.live
                  : MatchState.unknown,
            },
      matchStateText: matchStateText,
      bettingStatus: switch (rawBettingStatus) {
        'open' => BettingStatus.open,
        'closed' => BettingStatus.closed,
        _ => BettingStatus.unknown,
      },
      bettingStatusText: bettingStatusText,
      singleSupported: json['singleSupported'] == true,
      spfSingleSupported: json['spfSingleSupported'] == true,
      singlePlayTypes: singlePlayTypesRaw is Iterable
          ? singlePlayTypesRaw.map((e) => e.toString()).toList(growable: false)
          : const [],
      canSingle: json['canSingle'] == true,
      canParlay: json['canParlay'] == true,
      score: score,
      finalScore: finalScore ?? officialFinalScore,
      halfTimeScore: json['halfTimeScore']?.toString(),
      liveStatusText: liveStatusText.isEmpty ? null : liveStatusText,
      titanLastUpdated: DateTime.tryParse(
        json['titanLastUpdated']?.toString() ?? '',
      ),
      fetchedAt: DateTime.tryParse(
        json['fetchedAt']?.toString() ?? '',
      ),
      extraTimeScore: findStageScore(
        officialResults,
        const [
          'extraTimeScore',
          'overtimeScore',
          'aetScore',
          'afterExtraTimeScore',
        ],
        codeHints: const ['AET', 'ET', 'EXTRA', 'OVERTIME'],
        labelHints: const ['加时'],
      ),
      penaltyScore: findStageScore(
        officialResults,
        const [
          'penaltyScore',
          'penaltiesScore',
          'penaltyShootoutScore',
          'shootoutScore',
          'psScore',
        ],
        codeHints: const ['PEN'],
        labelHints: const ['点球'],
      ),
      officialResults: officialResults.isEmpty ? null : officialResults,
      had: toDoubleMap(odds['had']),
      hhad: (odds['hhad'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value),
          ) ??
          const {},
      ttg: toDoubleMap(odds['ttg']),
      crs: toDoubleMap(odds['crs']),
      hafu: toDoubleMap(odds['hafu']),
      pools: (json['pools'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  bool get isLiveDataStale {
    if (matchState != MatchState.live && matchState != MatchState.halftime) {
      return false;
    }
    final updated = titanLastUpdated ?? fetchedAt;
    return updated != null &&
        DateTime.now().difference(updated.toLocal()) >
            const Duration(minutes: 2);
  }
}

enum MatchStatus { pending, live, finished }

enum MatchState {
  notStarted,
  live,
  halftime,
  finished,
  postponed,
  cancelled,
  suspended,
  unknown,
}

enum BettingStatus { open, closed, unknown }

class ModelPrediction {
  const ModelPrediction({
    required this.model,
    required this.direction,
    required this.score,
    required this.homePercent,
    required this.drawPercent,
    required this.awayPercent,
    required this.state,
    required this.heat,
  });

  final String model;
  final String direction;
  final String score;
  final int homePercent;
  final int drawPercent;
  final int awayPercent;
  final PredictionState state;
  final String heat;
}

enum PredictionState { scoreHit, directionHit, pending }

/// 旧详情展示 DTO，仅保留以兼容尚未清理的私有 UI 组件。
/// 生产请求已不再使用这些 DTO；详情页统一使用 [MatchItem]。
class MatchDetailSnapshot {
  const MatchDetailSnapshot(this.raw);
  final Map<String, dynamic> raw;
  String? get score => raw['score']?.toString();
  String? get halfTimeScore => raw['halfTimeScore']?.toString();
  String? get liveStatusText => raw['liveStatusText']?.toString();
  Map<String, dynamic> get officialResults =>
      (raw['officialResults'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get odds =>
      (raw['odds'] as Map?)?.cast<String, dynamic>() ?? const {};
}

class MatchBasicSnapshot {
  const MatchBasicSnapshot(this.raw);
  final Map<String, dynamic> raw;
  List<String> get notes =>
      (raw['notes'] as List?)
          ?.map((item) => item.toString())
          .toList(growable: false) ??
      const [];
}

class MatchAnalysisSnapshot {
  const MatchAnalysisSnapshot(this.raw);
  final Map<String, dynamic> raw;
  int get count => (raw['count'] as num?)?.toInt() ?? 0;
  String? get consensusDirection => raw['consensusDirection']?.toString();
  Map<String, dynamic> get directionCounter =>
      (raw['directionCounter'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get streakSummary =>
      (raw['streakSummary'] as Map?)?.cast<String, dynamic>() ?? const {};
}

final demoMatches = <MatchItem>[
  MatchItem(
    id: '2192078',
    businessDate: '2026-07-02',
    number: '周四001',
    league: '世界杯',
    home: '荷兰',
    away: '摩洛哥',
    kickoff: DateTime(2026, 7, 2, 21, 0),
    kickoffRaw: '2026-07-02 21:00:00',
    status: MatchStatus.live,
    matchState: MatchState.live,
    matchStateText: '进行中',
    bettingStatus: BettingStatus.open,
    bettingStatusText: '开售',
    singleSupported: true,
    spfSingleSupported: true,
    singlePlayTypes: ['SPF', 'RQSPF'],
    canSingle: true,
    canParlay: true,
    score: '1:1',
    had: {'胜': 2.18, '平': 3.05, '负': 3.10},
    hhad: {'让球': -1, '胜': 4.60, '平': 3.75, '负': 1.58},
    ttg: {'0': 9.00, '1': 4.20, '2': 3.20, '3': 3.70, '4': 5.80, '5': 10.50},
  ),
  MatchItem(
    id: '2192079',
    businessDate: '2026-07-02',
    number: '周四002',
    league: '国际赛',
    home: '英格兰',
    away: '塞内加尔',
    kickoff: DateTime(2026, 7, 2, 23, 30),
    kickoffRaw: '2026-07-02 23:30:00',
    status: MatchStatus.pending,
    matchState: MatchState.notStarted,
    matchStateText: '未赛',
    bettingStatus: BettingStatus.open,
    bettingStatusText: '开售',
    singleSupported: false,
    spfSingleSupported: false,
    singlePlayTypes: const [],
    canSingle: false,
    canParlay: true,
    had: {'胜': 1.72, '平': 3.40, '负': 4.35},
    hhad: {'让球': -1, '胜': 3.15, '平': 3.35, '负': 1.92},
    ttg: {'0': 11.0, '1': 4.70, '2': 3.05, '3': 3.45, '4': 5.40, '5': 9.50},
  ),
  MatchItem(
    id: '2192080',
    businessDate: '2026-07-01',
    number: '周三080',
    league: '世界杯',
    home: '法国',
    away: '巴西',
    kickoff: DateTime(2026, 7, 1, 21, 0),
    kickoffRaw: '2026-07-01 21:00:00',
    status: MatchStatus.finished,
    matchState: MatchState.finished,
    matchStateText: '完场',
    bettingStatus: BettingStatus.closed,
    bettingStatusText: '停售',
    singleSupported: true,
    spfSingleSupported: false,
    singlePlayTypes: ['SPF'],
    canSingle: true,
    canParlay: true,
    score: '2:1',
    had: {'胜': 2.42, '平': 3.15, '负': 2.65},
    hhad: {'让球': 1, '胜': 1.42, '平': 4.10, '负': 5.30},
    ttg: {'0': 12.0, '1': 5.10, '2': 3.30, '3': 3.35, '4': 5.10, '5': 8.80},
  ),
];
const demoPredictions = <ModelPrediction>[
  ModelPrediction(
    model: 'Claude',
    direction: '平局',
    score: '1:1',
    homePercent: 33,
    drawPercent: 34,
    awayPercent: 33,
    state: PredictionState.scoreHit,
    heat: '冷门中',
  ),
  ModelPrediction(
    model: 'DeepSeek',
    direction: '平局',
    score: '1:1',
    homePercent: 38,
    drawPercent: 35,
    awayPercent: 27,
    state: PredictionState.scoreHit,
    heat: '冷门高',
  ),
  ModelPrediction(
    model: '豆包',
    direction: '平局',
    score: '1:1',
    homePercent: 42,
    drawPercent: 32,
    awayPercent: 26,
    state: PredictionState.scoreHit,
    heat: '冷门中',
  ),
  ModelPrediction(
    model: '千问',
    direction: '荷兰胜',
    score: '2:1',
    homePercent: 55,
    drawPercent: 25,
    awayPercent: 20,
    state: PredictionState.directionHit,
    heat: '冷门中',
  ),
  ModelPrediction(
    model: 'Codex',
    direction: '荷兰胜',
    score: '2:1',
    homePercent: 40,
    drawPercent: 31,
    awayPercent: 29,
    state: PredictionState.directionHit,
    heat: '冷门高',
  ),
];
