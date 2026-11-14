package com.example.piliplus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 消息通知的后台轮询宿主。
 *
 * 没有前台服务时，App 退到后台会被系统冻结，Dart 的定时轮询不会继续，
 * 通知栏也就只能停在最后一次前台刷新时的内容。这里用一个 `remoteMessaging`
 * 前台服务把进程钉住，轮询本身仍在 Dart 侧完成。
 *
 * 不用 `dataSync`：Android 15+ 对 `dataSync` 有 6 小时/24h 累计上限，常驻会被系统掐断。
 */
class MessageNotifyService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android 12+ 在后台可能拒绝把服务提升为前台；抛异常会直接崩进程，
        // 这里降级为「启动失败」：停掉自己，Dart 侧下次进入后台会重试。
        val started = runCatching {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        }.isSuccess
        if (!started) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        ensureChannel()
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else {
                    0
                },
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_icon)
            .setContentTitle("正在接收消息通知")
            .setContentText("应用在后台时接收新的私信提醒")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            // Android 12+ 默认会把前台服务通知延后 10 秒才显示，退到后台要立刻可见
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(pending)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "消息通知服务",
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "在后台接收私信提醒；关闭应用内通知后自动停止"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "message_notify_service"
        private const val NOTIFICATION_ID = 0x2200

        fun start(context: Context) {
            val intent = Intent(context, MessageNotifyService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            // stopService 不受后台启动限制，onDestroy 里会一并摘掉常驻通知
            context.stopService(Intent(context, MessageNotifyService::class.java))
        }
    }
}
