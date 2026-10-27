package com.nascabos.mobile

import android.content.Context
import android.media.AudioManager
import android.os.StatFs
import android.provider.Settings
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import com.nascabos.mobile.playback.Media3PlayerViewFactory
import com.nascabos.mobile.playback.NascabPlaybackMethodHandler
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs

class MainActivity : AudioServiceActivity() {
    private var joystickHorizontalDirection = 0
    private var galleryControllerActive = false
    private var galleryControllerChannel: MethodChannel? = null

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
        galleryControllerChannel =
            MethodChannel(messenger, "com.nascabos/gallery_controller").also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method == "setActive") {
                        galleryControllerActive = call.argument<Boolean>("active") == true
                        if (!galleryControllerActive) joystickHorizontalDirection = 0
                        result.success(null)
                    } else {
                        result.notImplemented()
                    }
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

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (galleryControllerActive &&
            (event.keyCode == KeyEvent.KEYCODE_DPAD_LEFT ||
                event.keyCode == KeyEvent.KEYCODE_DPAD_RIGHT)
        ) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                emitGalleryDirection(if (event.keyCode == KeyEvent.KEYCODE_DPAD_LEFT) -1 else 1)
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    /** Pico 的 2D 兼容层不向普通应用发任何按键或摇杆轴事件（实测 v2075），
     * 这条路径只在真正的 Android TV / 标准手柄上才会走到。 */
    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (!galleryControllerActive) return super.dispatchGenericMotionEvent(event)
        val isJoystickMove =
            event.action == MotionEvent.ACTION_MOVE &&
                ((event.source and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK ||
                    (event.source and InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD)
        val isHorizontalScroll =
            event.action == MotionEvent.ACTION_SCROLL &&
                abs(event.getAxisValue(MotionEvent.AXIS_HSCROLL)) > 0f
        if (!isJoystickMove && !isHorizontalScroll) {
            return super.dispatchGenericMotionEvent(event)
        }

        val horizontal =
            listOf(
                event.getAxisValue(MotionEvent.AXIS_X),
                event.getAxisValue(MotionEvent.AXIS_HAT_X),
                event.getAxisValue(MotionEvent.AXIS_RX),
                event.getAxisValue(MotionEvent.AXIS_Z),
                event.getAxisValue(MotionEvent.AXIS_RZ),
                event.getAxisValue(MotionEvent.AXIS_HSCROLL),
            ).maxByOrNull(::abs) ?: 0f
        val direction = when {
            horizontal <= -JOYSTICK_TRIGGER_THRESHOLD -> -1
            horizontal >= JOYSTICK_TRIGGER_THRESHOLD -> 1
            else -> 0
        }

        if (direction == 0) {
            joystickHorizontalDirection = 0
            return super.dispatchGenericMotionEvent(event)
        }
        if (direction == joystickHorizontalDirection) return true

        joystickHorizontalDirection = direction
        emitGalleryDirection(direction)
        return true
    }

    private fun emitGalleryDirection(direction: Int) {
        galleryControllerChannel?.invokeMethod("horizontal", direction)
    }

    private companion object {
        const val JOYSTICK_TRIGGER_THRESHOLD = 0.65f
    }
}
