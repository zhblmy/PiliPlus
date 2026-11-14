import 'dart:io';

import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:flutter/services.dart';

/// Android 消息通知的后台轮询宿主（`remoteMessaging` 前台服务）。
///
/// 没有前台服务时，App 退到后台会被系统冻结，纯 Dart 的定时轮询不会继续；
/// 原生侧 `MessageNotifyService` 只负责常驻通知与保活，轮询仍在 Dart 侧完成。
abstract final class MessageNotifyForeground {
  static const _channel = MethodChannel('piliplus/message_notify_foreground');

  static bool _running = false;
  static int _lastStartMs = 0;

  static bool get isRunning => _running;

  /// 幂等；失败后 5 秒内不重试，避免每轮轮询都重复唤起
  static Future<bool> start() async {
    if (!Platform.isAndroid) return false;
    if (_running) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastStartMs < 5000) return false;
    // 权限申请交给设置页，后台静默启动时不弹窗
    if (!await Permission.notification.isGranted) return false;
    _lastStartMs = now;
    try {
      _running = await _channel.invokeMethod<bool>('start') ?? false;
    } catch (_) {
      _running = false;
    }
    return _running;
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    _running = false;
    // 允许「退后台 → 立刻回前台 → 再退后台」时立刻重新拉起，不被 5 秒退避挡住
    _lastStartMs = 0;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {
      // 服务未启动或原生未接入时忽略
    }
  }
}
