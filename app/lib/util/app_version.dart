/// Client build identifier, supplied by release builds with
/// `--dart-define=SKIPPY_CLIENT_VERSION=…`.
///
/// Local runs use an explicit SemVer development version; production images
/// receive the pipeline-stamped release version and build metadata.
const clientVersion = String.fromEnvironment(
  'SKIPPY_CLIENT_VERSION',
  defaultValue: '1.0.0-dev+local',
);
