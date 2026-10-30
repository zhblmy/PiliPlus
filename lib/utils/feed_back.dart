import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart' show HapticFeedback;

bool enableFeedback = Pref.feedBackEnable;

/// 触感反馈（系统触感）。
///
/// 按 Android 引擎的实际映射：lightImpact → VIRTUAL_KEY（很轻）、
/// mediumImpact → KEYBOARD_TAP（也很轻）、heavyImpact → CONTEXT_CLICK（系统长按 /
/// 上下文菜单那种“实”的手感）、selectionClick → CLOCK_TICK（最轻）。
/// 以前用 lightImpact，在澎湃 OS 等设备上几乎感觉不到，所以统一改用 heavyImpact；
/// 强度仍由系统的“触感反馈”设置决定。
void feedBack() {
  if (enableFeedback) {
    HapticFeedback.heavyImpact();
  }
}
