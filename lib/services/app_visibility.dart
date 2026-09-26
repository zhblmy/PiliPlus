import 'dart:io' show Platform;

import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/widgets.dart'
    show
        AppLifecycleState,
        VoidCallback,
        WidgetsBinding,
        WidgetsBindingObserver;

/// 应用可见性统一门控（性能报告 PF-03）—— **仅 Android 生效**。
///
/// 目的：把「应用不可见即暂停」的零散生命周期判断收口到一处，避免每个功能各写一份
/// `WidgetsBindingObserver`。需要该行为的功能在创建时 [register]、销毁时 [unregister]；
/// 页面已不在前台但仍存活（被 push 走、切 Tab）时用 [setActive] 临时摘除门控。
///
/// 可见性口径与播放器保持一致：`resumed` / `inactive` 都算「可见」（画中画、权限弹窗、
/// 下拉通知栏期间不打断后台播放），只有真正进入后台（`paused` / `hidden` / `detached`）
/// 才触发暂停。
///
/// 非 Android 平台不注册观察者，门控恒不触发 —— 即其它平台行为与改动前完全一致。
abstract final class AppVisibility {
  static bool get isVisible => _visible;
  static bool _visible = true;
  static bool _inited = false;

  static final Map<Object, _Gate> _gates = {};
  static final _observer = _LifecycleObserver();

  static void ensureInitialized() {
    if (_inited) return;
    _inited = true;
    if (!Platform.isAndroid) return;
    WidgetsBinding.instance.addObserver(_observer);
  }

  /// 登记门控。同一个 [key] 重复登记会覆盖（不会叠加、不会泄漏）。
  static void register(
    Object key, {
    required VoidCallback onPause,
    required VoidCallback onResume,
  }) {
    ensureInitialized();
    _gates[key] = _Gate(onPause, onResume)..paused = !_visible;
  }

  static void unregister(Object key) {
    _gates.remove(key);
  }

  /// 切换门控是否生效。置 false 时清掉「已暂停」状态，避免回到应用前台时去恢复
  /// 一个用户已经离开的页面（例如「人在别的页面、直播却重新连上」）。
  static void setActive(Object key, bool active) {
    final gate = _gates[key];
    if (gate == null || gate.active == active) return;
    gate.active = active;
    if (!active) gate.paused = false;
  }

  static void _onStateChanged(AppLifecycleState state) {
    final visible =
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached;
    if (visible == _visible) return;
    _visible = visible;
    // 回调里可能 register/unregister，先取快照再遍历
    for (final gate in _gates.values.toList(growable: false)) {
      if (!gate.active) continue;
      if (visible) {
        if (!gate.paused) continue;
        gate.paused = false;
        _safe(gate.onResume);
      } else {
        if (gate.paused) continue;
        gate.paused = true;
        _safe(gate.onPause);
      }
    }
  }

  /// 单个门控抛异常不能影响后面的门控（否则会漏掉整批暂停逻辑）
  static void _safe(VoidCallback callback) {
    try {
      callback();
    } catch (e) {
      Utils.reportError(e);
    }
  }
}

final class _Gate {
  _Gate(this.onPause, this.onResume);

  final VoidCallback onPause;
  final VoidCallback onResume;
  bool active = true;
  bool paused = false;
}

final class _LifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      AppVisibility._onStateChanged(state);
}
