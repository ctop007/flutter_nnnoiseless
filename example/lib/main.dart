import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_nnnoiseless/flutter_nnnoiseless.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const _audioPreviewChannel = MethodChannel(
    'example.flutter_nnnoiseless/audio_preview',
  );

  final _recorder = AudioRecorder();
  final _noiseless = Noiseless.instance;

  StreamSubscription<Uint8List>? _streamSubscription;
  NoiselessStreamSession? _session;

  bool _isRecording = false;
  bool _isBusy = false;
  String _status = 'Ready';
  String? _tempDir;
  String? _rawWavPath;
  String? _denoisedWavPath;
  String? _fileDenoisedPath;

  @override
  void initState() {
    super.initState();
    _initTempDir();
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _session?.close();
    _recorder.dispose();
    unawaited(_stopPlayback());
    super.dispose();
  }

  Future<void> _initTempDir() async {
    final directory = await getTemporaryDirectory();
    if (!mounted) {
      return;
    }
    setState(() {
      _tempDir = directory.path;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0E7A64)),
      useMaterial3: true,
    );

    return MaterialApp(
      theme: theme,
      home: Scaffold(
        appBar: AppBar(title: const Text('NNNoiseless Debug')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionCard(
              title: 'Engine',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Target sample rate: ${Noiseless.targetSampleRate} Hz'),
                  Text('Model frame size: ${Noiseless.frameSize} samples'),
                  Text(
                    'Recommended chunk @ 48k mono: '
                    '${_noiseless.recommendedInputFrameBytes(sampleRate: 48000)} bytes',
                  ),
                  if (_tempDir != null) ...[
                    const SizedBox(height: 8),
                    SelectableText('Temp dir: $_tempDir'),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Actions',
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton(
                    onPressed: _isBusy ? null : _denoiseBundledFile,
                    child: const Text('Denoise sample.wav'),
                  ),
                  FilledButton.tonal(
                    onPressed:
                        _isBusy || _isRecording ? null : _startRealtimeDenoise,
                    child: const Text('Start mic stream'),
                  ),
                  OutlinedButton(
                    onPressed: _isRecording ? _stopRealtimeDenoise : null,
                    child: const Text('Stop stream'),
                  ),
                  OutlinedButton(
                    onPressed: _hasPlayableFile ? _stopPlayback : null,
                    child: const Text('Stop playback'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Status',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_status),
                  const SizedBox(height: 8),
                  Text('Recording: ${_isRecording ? "yes" : "no"}'),
                  Text('Busy: ${_isBusy ? "yes" : "no"}'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _buildOutputCard(
              title: 'Realtime raw',
              filePath: _rawWavPath,
              playLabel: 'Play raw',
            ),
            const SizedBox(height: 12),
            _buildOutputCard(
              title: 'Realtime denoised',
              filePath: _denoisedWavPath,
              playLabel: 'Play denoised',
            ),
            const SizedBox(height: 12),
            _buildOutputCard(
              title: 'File denoised',
              filePath: _fileDenoisedPath,
              playLabel: 'Play file output',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOutputCard({
    required String title,
    required String? filePath,
    required String playLabel,
  }) {
    return _SectionCard(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(filePath ?? 'No file yet'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.tonal(
                onPressed: filePath == null ? null : () => _playFile(filePath),
                child: Text(playLabel),
              ),
              OutlinedButton(
                onPressed:
                    filePath == null ? null : () => _revealFileInfo(filePath),
                child: const Text('Refresh stats'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _denoiseBundledFile() async {
    final tempDir = _tempDir;
    if (tempDir == null) {
      _setStatus('Temporary directory is not ready yet.');
      return;
    }

    _setBusy(true, 'Denoising bundled asset...');
    try {
      final byteData = await rootBundle.load('assets/sample.wav');
      final noiseWavPath = path.join(tempDir, 'sample.wav');
      final outputPath = path.join(tempDir, 'sample_denoised.wav');
      await File(noiseWavPath).writeAsBytes(byteData.buffer.asUint8List());
      await _noiseless.denoiseFile(
        inputPathStr: noiseWavPath,
        outputPathStr: outputPath,
      );
      setState(() {
        _fileDenoisedPath = outputPath;
      });
      await _revealFileInfo(outputPath);
    } catch (error) {
      _setStatus('File denoise failed: $error');
    } finally {
      _setBusy(false, _status);
    }
  }

  Future<void> _startRealtimeDenoise() async {
    final tempDir = _tempDir;
    if (tempDir == null) {
      _setStatus('Temporary directory is not ready yet.');
      return;
    }

    if (!await _recorder.hasPermission()) {
      _setStatus('Microphone permission was denied.');
      return;
    }

    final rawPcmPath = path.join(tempDir, 'stream_raw');
    final denoisedPcmPath = path.join(tempDir, 'stream_denoised');
    final rawWavPath = '$rawPcmPath.wav';
    final denoisedWavPath = '$denoisedPcmPath.wav';

    await _deleteIfExists(rawPcmPath);
    await _deleteIfExists(denoisedPcmPath);
    await _deleteIfExists(rawWavPath);
    await _deleteIfExists(denoisedWavPath);

    final rawSink = File(rawPcmPath).openWrite();
    final denoisedSink = File(denoisedPcmPath).openWrite();
    final session = _noiseless.createSession(inputSampleRate: 48000);
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 48000,
        numChannels: 1,
      ),
    );

    setState(() {
      _isRecording = true;
      _session = session;
      _rawWavPath = null;
      _denoisedWavPath = null;
    });
    _setStatus(
      'Streaming... speak into the mic. Recommended chunk size: '
      '${session.recommendedInputFrameBytes} bytes',
    );

    _streamSubscription = stream.listen(
      (chunk) {
        rawSink.add(chunk);
        final denoised = session.processChunk(chunk);
        if (denoised.isNotEmpty) {
          denoisedSink.add(denoised);
        }
      },
      onError: (Object error, StackTrace stackTrace) async {
        await rawSink.close();
        await denoisedSink.close();
        session.close();
        if (!mounted) {
          return;
        }
        setState(() {
          _isRecording = false;
          _session = null;
          _streamSubscription = null;
        });
        _setStatus('Realtime stream failed: $error');
      },
      onDone: () async {
        final flushed = session.flush();
        if (flushed.isNotEmpty) {
          denoisedSink.add(flushed);
        }
        session.close();

        final rawFile = await rawSink.close();
        final denoisedFile = await denoisedSink.close();

        await _noiseless.pcmToWav(
          pcmData: rawFile.readAsBytesSync(),
          outputPath: rawPcmPath,
          sampleRate: 48000,
        );
        await _noiseless.pcmToWav(
          pcmData: denoisedFile.readAsBytesSync(),
          outputPath: denoisedPcmPath,
          sampleRate: session.outputSampleRate,
        );

        if (!mounted) {
          return;
        }
        setState(() {
          _isRecording = false;
          _session = null;
          _streamSubscription = null;
          _rawWavPath = rawWavPath;
          _denoisedWavPath = denoisedWavPath;
        });
        await _revealFileInfo(denoisedWavPath);
      },
      cancelOnError: true,
    );
  }

  Future<void> _stopRealtimeDenoise() async {
    if (!_isRecording) {
      return;
    }
    await _recorder.stop();
    _setStatus('Stopping stream and flushing remaining audio...');
  }

  Future<void> _playFile(String pathStr) async {
    await _audioPreviewChannel.invokeMethod<void>('playFile', {
      'path': pathStr,
    });
    _setStatus('Playing $pathStr');
  }

  Future<void> _stopPlayback() async {
    await _audioPreviewChannel.invokeMethod<void>('stopPlayback');
    _setStatus('Playback stopped.');
  }

  Future<void> _revealFileInfo(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      _setStatus('File not found: $filePath');
      return;
    }
    final bytes = await file.length();
    _setStatus('Ready: $filePath ($bytes bytes)');
  }

  Future<void> _deleteIfExists(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  bool get _hasPlayableFile =>
      _rawWavPath != null ||
      _denoisedWavPath != null ||
      _fileDenoisedPath != null;

  void _setBusy(bool value, String status) {
    if (!mounted) {
      return;
    }
    setState(() {
      _isBusy = value;
      _status = status;
    });
  }

  void _setStatus(String status) {
    if (!mounted) {
      return;
    }
    setState(() {
      _status = status;
    });
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
