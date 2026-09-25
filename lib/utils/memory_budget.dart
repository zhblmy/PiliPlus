import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver;

/// Android 17 起系统会按设备物理内存给应用设内存上限（MemLimiter），超限时进程
/// 会被直接回收，`ApplicationExitInfo` 里表现为 `REASON_OTHER` +
/// 描述含 `MemoryLimiter:AnonSwap`。用户感知就是「用着用着突然回到桌面」。
///
/// 这里按设备实际内存给「图片内存缓存 / 解码缓冲」定预算，把「被杀」变成「提前降级」：
/// - 低内存设备（或 < 4 GiB）：图片缓存 64 MiB、解码缓冲减半；
/// - 8 GiB 及以上：图片缓存放宽到 192 MiB（大图瀑布流更流畅）；
/// - 其它：128 MiB。
///
/// **只对 Android 生效**：其它平台不读取设备信息，[bufferScale] 恒为 1.0，
/// Flutter / 播放器行为与改动前完全一致。
abstract final class MemoryBudget {
  static const int _unknown = 0;

  static int _totalRamMb = _unknown;
  static bool _lowRam = false;
  static bool _ready = false;

  /// 是否出现过系统内存压力（本进程内锁定，见 [onMemoryPressure]）
  static bool _pressure = false;
  static DateTime? _lastPressureClear;

  static bool get isUnderPressure => _pressure;

  /// 设备物理内存（MB），未知时为 0
  static int get totalRamMb => _totalRamMb;

  static bool get isLowRamDevice => _lowRam;

  /// 是否已拿到设备内存信息（非 Android 平台恒为 false）
  static bool get isReady => _ready;

  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      _totalRamMb = info.physicalRamSize;
      _lowRam = info.isLowRamDevice;
    } catch (_) {
      _totalRamMb = _unknown;
      _lowRam = false;
    }
    _ready = true;
    // 这一步在启动路径上，任何意外都不应让 App 起不来
    try {
      _applyImageCacheLimit();
    } catch (_) {}
    // MI-16：监听系统内存压力，主动腾内存（澎湃 OS 的内存回收比 AOSP 激进）
    WidgetsBinding.instance.addObserver(_MemoryPressureObserver());
  }

  /// 图片内存缓存预算（字节）
  static int get imageCacheBytes {
    if (!_ready || _totalRamMb <= 0) return 128 << 20;
    if (_lowRam || _totalRamMb < 4096) return 64 << 20;
    if (_totalRamMb >= 8192) return 192 << 20;
    return 128 << 20;
  }

  /// 图片内存缓存条目上限，按「平均一张缩略图约占 256 KiB」估算
  static int get imageCacheCount => imageCacheBytes >> 18;

  /// 解码缓冲系数：内存紧张的设备减半，避免与图片缓存、libmpv 内部缓存争内存。
  /// 非 Android / 未初始化时恒为 1.0（不影响原有缓冲设置）。
  static double get bufferScale {
    if (!_ready) return 1.0;
    // 出现过内存压力后本进程保持保守（见 [onMemoryPressure]）
    if (_pressure) return 0.5;
    return _lowRam || (_totalRamMb > 0 && _totalRamMb < 4096) ? 0.5 : 1.0;
  }

  /// 系统内存压力（Flutter 侧 `didHaveMemoryPressure`）—— MI-16。
  ///
  /// 澎湃 OS 的内存回收比 AOSP 激进，这里主动腾内存，把「被系统冻结/杀掉」变成
  /// 「先降级」：清空图片缓存（只清缓存、不动正在显示的图，避免闪烁），并把解码
  /// 缓冲预算再降一档（对之后新建的播放器生效）。带 30s 冷却，避免频繁触发。
  static void onMemoryPressure() {
    _pressure = true;
    final now = DateTime.now();
    if (_lastPressureClear != null &&
        now.difference(_lastPressureClear!) < const Duration(seconds: 30)) {
      return;
    }
    _lastPressureClear = now;
    try {
      PaintingBinding.instance.imageCache.clear();
    } catch (_) {}
  }

  static void _applyImageCacheLimit() {
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = imageCacheBytes
      ..maximumSize = imageCacheCount;
  }
}

/// 只关心内存压力的观察者（仅 Android 注册）
final class _MemoryPressureObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() => MemoryBudget.onMemoryPressure();
}
