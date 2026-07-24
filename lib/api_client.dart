import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_session.dart';
import 'models.dart';

class ApiException implements Exception {
  const ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CaiApiClient {
  CaiApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static bool _didLogRuntimeConfig = false;

  bool get isConfigured => ApiSession.instance.isConfigured;

  void _logRuntimeConfig(Uri uri) {
    if (_didLogRuntimeConfig) return;
    _didLogRuntimeConfig = true;
    final scheme = uri.scheme.toLowerCase();
    debugPrint(
      '[CAI_API][config] url=${_sanitizeUri(uri)} '
      'scheme=$scheme '
      'sessionConfigured=${ApiSession.instance.isConfigured} '
      'legacyMigration=${ApiSession.instance.usesLegacyToken}',
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

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final uri = Uri.parse('$apiBaseUrl$path').replace(queryParameters: {
      ...?queryParameters,
      '_ts': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    _logRuntimeConfig(uri);
    var token = await ApiSession.instance.authorizationToken();
    if (token == null || token.isEmpty) {
      debugPrint(
        '[CAI_API][error] url=${_sanitizeUri(uri)} type=missing_session',
      );
      throw const ApiException('设备尚未激活，请前往设置完成激活');
    }
    try {
      var response = await _request(uri, token);
      if (response.statusCode == 401 && !ApiSession.instance.usesLegacyToken) {
        await ApiSession.instance.refreshAccessToken();
        token = await ApiSession.instance.authorizationToken();
        if (token != null && token.isNotEmpty) {
          response = await _request(uri, token);
        }
      }
      debugPrint(
        '[CAI_API][response] url=${_sanitizeUri(uri)} '
        'status=${response.statusCode} type=${_classifyStatus(response.statusCode)}',
      );
      if (response.statusCode != 200) {
        throw ApiException(
          '服务端响应异常：${response.statusCode}（${_classifyStatus(response.statusCode)}）',
        );
      }
      return jsonDecode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    } catch (error) {
      if (error is ApiException) rethrow;
      debugPrint(
        '[CAI_API][error] url=${_sanitizeUri(uri)} '
        'type=${_classifyError(error)} detail=${error.runtimeType}',
      );
      throw ApiException('请求失败：${_classifyError(error)}');
    }
  }

  Future<http.Response> _request(Uri uri, String token) =>
      _client.get(uri, headers: {
        'Authorization': 'Bearer $token',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      }).timeout(const Duration(seconds: 12));

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

  Future<List<Map<String, dynamic>>> fetchModelRankings() async {
    final body = await _getJson('/v1/models/rankings');
    final items = body['items'] as List<dynamic>? ?? const [];
    return items.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  void close() => _client.close();
}
