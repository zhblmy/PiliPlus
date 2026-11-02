import 'dart:ui' show BlurStyle, ImageFilter, MaskFilter, PathOperation;

import 'package:PiliPlus/utils/device_state.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:get/get.dart' show Obx;
import 'package:material_ui/material_ui.dart';

/// iOS 26 那种玻璃的“高光边”：左上偏亮、右下渐隐
const kGlassRimGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0x8CFFFFFF), Color(0x14FFFFFF)],
);

/// [kGlassRimGradient] 的暗色版
const kGlassRimGradientDark = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0x59FFFFFF), Color(0x0FFFFFFF)],
);

/// 液体玻璃（Liquid Glass）容器。
///
/// 用 [BackdropFilter] 对**下层已绘制内容**做高斯模糊，再叠加半透明着色、
/// 高光描边与投影，得到 iOS 26 / IT之家 那种“玻璃”质感。
///
/// 使用前提：需要被模糊的内容必须绘制在它后面，
/// 典型写法是放进 `Stack` 的底层，例如：
///
/// ```dart
/// Stack(
///   children: [
///     Positioned.fill(child: body),   // 会被模糊的内容
///     Positioned(bottom: 12, child: LiquidGlass(child: navBar)),
///   ],
/// )
/// ```
///
/// 因此，如果某个栏（如底栏）本来就是叠在内容之上的，直接包一层即可；
/// 如果它原本参与布局（如首页顶栏），需要把内容改成“穿过式”布局，
/// 见 [TopBarInset] / [TopBarInsetSpacer]。
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.shape = const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(24)),
    ),
    this.blur = 12.0,
    this.color,
    this.highlightColor,
    this.highlightGradient,
    this.borderWidth = 0.8,
    this.shadowColor,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;

  /// 玻璃外形，同时决定裁剪形状与描边形状。
  final ShapeBorder shape;

  /// 背景模糊强度（sigma）。
  final double blur;

  /// 玻璃着色，默认按亮/暗色取 surface 的半透明色。
  final Color? color;

  /// 高光描边颜色，传 `Colors.transparent` 可关闭。
  final Color? highlightColor;

  /// 高光描边的渐变（传了就优先于 [highlightColor] 的纯色）。
  /// iOS 26 那样的玻璃，描边是“左上亮、右下渐隐”的。
  final Gradient? highlightGradient;

  final double borderWidth;

  /// 投影颜色，`null` 表示不绘制阴影。
  final Color? shadowColor;

  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.of(context);
    final isDark = scheme.brightness == .dark;

    final Color rawFill =
        color ??
        (isDark ? scheme.surfaceContainer : scheme.surface).withValues(
          alpha: isDark ? 0.58 : 0.66,
        );
    final Color highlight =
        highlightColor ?? Colors.white.withValues(alpha: isDark ? 0.12 : 0.42);

    // BackdropFilter 会在每一帧随下层内容重算高斯模糊，是玻璃栏最大的 GPU 开销；
    // 低功耗（省电模式 / 低电量 / 温控降档）时直接去掉，换成近乎不透明的纯色底。
    Widget glass = Obx(() {
      final lowPower = DeviceState.isLowPower.value;
      final fill = lowPower ? rawFill.withValues(alpha: 0.94) : rawFill;
      final content = ColoredBox(color: fill, child: child);
      return ClipPath(
        clipper: ShapeBorderClipper(
          shape: shape,
          textDirection: .ltr,
        ),
        clipBehavior: clipBehavior,
        child: lowPower
            ? content
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                // 用 ColoredBox（opaque 命中测试）：玻璃栏应该吃掉自己区域上的手势，
                // 否则会误触到被模糊盖住的下层内容
                child: content,
              ),
      );
    });

    if (borderWidth > 0 && highlight.a > 0) {
      glass = Stack(
        children: [
          glass,
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _GlassBorderPainter(
                  shape: shape,
                  color: highlight,
                  gradient: highlightGradient,
                  width: borderWidth,
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (shadowColor != null) {
      glass = Stack(
        // 投影要画到玻璃盒子外面去
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ClipPath(
                clipper: _GlassShadowClipper(shape),
                child: CustomPaint(
                  painter: _GlassShadowPainter(
                    shape: shape,
                    color: shadowColor!,
                  ),
                ),
              ),
            ),
          ),
          glass,
        ],
      );
    }

    return glass;
  }
}

