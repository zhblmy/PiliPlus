import 'dart:ui' show BlurStyle, ImageFilter, MaskFilter, PathOperation;

import 'package:material_ui/material_ui.dart';

/// 玻璃顶栏外形：铺满屏幕上方的一条（不带圆角）
const kGlassTopBarShape = RoundedRectangleBorder();

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

    final Color fill =
        color ??
        (isDark ? scheme.surfaceContainer : scheme.surface).withValues(
          alpha: isDark ? 0.58 : 0.66,
        );
    final Color highlight =
        highlightColor ?? Colors.white.withValues(alpha: isDark ? 0.12 : 0.42);

    Widget glass = ClipPath(
      clipper: ShapeBorderClipper(
        shape: shape,
        textDirection: .ltr,
      ),
      clipBehavior: clipBehavior,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        // 用 ColoredBox（opaque 命中测试）：玻璃栏应该吃掉自己区域上的手势，
        // 否则会误触到被模糊盖住的下层内容
        child: ColoredBox(color: fill, child: child),
      ),
    );

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

/// 玻璃顶栏（悬浮样式）需要预留的顶部内边距。
///
/// 首页顶栏改成悬浮玻璃层后，滚动内容会从它下方穿过；为了让内容一开始不被
/// 压住，各 Tab 页的滚动视图需要在最前面留出这段空白 —— 用
/// [TopBarInsetSpacer] 即可，值为 0 时不会有任何影响。
class TopBarInset extends InheritedWidget {
  const TopBarInset({
    super.key,
    required this.value,
    required super.child,
  });

  final double value;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TopBarInset>()?.value ?? 0.0;

  @override
  bool updateShouldNotify(TopBarInset oldWidget) => value != oldWidget.value;
}

/// 放在 `CustomScrollView.slivers` 最前面的占位 sliver，
/// 高度等于当前玻璃顶栏的高度（没有玻璃顶栏时为 0）。
class TopBarInsetSpacer extends StatelessWidget {
  const TopBarInsetSpacer({super.key});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: SizedBox(height: TopBarInset.of(context)),
    );
  }
}
