import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'match_analysis.dart';

const apiBaseUrl = String.fromEnvironment(
  'CAIMASTER_API_BASE_URL',
  defaultValue: String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.cclloo.com',
  ),
);

class ApiException implements Exception {
  const ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class TeamMetadata {
  const TeamMetadata({
    required this.name,
    required this.badgeUrl,
    this.sourceName = '',
    this.league = '',
    this.country = '',
  });

  factory TeamMetadata.fromJson(Map<String, dynamic> json) => TeamMetadata(
        name: (json['name'] ?? '').toString(),
        badgeUrl: (json['badgeUrl'] ?? '').toString(),
        sourceName: (json['sourceName'] ?? '').toString(),
        league: (json['league'] ?? '').toString(),
        country: (json['country'] ?? '').toString(),
      );

  final String name;
  final String badgeUrl;
  final String sourceName;
  final String league;
  final String country;
}

class CaiApiClient {
  CaiApiClient({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  http.Client _client;
  final bool _ownsClient;
  static bool _didLogRuntimeConfig = false;

  bool get isConfigured => apiBaseUrl.isNotEmpty;

  void _logRuntimeConfig(Uri uri) {
    if (_didLogRuntimeConfig) return;
    _didLogRuntimeConfig = true;
    final scheme = uri.scheme.toLowerCase();
    debugPrint(
      '[CAI_API][config] url=${_sanitizeUri(uri)} '
      'scheme=$scheme '
      'publicReadOnlyApi=true',
    );
    if (scheme != 'https') {
      debugPrint('[CAI_API][transport] Non-HTTPS API URL detected.');
    }
  }

  String _sanitizeUri(Uri uri) => uri.replace(userInfo: '').toString();

  String _classifyError(Object error) {
    final text = error.toString().toLowerCase();
    if (error is TimeoutException) return 'timeout';
    if (error is HandshakeException) return 'tls_handshake';
    if (error is SocketException) return 'socket_dns_or_network';
    if (error is http.ClientException && text.contains('app transport')) {
      return 'ats_blocked';
    }
    if (text.contains('app transport security') || text.contains('ats')) {
      return 'ats_blocked';
    }
    return error.runtimeType.toString();
  }

  String _classifyStatus(int statusCode) {
    if (statusCode == 401 || statusCode == 403) return 'auth_rejected';
    if (statusCode >= 500) return 'server_error';
    if (statusCode >= 400) return 'client_error';
    return 'http_$statusCode';
  }

  String _userMessageForError(Object error) {
    if (error is TimeoutException) return '请求超时，请稍后重试';
    if (error is HandshakeException) return '安全连接失败，请稍后重试';
    if (error is SocketException || error is http.ClientException) {
      return '网络连接异常，请检查网络后重试';
    }
    return '数据加载失败，请稍后重试';
  }

  String _userMessageForStatus(int statusCode) {
    if (statusCode >= 500) return '服务暂时不可用，请稍后重试';
    return '数据请求异常，请稍后重试';
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final uri = Uri.parse('$apiBaseUrl$path').replace(queryParameters: {
      ...?queryParameters,
      '_ts': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    _logRuntimeConfig(uri);
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await _request(uri);
        debugPrint(
          '[CAI_API][response] url=${_sanitizeUri(uri)} '
          'status=${response.statusCode} type=${_classifyStatus(response.statusCode)}',
        );
        if (response.statusCode != 200) {
          throw ApiException(_userMessageForStatus(response.statusCode));
        }
        return jsonDecode(utf8.decode(response.bodyBytes))
            as Map<String, dynamic>;
      } catch (error) {
        if (error is ApiException) rethrow;
        lastError = error;
        if (attempt < 2) {
          _resetOwnedClient();
          await Future<void>.delayed(
            Duration(milliseconds: attempt == 0 ? 300 : 700),
          );
          continue;
        }
      }
    }
    final error = lastError ?? const FormatException('Unknown request error');
    debugPrint(
      '[CAI_API][error] url=${_sanitizeUri(uri)} '
      'type=${_classifyError(error)} detail=${error.runtimeType}',
    );
    throw ApiException(_userMessageForError(error));
  }

  Future<http.Response> _request(Uri uri) =>
      _client.get(uri).timeout(const Duration(seconds: 12));

  void _resetOwnedClient() {
    if (!_ownsClient) return;
    _client.close();
    _client = http.Client();
  }

  Future<List<MatchItem>> fetchMatches(String scope, {DateTime? date}) async {
    final queryParameters = <String, String>{
      'scope': scope,
      'limit': '300',
      if (date != null)
        'date':
            '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
    };
    final body =
        await _getJson('/v1/matches', queryParameters: queryParameters);
    final items = body['items'] as List<dynamic>? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(MatchItem.fromJson)
        .toList(growable: false);
  }

  Future<List<dynamic>> fetchLiveMatches({int limit = 150}) async {
    final body = await _getJson('/v1/matches/live', queryParameters: {
      'limit': '$limit',
    });
    return body['items'] as List<dynamic>? ?? const [];
  }

  Future<List<dynamic>> fetchResultMatches({
    int limit = 150,
    DateTime? date,
  }) async {
    final queryParameters = <String, String>{
      'limit': '$limit',
      if (date != null)
        'date':
            '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
    };
    final body = await _getJson(
      '/v1/matches/results',
      queryParameters: queryParameters,
    );
    return body['items'] as List<dynamic>? ?? const [];
  }

  Future<List<dynamic>> fetchBettableMatches({int limit = 150}) async {
    final body = await _getJson('/v1/matches/bettable', queryParameters: {
      'limit': '$limit',
    });
    return body['items'] as List<dynamic>? ?? const [];
  }

  /// 生产详情接口：返回单场真实比赛、状态、赛果和各玩法赔率。
  Future<MatchItem> fetchMatch(String matchId) async {
    final body = await _getJson('/v1/matches/$matchId');
    return MatchItem.fromJson(body);
  }

  Future<List<Map<String, dynamic>>> fetchMatchPredictions(
    String matchId,
  ) async {
    final body = await _getJson('/v1/matches/$matchId/predictions');
    final items = body['items'] as List<dynamic>? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  /// 官方赔率采集器按变化写入的历史快照，按时间正序返回。
  Future<List<Map<String, dynamic>>> fetchOddsHistory(
    String matchId,
  ) async {
    final body = await _getJson('/v1/matches/$matchId/odds-history');
    final items = body['items'] as List<dynamic>? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> fetchMarketOdds(String matchId) async {
    final body = await _getJson('/v1/matches/$matchId/market-odds');
    return Map<String, dynamic>.from(body);
  }

  Future<MatchAnalysisData> fetchMatchAnalysis(String matchId) async {
    final body = await _getJson('/v1/matches/$matchId/analysis');
    return MatchAnalysisData.fromJson(body);
  }

  Future<Map<String, TeamMetadata>> fetchTeamMetadata(
    Iterable<String> names,
  ) async {
    final requested = names
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .take(10)
        .toList(growable: false);
    if (requested.isEmpty) return const {};
    final body = await _getJson(
      '/v1/teams/metadata',
      queryParameters: {'names': requested.join(',')},
    );
    final result = <String, TeamMetadata>{};
    for (final item in body['items'] as List<dynamic>? ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      final metadata = TeamMetadata.fromJson(item);
      if (metadata.name.isNotEmpty && metadata.badgeUrl.isNotEmpty) {
        result[metadata.name] = metadata;
      }
    }
    return result;
  }

  Future<MatchStandings> fetchTeamStandings({
    required String home,
    required String away,
  }) async {
    final body = await _getJson(
      '/v1/teams/standings',
      queryParameters: {'home': home.trim(), 'away': away.trim()},
    );
    return MatchStandings.fromJson(body);
  }

  Future<List<Map<String, dynamic>>> fetchModelRankings() async {
    final body = await _getJson('/v1/models/rankings');
    final items = body['items'] as List<dynamic>? ?? const [];
    return items.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  Future<Map<String, dynamic>> fetchPlans({
    String query = '',
    List<String> ids = const [],
    String activity = 'all',
    int limit = 20,
    int offset = 0,
  }) {
    final keyword = query.trim();
    return _getJson('/v1/plans', queryParameters: {
      if (keyword.isNotEmpty) 'q': keyword,
      if (ids.isNotEmpty) 'ids': ids.join(','),
      if (ids.isEmpty && keyword.isEmpty && activity != 'all')
        'activity': activity,
      'limit': '$limit',
      'offset': '$offset',
    });
  }

  Future<Map<String, dynamic>> fetchRecentPlans({int limit = 6}) {
    return _getJson('/v1/plans/recent', queryParameters: {
      'limit': '$limit',
    });
  }

  Future<Map<String, dynamic>> fetchPlanUpdates(
    String planId, {
    int? days,
    int limit = 10,
    int offset = 0,
  }) {
    return _getJson('/v1/plans/$planId/updates', queryParameters: {
      if (days != null) 'days': '$days',
      'limit': '$limit',
      'offset': '$offset',
    });
  }

  Future<Map<String, dynamic>> fetchPlanArticles({
    String query = '',
    List<String> ids = const [],
    String activity = 'all',
    int limit = 20,
    int offset = 0,
  }) {
    final keyword = query.trim();
    return _getJson('/v1/plan-articles', queryParameters: {
      if (keyword.isNotEmpty) 'q': keyword,
      if (ids.isNotEmpty) 'ids': ids.join(','),
      if (ids.isEmpty && keyword.isEmpty && activity != 'all')
        'activity': activity,
      'limit': '$limit',
      'offset': '$offset',
    });
  }

  Future<Map<String, dynamic>> fetchRecentPlanArticles({int limit = 6}) {
    return _getJson('/v1/plan-articles/recent', queryParameters: {
      'limit': '$limit',
    });
  }

  Future<Map<String, dynamic>> fetchPlanArticleVersions(
    String articleId, {
    int limit = 10,
    int offset = 0,
  }) {
    return _getJson(
      '/v1/plan-articles/$articleId/versions',
      queryParameters: {
        'limit': '$limit',
        'offset': '$offset',
      },
    );
  }

  void close() => _client.close();
}
