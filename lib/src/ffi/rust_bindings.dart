import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _StreamHandle extends ffi.Opaque {}

final class FfiByteBuffer extends ffi.Struct {
  external ffi.Pointer<ffi.Uint8> ptr;

  @ffi.Size()
  external int len;

  @ffi.Int32()
  external int code;
}

typedef _DenoiseFileNative =
    ffi.Int32 Function(
      ffi.Pointer<Utf8> inputPath,
      ffi.Pointer<Utf8> outputPath,
    );
typedef _DenoiseFileDart =
    int Function(ffi.Pointer<Utf8> inputPath, ffi.Pointer<Utf8> outputPath);

typedef _GetU32Native = ffi.Uint32 Function();
typedef _GetU32Dart = int Function();

typedef _GetUsizeNative = ffi.UintPtr Function();
typedef _GetUsizeDart = int Function();

typedef _RecommendedBytesNative =
    ffi.UintPtr Function(ffi.Uint32 inputSampleRate, ffi.Uint32 numChannels);
typedef _RecommendedBytesDart =
    int Function(int inputSampleRate, int numChannels);

typedef _CreateStreamNative =
    ffi.Pointer<_StreamHandle> Function(
      ffi.Uint32 inputSampleRate,
      ffi.Uint32 numChannels,
    );
typedef _CreateStreamDart =
    ffi.Pointer<_StreamHandle> Function(int inputSampleRate, int numChannels);

typedef _ProcessStreamNative =
    FfiByteBuffer Function(
      ffi.Pointer<_StreamHandle> stream,
      ffi.Pointer<ffi.Uint8> input,
      ffi.UintPtr inputLength,
    );
typedef _ProcessStreamDart =
    FfiByteBuffer Function(
      ffi.Pointer<_StreamHandle> stream,
      ffi.Pointer<ffi.Uint8> input,
      int inputLength,
    );

typedef _FlushStreamNative =
    FfiByteBuffer Function(ffi.Pointer<_StreamHandle> stream);
typedef _FlushStreamDart =
    FfiByteBuffer Function(ffi.Pointer<_StreamHandle> stream);

typedef _DestroyStreamNative =
    ffi.Void Function(ffi.Pointer<_StreamHandle> stream);
typedef _DestroyStreamDart = void Function(ffi.Pointer<_StreamHandle> stream);
typedef _FreeBufferNative =
    ffi.Void Function(ffi.Pointer<ffi.Uint8> ptr, ffi.UintPtr len);
typedef _FreeBufferDart = void Function(ffi.Pointer<ffi.Uint8> ptr, int len);

typedef _LastErrorNative = ffi.Pointer<Utf8> Function();
typedef _LastErrorDart = ffi.Pointer<Utf8> Function();

typedef _FreeStringNative = ffi.Void Function(ffi.Pointer<Utf8> ptr);
typedef _FreeStringDart = void Function(ffi.Pointer<Utf8> ptr);

class RustBindings {
  RustBindings._(ffi.DynamicLibrary library)
    : _denoiseFile = library
          .lookupFunction<_DenoiseFileNative, _DenoiseFileDart>(
            'nnnoiseless_denoise_file',
          ),
      _targetSampleRate = library.lookupFunction<_GetU32Native, _GetU32Dart>(
        'nnnoiseless_target_sample_rate',
      ),
      _frameSize = library.lookupFunction<_GetUsizeNative, _GetUsizeDart>(
        'nnnoiseless_frame_size',
      ),
      _recommendedInputBytes = library
          .lookupFunction<_RecommendedBytesNative, _RecommendedBytesDart>(
            'nnnoiseless_stream_recommended_input_bytes',
          ),
      _streamCreate = library
          .lookupFunction<_CreateStreamNative, _CreateStreamDart>(
            'nnnoiseless_stream_create',
          ),
      _streamProcess = library
          .lookupFunction<_ProcessStreamNative, _ProcessStreamDart>(
            'nnnoiseless_stream_process',
          ),
      _streamFlush = library
          .lookupFunction<_FlushStreamNative, _FlushStreamDart>(
            'nnnoiseless_stream_flush',
          ),
      _streamDestroy = library
          .lookupFunction<_DestroyStreamNative, _DestroyStreamDart>(
            'nnnoiseless_stream_destroy',
          ),
      _streamDestroySymbol = library
          .lookup<ffi.NativeFunction<_DestroyStreamNative>>(
            'nnnoiseless_stream_destroy',
          )
          .cast(),
      _bufferFree = library.lookupFunction<_FreeBufferNative, _FreeBufferDart>(
        'nnnoiseless_buffer_free',
      ),
      _lastError = library.lookupFunction<_LastErrorNative, _LastErrorDart>(
        'nnnoiseless_last_error_message',
      ),
      _stringFree = library.lookupFunction<_FreeStringNative, _FreeStringDart>(
        'nnnoiseless_string_free',
      );

