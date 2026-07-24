import 'dart:async';

import 'package:flutter/material.dart';

import '../../models.dart';

class HomeDateDivider extends StatelessWidget {
  const HomeDateDivider({required this.date, super.key});

  final DateTime date;

  static const _orange = Color(0xffffad21);

  String _weekday(int weekday) {
    const values = [
      [0x5468, 0x4e00],
      [0x5468, 0x4e8c],
      [0x5468, 0x4e09],
      [0x5468, 0x56db],
      [0x5468, 0x4e94],
      [0x5468, 0x516d],
      [0x5468, 0x65e5],
    ];
    return String.fromCharCodes(values[weekday - 1]);
  }

  @override
  Widget build(BuildContext context) {
    final label =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}  ${_weekday(date.weekday)}';
    return SizedBox(
      height: 28,
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            color: _orange,
            fontSize: 13,
            height: 1.0,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class HomeMatchRow extends StatefulWidget {
  const HomeMatchRow({required this.match, this.onTap, super.key});

  final MatchItem match;
  final VoidCallback? onTap;

  @override
  State<HomeMatchRow> createState() => _HomeMatchRowState();
}

class _HomeMatchRowState extends State<HomeMatchRow> {
  static const _teamColor = Color(0xff202224);
  static const _helperColor = Color(0xff969ca1);
  static const _leagueColor = Color(0xff65ad3c);
  static const _liveColor = Color(0xff20a95a);
  static const _resultColor = Color(0xffff3f70);

  bool _starred = false;
  bool _goalFlash = false;
  int? _goalSide;
  Timer? _goalFlashTimer;

  MatchItem get match => widget.match;

  ({int home, int away})? _scorePair(MatchItem item) {
    final raw = (item.score ?? item.finalScore ?? '').trim();
    final found = RegExp(r'(\d+)\s*[:\-]\s*(\d+)').firstMatch(raw);
    if (found == null) return null;
    return (
      home: int.parse(found.group(1)!),
      away: int.parse(found.group(2)!),
    );
  }

  @override
  void didUpdateWidget(covariant HomeMatchRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameMatch = oldWidget.match.id == widget.match.id ||
        (oldWidget.match.id.isEmpty &&
            oldWidget.match.number == widget.match.number &&
            oldWidget.match.businessDate == widget.match.businessDate);
    final oldScore = _scorePair(oldWidget.match);
    final newScore = _scorePair(widget.match);
    final isLiveUpdate = widget.match.matchState == MatchState.live ||
        widget.match.matchState == MatchState.halftime;
    if (!sameMatch ||
        !isLiveUpdate ||
        oldScore == null ||
        newScore == null ||
        newScore.home + newScore.away <= oldScore.home + oldScore.away) {
      return;
    }
    final homeScored = newScore.home > oldScore.home;
    final awayScored = newScore.away > oldScore.away;
    _goalFlashTimer?.cancel();
    setState(() {
      _goalFlash = true;
      _goalSide = homeScored && !awayScored
          ? -1
          : awayScored && !homeScored
              ? 1
              : 0;
    });
    _goalFlashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() {
          _goalFlash = false;
          _goalSide = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _goalFlashTimer?.cancel();
    super.dispose();
  }

  String _text(List<int> codeUnits) => String.fromCharCodes(codeUnits);

  String _keyWin() => _text(const [0x80dc]);
  String _keyDraw() => _text(const [0x5e73]);
  String _keyLose() => _text(const [0x8d1f]);
  String _keyHandicap() => _text(const [0x8ba9, 0x7403]);
  String _notStartedLabel() => _text(const [0x672a, 0x8d5b]);
  String _singleLabel() => _text(const [0x5355, 0x5173]);

  bool get _isPending =>
      match.matchState == MatchState.notStarted ||
      match.matchState == MatchState.unknown;
  bool get _isLive => match.matchState == MatchState.live;
  bool get _isHalfTime => match.matchState == MatchState.halftime;
  bool get _isFinished =>
      match.matchState == MatchState.finished ||
      match.status == MatchStatus.finished;

  String _statusText() {
    if (_isPending) return _notStartedLabel();
    final provided = match.matchStateText.trim();
    if (provided.isNotEmpty) return provided;
    final fallback = match.liveStatusText?.trim() ?? '';
    return fallback;
  }

  String? _minuteText() {
    final raw = (match.liveStatusText ?? '').trim();
    final minute = RegExp(r'\d{1,3}(?:\+\d{1,2})?').firstMatch(raw)?.group(0);
    return minute == null || minute.isEmpty ? null : "$minute'";
  }

  String _extractFinalScore(Map<String, dynamic>? source) {
    if (source == null || source.isEmpty) return '--';

    String? readScore(dynamic value) {
      if (value is Map) {
        for (final key in const [
          'finalScore',
          'fullTimeScore',
          'ftScore',
          'sectionsNo999',
          'sectionsNo998',
          'score',
          'result',
          'combination',
        ]) {
          final found = readScore(value[key]);
          if (found != null) return found;
        }
        for (final item in value.values) {
          final found = readScore(item);
          if (found != null) return found;
        }
      } else if (value is Iterable) {
        for (final item in value) {
          final found = readScore(item);
          if (found != null) return found;
        }
      } else if (value != null) {
        final found =
            RegExp(r'(\d+)\s*[:\-]\s*(\d+)').firstMatch(value.toString());
        if (found != null) return '${found.group(1)}:${found.group(2)}';
      }
      return null;
    }

    return readScore(source) ?? '--';
  }

  String _handicapText() {
    final value = match.hhad[_keyHandicap()]?.toString().trim() ?? '';
    if (value.isEmpty) return '';
    return value == '0' ? _text(const [0x5e73, 0x624b]) : value;
  }

  String _handicapDisplay() {
    final handicap = _handicapText();
    if (handicap.isEmpty || handicap == _text(const [0x5e73, 0x624b])) {
      return handicap;
    }
    if (handicap.startsWith('-')) {
      return _text(const [0x8ba9]) +
          handicap.substring(1) +
          _text(const [0x7403]);
    }
    if (handicap.startsWith('+')) {
      return _text(const [0x53d7, 0x8ba9]) +
          handicap.substring(1) +
          _text(const [0x7403]);
    }
    return _text(const [0x8ba9]) + handicap + _text(const [0x7403]);
  }

  List<String> _homeOdds() => [
        _formatOdd(match.had[_keyWin()]),
        _formatOdd(match.had[_keyDraw()]),
        _formatOdd(match.had[_keyLose()]),
      ];

  List<String> _awayOdds() => [
        _formatOdd(match.hhad[_keyWin()]),
        _formatOdd(match.hhad[_keyDraw()]),
        _formatOdd(match.hhad[_keyLose()]),
      ];

  String _formatOdd(dynamic value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty || text == '--') return '--';
    return double.tryParse(text)?.toStringAsFixed(2) ?? text;
  }

  Widget _odds(List<String> values,
      {required TextAlign align, String prefix = ''}) {
    final text = '$prefix${values.join('  ')}';
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: align == TextAlign.right
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: Text(
        text,
        maxLines: 1,
        textAlign: align,
        style: const TextStyle(
          color: _helperColor,
          fontSize: 9.5,
          height: 1.0,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  String _matchDayText() {
    final number = match.number.trim();
    final sequence = RegExp(r'\d+$').firstMatch(number);
    return sequence == null ? number : number.substring(0, sequence.start);
  }

  String _matchSequenceText() {
    final number = match.number.trim();
    return RegExp(r'\d+$').firstMatch(number)?.group(0) ?? '';
  }

  Widget _numberText(String value) {
    return Text(
      value,
      maxLines: 1,
      style: const TextStyle(
        color: Color(0xff747b81),
        fontSize: 10.5,
        height: 1.0,
        fontWeight: FontWeight.w500,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _leagueLabel() {
    return Text(
      match.league,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: _leagueColor,
        fontSize: 10.5,
        height: 1.0,
      ),
    );
  }

  Widget _singleTag() {
    if (!match.spfSingleSupported) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: _resultColor, width: 0.8),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        _singleLabel(),
        style: const TextStyle(
          color: _resultColor,
          fontSize: 8.5,
          height: 1.0,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _homeTeam() {
    return Text(
      match.home,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
      style: const TextStyle(
        color: _teamColor,
        fontSize: 14,
        height: 1.0,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _awayTeam() {
    return Text(
      match.away,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: _teamColor,
        fontSize: 14,
        height: 1.0,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  String _displayStatus() {
    if (match.isLiveDataStale) return '比分更新中';
    final status = _isLive ? (_minuteText() ?? _statusText()) : _statusText();
    return _isLive ? (_minuteText() ?? status) : status;
  }

  String _displayScore() {
    final finalScore = match.finalScore?.trim().isNotEmpty == true
        ? match.finalScore!.trim()
        : _extractFinalScore(match.officialResults);
    final score = finalScore == '--' ? (match.score ?? '--') : finalScore;
    return score;
  }

  String _displayHalfScore() => (match.halfTimeScore ?? '').trim();

  bool get _isFirstHalf {
    if (!_isLive) return false;
    final raw = (match.liveStatusText ?? '').trim().toLowerCase();
    if (raw.contains('下半场') || raw.contains('second half') || raw == '2h') {
      return false;
    }
    if (raw.contains('上半场') || raw.contains('first half') || raw == '1h') {
      return true;
    }
    final minute = RegExp(r'\d{1,3}').firstMatch(raw)?.group(0);
    return minute != null && (int.tryParse(minute) ?? 46) <= 45;
  }

  Color _statusColor() {
    return _isFinished
        ? _resultColor
        : (_isHalfTime
            ? const Color(0xffff9f1c)
            : (_isLive ? _resultColor : _helperColor));
  }

  Color _scoreColor() {
    final isScoring = _isLive || _isHalfTime;
    return _isFinished ? _resultColor : (isScoring ? _liveColor : _helperColor);
  }

  Widget _centerTopStatus() {
    if (_isPending) return const SizedBox.shrink();
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        _displayStatus(),
        maxLines: 1,
        style: TextStyle(
          color: _statusColor(),
          fontSize: 12,
          height: 1.0,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _centerMainStatus() {
    if (_isPending) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          _displayStatus(),
          maxLines: 1,
          style: const TextStyle(
            color: _helperColor,
            fontSize: 12,
            height: 1.0,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }
    final scoreColor = _scoreColor();
    final half = _displayHalfScore();
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: _displayScore(),
              style: TextStyle(
                color: scoreColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (half.isNotEmpty && !_isFirstHalf)
              TextSpan(
                text: ' ($half)',
                style: TextStyle(
                  color: scoreColor.withAlpha(178),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
        maxLines: 1,
        textAlign: TextAlign.center,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
        height: 68,
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xffeceeef))),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const numberWidth = 40.0;
            const leagueLeft = 44.0;
            const leagueWidth = 56.0;
            const timeLeft = 104.0;
            const homeContentLeft = 58.0;
            const starWidth = 22.0;
            const centerWidth = 78.0;
            const sideGap = 6.0;
            final centerX = constraints.maxWidth / 2;
            final homeRight =
                constraints.maxWidth - (centerX - centerWidth / 2 - sideGap);
            final awayLeft = centerX + centerWidth / 2 + sideGap;
            final handicap = _handicapText();
            final handicapDisplay = _handicapDisplay();
            return Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: centerX,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _goalFlash && (_goalSide == -1 || _goalSide == 0)
                          ? 1
                          : 0,
                      duration: const Duration(milliseconds: 280),
                      child: const ColoredBox(color: Color(0xffe5f8ed)),
                    ),
                  ),
                ),
                Positioned(
                  left: centerX,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _goalFlash && (_goalSide == 1 || _goalSide == 0)
                          ? 1
                          : 0,
                      duration: const Duration(milliseconds: 280),
                      child: const ColoredBox(color: Color(0xffe5f8ed)),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 7,
                  width: numberWidth,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _numberText(_matchDayText()),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 27,
                  width: numberWidth,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _numberText(_matchSequenceText()),
                  ),
                ),
                Positioned(
                  left: leagueLeft,
                  top: 8,
                  width: leagueWidth,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _leagueLabel(),
                  ),
                ),
                Positioned(
                  left: timeLeft,
                  right: homeRight,
                  top: 8,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      match.kickoffDisplayTime,
                      style: const TextStyle(
                        color: Color(0xff7d848a),
                        fontSize: 10.5,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: centerX - centerWidth / 2,
                  width: centerWidth,
                  top: 8,
                  child: Center(child: _centerTopStatus()),
                ),
                Positioned(
                  left: homeContentLeft,
                  right: homeRight,
                  top: 27,
                  child: _homeTeam(),
                ),
                Positioned(
                  left: awayLeft,
                  right: starWidth,
                  top: 8,
                  child: Text(
                    handicapDisplay,
                    maxLines: 1,
                    style: const TextStyle(
                      color: Color(0xff7d848a),
                      fontSize: 11,
                      height: 1.0,
                    ),
                  ),
                ),
                Positioned(
                  left: centerX - centerWidth / 2,
                  width: centerWidth,
                  top: 27,
                  child: Center(
                    child: AnimatedScale(
                      scale: _goalFlash ? 1.14 : 1,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      child: _centerMainStatus(),
                    ),
                  ),
                ),
                Positioned(
                  left: awayLeft,
                  right: starWidth,
                  top: 27,
                  child: _awayTeam(),
                ),
                Positioned(
                  left: 0,
                  bottom: 6,
                  width: numberWidth,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _singleTag(),
                  ),
                ),
                Positioned(
                  left: homeContentLeft,
                  right: homeRight,
                  bottom: 8,
                  child: _odds(_homeOdds(), align: TextAlign.right),
                ),
                Positioned(
                  left: awayLeft,
                  right: starWidth,
                  bottom: 8,
                  child: _odds(
                    _awayOdds(),
                    align: TextAlign.left,
                    prefix: handicap.isEmpty ? '' : '($handicap) ',
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: starWidth,
                  child: Center(
                    child: IconButton(
                      iconSize: 19,
                      padding: EdgeInsets.zero,
                      splashRadius: 16,
                      onPressed: () => setState(() => _starred = !_starred),
                      icon: Icon(
                        _starred ? Icons.star : Icons.star_border,
                        color: _starred
                            ? const Color(0xffffad21)
                            : const Color(0xffc3c8cb),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
