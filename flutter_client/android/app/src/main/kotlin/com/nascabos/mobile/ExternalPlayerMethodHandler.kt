package com.nascabos.mobile

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 以 ACTION_VIEW 把视频直链交给外部播放器（Pico 自带播放器 / 系统播放器）。
 *
 * 动机：VR 一体机上设备自带播放器能提供更好的巨幕播放体验，
 * 而应用内渲染路径在虚拟显示上受限。
 */
class ExternalPlayerMethodHandler(
    private val activityProvider: () -> Activity?,
) {

    /** 已知 VR 一体机自带播放器包名（按机型不同可能有多个）。 */
    private val vrPlayerPackages = listOf(
        "com.picovr.wing.videoplayer",
        "com.picovr.videoplayer",
        "com.pvr.videoplayer",
    )

    fun install(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "launch" -> launch(call, result)
                "vrPlayer" -> result.success(findVrPlayerPackage(activityProvider()))
                else -> result.notImplemented()
            }
        }
    }

    private fun findVrPlayerPackage(activity: Activity?): String? {
        if (activity == null) return null
        val pm = activity.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            PackageManager.MATCH_DEFAULT_ONLY
        } else {
            @Suppress("DEPRECATION")
            PackageManager.MATCH_DEFAULT_ONLY
        }
        for (pkg in vrPlayerPackages) {
            val probe = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse("https://localhost/probe.mp4"), "video/mp4")
                setPackage(pkg)
            }
            val resolved = runCatching { pm.resolveActivity(probe, flags) }.getOrNull()
            if (resolved != null) return pkg
        }
        return null
    }

    private fun launch(call: MethodCall, result: MethodChannel.Result) {
        val activity = activityProvider()
        val url = call.argument<String>("url")
        if (activity == null || url.isNullOrBlank()) {
            result.success(false)
            return
        }
        val title = call.argument<String>("title") ?: ""
        val mimeType = call.argument<String>("mimeType")?.takeIf { it.isNotBlank() }
            ?: "video/*"
        val positionMs = ((call.argument<Number>("startPositionSeconds") ?: 0).toInt()) * 1000
        val uri = Uri.parse(url)

        val baseIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (title.isNotEmpty()) {
                putExtra("title", title)
                putExtra("displayName", title)
            }
            if (positionMs > 0) {
                // 主流播放器（MX Player / VLC / 系统播放器）约定的断点续播 extra
                putExtra("position", positionMs)
                putExtra("start_position", positionMs)
                putExtra("video_position", positionMs)
            }
            // 播放结束后回传结果，便于本应用重新回到前台
            putExtra("return_result", true)
        }

        val pm = activity.packageManager
        val target = call.argument<String>("target") ?: "chooser"

        // 指定播放器（如 Pico 自带播放器）：VR 里系统选择器可能不可交互，
        // 能直接定位到包名时优先直接启动。
        if (target != "chooser") {
            val pkg = if (target == "vr") findVrPlayerPackage(activity) else target
            if (!pkg.isNullOrBlank()) {
                val direct = Intent(baseIntent).apply { setPackage(pkg) }
                if (runCatching { pm.resolveActivity(direct, 0) }.getOrNull() != null) {
                    result.success(startActivity(activity, direct))
                    return
                }
            }
        }

        // 兜底：系统选择器（用户可设为默认）
        val chooser = Intent.createChooser(baseIntent, title.ifEmpty { "选择播放器" })
            .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        result.success(startActivity(activity, chooser))
    }

    private fun startActivity(activity: Activity, intent: Intent): Boolean =
        runCatching {
            activity.startActivity(intent)
            true
        }.getOrElse { false }
}
