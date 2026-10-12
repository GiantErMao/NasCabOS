package com.nascabos.mobile

import android.os.StatFs
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
