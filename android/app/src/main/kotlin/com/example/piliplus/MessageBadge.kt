package com.example.piliplus

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** Dart 侧传入的一条会话通知数据。 */
class ConversationNotice(
    val key: String,
    val name: String,
    val avatarUrl: String,
    val avatar: ByteArray?,
    val content: String,
    val unread: Int,
    val muted: Boolean,
    val timestamp: Long,
    val alert: Boolean,
)

/**
 * 消息通知：每个有未读的会话一条，展示发送者头像、会话名和消息内容。
 *
 * 不再发「有未读消息 / N 条未读消息」的汇总通知：桌面角标数字改由会话通知的
 * `setNumber` 带出（启动器会把同一渠道里各条通知的数字相加），没有会话通知时
 * 也就没有角标。`badge = false` 时改发到不带角标的渠道。
 *
 * 刻意不做通知分组：分组的 summary 一旦被系统折叠或渠道被限，子通知会跟着看不见，
 * 反而让「头像 + 会话名 + 内容」失效。每条会话通知独立展示。
 *
 * `conversations` 传 null 表示本次不改动，传空列表才是清空。
 */
object MessageBadge {
    private const val NOTICE_CHANNEL_ID = "message_conversations_v2"

    /**
     * 关闭「桌面未读角标」时改用这个渠道。
     *
     * `setShowBadge` 提交给系统后就不能再改（只能改名称/描述），所以「带不带角标」
     * 只能靠两个渠道区分；否则关掉开关后启动器仍会按通知条数显示角标。
     */
    private const val NOTICE_CHANNEL_NO_BADGE_ID = "message_conversations_v2_nobadge"
    private const val SESSION_ID = 0x2100
    private const val MAX_SESSIONS = 5
    private const val AVATAR_MAX_PX = 192
    private const val EXTRA_SESSION_KEY = "session_key"

    /** 汇总通知时代的渠道与 id：升级后清掉旧实现留下的通知和渠道 */
    private const val LEGACY_BADGE_CHANNEL_ID = "message_badge"
    private const val LEGACY_NOTICE_CHANNEL_ID = "message_conversations_v1"
    private const val LEGACY_SUMMARY_ID = 0x2001
    private var migrated = false

    private fun channelId(badge: Boolean) =
        if (badge) NOTICE_CHANNEL_ID else NOTICE_CHANNEL_NO_BADGE_ID

    /** 已发布的会话 key，用于清理已读/已删除会话的通知 */
    private val published = mutableSetOf<String>()

    /** 每条通知最近一次的内容指纹：内容没变就不再重复 notify（否则会重复提醒） */
    private val lastPosted = mutableMapOf<String, String>()

    private fun fingerprint(item: ConversationNotice, badge: Boolean): String =
        buildString {
            append(item.name).append('\u0001')
            append(item.content).append('\u0001')
            // 只有带数字时未读数才影响通知外观
            append(if (badge) item.unread else 0).append('\u0001')
            append(item.muted).append('\u0001')
            append(item.timestamp).append('\u0001')
            // 不含 alert：它只决定这次要不要响，不是内容变化
            append(item.avatar?.contentHashCode() ?: 0)
        }

    @SuppressLint("MissingPermission")
    fun update(
        context: Context,
        conversations: List<ConversationNotice>?,
        badge: Boolean,
    ): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
            ?: return false
        val compat = NotificationManagerCompat.from(context)
        migrateLegacy(manager, compat)

        // null = 本次不改动
        if (conversations == null) return true

