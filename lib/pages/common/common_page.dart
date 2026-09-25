import 'dart:async';

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/pages/home/controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:flutter/foundation.dart' show clampDouble;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract class CommonPageState<T extends StatefulWidget> extends State<T> {
  RxDouble? _barOffset;
  RxBool? _showTopBar;
  RxBool? _showBottomBar;
  final _mainController = Get.find<MainController>();

  bool get needsCorrection => false;

  /// 收尾补间定时器：滚动（含惯性）结束后把栏补完到端点，
  /// 否则抬手后栏会停在一半——看起来“卡在下面一点”。
  Timer? _settleTimer;

  /// 本次手势的累计位移：> 0 = 内容上滑（收起栏），< 0 = 内容下滑（展开栏）
  double _gestureDelta = 0.0;

  /// 本次手势是否带动过栏的位移（只有用户拖动才会置位）
  bool _pendingSettle = false;

  static const _settleDuration = 220;
  static const _settleStep = Duration(milliseconds: 16);

  @override
  void initState() {
    super.initState();
    _barOffset = _mainController.barOffset;
    _showBottomBar = _mainController.showBottomBar;
    try {
      _showTopBar = Get.find<HomeController>().showTopBar;
    } catch (_) {}
  }

  Widget onBuild(Widget child) {
    if (_barOffset != null) {
      return NotificationListener<ScrollNotification>(
        onNotification: onNotificationType2,
        child: child,
      );
    }
    if (_showTopBar != null || _showBottomBar != null) {
      return NotificationListener<UserScrollNotification>(
        onNotification: onNotificationType1,
        child: child,
      );
    }
    return child;
  }

  bool onNotificationType1(UserScrollNotification notification) {
    if (!_mainController.useBottomNav) return false;
    if (notification.metrics.axis == .horizontal) return false;
    switch (notification.direction) {
      case .forward:
        _showTopBar?.value = true;
        _showBottomBar?.value = true;
      case .reverse:
        _showTopBar?.value = false;
        _showBottomBar?.value = false;
      case _:
    }
    return false;
  }

  /// 记录本次位移：收尾补间靠累计方向判断该收起还是展开。
  /// 一旦又有滚动位移，说明手指/惯性重新接管，立即停掉收尾动画。
  void _trackOffset(double scrollDelta) {
    _gestureDelta += scrollDelta;
    _pendingSettle = true;
    _stopSettle();
  }

  void _updateOffset(double scrollDelta) {
    _trackOffset(scrollDelta);
    _barOffset!.value = clampDouble(
      _barOffset!.value + scrollDelta,
      0.0,
      Style.topBarHeight,
    );
  }

  void _stopSettle() {
    _settleTimer?.cancel();
    _settleTimer = null;
  }

  /// 滚动结束后把栏滑到底（完全收起 / 完全展开）：
  /// 拖动时依旧 1:1 跟随手指，抬手后补一段缓出动画，
  /// 这样惯性滑动、慢速拖动都不会把栏留在半路。
  void _settleBarOffset() {
    final barOffset = _barOffset;
    if (barOffset == null) return;
    final double from = barOffset.value;
    final double to;
    if (_gestureDelta > 0) {
      // 内容上滑 → 完全收起
      to = Style.topBarHeight;
    } else if (_gestureDelta < 0) {
      // 内容下滑 → 完全展开
      to = 0.0;
    } else {
      // 方向未知（位移被别的 ScrollEnd 清掉了）：就近收尾，总之别留在半路
      to = from < Style.topBarHeight / 2 ? 0.0 : Style.topBarHeight;
    }
    if (from == to) return;
    _stopSettle();
    final double delta = to - from;
    final stopwatch = Stopwatch()..start();
    // 上一次写入的值：barOffset 是所有页面共用的，中途被别人改过就让位
    double last = from;
    _settleTimer = Timer.periodic(_settleStep, (_) {
      final double elapsed = stopwatch.elapsedMilliseconds / _settleDuration;
      if (elapsed >= 1.0) {
        barOffset.value = to;
        _stopSettle();
        return;
      }
      if ((barOffset.value - last).abs() > 0.001) {
        // 别的页滚动 / 返回首页把 offset 归零 等等：不再抢这个值
        _stopSettle();
        return;
      }
      final double value = from + delta * Curves.easeOutCubic.transform(elapsed);
      barOffset.value = value;
      last = value;
    });
  }

  bool onNotificationType2(ScrollNotification notification) {
    if (!_mainController.useBottomNav) return false;

    final metrics = notification.metrics;
    if (metrics.axis == .horizontal) return false;

    if (notification is ScrollStartNotification) {
      // 手指按下：收尾动画立即让位给手指并重新累计方向。
      // 注意这里只认“手指拖动”（dragDetails != null），
      // 程序化滚动（animateTo/jumpTo）不该把补间打断在半路。
      if (notification.dragDetails != null) {
        _stopSettle();
        _gestureDelta = 0.0;
      }
      return false;
    }

    if (notification is ScrollEndNotification) {
      // 手指抬起、惯性滑动也停下之后才补完，避免停在一半
      if (_pendingSettle) {
        _pendingSettle = false;
        _settleBarOffset();
      }
      _gestureDelta = 0.0;
      return false;
    }

    if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails == null) return false;
      final pixel = metrics.pixels;
      final scrollDelta = notification.scrollDelta ?? 0;
      if (pixel < 0.0 && scrollDelta > 0) return false;
      if (needsCorrection) {
        _trackOffset(scrollDelta);
        final value = _barOffset!.value;
        final newValue = clampDouble(
          value + scrollDelta,
          0.0,
          Style.topBarHeight,
        );
        final offset = value - newValue;
        if (offset != 0) {
          _barOffset!.value = newValue;
          if (pixel < 0.0 && scrollDelta < 0.0 && value > 0.0) {
            return false;
          }
          Scrollable.of(notification.context!).position.correctBy(offset);
        }
      } else {
        _updateOffset(scrollDelta);
      }
      return false;
    }

    if (notification is OverscrollNotification) {
      _updateOffset(notification.overscroll);
      return false;
    }

    return false;
  }

  @override
  void dispose() {
    _stopSettle();
    _barOffset = null;
    _showTopBar = null;
    _showBottomBar = null;
    super.dispose();
  }
}