  static final RustBindings instance = RustBindings._(_openLibrary());

  final _DenoiseFileDart _denoiseFile;
  final _GetU32Dart _targetSampleRate;
  final _GetUsizeDart _frameSize;
  final _RecommendedBytesDart _recommendedInputBytes;
  final _CreateStreamDart _streamCreate;
  final _ProcessStreamDart _streamProcess;
  final _FlushStreamDart _streamFlush;
  final _DestroyStreamDart _streamDestroy;
  final ffi.Pointer<
    ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>
  >
  _streamDestroySymbol;
  final _FreeBufferDart _bufferFree;
  final _LastErrorDart _lastError;
  final _FreeStringDart _stringFree;

  ffi.Pointer<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>
  get streamDestroySymbol => _streamDestroySymbol;

  int get targetSampleRate => _targetSampleRate();

  int get frameSize => _frameSize();

  int recommendedInputFrameBytes({
    required int sampleRate,
    int numChannels = 1,
  }) {
    return _recommendedInputBytes(sampleRate, numChannels);
  }

  void denoiseFile({required String inputPath, required String outputPath}) {
    final inputPathPtr = inputPath.toNativeUtf8();
    final outputPathPtr = outputPath.toNativeUtf8();

    try {
      final code = _denoiseFile(inputPathPtr, outputPathPtr);
      if (code != 0) {
        throw RustException(_lastErrorMessage());
      }
    } finally {
      malloc.free(inputPathPtr);
      malloc.free(outputPathPtr);
    }
  }

  ffi.Pointer<ffi.Void> createStream({
    required int inputSampleRate,
    int numChannels = 1,
  }) {
    final handle = _streamCreate(inputSampleRate, numChannels);
    if (handle == ffi.nullptr) {
      throw RustException(_lastErrorMessage());
    }
    return handle.cast();
  }

  Uint8List processStream(ffi.Pointer<ffi.Void> handle, Uint8List input) {
    ffi.Pointer<ffi.Uint8> inputPtr = ffi.nullptr;
    if (input.isNotEmpty) {
      inputPtr = malloc.allocate<ffi.Uint8>(input.length);
      inputPtr.asTypedList(input.length).setAll(0, input);
    }

    try {
      final result = _streamProcess(handle.cast(), inputPtr, input.length);
      return _copyAndFreeBuffer(result);
    } finally {
      if (inputPtr != ffi.nullptr) {
        malloc.free(inputPtr);
      }
    }
  }

  Uint8List flushStream(ffi.Pointer<ffi.Void> handle) {
    final result = _streamFlush(handle.cast());
    return _copyAndFreeBuffer(result);
  }

  void destroyStream(ffi.Pointer<ffi.Void> handle) {
    if (handle == ffi.nullptr) {
      return;
    }
    _streamDestroy(handle.cast());
  }

  Uint8List _copyAndFreeBuffer(FfiByteBuffer buffer) {
    if (buffer.code != 0) {
      throw RustException(_lastErrorMessage());
    }
    if (buffer.ptr == ffi.nullptr || buffer.len == 0) {
      return Uint8List(0);
    }

    try {
      return Uint8List.fromList(buffer.ptr.asTypedList(buffer.len));
    } finally {
      _bufferFree(buffer.ptr, buffer.len);
    }
  }

  String _lastErrorMessage() {
    final errorPtr = _lastError();
    if (errorPtr == ffi.nullptr) {
      return 'Rust call failed without an error message.';
    }

    try {
      return errorPtr.toDartString();
    } finally {
      _stringFree(errorPtr);
    }
  }

  static ffi.DynamicLibrary _openLibrary() {
    if (Platform.isIOS || Platform.isMacOS) {
      return ffi.DynamicLibrary.process();
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return ffi.DynamicLibrary.open('libhzh_noise.so');
    }
    if (Platform.isWindows) {
      return ffi.DynamicLibrary.open('hzh_noise.dll');
    }

    throw UnsupportedError('Unsupported platform for flutter_nnnoiseless');
  }
}

class RustException implements Exception {
  RustException(this.message);

  final String message;

  @override
  String toString() => message;
}
