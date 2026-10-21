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
 * 下载期间的 dataSync 前台服务。
 *
 * 进程没有前台服务时（未播放音频时 audio_service 不持有前台服务），澎湃 OS / 各家
 * 后台冻结策略会直接中断纯 Dart 的下载任务；这里用一个常驻进度通知把进程钉在前台。
 */
class DownloadForegroundService : Service() {
    private var isForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty()
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0
        val total = intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0
        val notification = buildNotification(title, progress, total)

        if (isForeground) {
            // 已经在前台，直接更新同 id 的通知即可
            getSystemService(NotificationManager::class.java)
                ?.notify(NOTIFICATION_ID, notification)
        } else {
            startForegroundCompat(notification)
            isForeground = true
        }
        return START_NOT_STICKY
    }

    // Android 15+ 的 dataSync 有 6 小时/24h 上限：超时由系统回调 onTimeout，
    // 其默认实现就是 stopSelf(startId)，所以这里不需要再覆写。

    override fun onDestroy() {
        isForeground = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(title: String, progress: Int, total: Int): Notification {
        ensureChannel()
        val percent = if (total > 0) (progress * 100L / total).toInt() else 0
        val text = if (total > 0) {
            "已下载 $percent%（${formatBytes(progress)} / ${formatBytes(total)}）"
        } else {
            "正在准备下载…"
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title.ifEmpty { "正在下载" })
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setContentIntent(contentIntent())

        if (total > 0) {
            builder.setProgress(100, percent, false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    private fun contentIntent(): PendingIntent? {
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        return PendingIntent.getActivity(this, 0, launch, flags)
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "下载进度",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "离线缓存的下载进度与状态"
            setShowBadge(false)
            enableVibration(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun formatBytes(bytes: Int): String {
        if (bytes < 1024) return "$bytes B"
        val kb = bytes / 1024.0
        if (kb < 1024) return String.format("%.1f KB", kb)
        val mb = kb / 1024.0
        if (mb < 1024) return String.format("%.1f MB", mb)
        return String.format("%.2f GB", mb / 1024.0)
    }

    companion object {
        const val CHANNEL = "piliplus/download_foreground"

        private const val CHANNEL_ID = "download_progress"
        private const val NOTIFICATION_ID = 0x1001
        private const val ACTION_START = "com.example.piliplus.action.DOWNLOAD_START"
        private const val ACTION_UPDATE = "com.example.piliplus.action.DOWNLOAD_UPDATE"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_PROGRESS = "progress"
        private const val EXTRA_TOTAL = "total"

        fun start(context: Context, title: String) {
            val intent = Intent(context, DownloadForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun update(context: Context, title: String, progress: Int, total: Int) {
            // 服务已在前台，直接投递一次更新
            val intent = Intent(context, DownloadForegroundService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_TOTAL, total)
            }
            runCatching { context.startService(intent) }
        }

        fun stop(context: Context) {
            // stopService 不受后台启动限制，onDestroy 里会一并摘掉通知
            context.stopService(Intent(context, DownloadForegroundService::class.java))
        }
    }
}
