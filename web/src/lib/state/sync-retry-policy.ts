// Classifies HTTP failures for the durable optimistic-write queue. Ported from
// `state/sync_retry_policy.dart`.

export type SyncFailureDecision =
  | { readonly kind: "drop" }
  | { readonly kind: "retry"; readonly markConnectionDown: boolean; readonly retryDelayMs: number };

const HTTP_UNAUTHORIZED = 401;
const HTTP_REQUEST_TIMEOUT = 408;
const HTTP_TOO_EARLY = 425;
const HTTP_TOO_MANY_REQUESTS = 429;
const RETRY_DELAY_MS = 5_000;
const SERVER_ASKED_TO_WAIT_DELAY_MS = 10_000;

export function syncFailureDecision(statusCode: number): SyncFailureDecision {
  const retryableClientFailure =
    statusCode === HTTP_UNAUTHORIZED ||
    statusCode === HTTP_REQUEST_TIMEOUT ||
    statusCode === HTTP_TOO_EARLY ||
    statusCode === HTTP_TOO_MANY_REQUESTS;
  if (statusCode >= 400 && statusCode < 500 && !retryableClientFailure) {
    return { kind: "drop" };
  }
  const serverAskedToWait = statusCode === HTTP_UNAUTHORIZED || statusCode === HTTP_TOO_EARLY || statusCode === HTTP_TOO_MANY_REQUESTS;
  return {
    kind: "retry",
    markConnectionDown: !serverAskedToWait,
    retryDelayMs: serverAskedToWait ? SERVER_ASKED_TO_WAIT_DELAY_MS : RETRY_DELAY_MS,
  };
}
