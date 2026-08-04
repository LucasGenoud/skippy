import '../api/api_client.dart';

class SyncFailureDecision {
  const SyncFailureDecision.drop()
    : shouldDrop = true,
      markConnectionDown = false,
      retryDelay = Duration.zero;

  const SyncFailureDecision.retry({
    required this.markConnectionDown,
    required this.retryDelay,
  }) : shouldDrop = false;

  final bool shouldDrop;
  final bool markConnectionDown;
  final Duration retryDelay;
}

/// Classifies HTTP failures for the durable optimistic-write queue.
SyncFailureDecision syncFailureDecision(ApiException error) {
  final retryableClientFailure =
      error.statusCode == 401 ||
      error.statusCode == 408 ||
      error.statusCode == 425 ||
      error.statusCode == 429;
  final permanentClientFailure =
      error.statusCode >= 400 &&
      error.statusCode < 500 &&
      !retryableClientFailure;
  if (permanentClientFailure) {
    return const SyncFailureDecision.drop();
  }

  final serverAskedToWait =
      error.statusCode == 401 ||
      error.statusCode == 425 ||
      error.statusCode == 429;
  return SyncFailureDecision.retry(
    markConnectionDown: !serverAskedToWait,
    retryDelay: serverAskedToWait
        ? const Duration(seconds: 10)
        : const Duration(seconds: 5),
  );
}
