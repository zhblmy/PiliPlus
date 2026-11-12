package com.example.piliplus

import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DownloadForegroundService.CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // 后台启动前台服务可能被系统拒绝，这里吞掉异常并把结果回给 Dart，
                // 避免下载因为「通知起不来」而整体失败
                "start" -> result.success(
                    runCatching {
                        DownloadForegroundService.start(
                            this,
                            call.argument<String>("title").orEmpty(),
                        )
                    }.isSuccess,
                )

                "update" -> result.success(
                    runCatching {
                        DownloadForegroundService.update(
                            this,
                            call.argument<String>("title").orEmpty(),
                            call.argument<Int>("progress") ?: 0,
                            call.argument<Int>("total") ?: 0,
                        )
                    }.isSuccess,
                )

                "stop" -> result.success(
                    runCatching { DownloadForegroundService.stop(this) }.isSuccess,
                )

                else -> result.notImplemented()
            }
        }

        // 消息未读桌面角标：Dart 侧只传未读总数，权限/渠道/失败都在原生侧兜底
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MESSAGE_BADGE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setCount" -> result.success(
                    MessageBadge.update(this, call.argument<Int>("count") ?: 0),
                )

                else -> result.notImplemented()
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
        // 通知 Dart 侧：PiP 期间需要降载（降刷新率、关超分），退出后还原
        AndroidHelper.ToDart.onPipModeChanged?.run()
    }

    companion object {
        private const val MESSAGE_BADGE_CHANNEL = "piliplus/message_badge"
    }
}