        val next = LinkedHashMap<String, ConversationNotice>()
        for (item in conversations) {
            if (next.size >= MAX_SESSIONS) break
            next[item.key] = item
        }
        // 进程被系统回收后 published 是空的：先用系统里还在的通知补齐，
        // 否则「上次发布、这次已读」的会话会一直留在通知栏
        restorePublished(context)
        for (tag in published - next.keys) {
            compat.cancel(tag, SESSION_ID)
        }
        published.retainAll(next.keys)
        lastPosted.keys.retainAll(next.keys)
        // 撤销通知不需要通知权限
        if (next.isEmpty()) return true
        if (!compat.areNotificationsEnabled()) {
            // 权限关闭期间系统已经清掉了通知：指纹一并作废，重新授权后还能再发出来
            lastPosted.clear()
            return false
        }
        ensureChannels(manager, badge)
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(channelId(badge))?.importance ==
                NotificationManager.IMPORTANCE_NONE
        ) {
            // 用户在系统设置里关闭了当前渠道；重新开启后相同内容也要能补发
            lastPosted.clear()
            return false
        }

        var allPosted = true
        for (item in next.values) {
            val fp = fingerprint(item, badge)
            // 内容没变（含用户手动划掉的情况）就不再 notify，避免整批重复提醒
            if (lastPosted[item.key] == fp) continue
            val icon = decodeAvatar(item.avatar)
            val posted = runCatching {
                compat.notify(item.key, SESSION_ID, buildSession(context, item, icon, badge))
            }.isSuccess
            if (posted) {
                published += item.key
                lastPosted[item.key] = fp
            } else {
                lastPosted.remove(item.key)
                allPosted = false
            }
        }
        return allPosted
    }

    private fun migrateLegacy(manager: NotificationManager, compat: NotificationManagerCompat) {
        if (migrated) return
        migrated = true
        // 旧版那条「有未读消息 / N 条未读消息」的汇总通知，删渠道会连同通知一起撤掉
        runCatching { compat.cancel(LEGACY_SUMMARY_ID) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            runCatching {
                manager.deleteNotificationChannel(LEGACY_BADGE_CHANNEL_ID)
                manager.deleteNotificationChannel(LEGACY_NOTICE_CHANNEL_ID)
            }
        }
    }

    /** App 启动时调一次：即使这一轮没有通知要发，也要把旧版汇总通知清掉 */
    fun ensureMigrated(context: Context) {
        if (migrated) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        migrateLegacy(manager, NotificationManagerCompat.from(context))
    }

    private fun restorePublished(context: Context) {
        if (published.isNotEmpty()) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.activeNotifications
            .filter { it.id == SESSION_ID }
            .mapNotNull { it.tag }
            .forEach { published += it }
    }

    private fun buildSession(
        context: Context,
        item: ConversationNotice,
        avatar: Bitmap?,
        badge: Boolean,
    ): Notification {
        // alert=false 表示这条只需要更新内容，不要响（例如在别处读掉一条、只改了未读数）
        val silent = item.muted || !item.alert
        val builder = NotificationCompat.Builder(context, channelId(badge))
            .setSmallIcon(R.drawable.ic_notification_icon)
            .setContentTitle(item.name)
            .setContentText(item.content)
            .setStyle(NotificationCompat.BigTextStyle().bigText(item.content))
            .setWhen(if (item.timestamp > 0) item.timestamp else System.currentTimeMillis())
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            // 静默阶段禁止重复提醒；正式提醒时允许内容变化再次提醒
            .setOnlyAlertOnce(silent)
            .setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(
                if (item.muted) {
                    NotificationCompat.PRIORITY_LOW
                } else {
                    NotificationCompat.PRIORITY_DEFAULT
                },
            )
            .setContentIntent(contentIntent(context, item))
        // 桌面角标：同一渠道里各条通知的 setNumber 会被启动器相加
        if (badge) builder.setNumber(item.unread)
        if (avatar != null) builder.setLargeIcon(avatar)
        if (silent) builder.setSilent(true)
        return builder.build()
    }

    private fun contentIntent(
        context: Context,
        item: ConversationNotice,
    ): PendingIntent? {
        val launch = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_SESSION_KEY, item.key)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        // 固定 requestCode 会让后发布的会话覆盖前一条的 extras，
        // 导致点开任意一条都跳到同一个会话
        return PendingIntent.getActivity(context, item.key.hashCode(), launch, flags)
    }

    private fun decodeAvatar(bytes: ByteArray?): Bitmap? {
        if (bytes == null || bytes.isEmpty()) return null
        return runCatching {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }.getOrNull()?.let { bitmap ->
            val longest = maxOf(bitmap.width, bitmap.height)
            if (longest <= AVATAR_MAX_PX) {
                bitmap
            } else {
                val scale = AVATAR_MAX_PX.toFloat() / longest
                Bitmap.createScaledBitmap(
                    bitmap,
                    (bitmap.width * scale).toInt().coerceAtLeast(1),
                    (bitmap.height * scale).toInt().coerceAtLeast(1),
                    true,
                )
            }
        }
    }

    private fun ensureChannels(manager: NotificationManager, badge: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val id = channelId(badge)
        if (manager.getNotificationChannel(id) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                id,
                if (badge) "消息详情" else "消息详情（不显示桌面角标）",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = if (badge) {
                    "按会话显示发送者头像、会话名与消息内容；未读数字会汇总到桌面角标"
                } else {
                    "按会话显示发送者头像、会话名与消息内容；桌面图标上不显示未读数字"
                }
                setShowBadge(badge)
            },
        )
    }
}
