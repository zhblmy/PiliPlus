import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/logger.dart';
import 'package:catcher_2/catcher_2.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

class JsonFileHandler extends ReportHandler {
  final bool enableDeviceParameters;
  final bool enableApplicationParameters;
  final bool enableStackTrace;
  final bool enableCustomParameters;
  final bool printLogs;
  final bool handleWhenRejected;

  /// 单个日志文件大小上限，超过后清空重写（原实现文件无上限、无轮转）
  static const int _maxFileSize = 2 << 20; // 2 MiB

  /// 批量 flush 间隔：原实现每条日志一次 fsync，会持续唤醒存储控制器
  static const Duration _flushInterval = Duration(seconds: 5);

  static Timer? _flushTimer;
  static bool _dirty = false;
  static bool _broken = false;

  static Future<RandomAccessFile> _future = LoggerUtils.getLogsPath()
      .then((file) => file.open(mode: FileMode.writeOnlyAppend))
      .then((raf) => raf.writeFrom(const []))
      .then(_flushNow);

  JsonFileHandler._({
    this.enableDeviceParameters = true,
    this.enableApplicationParameters = true,
    this.enableStackTrace = true,
    this.enableCustomParameters = true,
    this.printLogs = false,
    this.handleWhenRejected = false,
  });

  static Future<JsonFileHandler?> init({
    bool enableDeviceParameters = true,
    bool enableApplicationParameters = true,
    bool enableStackTrace = true,
    bool enableCustomParameters = true,
    bool printLogs = false,
    bool handleWhenRejected = false,
  }) async {
    try {
      await _future;
      return JsonFileHandler._(
        enableDeviceParameters: enableDeviceParameters,
        enableApplicationParameters: enableApplicationParameters,
        enableStackTrace: enableStackTrace,
        enableCustomParameters: enableCustomParameters,
        printLogs: printLogs,
        handleWhenRejected: handleWhenRejected,
      );
    } catch (e, s) {
      logger.e('Init log file', error: e, stackTrace: s);
      return null;
    }
  }

  static Future<RandomAccessFile> _flushNow(RandomAccessFile raf) async {
    try {
      return await raf.flush();
    } catch (e) {
      // flush 失败（磁盘满/文件被删）不该打断写入链，调用方也无需感知
      if (kDebugMode) debugPrint('flush log file failed: $e');
      return raf;
    }
  }

  /// 追加写入：不再每条都 fsync，改为定时批量 flush，并在超过上限时重置文件
  static Future<RandomAccessFile> add(
    Future<RandomAccessFile> Function(RandomAccessFile) onValue,
  ) {
    _dirty = true;
    _scheduleFlush();
    // 旁听写入结果，记录链是否已损坏（供定时 flush 判断），但不吞掉异常
    final Future<RandomAccessFile> result = _future
        .then(_rotateIfNeeded)
        .then(onValue)
      ..then(
        (_) {},
        onError: (Object _) {
          _broken = true;
        },
      );
    return _future = result;
  }

  static void _scheduleFlush() {
    _flushTimer ??= Timer(_flushInterval, () {
      _flushTimer = null;
      if (!_dirty) return;
      _dirty = false;
      // 这条链没有人 await，一旦链上已有异常就会产生未处理的异步异常，先跳过
      if (_broken) return;
      _future = _future.then(_flushNow);
    });
  }

  /// 追加模式下写入位置即文件长度，超过上限时清空，避免日志无限增长
  static Future<RandomAccessFile> _rotateIfNeeded(RandomAccessFile raf) async {
    if (raf.positionSync() > _maxFileSize) {
      await raf.setPosition(0);
      await raf.truncate(0);
      await raf.setPosition(0);
    }
    return raf;
  }

  @override
  Future<bool> handle(Report report) async {
    try {
      await _processReport(report);
      return true;
    } catch (exc, stackTrace) {
      logger.e(
        'Write Json Exception occurred',
        error: exc,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> _processReport(Report report) {
    if (printLogs) {
      logger.d('Writing report to file');
    }
    final json = report.toJson(
      enableDeviceParameters: enableDeviceParameters,
      enableApplicationParameters: enableApplicationParameters,
      enableStackTrace: enableStackTrace,
      enableCustomParameters: enableCustomParameters,
    );
    return add((raf) => raf.writeString('${jsonEncode(json)}\n'));
  }
}