/// 沿玻璃外形描一条高光边（`ShapeDecoration` 没有 side 参数，只能自己 stroke）
class _GlassBorderPainter extends CustomPainter {
  const _GlassBorderPainter({
    required this.shape,
    required this.color,
    required this.gradient,
    required this.width,
  });

  final ShapeBorder shape;
  final Color color;

  /// 描边渐变；为 null 时用 [color] 纯色
  final Gradient? gradient;

  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final gradient = this.gradient;
    final paint = Paint()
      ..style = .stroke
      ..strokeWidth = width
      ..color = color
      ..isAntiAlias = true;
    if (gradient != null) {
      paint.shader = gradient.createShader(rect);
    }
    canvas.drawPath(shape.getOuterPath(rect, textDirection: .ltr), paint);
  }

  @override
  bool shouldRepaint(_GlassBorderPainter oldDelegate) =>
      oldDelegate.shape != shape ||
      oldDelegate.color != color ||
      oldDelegate.gradient != gradient ||
      oldDelegate.width != width;
}

/// 剪出「玻璃外形**之外**」的区域，配合 [_GlassShadowPainter] 只画外投影。
///
/// 不能直接用 `BoxShadow`：它会把外形内部也刷上一遍阴影色，透过半透明的玻璃
/// 会显出一层脏灰（暗色主题下尤其明显）。这里用 `Path.combine(difference)`
/// 把外形从一个大矩形里挖掉（`Canvas.clipPath` 在当前 Flutter 版本不支持 `ClipOp`）。
class _GlassShadowClipper extends CustomClipper<Path> {
  const _GlassShadowClipper(this.shape);

  final ShapeBorder shape;

  /// 外投影最多能扩散出去的范围
  static const double extent = 64.0;

  @override
  Path getClip(Size size) {
    final rect = Offset.zero & size;
    return Path.combine(
      PathOperation.difference,
      Path()..addRect(rect.inflate(extent)),
      shape.getOuterPath(rect, textDirection: .ltr),
    );
  }

  @override
  bool shouldReclip(_GlassShadowClipper oldClipper) =>
      oldClipper.shape != shape;
}

/// 投影本体：外形向下位移 + 高斯模糊，内部由 [_GlassShadowClipper] 裁掉
class _GlassShadowPainter extends CustomPainter {
  const _GlassShadowPainter({
    required this.shape,
    required this.color,
  });

  final ShapeBorder shape;
  final Color color;

  /// 与 `BoxShadow.blurRadius` / `offset` 的语义对齐
  static const double blurRadius = 16.0;
  static const Offset offset = Offset(0, 4);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      shape.getOuterPath(
        (Offset.zero & size).shift(offset),
        textDirection: .ltr,
      ),
      Paint()
        ..color = color
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          blurRadius * 0.57735,
        ),
    );
  }

  @override
  bool shouldRepaint(_GlassShadowPainter oldDelegate) =>
      oldDelegate.shape != shape || oldDelegate.color != color;
}

/// 悬浮顶栏需要预留的顶部内边距。
///
/// 首页/动态页的顶栏是**页面 Stack 里铺满整宽的实心悬浮层**（位于 TabBarView 之外，
/// 所以切分类 Tab 时不动、也不会被各页自己的左右留白切窄）；
/// 各 Tab 页的滚动视图只需要在 `slivers` 最前面放一个 [TopBarInsetSpacer] 让出空间。
/// 值为 0 时不会有任何影响。
class TopBarInset extends InheritedWidget {
  const TopBarInset({
    super.key,
    required this.value,
    double? minValue,
    this.collapse,
    this.followScroll = true,
    required super.child,
  }) : assert(
         minValue == null || minValue <= value,
         'minValue 不能大于 value：收起量程 = value - minValue',
       ),
       minValue = minValue ?? value;

  /// 顶栏完全展开时的高度（收起量程就是 `value - minValue`）
  final double value;

  /// 顶栏收到最小时仍要保留的高度（状态栏那片 + 分类 Tab 栏）
  final double minValue;

  /// 顶栏当前的收起进度（px，0..`value - minValue`），由页面驱动：
  /// * 同步模式 = 可见列表的滚动位置（跟手 1:1）；
  /// * 即时模式 = 收起动画的进度（上滑收起、下滑出现）。
  ///
  /// 顶栏当前高度 = `value - collapse`（超出量程的部分自动 clamp）。
  /// 顶栏、让位 sliver、以及固定不滚动又要与顶栏底部对齐的元素
  /// （如排行榜左侧竖排 Tab 栏）都用同一个值，天然不会对不上。
  ///
  /// 必须是**稳定的实例**（如页面 State 里的一个 `ValueNotifier`、一个
  /// `AnimationController`）：它一变就会重建所有下层的让位/固定元素，
  /// 每次 build 新建一个的话，切 Tab / 旋转屏幕时会整棵子树重建。
  final ValueListenable<double>? collapse;

