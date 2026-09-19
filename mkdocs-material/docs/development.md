# Development

## Run locally

```sh
cd backend && cargo run
cd app && flutter run
```

## Check changes

```sh
cd backend && cargo test && cargo clippy --all-targets -- -D warnings
cd app && flutter analyze && flutter test
```

Format touched Dart files with `dart format` and Rust files with `cargo fmt`.
