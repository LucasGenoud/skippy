// Plain-language explanation of a request that never reached the server's
// application layer. Ported from `util/network_error.dart`; the browser
// reports most failures as a TypeError("Failed to fetch"), which lands in the
// browser-specific branch.

function hostOf(baseUrl: string): string {
  try {
    const url = new URL(baseUrl);
    if (!url.hostname) {
      return baseUrl || "the server";
    }
    return url.port ? `${url.hostname}:${url.port}` : url.hostname;
  } catch {
    return baseUrl || "the server";
  }
}

/** Marks a request that ran out of time (see the API transport). */
export class TimeoutError extends Error {
  constructor(message = "request timeout") {
    super(message);
    this.name = "TimeoutError";
  }
}

export function describeConnectionFailure(error: unknown, baseUrl: string): string {
  const host = hostOf(baseUrl);
  const text = (error instanceof Error ? `${error.name}: ${error.message}` : String(error)).toLowerCase();
  const mentions = (needle: string): boolean => text.includes(needle);

  if (error instanceof TimeoutError || mentions("timeout") || mentions("aborterror")) {
    return `${host} did not respond in time. It may be starting up, or unreachable from this network.`;
  }
  if (
    mentions("failed host lookup") ||
    mentions("nodename nor servname") ||
    mentions("name or service not known") ||
    mentions("no address associated")
  ) {
    return `Can't find ${host}. Check the address for typos, and that this device can resolve it.`;
  }
  if (mentions("connection refused")) {
    return `Nothing is answering at ${host}. Check the port, and that the server is running.`;
  }
  if (mentions("handshake") || mentions("certificate") || (mentions("tls") && mentions("error"))) {
    return `Couldn't open a secure connection to ${host}. Its HTTPS certificate was rejected — a self-signed one has to be trusted on this device first.`;
  }
  if (
    mentions("network is unreachable") ||
    mentions("no route to host") ||
    mentions("connection reset") ||
    mentions("connection closed") ||
    mentions("connection failed")
  ) {
    return `Couldn't reach ${host}. Check this device's connection, and that the server is reachable from it.`;
  }
  // The browser reports a blocked or failed fetch identically whether the
  // server is down, the certificate is untrusted, or CORS refused it.
  if (mentions("xmlhttprequest") || mentions("failed to fetch") || mentions("networkerror") || mentions("load failed")) {
    return `The browser couldn't reach ${host}. It may be offline, using an untrusted certificate, or refusing this origin.`;
  }
  if (mentions("invalid url") || mentions("formatexception")) {
    return "That server address is not valid. It has to start with http:// or https://.";
  }
  return `Can't reach ${host}. Check the server address and this device's connection.`;
}
