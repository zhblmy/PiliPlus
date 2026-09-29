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

  /// 本页顶栏是否为「页面级悬浮层 + 滚动驱动的 pinned sliver 让位」。
  ///
  /// 是则为 false：不再写共享的 [MainController.barOffset]（顶栏收起由滚动位置
  /// 直接驱动），也不需要 correctBy 偷滚动（空间由 pinned sliver 原生让出）。
  bool get useBarOffset => true;

  /// pinned 顶栏的收起量程（0 = 本页没有这种顶栏）：用来做「抬手补到端点」。
  double get pinnedHeaderExtent => 0.0;

  /// 上面那个顶栏对应的滚动控制器（当前可见 Tab 的那个）
  ScrollController? get pinnedHeaderScrollController => null;

  /// 本次手势的累计方向：true = 内容上滑（收起栏）、false = 下滑（展开栏）、
  /// null = 本次手势还没产生过位移（ScrollStartNotification 会清空）。
  /// 三态而不是 bool：不能拿上一次手势的方向去给这一次补间。
  bool? _pinnedScrollUp;
  bool _pinnedSettling = false;

  /// 这条滚动通知是哪个列表发出来的。
  ///
  /// **不要**用 `identical(notification.metrics, position)` 判断：`ScrollPosition`
  /// 派发通知时传的是 `copyWith()` 出来的 `ScrollMetrics` 快照，永远不等于 position
  /// 本身（拿它做白名单会把所有通知都过滤掉）。`notification.context` 是派发者里
  /// GestureDetector 的 context、位置在 Scrollable 内部，所以能拿回那个 Scrollable。
  ScrollPosition? dispatchPositionOf(ScrollNotification notification) {
    final ctx = notification.context;
    return ctx == null ? null : Scrollable.maybeOf(ctx)?.position;
  }

  /// 抬手/惯性结束后的收尾补间：停在收起区间（0 < pixels < 量程）时补到端点，
  /// 否则搜索行/面板会停在半截。
  ///
  /// 两个方向都补（收起到端点 / 展开回 0）：这里让位是**真滚动**，补回 0 会让列表回到
  /// 顶部，但只在 pixels 小于量程（一屏顶部那 50～80 px）时才补，观感就是「松手后归位」。
  bool onPinnedHeaderNotification(ScrollNotification notification) {
    if (notification.metrics.axis != .vertical) return false;
    final controller = pinnedHeaderScrollController;
    if (controller == null || !controller.hasClients) return false;
    final positions = controller.positions;
    final dispatcher = dispatchPositionOf(notification);
    if (positions.length != 1 ||
        dispatcher == null ||
        !identical(dispatcher, positions.first)) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      // 新手势：方向重新判定
      _pinnedScrollUp = null;
      return false;
    }
    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta;
      if (delta != null && delta != 0) _pinnedScrollUp = delta > 0;
      return false;
    }
    if (notification is! ScrollEndNotification || _pinnedSettling) return false;
    final bool? up = _pinnedScrollUp;
    // 这次手势没滚动过（点一下又抬手）：方向未知就不补，免得往反方向怼
    if (up == null) return false;
    final double pixels = notification.metrics.pixels;
    final double target;
    if (up) {
      final double extent = pinnedHeaderExtent;
      if (pixels <= 0 || pixels >= extent) return false;
      // 已经滚到底、补也补不动了：否则「列表本身就短于量程」时会
      // animateTo → ScrollEnd → 再 animateTo 无限空转（每 220ms 起一次动画）
      if (pixels >= notification.metrics.maxScrollExtent) return false;
      target = extent;
    } else {
      // 下滑：回到展开态
      if (pixels <= 0) return false;
      target = 0.0;
    }
    _pinnedSettling = true;
    // 通知回调里不能直接改滚动活动，下一帧再动
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_pinnedSettling) return;
      if (!controller.hasClients) {
        _pinnedSettling = false;
        return;
      }
      controller
          .animateTo(
            target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() => _pinnedSettling = false);
    });
    return false;
  }

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
    if (pinnedHeaderExtent > 0) {
      child = NotificationListener<ScrollNotification>(
        onNotification: onPinnedHeaderNotification,
        child: child,
      );
    }
    if (useBarOffset && _barOffset != null) {
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
      final double value =
          from + delta * Curves.easeOutCubic.transform(elapsed);
      barOffset.value = value;
      last = value;
    });
  }

  bool onNotificationType2(ScrollNotification notification) {
    if (!_mainController.useBottomNav) return false;

    final metrics = notification.metrics;
    if (metrics.axis == .horizontal) return false;

    if (notification is UserScrollNotification) {
      // 底栏是两态：只要滚动方向变了就一次性收起/弹出（不跟位移），
      // 与 barOffset 的连续补间互不干扰。
      onNotificationType1(notification);
      return false;
    }

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
