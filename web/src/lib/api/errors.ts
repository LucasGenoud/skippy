import { describeConnectionFailure } from "@/lib/util/network-error";

// Failure types every API call can raise. Ported from `ApiException` in
// `api/api_client.dart` plus the plain-language network failures of
// `util/network_error.dart`.

const MAX_USABLE_BODY = 200;

/** The server answered with a non-2xx status. */
export class ApiError extends Error {
  constructor(
    readonly statusCode: number,
    /** The raw response body. */
    readonly body: string,
  ) {
    super(`ApiError(${statusCode}): ${body}`);
    this.name = "ApiError";
  }

  /**
   * Human-readable server error from our JSON envelope; never something with
   * no point showing (empty bodies, HTML proxy pages fall back to [statusSummary]).
   */
  get serverMessage(): string {
    const body = this.body.trim();
    try {
      const decoded: unknown = JSON.parse(body);
      if (decoded !== null && typeof decoded === "object" && !Array.isArray(decoded)) {
        const error = (decoded as Record<string, unknown>).error;
        if (typeof error === "string" && error.trim()) {
          return error.trim();
        }
      }
      // Parsed as JSON but carried no message of its own.
      return this.statusSummary;
    } catch {
      // Not JSON.
    }
    const usable = body !== "" && body.length <= MAX_USABLE_BODY && !body.startsWith("<");
    return usable ? body : this.statusSummary;
  }

  /** What the status means in the app's own words, number included. */
  get statusSummary(): string {
    const code = this.statusCode;
    switch (code) {
      case 400:
        return "The server rejected the request (400).";
      case 401:
        return "Not signed in, or the session has expired (401).";
      case 403:
        return "You don't have access to that (403).";
      case 404:
      case 405:
        return `That address didn't answer like a Skippy server (${code}). Check the server URL.`;
      case 408:
        return "The server gave up waiting for the request (408).";
      case 409:
        return "That conflicts with something already saved (409).";
      case 413:
        return "That is larger than this server accepts (413).";
      case 429:
        return "Too many requests — wait a moment and try again (429).";
      case 502:
      case 503:
      case 504:
        return `The server is unavailable right now (${code}). It may be restarting, or behind a proxy that cannot reach it.`;
      default:
        return code >= 500 ? `The server ran into an error (${code}).` : `The server refused the request (${code}).`;
    }
  }
}

/** The request never reached the server's application layer. */
export class NetworkError extends Error {
  constructor(
    readonly failure: unknown,
    readonly baseUrl: string,
  ) {
    super(describeConnectionFailure(failure, baseUrl));
    this.name = "NetworkError";
  }
}

/** The caller cancelled the request through its AbortSignal. */
export class AbortedError extends Error {
  constructor() {
    super("request aborted");
    this.name = "AbortedError";
  }
}

/** What to show the user for any failure an API call raised. */
export function errorMessage(error: unknown, fallback = "Something went wrong"): string {
  if (error instanceof ApiError) {
    return error.serverMessage;
  }
  if (error instanceof NetworkError) {
    return error.message;
  }
  if (error instanceof Error && error.message) {
    return error.message;
  }
  return fallback;
}
