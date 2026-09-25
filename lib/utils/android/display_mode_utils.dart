import 'dart:async' show Timer;
import 'dart:io' show Platform;

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_displaymode/flutter_displaymode.dart';

/// 场景化刷新率（仅 Android 生效）—— 性能报告 MI-02。
///
/// LTPO 面板只有在应用"不要求高刷"时才能降频，而**播放视频**（B 站内容绝大多数
/// ≤ 60fps）与**低功耗 / 温控降档 / 画中画**都不需要 120Hz。这里的做法是：
/// 默认不主动提升刷新率（未设置档位时保持 [DisplayMode.auto]），只在上述场景临时
/// 降到 60Hz 档，退出后恢复用户档位 —— 普通列表浏览完全不受影响。
abstract final class DisplayModeUtils {
  /// 内容帧率高于该值时不降档（高帧率内容保留高刷收益）
  static const double highFpsThreshold = 45;

  static List<DisplayMode> _supported = const [];
  static DisplayMode? _userMode;
  static DisplayMode? _lowMode;
  static DisplayMode? _applied;
  static bool _ready = false;
  static bool _lowPower = false;
  static bool _videoScene = false;
  static bool _pip = false;
  static bool _suspended = false;
  static bool _overridden = false;
  static Timer? _verifyTimer;

  static bool get isReady => _ready;

  /// 我们请求的低刷新率是否被系统忽略（MI-14）。
  ///
  /// 澎湃 OS 的「设置 → 显示 → 屏幕刷新率 → 自定义」可以按应用指定刷新率，
  /// 此时系统会忽略应用请求 —— 供兼容性检查页展示与引导用户改正。
  static bool get systemOverridden => _overridden;

  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    try {
      _supported = await FlutterDisplayMode.supported;
      final storageDisplay = GStorage.setting.get(SettingBoxKey.displayMode);
      if (storageDisplay is String) {
        _userMode = _supported.firstWhereOrNull(
          (e) => e.toString() == storageDisplay,
        );
      }
      _lowMode = _pickLowMode();
      _ready = true;
      await _apply();
    } catch (_) {
      // 部分 ROM 取不到模式列表 → 整体降级为「不干预」
      _ready = false;
    }
  }

  /// 用户在设置页切换档位后调用
  static Future<void> setUserMode(DisplayMode? mode) async {
    _userMode = mode;
    _lowMode = _pickLowMode();
    _applied = null;
    await _apply();
  }

  static Future<void> setLowPower(bool active) async {
    if (_lowPower == active) return;
    _lowPower = active;
    await _apply();
  }

  /// 视频场景（播放 / 暂停 / 离开播放页）。[contentFps] 为内容帧率，未知传 null。
  static Future<void> setVideoScene(bool active, {double? contentFps}) async {
    final next =
        active && (contentFps == null || contentFps <= highFpsThreshold);
    if (_videoScene == next) return;
    _videoScene = next;
    await _apply();
  }

  /// 画中画场景（PL-08）：小窗下同样没有高刷收益
  static Future<void> setPipMode(bool active) async {
    if (_pip == active) return;
    _pip = active;
    await _apply();
  }

  /// 「屏幕帧率设置」页打开期间暂停场景降档：
  /// 否则页面会把**降档后的档位**当成用户档位写回设置（用户选择被污染）。
  static Future<void> suspendForUserPick(bool suspend) async {
    if (_suspended == suspend) return;
    _suspended = suspend;
    _applied = null;
    await _apply();
  }

  static bool get _needLow => !_suspended && (_lowPower || _videoScene || _pip);

  static Future<void> _apply() async {
    if (!_ready) return;
    final desired = Pref.limitDisplayMode && _needLow && _lowMode != null
        ? _lowMode!
        : (_userMode ?? DisplayMode.auto);
    if (_applied == desired) return;
    _applied = desired;
    try {
      await FlutterDisplayMode.setPreferredMode(desired);
      // 只有「恢复到用户档位/aoot」这种请求不参与校验，否则会把刚检测到的
      // 「被系统覆盖」在离开播放页时又被清掉（告警刚出现就消失）。
      _verifyApplied(desired, expectLow: identical(desired, _lowMode));
    } catch (_) {
      _applied = null;
    }
  }

  /// MI-14：校验「请求的低档」是否真的生效。
  ///
  /// 只在 [expectLow] 为真（即本次确实是向系统要低刷新率）时判定，避免把系统
  /// 自身的动态调节误判为「被覆盖」；延迟检查是因为模式切换生效需要几百毫秒。
  static void _verifyApplied(DisplayMode expected, {required bool expectLow}) {
    if (!expectLow) return;
    _verifyTimer?.cancel();
    _verifyTimer = Timer(const Duration(milliseconds: 1200), () async {
      try {
        final active = await FlutterDisplayMode.active;
        _overridden = active.refreshRate > expected.refreshRate + 1;
        if (_overridden && kDebugMode) {
          debugPrint('显示模式被系统覆盖: active=$active expected=$expected');
        }
      } catch (_) {}
    });
  }

  /// 低功耗档位优先取「与用户档位同分辨率的 60Hz」，
  /// 避免降档时顺带改变分辨率（分辨率变化在部分 ROM 上会闪一下）。
  static DisplayMode? _pickLowMode() {
    if (_supported.isEmpty) return null;
    final ref =
        _userMode ??
        _supported.reduce(
          (a, b) => (b.width * b.height) > (a.width * a.height) ? b : a,
        );
    final sameRes = _supported
        .where((e) => e.width == ref.width && e.height == ref.height)
        .toList();
    final pool = sameRes.isEmpty ? _supported : sameRes;
    DisplayMode? best;
    for (final e in pool) {
      if (e.refreshRate <= 60 &&
          (best == null || e.refreshRate > best.refreshRate)) {
        best = e;
      }
    }
    return best;
  }
}
