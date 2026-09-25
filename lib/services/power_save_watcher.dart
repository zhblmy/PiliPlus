import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/android/display_mode_utils.dart';
import 'package:PiliPlus/utils/device_state.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// 低功耗 / 高温 / 画中画 降档调度（仅 Android 生效）—— 性能报告 MI-04 + PL-08。
///
/// 判定为「低功耗」的任一条件：
/// - 系统省电模式；
/// - 未充电且电量 < 20%；
/// - 温控等级 ≥ THERMAL_STATUS_MODERATE(2)。
///
/// 降档动作（进入时应用、恢复时还原）：
/// - 刷新率回 60Hz 档（[DisplayModeUtils]）；
/// - 临时清空 glsl-shaders —— Anime4K 超分是移动 GPU 上最重的一项，且**不落盘**
///   改动用户设置（见 `PlPlayerController.trimShadersForLowPower`）；
/// - 弹幕显示区域缩小、去掉描边（[DeviceState] 供 `DanmakuOptions` 读取）；
/// - 点播 / 直播缓冲下调一档（[DeviceState.bufferScale]，对之后新建的播放器生效）。
abstract final class PowerSaveWatcher {
  static const int _lowBatteryLevel = 20;
  static const int _thermalModerate = 2;
  static const Duration _pollInterval = Duration(minutes: 3);

  static final _LifecycleWatcher _lifecycle = _LifecycleWatcher();
  static Timer? _timer;
  static bool _inited = false;
  static bool _pip = false;
  static bool _firstEvaluate = true;

  static Future<void> init() async {
    if (!Platform.isAndroid || _inited) return;
    _inited = true;
    WidgetsBinding.instance.addObserver(_lifecycle);
    // 画中画进入/退出由原生回调（MainActivity.onPictureInPictureModeChanged）
    AndroidHelper$ToDart.onPipModeChanged = Runnable.implement(
      $Runnable(run: _onPipModeChanged),
    );
    // 插拔电源 / 充电状态变化时立即复评
    Battery().onBatteryStateChanged.listen((_) => _evaluate());
    _startTimer();
    await _evaluate();
    _firstEvaluate = false;
  }

  /// 省电模式与温控等级没有广播，只能低频轮询（仅在应用可见时）
  static void _startTimer() {
    _timer ??= Timer.periodic(_pollInterval, (_) => _evaluate());
  }

  static void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  static void _resume() {
    _startTimer();
    _evaluate();
  }

  static Future<void> _evaluate() async {
    final battery = Battery();
    var low = false;
    try {
      if (await battery.isInBatterySaveMode) {
        low = true;
      } else {
        final state = await battery.batteryState;
        final charging =
            state != BatteryState.discharging && state != BatteryState.unknown;
        if (!charging && await battery.batteryLevel < _lowBatteryLevel) {
          low = true;
        }
      }
    } catch (_) {}
    if (!low) {
      try {
        low = PiliAndroidHelper.thermalStatus() >= _thermalModerate;
      } catch (_) {}
    }
    _apply(low);
  }

  static void _apply(bool low) {
    if (DeviceState.isLowPower.value == low) return;
    DeviceState.isLowPower.value = low;
    DisplayModeUtils.setLowPower(low);
    final controller = PlPlayerController.instance;
    if (low) {
      controller?.trimShadersForLowPower();
      // 启动时就已经是省电模式的话不弹提示，避免每次冷启动都打扰
      if (!_firstEvaluate) {
        SmartDialog.showToast('低功耗降档：已降低刷新率、弹幕与画质特效');
      }
    } else if (controller != null && !_pip) {
      controller.restoreSuperResolution();
    }
  }

  static void _onPipModeChanged() {
    final pip = AndroidHelper.isPipMode;
    if (_pip == pip) return;
    _pip = pip;
    DisplayModeUtils.setPipMode(pip);
    final controller = PlPlayerController.instance;
    if (controller == null) return;
    if (pip) {
      // 小窗下超分收益极低、功耗不变 → 直接清空
      controller.trimShadersForLowPower();
    } else if (!DeviceState.isLowPower.value) {
      controller.restoreSuperResolution();
    }
  }
}

/// 只在应用可见时轮询：不可见时省电模式/温控状态变化不需要立刻响应，
/// 回到前台会立即复评一次（与性能报告「应用不可见即暂停」的原则一致）。
final class _LifecycleWatcher with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      PowerSaveWatcher._resume();
    } else {
      PowerSaveWatcher._stopTimer();
    }
  }
}
