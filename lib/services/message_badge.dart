import 'dart:io';

import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Android 消息通知：每个有未读的会话一条，展示发送者头像、会话名和消息内容。
///
/// 不发「有未读消息 / N 条未读消息」这类汇总通知；桌面角标数字由这些会话通知
/// 带出（启动器会把同一渠道里各条通知的数字相加），[Pref.enableMsgBadge] 决定
/// 发到带角标的渠道还是不带角标的渠道。非 Android、关闭开关、未授予通知权限或
/// 调用失败时静默跳过，不影响 App 内的未读角标逻辑。
abstract final class MessageBadge {
  static const _channel = MethodChannel('piliplus/message_badge');

  static String? _lastConvSig;

  /// 更新会话通知。
  ///
  /// [conversations] 为 `null` 表示本次不改动（保持已发布内容），空列表表示清空。
  /// 关闭「通知栏消息详情」后，即使调用方不传数据也要把已发布的会话通知撤掉。
  static void updateConversations(List<Map<String, Object?>>? conversations) {
    if (!Platform.isAndroid) return;
    final items = Pref.enableMsgDetailNotify
        ? conversations
        : const <Map<String, Object?>>[];
    // null = 本次不改动
    if (items == null) return;
    final badge = Pref.enableMsgBadge;
    final signature = _signatureOf(items, badge: badge);
    if (signature == _lastConvSig) return;
    _lastConvSig = signature;
    _update(items, badge).then((success) {
      // 失败就把「已发送」标记清掉，下一次重新发
      if (!success && _lastConvSig == signature) _lastConvSig = null;
    });
  }

  /// 退出登录 / 切换账号：会话通知（含桌面角标）全部清掉
  static void clearAll() => updateConversations(const []);

  /// 内容指纹：不能用 List/Map 的 hashCode（Dart 未重写，是身份哈希）。
  ///
  /// 刻意不含 `alert`：它只决定"这次要不要响"，不是内容变化；算进来会让每次
  /// 提醒之后又多一次静默重发。`badge` 要算进来：角标开关切换后要按新状态
  /// 重发一遍（带数字 ↔ 不带数字）。
  static String _signatureOf(
    List<Map<String, Object?>> conversations, {
    required bool badge,
  }) =>
      '${badge ? 1 : 0}\u0003'
      '${conversations.map((item) => '${item['key']}\u0001${item['name']}\u0001'
          '${item['avatarUrl']}\u0001${item['content']}\u0001'
          '${item['unread']}\u0001${item['muted']}\u0001'
          '${item['timestamp']}\u0001${item['avatar'] != null}').join('\u0002')}';

  @visibleForTesting
  static String signatureForTesting(
    List<Map<String, Object?>> conversations, {
    bool badge = true,
  }) => _signatureOf(conversations, badge: badge);

  static bool _askedPermission = false;

  /// 桌面角标默认开启，但 Android 13+ 仍需要运行时权限：
  /// 首次进入消息页时补一次申请，每个进程最多一次，拒绝后不再打扰。
  static Future<void> ensurePermission() async {
    if (!Platform.isAndroid ||
        _askedPermission ||
        !(Pref.enableMsgBadge || Pref.enableMsgDetailNotify)) {
      return;
    }
    _askedPermission = true;
    if (!await Permission.notification.isGranted) {
      await Permission.notification.request();
    }
  }

  static Future<bool> _update(
    List<Map<String, Object?>> conversations,
    bool badge,
  ) async {
    try {
      return await _channel.invokeMethod<bool>('setConversations', {
            'conversations': conversations,
            'badge': badge,
          }) ??
          false;
    } on MissingPluginException {
      // 未接入原生实现时忽略
      return false;
    } on PlatformException {
      // 通知权限被拒绝等：桌面角标失败不应影响未读逻辑
      return false;
    } catch (_) {
      return false;
    }
  }
}
