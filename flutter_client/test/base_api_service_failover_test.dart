import 'dart:async';
import 'dart:collection';

import 'package:NasCabOS/core/api/base_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _FakeApiService extends BaseApiService {
  _FakeApiService({
    required Iterable<Object> outcomes,
    required this.recoveryResults,
  }) : outcomes = Queue<Object>.from(outcomes);

  final Queue<Object> outcomes;
  final Queue<bool> recoveryResults;
  int sendCount = 0;
  int recoveryCount = 0;

  @override
  Future<http.Response> sendApiRequest(
    String method,
    String endpoint, {
    dynamic body,
    Map<String, String>? headers,
    Map<String, String>? queryParams,
    Duration? timeout,
    Future<void>? cancelFuture,
  }) async {
    sendCount++;
    final outcome = outcomes.removeFirst();
    if (outcome is http.Response) return outcome;
    throw outcome;
  }

  @override
  Future<bool> recoverConnectionAfterRequestError({
    required Object error,
    required String endpoint,
  }) async {
    recoveryCount++;
    return recoveryResults.isEmpty ? false : recoveryResults.removeFirst();
  }
}

http.Response _successResponse() {
  return http.Response(
    '{"success":true,"data":{}}',
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  test('GET replays once after a successful channel switch', () async {
    final service = _FakeApiService(
      outcomes: [TimeoutException('first channel failed'), _successResponse()],
      recoveryResults: Queue<bool>.of([true]),
    );

    final result = await service.apiGet<dynamic>(
      '/api/files',
      maxRetries: 0,
      showLoading: false,
      showNetworkIssueOnFailure: false,
    );

    expect(result.success, isTrue);
    expect(service.sendCount, 2);
    expect(service.recoveryCount, 1);
  });

  test('GET never replays more than once for channel failover', () async {
    final service = _FakeApiService(
      outcomes: [
        TimeoutException('first channel failed'),
        TimeoutException('replacement channel failed'),
      ],
      recoveryResults: Queue<bool>.of([true, true]),
    );

    final result = await service.apiGet<dynamic>(
      '/api/files',
      maxRetries: 0,
      showLoading: false,
      showNetworkIssueOnFailure: false,
    );

    expect(result.success, isFalse);
    expect(service.sendCount, 2);
    expect(service.recoveryCount, 2);
  });

  test('POST recovers the channel but does not replay the request', () async {
    final service = _FakeApiService(
      outcomes: [TimeoutException('response was lost')],
      recoveryResults: Queue<bool>.of([true]),
    );

    final result = await service.apiPost<dynamic>(
      '/api/files/delete',
      body: const {'path': '/example'},
      maxRetries: 3,
      showLoading: false,
      showNetworkIssueOnFailure: false,
    );

    expect(result.success, isFalse);
    expect(service.sendCount, 1);
    expect(service.recoveryCount, 1);
  });
}
