package com.example.piliplus

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * 消息未读角标。
 *
 * Android 没有通用的「只改图标数字」接口：各家启动器（含澎湃 OS）都从活跃通知的
 * number / 数量推导角标，所以这里维护一条低打扰的消息摘要通知，计数归零时取消。
 * 与下载通知（setShowBadge(false)）、音频通知分开渠道，避免互相干扰。
 */
object MessageBadge {
    private const val CHANNEL_ID = "message_badge"
    private const val NOTIFICATION_ID = 0x2001

    @SuppressLint("MissingPermission")
    fun update(context: Context, count: Int): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
            ?: return false
        val compat = NotificationManagerCompat.from(context)
        if (count <= 0) {
            // 撤销已发通知不需要通知权限
            compat.cancel(NOTIFICATION_ID)
            return true
        }
        // 没有通知权限时桌面也不会显示角标，这里直接跳过，不打断调用方
        if (!compat.areNotificationsEnabled()) return false

        ensureChannel(manager)
        val text = if (count > 99) "99+ 条未读消息" else "$count 条未读消息"
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_icon)
            .setContentTitle("有未读消息")
            .setContentText(text)
            .setNumber(count)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            // 点击后不自动消失：否则点击进入 App 时角标会跟着消失，而未读数并没有变
            .setAutoCancel(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setContentIntent(contentIntent(context))
            .build()

        return runCatching { compat.notify(NOTIFICATION_ID, notification) }.isSuccess
    }

    private fun contentIntent(context: Context): PendingIntent? {
        val launch = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        return PendingIntent.getActivity(context, 1, launch, flags)
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "消息提醒",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "在桌面图标上显示未读消息数"
            setShowBadge(true)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }
}
