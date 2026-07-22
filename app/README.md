# Skippy Flutter client

This directory contains the Flutter client for Skippy. It targets web, iOS, and Android and talks to the Rust API in `../backend`. See the [root README](../README.md) for product features, full-stack setup, and deployment details.

## Development

Use Flutter 3.44+ with Dart 3.12+.

```sh
flutter pub get
flutter run
```

The login screen lets users choose a backend. A bundled web build normally uses the current origin; `--dart-define=API_BASE=http://localhost:8787` overrides that default during development.

## Verification

```sh
flutter analyze
flutter test
```

Production code depends on the `Api` interface in `lib/api/api_client.dart`. Tests use `test/fake_api.dart`, so store and widget behavior can be exercised without a running backend.
