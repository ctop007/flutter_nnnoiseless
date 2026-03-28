<div align="center">

# Flutter NNNoiseless

_Real-Time and batch audio noise reduction for Flutter. Port of the [nnnoiseless](https://github.com/jneem/nnnoiseless) Rust project, using traditional Dart FFI with a Rust backend._

<p align="center">
  <a href="https://pub.dev/packages/flutter_nnnoiseless">
     <img src="https://img.shields.io/badge/pub-1.0.1-blue?logo=dart" alt="pub">
  </a>
  <a href="https://buymeacoffee.com/sk3llo" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/default-orange.png" alt="Buy Me A Coffee" height="21" width="114"></a>
</p>
</div>


## Supported platforms


| Platform  | Supported |
|-----------|-----------|
| Android   | ✅        |
| iOS       | ✅        |
| MacOS     | ✅        |
| Windows   | ✅        |
| Linux     | In progress       |


## Requirements

- `Flutter 3.0.0` or higher
- `iOS 11.0` or higher
- `macOS 10.15` or higher
- `Android SDK 23` or higher
- `Windows 10` or higher

## Getting started

1. Create a `Noiseless` instance:

```dart
final noiseless = Noiseless.instance;
```

2. Denoise a file:

```dart
await noiseless.denoiseFile(inputPathStr: 'assets/noise.wav', outputPathStr: 'assets/output.wav');
```

3. For real-time audio, create a dedicated session and keep it for the whole stream:

```dart
final session = noiseless.createSession(inputSampleRate: 48000);

stream.listen((input) {
  final result = session.processChunk(input);
  if (result.isNotEmpty) {
    // Write or play the denoised PCM chunk.
  }
});

final tail = session.flush();
session.close();
```

## Streaming requirements

- Input must be raw `pcm16le`.
- Real-time processing currently supports mono audio only.
- Use the real input sample rate when creating the session.
- A session keeps its own denoiser and resampler state, so do not recreate it for every chunk.
- Output PCM uses the same sample rate as the session input.
- Recommended chunk size is about 10-20ms of audio. You can query it with:

```dart
final bytes = noiseless.recommendedInputFrameBytes(sampleRate: 48000);
```

## Prebuilt mobile binaries

This repository can bundle prebuilt Android and iOS native artifacts so downstream
apps do not need Rust installed.

To refresh the mobile prebuilts on macOS:

```bash
./scripts/build_prebuilt_mobile.sh
```

This script updates:

- Android JNI libraries in `android/src/main/jniLibs`
- iOS XCFramework in `ios/Frameworks/hzh_noise.xcframework`

Android will prefer the checked-in JNI libraries when all four ABI slices are
present. iOS will prefer the checked-in XCFramework when it exists. If the
prebuilt artifacts are missing, the plugin falls back to building Rust from
source.
