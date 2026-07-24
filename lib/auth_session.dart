import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

const apiBaseUrl = String.fromEnvironment(
  'CAIMASTER_API_BASE_URL',
  defaultValue: String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.cclloo.com',
  ),
);

/// Keeps only a short-lived access token in memory. The rotating refresh
/// token is protected by the iOS Keychain through flutter_secure_storage.
class ApiSession extends ChangeNotifier {
  ApiSession._();

  static final instance = ApiSession._();
  static const _refreshTokenKey = 'caimaster.refresh-token.v1';
  static const _legacyToken = String.fromEnvironment(
    'CAIMASTER_API_TOKEN',
    defaultValue: String.fromEnvironment('API_TOKEN', defaultValue: ''),
  );

  final _storage = const FlutterSecureStorage();
  final _client = http.Client();

  Future<void>? _initialization;
  String? _accessToken;
  DateTime? _accessExpiresAt;
  bool _initialized = false;

  bool get isInitialized => _initialized;
  bool get isConfigured =>
      apiBaseUrl.isNotEmpty &&
      (_accessToken != null || _legacyToken.isNotEmpty);
  bool get usesLegacyToken => _accessToken == null && _legacyToken.isNotEmpty;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      if (_legacyToken.isEmpty) {
        final refreshToken = await _storage.read(key: _refreshTokenKey);
        if (refreshToken?.isNotEmpty ?? false) {
          await _refresh(refreshToken!);
        }
      }
    } catch (error) {
      debugPrint('[CAI_AUTH] Session restore failed: ${error.runtimeType}');
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  Future<void> activate(String enrollmentCode) async {
    final code = enrollmentCode.trim();
    if (code.isEmpty) {
      throw const ApiSessionException('请输入设备激活码');
    }
    final response = await _post('/v1/auth/enroll', {
      'enrollmentCode': code,
      'deviceName': 'iOS ${defaultTargetPlatform.name}',
    });
    await _applySession(response);
    _initialized = true;
    notifyListeners();
  }

  Future<String?> authorizationToken() async {
    await initialize();
    if (_accessToken != null && !_accessWillExpireSoon) return _accessToken;
    final refreshToken = await _storage.read(key: _refreshTokenKey);
    if (refreshToken?.isNotEmpty ?? false) {
      try {
        await _refresh(refreshToken!);
        return _accessToken;
      } on ApiSessionException {
        await _storage.delete(key: _refreshTokenKey);
        _accessToken = null;
        _accessExpiresAt = null;
        notifyListeners();
      }
    }
    return _legacyToken.isEmpty ? null : _legacyToken;
  }

  Future<void> refreshAccessToken() async {
    final refreshToken = await _storage.read(key: _refreshTokenKey);
    if (refreshToken?.isEmpty ?? true) {
      throw const ApiSessionException('设备未激活');
    }
    await _refresh(refreshToken!);
  }

  Future<void> reset() async {
    _accessToken = null;
    _accessExpiresAt = null;
    await _storage.delete(key: _refreshTokenKey);
    notifyListeners();
  }

  bool get _accessWillExpireSoon {
    final expiresAt = _accessExpiresAt;
    if (expiresAt == null) return true;
    return expiresAt
        .isBefore(DateTime.now().toUtc().add(const Duration(seconds: 30)));
  }

  Future<void> _refresh(String refreshToken) async {
    final response = await _post('/v1/auth/refresh', {
      'refreshToken': refreshToken,
    });
    await _applySession(response);
  }

  Future<void> _applySession(Map<String, dynamic> value) async {
    final accessToken = value['accessToken']?.toString().trim() ?? '';
    final refreshToken = value['refreshToken']?.toString().trim() ?? '';
    final expiresAt =
        DateTime.tryParse(value['accessExpiresAt']?.toString() ?? '');
    if (accessToken.isEmpty || refreshToken.isEmpty || expiresAt == null) {
      throw const ApiSessionException('服务端返回的设备凭据无效');
    }
    _accessToken = accessToken;
    _accessExpiresAt = expiresAt.toUtc();
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, String> body,
  ) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    try {
      final response = await _client
          .post(
            uri,
            headers: const {
              'Content-Type': 'application/json',
              'Cache-Control': 'no-store',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw ApiSessionException(_activationError(response.statusCode));
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const ApiSessionException('服务端返回格式异常');
      }
      return decoded;
    } on ApiSessionException {
      rethrow;
    } catch (error) {
      debugPrint('[CAI_AUTH] Request failed: ${error.runtimeType}');
      throw const ApiSessionException('无法连接服务，请检查网络后重试');
    }
  }

  String _activationError(int statusCode) {
    if (statusCode == 401 || statusCode == 403) return '设备激活码无效';
    if (statusCode == 429) return '尝试次数过多，请稍后再试';
    if (statusCode >= 500) return '服务暂不可用，请稍后再试';
    return '设备激活失败，请稍后再试';
  }
}

class ApiSessionException implements Exception {
  const ApiSessionException(this.message);

  final String message;

  @override
  String toString() => message;
}
