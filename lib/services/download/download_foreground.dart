import 'dart:io' show Platform;

import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;

/// 下载期间的 Android `dataSync` 前台服务。
///
/// 没有前台服务时，澎湃 OS 等系统的后台冻结会直接把纯 Dart 的下载任务掐断；
/// 原生侧 [DownloadForegroundService] 负责常驻通知，这里只做转发与节流。
abstract final class DownloadForeground {
  static const _channel = MethodChannel('piliplus/download_foreground');

  static bool _running = false;
  static int _lastUpdateMs = 0;
  static int _lastStartMs = 0;
  static bool _notificationRequested = false;

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// 是否已经成功拉起前台服务（下载中可用于判断要不要重试）
  static bool get isRunning => _running;

  /// 幂等；失败后 5 秒内不重试，避免进度回调把失败的拉起刷爆
  static Future<void> start(String title) async {
    if (!_supported || _running) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastStartMs < 5000) return;
    _lastStartMs = now;
    // 等 start 落地再刷进度，避免 update 抢在 start 前面把服务以「更新」的名义创建出来
    _lastUpdateMs = now;
    _running = true;
    _requestNotificationPermission();
    try {
      final ok = await _channel.invokeMethod<bool>('start', {'title': title});
      if (ok == false) _running = false;
    } catch (_) {
      _running = false;
    }
  }

  /// 每秒最多刷新一次，避免高频进度回调刷通知
  static Future<void> update(String title, int progress, int total) async {
    if (!_supported || !_running) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastUpdateMs < 1000) return;
    _lastUpdateMs = now;
    try {
      await _channel.invokeMethod('update', {
        'title': title,
        'progress': progress,
        'total': total,
      });
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!_supported || !_running) return;
    _running = false;
    _lastUpdateMs = 0;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  /// Android 13+ 没有通知权限时前台服务通知不会显示，只在任务管理器里可见
  static void _requestNotificationPermission() {
    if (_notificationRequested) return;
    _notificationRequested = true;
    Permission.notification.request().ignore();
  }
}
