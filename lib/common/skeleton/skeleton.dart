import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart' show Ticker, TickerCallback, SchedulerBinding;
import 'package:material_ui/material_ui.dart';

/// 全局共享的骨架屏 shimmer 动画（性能报告 U-01）。
///
/// 原实现里每个骨架项各自持有一个 `AnimationController.repeat()`，并在这个
/// 控制器的监听里 `setState`：首屏常态 10~12 个占位项 = 10~12 个动画控制器
/// + 每帧 10~12 次「整棵卡片子树重建」+ 10~12 层每帧重建的 `ShaderMask`。
///
/// 这里改为全局唯一的 [Ticker] 驱动一个 [AnimationController]：
/// - 骨架项只用 `AnimatedBuilder` 重建最外层的 `ShaderMask`，卡片内部静态内容
///   通过 `child` 复用，完全不参与每帧重建；
/// - 没有可见骨架项时（或被 [TickerMode] 静音时）停止动画，避免空转耗电。
abstract final class SkeletonAnimation {
  static const Duration period = Duration(milliseconds: 1000);
  static const double minValue = -0.5;
  static const double maxValue = 1.5;
  static const List<double> stops = [0.1, 0.3, 0.5, 0.7];

  static final AnimationController controller = AnimationController.unbounded(
    vsync: const _SharedTickerProvider(),
  );

  static int _enabledCount = 0;

  static void _acquire() {
    if (_enabledCount++ > 0) return;
    controller.repeat(min: minValue, max: maxValue, period: period);
  }

  static void _release() {
    if (_enabledCount > 0 && --_enabledCount > 0) return;
    _enabledCount = 0;
    controller.stop();
  }
}

/// 直接用 [Ticker] 作为 vsync，不需要每个骨架项各自持有 TickerProvider
class _SharedTickerProvider implements TickerProvider {
  const _SharedTickerProvider();

  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

class Skeleton extends StatefulWidget {
  final Widget child;

  const Skeleton({super.key, required this.child});

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> {
  bool _enabled = false;
  bool _acquirePending = false;
  late Color color;
  late List<Color> _colors;
  final Matrix4 _matrix = Matrix4.identity();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    color = ColorScheme.of(context).surface.withAlpha(10);
    _colors = [Colors.transparent, color, color, Colors.transparent];
    // 只在骨架真正可见（未被 TickerMode 静音）时才让共享动画运行
    _updateTicker(TickerMode.valuesOf(context).enabled);
  }

  @override
  void dispose() {
    _updateTicker(false);
    super.dispose();
  }

  void _updateTicker(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) {
      if (_acquirePending) {
        // 还没来得及 acquire 就取消，等于从未启动
        _acquirePending = false;
      } else {
        SkeletonAnimation._release();
      }
      return;
    }
    if (_acquirePending) return;
    _acquirePending = true;
    // 路由切进来时，TickerMode 翻转的这一帧往往正是转场收尾、整页首次实时绘制
    // 的那一帧（见 RouteAwareMixin.runAfterRouteAnimation 的说明）。推迟一帧再
    // 启动 shimmer，避免把「每帧 saveLayer 的 ShaderMask」叠到那帧上。
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_acquirePending) return;
      _acquirePending = false;
      if (mounted && _enabled) {
        SkeletonAnimation._acquire();
      }
    });
  }

  ui.Shader _createShader(Rect bounds) {
    final width = bounds.width;
    final height = bounds.height;
    _matrix[12] = width * SkeletonAnimation.controller.value;
    return ui.Gradient.linear(
      Offset(0, 0.35 * height),
      Offset(width, 0.95 * height),
      _colors,
      SkeletonAnimation.stops,
      TileMode.clamp,
      _matrix.storage,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SkeletonAnimation.controller,
      // 卡片内容不被重建，只在每帧更新最外层 ShaderMask 的 shader
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: _createShader,
        child: child,
      ),
    );
  }
}
