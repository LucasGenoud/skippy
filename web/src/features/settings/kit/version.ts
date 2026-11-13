/**
 * Client build identifier (`clientVersion` in `util/app_version.dart`). A
 * release build sets NEXT_PUBLIC_SKIPPY_CLIENT_VERSION; local runs read as a
 * development version.
 */
export const CLIENT_VERSION = process.env.NEXT_PUBLIC_SKIPPY_CLIENT_VERSION ?? "1.0.0-dev+local";
