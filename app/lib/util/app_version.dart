/// Client build identifier, supplied by release builds with
/// `--dart-define=SKIPPY_CLIENT_VERSION=…`.
///
/// Keeping a development fallback makes the Settings page useful for local
/// runs too, while production images receive the pipeline-stamped value.
const clientVersion = String.fromEnvironment(
  'SKIPPY_CLIENT_VERSION',
  defaultValue: 'development',
);
