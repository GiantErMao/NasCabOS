package com.nascabos.mobile

import android.content.Context
import android.media.AudioManager
import android.os.StatFs
import android.provider.Settings
import com.nascabos.mobile.playback.Media3PlayerViewFactory
import com.nascabos.mobile.playback.NascabPlaybackMethodHandler
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "nascab_media3_player",
            Media3PlayerViewFactory(messenger),
        )
        NascabPlaybackMethodHandler.install(
            this,
            MethodChannel(messenger, "com.nascabos/playback"),
        )
        ExternalPlayerMethodHandler { this }.install(
            MethodChannel(messenger, "com.nascabos/external_player"),
        )
        MethodChannel(messenger, "com.nascabos/mobile_player_controls")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBrightness" -> {
                        val windowBrightness = window.attributes.screenBrightness
                        val brightness = if (windowBrightness >= 0f) {
                            windowBrightness
                        } else {
                            Settings.System.getInt(
                                contentResolver,
                                Settings.System.SCREEN_BRIGHTNESS,
                                128,
                            ) / 255f
                        }
                        result.success(brightness.coerceIn(0.01f, 1f).toDouble())
                    }
                    "setBrightness" -> {
                        val brightness =
                            (call.argument<Number>("value")?.toFloat() ?: 0.5f)
                                .coerceIn(0.01f, 1f)
                        val attributes = window.attributes
                        attributes.screenBrightness = brightness
                        window.attributes = attributes
                        result.success(null)
                    }
                    "resetBrightness" -> {
                        val attributes = window.attributes
                        attributes.screenBrightness = -1f
                        window.attributes = attributes
                        result.success(null)
                    }
                    "getVolume" -> {
                        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                        result.success(
                            audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max,
                        )
                    }
                    "setVolume" -> {
                        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                        val value =
                            (call.argument<Number>("value")?.toDouble() ?: 1.0)
                                .coerceIn(0.0, 1.0)
                        audio.setStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            (value * max).toInt().coerceIn(0, max),
                            0,
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(messenger, "com.nascabos/storage").setMethodCallHandler { call, result ->
            if (call.method != "availableBytes") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            if (path == null) {
                result.error("invalid_path", "A storage path is required", null)
                return@setMethodCallHandler
            }
            runCatching { StatFs(path).availableBytes }
                .onSuccess(result::success)
                .onFailure {
                    result.error("storage_query_failed", it.message, null)
                }
        }
    }
}
