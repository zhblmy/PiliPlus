import 'dart:io';

import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart';

/// Android 桌面角标：用一条低优先级通知的 setNumber 让启动器显示未读数。
///
/// 非 Android、关闭开关、未授予通知权限或调用失败时静默跳过，
/// 不影响 App 内的未读角标逻辑。
abstract final class MessageBadge {
  static const _channel = MethodChannel('piliplus/message_badge');

  static int? _lastCount;
  static int _updateVersion = 0;

  static void update(int count) {
    if (!Platform.isAndroid) return;
    final target = Pref.enableMsgBadge && count > 0 ? count : 0;
    // 轮询会反复带回同一个未读数，重复调用只会白白跨一次平台通道
    if (_lastCount == target) return;
    _lastCount = target;
    final version = ++_updateVersion;
    _update(target).then((success) {
      if (!success && version == _updateVersion) {
        _lastCount = null;
      }
    });
  }

  /// 通知被用户滑掉后，回前台时按当前未读数重建
  static void reset() {
    _lastCount = null;
    _updateVersion++;
  }

  static bool _askedPermission = false;

  /// 桌面角标默认开启，但 Android 13+ 仍需要运行时权限：
  /// 首次进入消息页时补一次申请，每个进程最多一次，拒绝后不再打扰。
  static Future<void> ensurePermission() async {
    if (!Platform.isAndroid || _askedPermission || !Pref.enableMsgBadge) {
      return;
    }
    _askedPermission = true;
    if (await Permission.notification.isGranted) return;
    await Permission.notification.request();
  }

  static Future<bool> _update(int count) async {
    try {
      return await _channel.invokeMethod<bool>(
            'setCount',
            {'count': count},
          ) ??
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
