import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/state/sync_retry_policy.dart';

void main() {
  test('permanent client errors are dropped', () {
    for (final status in [400, 403, 404, 409, 422]) {
      expect(
        syncFailureDecision(ApiException(status, 'rejected')).shouldDrop,
        isTrue,
        reason: '$status should not poison the durable queue',
      );
    }
  });

  test('auth and throttling retry without claiming the network is down', () {
    for (final status in [401, 425, 429]) {
      final decision = syncFailureDecision(ApiException(status, 'wait'));
      expect(decision.shouldDrop, isFalse);
      expect(decision.markConnectionDown, isFalse);
      expect(decision.retryDelay, const Duration(seconds: 10));
    }
  });

  test('timeouts and server failures retry as connectivity failures', () {
    for (final status in [408, 500, 503]) {
      final decision = syncFailureDecision(ApiException(status, 'retry'));
      expect(decision.shouldDrop, isFalse);
      expect(decision.markConnectionDown, isTrue);
      expect(decision.retryDelay, const Duration(seconds: 5));
    }
  });
}
