# Contributing

Build the Release configuration using the README instructions. For Debug builds and tests, install Opus with `brew install opus`, then run:

```sh
xcodebuild -project "Roku Visor.xcodeproj" -scheme "Ukor Visor" \
  -configuration Debug -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build/DerivedData OPUS_PREFIX="$(brew --prefix opus)" build-for-testing
xcrun xctest "build/DerivedData/Build/Products/Debug/RokuVisorTests.xctest"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools
```

Run the README build command with `build analyze` for static analysis. The tests use fixtures, mocks, and loopback sockets. A physical Roku is optional for manual checks. The standalone display diagnostic remains available as the `RokuVisorDiagnostics` target.

Keep pull requests focused and describe how you verified them. Remove local paths, device information, and credentials from screenshots, logs, and fixtures. Preserve third-party notices and identify the source and license of contributed third-party code. See [third-party notices](Docs/Third-Party-Notices.md) before contributing any Roam-derived work.
