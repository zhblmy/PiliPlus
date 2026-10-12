import 'dart:io' show Platform;

import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart' show HapticFeedback;

bool enableFeedback = Pref.feedBackEnable;

/// 触感强度档位：(振动时长 ms, 振幅 0~255)
const List<(int, int)> kVibrateLevels = [
  (12, 120),
  (18, 190),
  (26, 255),
];

/// [kVibrateLevels] 的档位名（设置页用）
const List<String> kVibrateLevelNames = ['轻', '中', '强'];

/// 触感反馈。
///
/// Android 上**不**用 [HapticFeedback]：它只能选系统预设档位（lightImpact 对应
/// `HapticFeedbackConstants.CLOCK_TICK`），在澎湃 OS 等设备上非常轻、几乎感觉不到，
/// 强度也不可调。改为直接驱动原生振动器（[PiliAndroidHelper.vibrate]），
/// 强度由「其它设置 → 震动强度」决定；其余平台继续用系统触感。
void feedBack() {
  if (enableFeedback) {
    vibrateNow();
  }
}

/// 按当前档位震一下，**不受**「震动反馈」开关影响（设置页调强度时试手感用）。
void vibrateNow() {
  if (Platform.isAndroid) {
    final (ms, amplitude) =
        kVibrateLevels[Pref.vibrateStrength.clamp(
          0,
          kVibrateLevels.length - 1,
        )];
    try {
      PiliAndroidHelper.vibrate(ms, amplitude);
    } catch (_) {
      // 理论上不会走到（Java 侧自己 try/catch 了）：万一 JNI 查找/ROM 限制抛异常，
      // 退回系统触感即可，触感反馈不该把点击这种主流程带崩。
      HapticFeedback.lightImpact();
    }
  } else {
    HapticFeedback.lightImpact();
  }
}
