package com.example.piliplus

import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import java.util.concurrent.Executors
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

        // 消息通知：按会话展示发送者头像/名称/内容，桌面角标由这些通知的数字带出
        // 旧版的「有未读消息」汇总通知不再使用：启动时就清掉，不必等第一次更新
        MESSAGE_BADGE_EXECUTOR.execute {
            runCatching { MessageBadge.ensureMigrated(this) }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MESSAGE_BADGE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setConversations" -> {
                    val args = call.arguments as? Map<*, *>
                    // 没传 = 本次不改动；传空列表 = 清空会话通知
                    val conversations = if (args != null && args.containsKey("conversations")) {
                        (args["conversations"] as? List<*>).orEmpty()
                            .mapNotNull { (it as? Map<*, *>)?.toConversationNotice() }
                    } else {
                        null
                    }
                    val badge = args?.get("badge") as? Boolean ?: false
                    MESSAGE_BADGE_EXECUTOR.execute {
                        val success = runCatching {
                            MessageBadge.update(this, conversations, badge)
                        }.getOrDefault(false)
                        // 引擎可能已销毁（后台被回收）：回执失败不能带崩进程
                        runOnUiThread { runCatching { result.success(success) } }
                    }
                }

                else -> result.notImplemented()
            }
        }

        // 会话通知的后台轮询宿主：Dart 侧定时器需要前台服务把进程钉住
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MESSAGE_NOTIFY_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(
                    runCatching { MessageNotifyService.start(this) }.isSuccess,
                )

                "stop" -> result.success(
                    runCatching { MessageNotifyService.stop(this) }.isSuccess,
                )

                else -> result.notImplemented()
            }
        }
    }

    private fun Map<*, *>.toConversationNotice(): ConversationNotice? {
        val key = this["key"] as? String ?: return null
        return ConversationNotice(
            key = key,
            name = (this["name"] as? String).orEmpty().ifEmpty { "新消息" },
            avatarUrl = (this["avatarUrl"] as? String).orEmpty(),
            avatar = this["avatar"] as? ByteArray,
            content = (this["content"] as? String).orEmpty().ifEmpty { "有新消息" },
            unread = (this["unread"] as? Number)?.toInt()?.coerceAtLeast(1) ?: 1,
            muted = this["muted"] as? Boolean ?: false,
            timestamp = (this["timestamp"] as? Number)?.toLong() ?: 0L,
            alert = this["alert"] as? Boolean ?: true,
        )
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
        private val MESSAGE_BADGE_EXECUTOR = Executors.newSingleThreadExecutor()

        private const val MESSAGE_BADGE_CHANNEL = "piliplus/message_badge"
        private const val MESSAGE_NOTIFY_CHANNEL = "piliplus/message_notify_foreground"
    }
}
