import 'dart:convert';

import 'package:cai_tool_app/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('GET requests remain CORS-simple for Flutter Web', () async {
    late http.Request captured;
    final client = CaiApiClient(
      client: MockClient((request) async {
        captured = request;
        return http.Response('{"items": []}', 200);
      }),
    );

    await client.fetchLiveMatches();

    expect(captured.headers.containsKey('Cache-Control'), isFalse);
    expect(captured.headers.containsKey('Pragma'), isFalse);
  });

  test('live and bettable requests use the supported default limit', () async {
    final requests = <http.Request>[];
    final client = CaiApiClient(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('{"items": []}', 200);
      }),
    );

    await client.fetchLiveMatches();
    await client.fetchBettableMatches();

    expect(requests, hasLength(2));
    expect(requests[0].url.queryParameters['limit'], '150');
    expect(requests[1].url.queryParameters['limit'], '150');
  });

  test('API errors expose a user-facing server message', () async {
    final client = CaiApiClient(
      client: MockClient((_) async => http.Response('{}', 503)),
    );

    await expectLater(
      client.fetchLiveMatches(),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          '服务暂时不可用，请稍后重试',
        ),
      ),
    );
  });

  test('plan activity is sent unless favorite ids are requested', () async {
    final requests = <http.Request>[];
    final client = CaiApiClient(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('{"items": []}', 200);
      }),
    );

    await client.fetchPlans(activity: 'recent');
    await client.fetchPlans(ids: const ['12'], activity: 'recent');

    expect(requests.first.url.queryParameters['activity'], 'recent');
    expect(requests.last.url.queryParameters['ids'], '12');
    expect(requests.last.url.queryParameters.containsKey('activity'), isFalse);
  });

  test('network failures do not expose implementation exceptions', () async {
    var attempts = 0;
    final client = CaiApiClient(
      client: MockClient((_) async {
        attempts++;
        throw http.ClientException('blocked');
      }),
    );

    await expectLater(
      client.fetchLiveMatches(),
      throwsA(
        isA<ApiException>()
            .having(
              (error) => error.message,
              'message',
              '网络连接异常，请检查网络后重试',
            )
            .having(
              (error) => error.message,
              'message',
              isNot(contains('ClientException')),
            ),
      ),
    );
    expect(attempts, 3);
  });

  test('transient GET failure is retried without surfacing an error', () async {
    var attempts = 0;
    final client = CaiApiClient(
      client: MockClient((_) async {
        attempts++;
        if (attempts == 1) throw http.ClientException('temporary');
        return http.Response('{"items":[]}', 200);
      }),
    );

    final result = await client.fetchPlans();

    expect(result['items'], isEmpty);
    expect(attempts, 2);
  });

  test('team metadata uses exact names and parses mapped teams', () async {
    late http.Request captured;
    final client = CaiApiClient(
      client: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(
            '{"items":[{"name":"哈茨","sourceName":"Heart of Midlothian",'
            '"badgeUrl":"https://api.cclloo.com/media/teams/133643.png"}]}',
          ),
          200,
        );
      }),
    );

    final result = await client.fetchTeamMetadata(const ['哈茨', '哈茨', '奥胡斯']);

    expect(captured.url.path, '/v1/teams/metadata');
    expect(captured.url.queryParameters['names'], '哈茨,奥胡斯');
    expect(result['哈茨']?.sourceName, 'Heart of Midlothian');
    expect(result['哈茨']?.badgeUrl, contains('/media/teams/133643.png'));
  });

  test('team standings fallback parses domestic table rows', () async {
    late http.Request captured;
    final client = CaiApiClient(
      client: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(
            '{"league":"芬兰超","season":"2026",'
            '"home":{"total":{"team":"库奥皮奥","ranking":1,"points":36}},'
            '"away":{"total":{"team":"萨巴赫","ranking":2,"points":32}}}',
          ),
          200,
        );
      }),
    );

    final result = await client.fetchTeamStandings(home: '库奥皮奥', away: '萨巴赫');

    expect(captured.url.path, '/v1/teams/standings');
    expect(captured.url.queryParameters['home'], '库奥皮奥');
    expect(result.home.total.ranking, 1);
    expect(result.away.total.points, 32);
  });
}
