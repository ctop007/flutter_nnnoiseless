package com.antonkarpenko.nnnoiseless

import android.media.MediaPlayer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var mediaPlayer: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "example.flutter_nnnoiseless/audio_preview",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "playFile" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "Audio path is missing.", null)
                        return@setMethodCallHandler
                    }

                    runCatching {
                        mediaPlayer?.release()
                        mediaPlayer = MediaPlayer().apply {
                            setDataSource(path)
                            setOnCompletionListener {
                                it.release()
                                mediaPlayer = null
                            }
                            prepare()
                            start()
                        }
                    }.onSuccess {
                        result.success(null)
                    }.onFailure { error ->
                        result.error("playback_failed", error.message, null)
                    }
                }

                "stopPlayback" -> {
                    mediaPlayer?.run {
                        if (isPlaying) {
                            stop()
                        }
                        release()
                    }
                    mediaPlayer = null
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        mediaPlayer?.release()
        mediaPlayer = null
        super.onDestroy()
    }
}
