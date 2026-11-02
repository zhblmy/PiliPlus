import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

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

  /// 顶栏收起后仍要保留的高度（状态栏那片 + 分类 Tab 栏）
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
  /// * false（即时模式）：让位高度跟随 [collapse] 收缩，否则栏收起后顶上会留一条空白。
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
