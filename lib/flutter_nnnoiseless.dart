import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_nnnoiseless/src/ffi/rust_bindings.dart';
import 'package:wav/wav_file.dart';

abstract class Noiseless {
  static final Noiseless instance = _NoiselessImpl();

  static int get targetSampleRate => RustBindings.instance.targetSampleRate;

  static int get frameSize => RustBindings.instance.frameSize;

  Future<void> denoiseFile({
    required String inputPathStr,
    required String outputPathStr,
  });

  NoiselessStreamSession createSession({
    required int inputSampleRate,
    int numChannels = 1,
  });

  int recommendedInputFrameBytes({
    required int sampleRate,
    int numChannels = 1,
  });

  Uint8List denoiseChunk({
    required Uint8List input,
    int inputSampleRate = 48000,
  });

  void resetDenoiseChunkState();

  Future<void> pcmToWav({
    required Uint8List pcmData,
    required String outputPath,
    int sampleRate = 48000,
    int numChannels = 1,
  });
}

class NoiselessStreamSession implements ffi.Finalizable {
  NoiselessStreamSession._({
    required this.inputSampleRate,
    required this.numChannels,
    required ffi.Pointer<ffi.Void> handle,
  }) : _handle = handle {
    _finalizer.attach(this, _handle.cast(), detach: this);
  }

  static final _bindings = RustBindings.instance;
  static final _finalizer = ffi.NativeFinalizer(
    _bindings.streamDestroySymbol.cast(),
  );

  final int inputSampleRate;
  final int numChannels;
  ffi.Pointer<ffi.Void> _handle;

  int get outputSampleRate => inputSampleRate;

  int get recommendedInputFrameBytes => _bindings.recommendedInputFrameBytes(
    sampleRate: inputSampleRate,
    numChannels: numChannels,
  );

  bool get isClosed => _handle == ffi.nullptr;

  Uint8List processChunk(Uint8List input) {
    _ensureOpen();
    return _bindings.processStream(_handle, input);
  }

  Uint8List flush() {
    _ensureOpen();
    return _bindings.flushStream(_handle);
  }

  void close() {
    if (_handle == ffi.nullptr) {
      return;
    }

    _finalizer.detach(this);
    _bindings.destroyStream(_handle);
    _handle = ffi.nullptr;
  }

  void _ensureOpen() {
    if (_handle == ffi.nullptr) {
      throw StateError('NoiselessStreamSession has already been closed.');
    }
  }
}

class _NoiselessImpl extends Noiseless {
  _NoiselessImpl() : _bindings = RustBindings.instance;

  final RustBindings _bindings;
  NoiselessStreamSession? _compatSession;
  int? _compatSampleRate;

  @override
  Future<void> denoiseFile({
    required String inputPathStr,
    required String outputPathStr,
  }) {
    return Isolate.run(
      () => RustBindings.instance.denoiseFile(
        inputPath: inputPathStr,
        outputPath: outputPathStr,
      ),
    );
  }

  @override
  NoiselessStreamSession createSession({
    required int inputSampleRate,
    int numChannels = 1,
  }) {
    final handle = _bindings.createStream(
      inputSampleRate: inputSampleRate,
      numChannels: numChannels,
    );
    return NoiselessStreamSession._(
      inputSampleRate: inputSampleRate,
      numChannels: numChannels,
      handle: handle,
    );
  }

  @override
  int recommendedInputFrameBytes({
    required int sampleRate,
    int numChannels = 1,
  }) {
    return _bindings.recommendedInputFrameBytes(
      sampleRate: sampleRate,
      numChannels: numChannels,
    );
  }

  @override
  Uint8List denoiseChunk({
    required Uint8List input,
    int inputSampleRate = 48000,
  }) {
    final session = _compatSession;
    if (session == null ||
        _compatSampleRate != inputSampleRate ||
        session.isClosed) {
      _compatSession?.close();
      _compatSession = createSession(inputSampleRate: inputSampleRate);
      _compatSampleRate = inputSampleRate;
    }

    return _compatSession!.processChunk(input);
  }

  @override
  void resetDenoiseChunkState() {
    _compatSession?.close();
    _compatSession = null;
    _compatSampleRate = null;
  }

  @override
  Future<void> pcmToWav({
    required Uint8List pcmData,
    required String outputPath,
    int sampleRate = 48000,
    int numChannels = 1,
  }) async {
    final pcm16 = pcmData.buffer.asInt16List(
      pcmData.offsetInBytes,
      pcmData.lengthInBytes ~/ 2,
    );
    final frameCount = pcm16.length ~/ numChannels;
    final channels = List.generate(numChannels, (_) => Float64List(frameCount));

    for (int index = 0; index < frameCount; index++) {
      for (int channel = 0; channel < numChannels; channel++) {
        final raw = pcm16[index * numChannels + channel] / 32768.0;
        final sample = raw.isFinite ? raw : 0.0;
        channels[channel][index] = sample.clamp(-1.0, 1.0).toDouble();
      }
    }

    final wav = Wav(channels, sampleRate);
    final resolvedPath = outputPath.toLowerCase().endsWith('.wav')
        ? outputPath
        : '$outputPath.wav';
    await wav.writeFile(resolvedPath);
  }
}