  /// 让位（空间）是否由滚动本身完成。
  /// * true（同步模式）：让位 sliver 高度固定为 [value]，内容与手指 1:1 跟手，
  ///   滚动到哪就是哪（不需要 any 补间）；
  /// * false（即时模式）：让位高度跟随 [collapse] 收缩，否则杆收起后顶上会留一条空白。
  final bool followScroll;

  static TopBarInset? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TopBarInset>();

  /// 顶栏完全展开时的高度（需要动态高度的用 [maybeOf] + [collapse] 自己算）
  static double of(BuildContext context) => maybeOf(context)?.value ?? 0.0;

  @override
  bool updateShouldNotify(TopBarInset oldWidget) =>
      value != oldWidget.value ||
      minValue != oldWidget.minValue ||
      collapse != oldWidget.collapse ||
      followScroll != oldWidget.followScroll;
}

/// 放在 `CustomScrollView.slivers` 最前面的让位 sliver（顶栏本体由页面 Stack 画，
/// 这里只是占位、什么都不画）。
///
/// * 同步模式（[TopBarInset.followScroll]）：高度固定为 [TopBarInset.value]，
///   于是内容顶部 = `value - 滚动位置`，与顶栏的收起严格同步、原生 1:1；
/// * 即时模式：高度 = `value - 收起进度`，让位跟着收起动画收缩。
class TopBarInsetSpacer extends StatelessWidget {
  const TopBarInsetSpacer({super.key});

  @override
  Widget build(BuildContext context) {
    final inset = TopBarInset.maybeOf(context);
    final double maxExtent = inset?.value ?? 0.0;
    final double minExtent = (inset?.minValue ?? maxExtent).clamp(
      0.0,
      maxExtent,
    );
    final collapse = inset?.collapse;
    if (collapse == null || inset!.followScroll || minExtent >= maxExtent) {
      return SliverToBoxAdapter(child: SizedBox(height: maxExtent));
    }
    return SliverToBoxAdapter(
      child: ValueListenableBuilder<double>(
        valueListenable: collapse,
        builder: (context, value, _) => SizedBox(
          height: maxExtent - value.clamp(0.0, maxExtent - minExtent),
        ),
      ),
    );
  }
}

/// 裁掉顶栏**始终盖住**的那一块（= 顶栏收起后的高度），并把内容隔成独立的重绘层。
///
/// 首页/动态页的顶栏是**不透明实心色**（不做模糊）：内容从它下面经过时看不见，
/// 也就不必再画；滚动时也只有顶栏下面这块区域需要重绘。
///
/// 注意裁的是「收起后的高度」，**不是**顶栏当前高度：
/// * 收起进度与内容让位大多时候严格同步，但列表整体跳回顶部（刷新、切 Tab、
///   `jumpTo` 等不回发滚动通知的情况）时会有瞬时不一致；若按当前高度裁，
///   就会把已经露出来的列表顶部一起裁掉——表现为「收起后吞掉一截内容」。
/// * 而 `[0, 收起后的高度)` 这块**任何状态下都被不透明的顶栏盖住**，
///   裁掉它永远不会裁到用户看得见的东西；
/// * 它和顶栏当前高度之间那段（最多一条「让位 sliver」）本身是空的，
///   画不画都一样，所以按当前高度裁也省不下什么。
class ClipBelowTopBar extends StatelessWidget {
  const ClipBelowTopBar({
    super.key,
    required this.height,
    required this.child,
  });

  /// 顶栏收起后仍然盖住的高度（顶栏不收起时就是顶栏高度）
  final double height;

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    clipper: _TopEdgeClipper(height),
    // 内容自成一层的重绘边界：滚动时只有它在重画，
    // 页面外层（含顶栏那一层）只做合成，不再跟着重录绘制指令
    child: RepaintBoundary(child: child),
  );
}

/// 裁掉顶部 [top] 那一条（被顶栏盖住的区域）
class _TopEdgeClipper extends CustomClipper<Rect> {
  const _TopEdgeClipper(this.top);

  final double top;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    0,
    top.clamp(0.0, size.height),
    size.width,
    size.height,
  );

  @override
  bool shouldReclip(_TopEdgeClipper oldClipper) => oldClipper.top != top;
}
