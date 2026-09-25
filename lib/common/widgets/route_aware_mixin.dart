import 'dart:async' show Timer;

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_navigation/src/extension_navigation.dart';
import 'package:get/get_navigation/src/routes/default_route.dart'
    show GetPageRoute;

final routeObserver = RouteObserver<GetPageRoute>();

mixin RouteAwareMixin<T extends StatefulWidget> on State<T>, RouteAware {
  /// 动画被 TickerMode 静音（返回后立刻切后台 / 熄屏）时的兜底时长。
  /// 正常路由转场 ≤ 500ms。
  static const _fallbackDelay = Duration(milliseconds: 700);

  @override
  void initState() {
    super.initState();
    routeObserver.subscribe(this, Get.routing.route as GetPageRoute);
  }

  /// 把重活推到「本页相关的转场动画播完」之后再执行（并且还会再顺延一帧）。
  ///
  /// 为什么需要：Android 上 `Transition.native` 走 Zoom 缩放 + 快照
  /// （`_ZoomTransitionBase`），转场**结束那一帧**会把 `allowSnapshotting`
  /// 置 false，于是 `SnapshotWidget` 丢掉快照、整页在这一帧首次实时绘制 ——
  /// 体感就是「动画收尾卡一下」。而 `didPopNext` / `didPushNext` 是 Navigator
  /// 在**转场开始**时回调的：如果在里面立刻发网络请求、init 播放器、恢复弹幕，
  /// 就正好和转场收尾那一帧叠在一起，变成一次更长的掉帧。
  ///
  /// 用法：
  /// ```dart
  /// @override
  /// void didPopNext() {
  ///   addObserverMobile(this);
  ///   runAfterRouteAnimation(resumePlayback);
  ///   super.didPopNext();
  /// }
  /// ```
  void runAfterRouteAnimation(VoidCallback action) {
    final route = ModalRoute.of(context);
    final animations = <Animation<double>>[
      ?route?.animation,
      ?route?.secondaryAnimation,
    ];

    var done = false;
    void run() {
      if (done) return;
      done = true;
      // 注意：不能在异步回调里再 ModalRoute.of(context)（此时可能已失效），
      // 所以 route 在方法开头就取好。
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 转场结束后又被别的页面盖住（比如返回后马上再进一个页面）就别再干活了，
        // 否则会出现「已经在别的页面上，视频却又开始恢复播放」之类的怪事
        if (route != null && !route.isCurrent) return;
        action();
      });
    }

    // 兜底：转场动画被 TickerMode 静音时状态会停在 forward/reverse，
    // 状态监听可能永远等不到，正常转场（≤500ms）不会用到它
    Timer(_fallbackDelay, run);

    if (!animations.any((animation) => animation.status.isAnimating)) {
      run();
      return;
    }
    late final AnimationStatusListener listener;
    listener = (status) {
      if (animations.any((animation) => animation.status.isAnimating)) {
        return;
      }
      for (final animation in animations) {
        animation.removeStatusListener(listener);
      }
      run();
    };
    for (final animation in animations) {
      animation.addStatusListener(listener);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }
}
