// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:PiliPlus/common/widgets/liquid_glass.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:material_ui/material_ui.dart';

const double _kMaxLabelTextScaleFactor = 1.3;

/// 悬浮底栏整体尺寸
const _kNavigationHeight = 55.0;

/// 底栏宽度上限。
///
/// 手机竖屏时底栏**铺满可用宽度**，这样左右留白严格等于「到屏幕底边的距离」；
/// 平板 / 横屏用这个上限收住，免得被拉成一条超长胶囊。
const _kMaxBarWidth = 480.0;
const _kIndicatorPaddingInt = 4.0;

/// 极窄屏（分屏、折叠屏悬停）的兜底：优先压缩左右留白而不是硬撑格宽，
/// 否则底栏会比屏幕还宽（直接 overflow）
const _kMinCellWidth = 56.0;

/// 静止时气泡四周与底栏之间的留白：上下左右必须**一样**，
/// 气泡两端的圆弧才会和底栏同心（弧度一致）。
///
/// 底栏圆角 = 55/2 = 27.5，气泡高 = 55 - 2×3 = 49、圆角 = 24.5，
/// 差值正好是 3 —— 两条弧就是同心的。
const _kIndicatorRestInset = 3.0;

/// [ _kIndicatorRestInset] 换算到「图标行矩形」里的值。
///
/// 图标行外面还包了一层 [ _kIndicatorPadding]（4），气泡图层画在那一层里，
/// 所以横向留白要用 `restInset - padding`，才不会变成 4+3=7 而上下只有 3。
/// 留白比内边距还小时该值为负（3 − 4 = −1），气泡靠 [Clip.none] 溢出那一层，
/// 视觉上仍然是距底栏 3dp。
const _kIndicatorInnerInset = _kIndicatorRestInset - _kIndicatorPaddingInt;

/// 静止时气泡的尺寸（比一格略小、比栏略矮）
const _kIndicatorRestHeight = _kNavigationHeight - 2 * _kIndicatorRestInset;

/// 栏内留白之后的高度：气泡在这个区域里上下居中
const _kNavigationInnerHeight = _kNavigationHeight - 2 * _kIndicatorPaddingInt;

/// 按下时气泡在横向 / 纵向上额外撑开的尺寸（撑到溢出底栏）。
/// 整条底栏也会放大 1.05，这里不需要再撑太多，否则气泡会显得头重脚轻
const _kPressGrow = 20.0;

/// 气泡滑动用的缓动曲线。
///
/// Material 的 emphasized 曲线起步几乎瞬时（时间走 10% 就已经滑了 62%），
/// 看着像“跳过去”，完全看不出缓动。这里是一条「快起步 + 长尾巴」的 S 形：
/// 10% 时间走 3.4%、20% 走 17%、40% 走 64%、60% 走 88%、80% 走 98%，
/// 前段推进快（配上下面的短时长才不肉），后段用近四成时间慢慢收力，
/// 既看得出缓动、又不会像在“刹一脚”。
const _kSlideCurve = Cubic(0.35, 0.0, 0.20, 1.0);

/// 按下时气泡「滑到被按的那一格」的时长。
/// 目前比切换选中（310ms）略长一点，缓动过程更从容、看得更清楚。
const _kPressSlideDuration = Duration(milliseconds: 320);

/// 底栏玻璃的着色浓度：**越小越透**（下层内容越清楚，糊得也更明显）。
///
/// IT之家 那条底栏相当透，所以这里给的比一般 Material 表面低不少；
/// 想更透就继续往下调，想更实就往 0.4 走。
const _kBarFillAlphaLight = 0.14;
const _kBarFillAlphaDark = 0.24;

/// 玻璃模糊强度：iOS 26 那种玻璃是“重度磨砂”，糊得越狠越像玻璃。
///
/// 但 28 在 1.5K@120Hz 上滚动时每帧都要重算一次模糊 pass，代价过高；
/// 降到 16 后视觉差异很小，滚动帧时间明显改善。
const _kBlurSigma = 16.0;

/// 选中气泡的模糊强度：它叠在底栏之上再糊一次下层内容，
/// 比底栏“朦胧”得多才有 IT之家 那种透镜感（区域小，sigma 高一点也不贵）
const _kIndicatorBlurSigma = 32.0;

/// 气泡边缘的软化程度：IT之家 那颗囊泡是没有硬边框的，
/// 边缘像糊进底栏里一样虚化
const _kIndicatorEdgeBlur = 0.9;

/// 气泡内部预留给「边缘软化」的空间（模糊会往外扩，得留出画布）
const _kIndicatorEdgePadding = _kIndicatorEdgeBlur * 2.6;

/// 按下时整个悬浮底栏的放大倍数（松开回落）
const _kBarPressScale = 1.05;

/// 左右到屏幕边缘的距离 = 底部距离 × 该比例（1 = 与底部距离相同，
/// 想让两侧更宽就往大调）
const _kSideMarginRatio = 1.0;

/// 按下放大 / 抬手缩回的时长
const _kPressDuration = Duration(milliseconds: 150);

/// 手指横向移动超过这个距离才算“拖动气泡”，避免点按时气泡抖动
const _kDragSlop = 4.0;
const _kIndicatorPadding = EdgeInsets.all(_kIndicatorPaddingInt);
const _kBorderRadius = BorderRadius.all(.circular(_kNavigationHeight / 2));
const _kNavigationShape = RoundedSuperellipseBorder(
  borderRadius: _kBorderRadius,
);

/// 选中气泡外形：胶囊（椭圆两端），上下溢出底栏
const _kIndicatorShape = StadiumBorder();

/// ref [NavigationBar]
class FloatingNavigationBar extends StatefulWidget {
  // ignore: prefer_const_constructors_in_immutables
  FloatingNavigationBar({
    super.key,
    this.animationDuration = const Duration(milliseconds: 310),
    this.selectedIndex = 0,
    required this.destinations,
    this.onDestinationSelected,
    this.backgroundColor,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.indicatorColor,
    this.labelBehavior,
    this.labelTextStyle,
    this.labelPadding,
    this.bottomPadding = 8.0,
  }) : assert(destinations.length >= 2),
       assert(0 <= selectedIndex && selectedIndex < destinations.length);

  final Duration animationDuration;
  final int selectedIndex;
  final List<Widget> destinations;
  final ValueChanged<int>? onDestinationSelected;
  final Color? backgroundColor;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;

  /// 只用来给选中气泡「染色」；气泡本身由底栏统一绘制（单个气泡跟随滑动），
  /// 不再像 [NavigationBar] 那样每个 destination 各画一个 indicator。
  final Color? indicatorColor;
  final NavigationDestinationLabelBehavior? labelBehavior;
  final WidgetStateProperty<TextStyle?>? labelTextStyle;
  final EdgeInsetsGeometry? labelPadding;
  final double bottomPadding;

  @override
  State<FloatingNavigationBar> createState() => _FloatingNavigationBarState();
}

class _FloatingNavigationBarState extends State<FloatingNavigationBar>
    with TickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.animationDuration,
  );

  /// 按下放大 / 抬手缩回
  late final AnimationController _pressController = AnimationController(
    vsync: this,
    duration: _kPressDuration,
  );

  /// 按压进度（0..1）
  late final Animation<double> _pressProgress = CurvedAnimation(
    parent: _pressController,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeOutCubic,
  );

  /// 气泡滑动的起点 / 终点（单位：第几格）；动画途中再次切换时从当前位置续接
  late double _from = widget.selectedIndex.toDouble();
  late double _to = _from;

  /// 手指正在拖动气泡时的位置（单位：第几格，可带小数）；null = 没在拖。
  /// 用 [ValueNotifier] 而不是 setState：拖动过程中只有气泡自己重建，
  /// 整条玻璃栏（含 BackdropFilter）不跟着每帧重建。
  final _dragPosition = ValueNotifier<double?>(null);
  int? _activePointer;
  double _dragStartDx = 0.0;
  double _dragStartPosition = 0.0;

  /// 本次按下命中的是第几格（抬手时用来校验气泡和选中态是否一致）
  int? _pressedCell;

  /// 气泡当前所在的格（带小数 = 正在拖动 / 滑动）。
  ///
  /// 位置随时间走的不是直线：[_kSlideCurve] 让它慢起步、后段收力，
  /// 所以「移动过程」本身就能看出加速与减速。
  double get _position {
    final drag = _dragPosition.value;
    if (drag != null) return drag;
    return _from + (_to - _from) * _kSlideCurve.transform(_controller.value);
  }

  double get _cellWidth =>
      (widget.destinations.length * _cell - 2 * _kIndicatorPaddingInt) /
      widget.destinations.length;

  /// 每一格的实际宽度（[build] 里按屏幕宽度算好后写回，
  /// 拖动手势要跟它保持一致）
  double _cell = 90.0;

  /// 整条底栏当前的放大倍数（按压时 1 → [_kBarPressScale]）。
  ///
  /// 必须和视觉缩放用**同一个**值：气泡画在缩放后的坐标系里，
  /// 手指的位移得除以它才是“气泡走了几格”。取 [_pressProgress]（带缓动）
  /// 而不是 [_pressController]（线性），底栏的放大才和气泡撑开同一条曲线。
  double get _barScale => 1 + (_kBarPressScale - 1) * _pressProgress.value;

  /// 从气泡当前位置平滑滑到 [target]（单位：第几格）。
  ///
  /// 动画途中再次调用时用 [_position] 续接，所以不会跳变（永远不是硬切）。
  void _animateTo(double target, {Duration? duration}) {
    // 已经在去同一格的路上（比如按下时的 [_kPressSlideDuration] 滑入还没走完，
    // 紧接着 onTap 确认选中）：让它自然走完，不要把时间轴重排成
    // [animationDuration]，否则会“刹一脚”
    if (_to == target) return;
    _from = _position;
    _to = target;
    if (_from == _to) return;
    _controller
      ..duration = duration ?? widget.animationDuration
      ..reset()
      ..forward();
  }

  /// 手指落点属于第几格（0 起）
  int _cellAt(double localDx) {
    final int count = widget.destinations.length;
    final double offset = localDx - _kIndicatorPaddingInt;
    return (offset / _cellWidth).floor().clamp(0, count - 1);
  }

  void _onPointerDown(PointerDownEvent event) {
    // 不用 if (_activePointer != null) return：万一上一次按下没收到抬手事件
    // （比如中途被移出树），直接接管，别把气泡交互永久锁死。
    _activePointer = event.pointer;
    _dragStartDx = event.position.dx;
    _pressController.forward();
    // 按压震动反馈（跟随设置 → 其它设置 → 震动反馈）
    feedBack();

    // 按在哪一格，气泡就先滑到那一格（带动画，不硬切）
    final int cell = _cellAt(event.localPosition.dx);
    _pressedCell = cell;
    _animateTo(cell.toDouble(), duration: _kPressSlideDuration);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    final double dx = event.position.dx - _dragStartDx;
    if (_dragPosition.value == null) {
      if (dx.abs() < _kDragSlop) return;
      // 拖动的基准是「此刻气泡所在的位置」而不是按下的那一格：
      // 按下时的滑入动画可能还没走完，用格子做基准会看到气泡瞬间跳一段。
      _dragStartPosition = _position;
    }
    // 超过 slop 的那一小段「白走」：扣掉它，激活瞬间不会跳；
    // 后面的位移 1:1 跟手（不能像以前那样把 _dragStartDx 重置到当前点，
    // 那样一次大跨度移动的整段位移都会被吞掉）
    final double travel = dx - _kDragSlop * dx.sign;
    final double max = widget.destinations.length - 1.0;
    _dragPosition.value =
        (_dragStartPosition + travel / (_cellWidth * _barScale)).clamp(0.0, max);
  }

  /// 抬手（或手势被取消）：气泡收缩并吸附到最近一格。
  /// 吸附目标与当前选中项不同时，顺带切换过去，保证气泡和选中态一致。
  void _endDrag({int? pointer, bool cancel = false}) {
    // 多指同时按在底栏上时，只认第一个按下的那根手指；否则第二根手指抬起
    // 会把第一根手指的拖动/按压状态一起收掉
    if (pointer != null && pointer != _activePointer) return;
    _activePointer = null;
    _pressController.reverse();
    final int? pressed = _pressedCell;
    _pressedCell = null;
    final double? from = _dragPosition.value;
    _dragPosition.value = null;

    final int target;
    if (from == null) {
      // 只点了一下、没拖动：气泡已经在按下时滑到那一格了，这里不再动时间轴。
      // 选中由 destination 的 onTap 确认（它在本回调之后才触发）
      if (pressed == null) return;
      target = pressed;
    } else {
      target = from.round().clamp(0, widget.destinations.length - 1);
      // 不能用 _animateTo：它取的是 [_position]，而此刻拖动位置刚被清掉
      _from = from;
      _to = target.toDouble();
      _controller
        ..duration = widget.animationDuration
        ..reset()
        ..forward();
      // 拖动松手 = 直接切换（不再依赖 onTap，手指可能已经离开那一格）。
      // 和点击那条路一样，只有真的换了格才通知，避免 setIndex 走「重复点击
      // 当前项」的分支（那会触发刷新）
      if (!cancel && target != widget.selectedIndex) {
        widget.onDestinationSelected?.call(target);
      }
    }

    // 选中到底切没切过去，由 onTap / onDestinationSelected 决定，可能是被拒绝的
    // （长按菜单、手势被取消、未登录被拦下、回调被忽略……）。
    // 下一帧如果气泡还停在「没被选中」的格子上，就滑回真正选中的那一格。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activePointer != null) return;
      if (widget.selectedIndex != target) {
        _animateTo(widget.selectedIndex.toDouble());
      }
    });
  }

  @override
  void didUpdateWidget(covariant FloatingNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animationDuration != widget.animationDuration) {
      _controller.duration = widget.animationDuration;
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _animateTo(widget.selectedIndex.toDouble());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _pressController.dispose();
    _dragPosition.dispose();
    super.dispose();
  }

  VoidCallback _handleTap(int index) {
    return widget.onDestinationSelected != null
        ? () => widget.onDestinationSelected!(index)
        : () {};
  }

  @override
  Widget build(BuildContext context) {
    final defaults = _NavigationBarDefaultsM3(context);

    final navigationBarTheme = NavigationBarTheme.of(context);
    final effectiveLabelBehavior =
        widget.labelBehavior ??
        navigationBarTheme.labelBehavior ??
        defaults.labelBehavior!;

    final padding = MediaQuery.viewPaddingOf(context);

    final int count = widget.destinations.length;
    final double width = MediaQuery.sizeOf(context).width;
    // 底栏到屏幕底边的距离（含安全区），左右各留同样的一段
    final double bottomInset = widget.bottomPadding + padding.bottom;
    final double safeSide = math.max(padding.left, padding.right);
    // 极窄屏（分屏 / 折叠屏悬停）时优先压缩左右留白，保证底栏不会比屏幕还宽
    final double maxSide = math.max(
      safeSide,
      (width - count * _kMinCellWidth) / 2,
    );
    final double sideInset = math.min(
      math.max(bottomInset * _kSideMarginRatio, safeSide),
      maxSide,
    );
    final double available = math.max(0.0, width - 2 * sideInset);
    // 底栏铺满可用宽度：左右留白因此严格等于「到屏幕底边的距离」。
    // 只给「整条宽度」设上限（平板 / 横屏），格宽由它平均分出来，
    // 这样气泡位置（用 `_cell` 反推）永远和实际布局一致。
    final double barWidth = math.min(available, _kMaxBarWidth);
    final double cell = barWidth / count;
    _cell = cell;
    final double cellWidth = _cellWidth;
    // 静止：气泡四周留白一致（左右与上下相同，弧度和底栏一致）；
    // 按下：在中点基础上撑到溢出底栏
    final double restWidth = cellWidth - 2 * _kIndicatorInnerInset;
    // 显式指定了选中指示器颜色时拿它给气泡着色，否则用主题色
    final Color? indicatorTint =
        widget.indicatorColor ?? navigationBarTheme.indicatorColor;

    return Padding(
      padding: .fromLTRB(sideInset, 0, sideInset, bottomInset),
      // 按住时整条底栏一起放大，松开回落到原尺寸
      child: AnimatedBuilder(
        animation: _pressProgress,
        builder: (context, child) => Transform.scale(
          scale: _barScale,
          child: child,
        ),
        child: SizedBox(
          height: _kNavigationHeight,
          width: count * cell,
          // Listener 放在最外层（所有子节点的祖先）：它用原始指针事件，
          // 不会和下面每个 destination 的点击识别器抢手势（点按依旧由各自的
          // GestureDetector 处理），同时无论命中玻璃、气泡还是图标都能收到按下事件。
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: (event) => _endDrag(pointer: event.pointer),
            onPointerCancel: (event) =>
                _endDrag(pointer: event.pointer, cancel: true),
            child: Stack(
              // 气泡按压缩放后会超出 55 高的胶囊，这一层不能裁剪
              clipBehavior: Clip.none,
              children: [
                // 玻璃本体只包一层不可见占位：内容单独画在外层，
                // 这样玻璃自己的 ClipPath（外形裁剪）不会把放大后的气泡切掉。
                Positioned.fill(
                  child: LiquidGlass(
                    shape: _kNavigationShape,
                    blur: _kBlurSigma,
                    // 半透明着色：下面的内容会被高斯模糊后透出来。
                    // iOS 26 的玻璃更“透”，alpha 要比顶栏低不少才看得出玻璃感
                    color:
                        (widget.backgroundColor ??
                                navigationBarTheme.backgroundColor ??
                                defaults.backgroundColor!)
                            .withValues(
                              alpha: defaults.isDark
                                  ? _kBarFillAlphaDark
                                  : _kBarFillAlphaLight,
                            ),
                    highlightColor: Colors.white,
                    // 左上亮、右下渐隐的高光边
                    highlightGradient: defaults.isDark
                        ? kGlassRimGradientDark
                        : kGlassRimGradient,
                    // 底栏本身几乎看不到描边，只有一层很淡的边缘高光
                    borderWidth: 0.9,
                    shadowColor: Colors.black.withValues(
                      alpha: defaults.isDark ? 0.32 : 0.10,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                // 选中气泡只画一个，横向跟着选中项滑动、按住时撑大。
                // 尺寸随按压进度变化（不是 Transform 缩放）：非等比缩放会把
                // 胶囊两端的圆头压成圆角矩形，而 IT之家 那颗撑大后仍是标准胶囊。
                // 它画在栏内留白区域里，撑大后靠 Stack 的 Clip.none 溢出底栏。
                Positioned.fill(
                  child: Padding(
                    padding: _kIndicatorPadding,
                    child: AnimatedBuilder(
                      animation: Listenable.merge([
                        _controller,
                        _dragPosition,
                        _pressProgress,
                      ]),
                      builder: (context, child) {
                        final double press = _pressProgress.value;
                        final double width = restWidth + _kPressGrow * press;
                        final double height =
                            _kIndicatorRestHeight + _kPressGrow * press;
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned(
                              left:
                                  cellWidth * _position +
                                  (cellWidth - width) / 2 -
                                  _kIndicatorEdgePadding,
                              top:
                                  (_kNavigationInnerHeight - height) / 2 -
                                  _kIndicatorEdgePadding,
                              width: width + 2 * _kIndicatorEdgePadding,
                              height: height + 2 * _kIndicatorEdgePadding,
                              child: child!,
                            ),
                          ],
                        );
                      },
                      child: _IndicatorLens(
                        isDark: defaults.isDark,
                        accent: defaults.accent,
                        press: _pressProgress,
                        tint: indicatorTint,
                      ),
                    ),
                  ),
                ),
                // 图标 / 文字层。整层跟着气泡的位置重建：每个 destination 的
                // 「选中强调度」= 气泡离它多近（1 = 正中，0 = 至少隔了一格），
                // 所以颜色永远和气泡同步，拖动气泡时文字也是实时跟手变色的。
                Positioned.fill(
                  child: Padding(
                    padding: _kIndicatorPadding,
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_controller, _dragPosition]),
                      builder: (context, _) {
                        final double position = _position;
                        return Row(
                          crossAxisAlignment: .stretch,
                          children: <Widget>[
                            for (int i = 0; i < count; i++)
                              Expanded(
                                child: _NavigationDestinationInfo(
                                  index: i,
                                  selectedIndex: widget.selectedIndex,
                                  totalNumberOfDestinations: count,
                                  selectedAnimation: _Emphasis(
                                    // 越靠近气泡越强调，三次方让它只在气泡附近才明显变色
                                    math
                                        .pow(
                                          (1 - (position - i).abs()).clamp(
                                            0.0,
                                            1.0,
                                          ),
                                          3,
                                        )
                                        .toDouble(),
                                  ),
                                  labelBehavior: effectiveLabelBehavior,
                                  onTap: _handleTap(i),
                                  labelTextStyle: widget.labelTextStyle,
                                  labelPadding: widget.labelPadding,
                                  child: widget.destinations[i],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 只读的「选中强调度」：由气泡当前位置算出来，自己不会动。
///
/// 用它取代每个 destination 各自持有的 [AnimationController]，
/// 图标 / 文字的颜色就和气泡位置严格一致（含拖动途中的实时跟手）。
class _Emphasis extends Animation<double> {
  const _Emphasis(this.value);

  @override
  final double value;

  @override
  AnimationStatus get status => value >= 1
      ? AnimationStatus.completed
      : value <= 0
      ? AnimationStatus.dismissed
      : AnimationStatus.forward;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void addStatusListener(AnimationStatusListener listener) {}

  @override
  void removeStatusListener(AnimationStatusListener listener) {}
}

/// 选中项外面那颗「凸出底栏」的玻璃囊泡。
///
/// 它叠在底栏玻璃之上，会把「底栏 + 底下的页面内容」再糊一次，
/// 所以镜头里比栏内更朦胧，像一块有厚度的玻璃透镜。
class _IndicatorLens extends StatelessWidget {
  const _IndicatorLens({
    required this.isDark,
    required this.accent,
    required this.press,
    this.tint,
  });

  final bool isDark;

  /// 主题色，用作气泡的一点点染色
  final Color accent;

  /// 显式指定的指示器颜色（`indicatorColor`），为 null 时用 [accent]
  final Color? tint;

  /// 按压进度（0 = 静止，1 = 按到底）。
  /// 静止时气泡只是一层很淡的膜，按下去才变成通透的玻璃囊泡——
  /// 和 IT之家 那颗「按下去才亮起来」的泡泡一样。
  final Animation<double> press;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: press,
      builder: (context, _) {
        final double t = press.value.clamp(0.0, 1.0);
        // 静止：一层淡淡的暗膜（和 IT之家 选中格那种“压下去一点的灰”一致）；
        // 按下：变成明显更亮的玻璃囊泡
        final Color accentTint = tint ?? accent;
        final Color restFill = isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Color.alphaBlend(
                accentTint.withValues(alpha: 0.03),
                Colors.black.withValues(alpha: 0.055),
              );
        final Color pressedFill = isDark
            ? Color.alphaBlend(
                accentTint.withValues(alpha: 0.16),
                Colors.white.withValues(alpha: 0.14),
              )
            : Color.alphaBlend(
                accentTint.withValues(alpha: 0.05),
                Colors.white.withValues(alpha: 0.56),
              );
        final Color fill = Color.lerp(restFill, pressedFill, t)!;
        // 软边那层只取一半浓度，免得糊成一团白雾
        final Color halo = fill.withValues(alpha: fill.a * 0.55);

        return Padding(
          padding: const EdgeInsets.all(_kIndicatorEdgePadding),
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              // 先铺一层糊掉的「同色雾」当软边：BackdropFilter 没法做羽化，
              // 用一层纯色胶囊再模糊，边缘就会柔和地过渡进底栏，而不是一条硬边
              IgnorePointer(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: _kIndicatorEdgeBlur,
                    sigmaY: _kIndicatorEdgeBlur,
                  ),
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      shape: _kIndicatorShape,
                      color: halo,
                    ),
                  ),
                ),
              ),
              LiquidGlass(
                shape: _kIndicatorShape,
                blur: _kIndicatorBlurSigma,
                color: fill,
                highlightColor: null,
                highlightGradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(
                      alpha: isDark
                          ? _lerp(0.20, 0.66, t)
                          : _lerp(0.32, 0.92, t),
                    ),
                    Colors.white.withValues(
                      alpha: isDark
                          ? _lerp(0.03, 0.12, t)
                          : _lerp(0.06, 0.20, t),
                    ),
                  ],
                ),
                // 描边交给外面的 _LensOutlinePainter（它带上下渐变），
                // 这里只要玻璃本身
                borderWidth: 0,
                // 不画外投影：囊泡边缘已经软化，再加投影会糊出一圈脏灰
                child: const SizedBox.expand(),
              ),
              // 顶部内高光 + 底部反光：给囊泡一点厚度感
              IgnorePointer(
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: _kIndicatorShape,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(
                          alpha: isDark ? 0.10 : _lerp(0.02, 0.04, t),
                        ),
                        const Color(0x00FFFFFF),
                        Colors.white.withValues(
                          alpha: isDark
                              ? _lerp(0.04, 0.07, t)
                              : _lerp(0.10, 0.22, t),
                        ),
                      ],
                      stops: const [0.0, 0.42, 1.0],
                    ),
                  ),
                ),
              ),
              // 外沿一条渐变描边：顶部偏暗、底部亮，玻璃才有厚度和边界
              IgnorePointer(
                child: CustomPaint(
                  painter: _LensOutlinePainter(
                    width: _lerp(1.0, 1.6, t),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(
                          alpha: isDark
                              ? _lerp(0.06, 0.10, t)
                              : _lerp(0.04, 0.10, t),
                        ),
                        const Color(0x00000000),
                        Colors.white.withValues(
                          alpha: isDark
                              ? _lerp(0.25, 0.55, t)
                              : _lerp(0.45, 0.95, t),
                        ),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 沿气泡外沿描一条细边，颜色随高度渐变：
/// 顶部暗一点、底部亮一点——玻璃透镜的“上暗下亮”就是这样来的
class _LensOutlinePainter extends CustomPainter {
  const _LensOutlinePainter({required this.gradient, required this.width});

  final Gradient gradient;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width / 2);
    canvas.drawPath(
      _kIndicatorShape.getOuterPath(rect, textDirection: .ltr),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = gradient.createShader(Offset.zero & size)
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_LensOutlinePainter oldDelegate) =>
      oldDelegate.gradient != gradient || oldDelegate.width != width;
}

class FloatingNavigationDestination extends StatelessWidget {
  const FloatingNavigationDestination({
    super.key,
    required this.icon,
    this.selectedIcon,
    required this.label,
    this.tooltip,
    this.enabled = true,
  });

  final Widget icon;

  final Widget? selectedIcon;

  final String label;

  final String? tooltip;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final info = _NavigationDestinationInfo.of(context);
    const selectedState = <WidgetState>{WidgetState.selected};
    const unselectedState = <WidgetState>{};
    const disabledState = <WidgetState>{WidgetState.disabled};

    final navigationBarTheme = NavigationBarTheme.of(context);
    final defaults = _NavigationBarDefaultsM3(context);
    final animation = info.selectedAnimation;

    // 选中气泡现在由 FloatingNavigationBar 统一画（单个气泡跟随滑动），
    // 这里只负责图标 / 文字
    return _NavigationDestinationBuilder(
      label: label,
      tooltip: tooltip,
      enabled: enabled,
      buildIcon: (context) {
        final IconThemeData selectedIconTheme =
            navigationBarTheme.iconTheme?.resolve(selectedState) ??
            defaults.iconTheme!.resolve(selectedState)!;
        final IconThemeData unselectedIconTheme =
            navigationBarTheme.iconTheme?.resolve(unselectedState) ??
            defaults.iconTheme!.resolve(unselectedState)!;
        final IconThemeData disabledIconTheme =
            navigationBarTheme.iconTheme?.resolve(disabledState) ??
            defaults.iconTheme!.resolve(disabledState)!;

        final Widget selectedIconWidget = selectedIcon ?? icon;
        return AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final bool selected = animation.value >= 0.5;
            final IconThemeData themeData = enabled
                ? (selected ? selectedIconTheme : unselectedIconTheme)
                : disabledIconTheme;
            return IconTheme.merge(
              data: enabled
                  ? themeData.copyWith(
                      // 图标颜色跟着切换渐变成强调色
                      color: Color.lerp(
                        unselectedIconTheme.color,
                        selectedIconTheme.color,
                        animation.value,
                      ),
                    )
                  : themeData,
              child: selected ? selectedIconWidget : icon,
            );
          },
        );
      },
      buildLabel: (context) {
        final TextStyle? effectiveSelectedLabelTextStyle =
            info.labelTextStyle?.resolve(selectedState) ??
            navigationBarTheme.labelTextStyle?.resolve(selectedState) ??
            defaults.labelTextStyle!.resolve(selectedState);
        final TextStyle? effectiveUnselectedLabelTextStyle =
            info.labelTextStyle?.resolve(unselectedState) ??
            navigationBarTheme.labelTextStyle?.resolve(unselectedState) ??
            defaults.labelTextStyle!.resolve(unselectedState);
        final TextStyle? effectiveDisabledLabelTextStyle =
            info.labelTextStyle?.resolve(disabledState) ??
            navigationBarTheme.labelTextStyle?.resolve(disabledState) ??
            defaults.labelTextStyle!.resolve(disabledState);
        final EdgeInsetsGeometry labelPadding =
            info.labelPadding ??
            navigationBarTheme.labelPadding ??
            defaults.labelPadding!;

        final TextStyle? textStyle = enabled
            ? TextStyle.lerp(
                effectiveUnselectedLabelTextStyle,
                effectiveSelectedLabelTextStyle,
                animation.value,
              )
            : effectiveDisabledLabelTextStyle;

        return Padding(
          padding: labelPadding,
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: _kMaxLabelTextScaleFactor,
            child: Text(label, style: textStyle),
          ),
        );
      },
    );
  }
}

class _NavigationDestinationBuilder extends StatefulWidget {
  const _NavigationDestinationBuilder({
    required this.buildIcon,
    required this.buildLabel,
    required this.label,
    this.tooltip,
    this.enabled = true,
  });

  final WidgetBuilder buildIcon;

  final WidgetBuilder buildLabel;

  final String label;

  final String? tooltip;

  final bool enabled;

  @override
  State<_NavigationDestinationBuilder> createState() =>
      _NavigationDestinationBuilderState();
}

class _NavigationDestinationBuilderState
    extends State<_NavigationDestinationBuilder> {
  final GlobalKey iconKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final info = _NavigationDestinationInfo.of(context);

    final child = GestureDetector(
      behavior: .opaque,
      onTap: widget.enabled ? info.onTap : null,
      child: _NavigationBarDestinationLayout(
        icon: widget.buildIcon(context),
        iconKey: iconKey,
        label: widget.buildLabel(context),
      ),
    );
    if (info.labelBehavior == .alwaysShow) {
      return child;
    }
    return _NavigationBarDestinationTooltip(
      message: widget.tooltip ?? widget.label,
      child: child,
    );
  }
}

class _NavigationDestinationInfo extends InheritedWidget {
  const _NavigationDestinationInfo({
    required this.index,
    required this.selectedIndex,
    required this.totalNumberOfDestinations,
    required this.selectedAnimation,
    required this.labelBehavior,
    required this.onTap,
    this.labelTextStyle,
    this.labelPadding,
    required super.child,
  });

  final int index;

  final int selectedIndex;

  final int totalNumberOfDestinations;

  final Animation<double> selectedAnimation;

  final NavigationDestinationLabelBehavior labelBehavior;

  final VoidCallback onTap;

  final WidgetStateProperty<TextStyle?>? labelTextStyle;

  final EdgeInsetsGeometry? labelPadding;

  static _NavigationDestinationInfo of(BuildContext context) {
    final _NavigationDestinationInfo? result = context
        .dependOnInheritedWidgetOfExactType<_NavigationDestinationInfo>();
    assert(
      result != null,
      'Navigation destinations need a _NavigationDestinationInfo parent, '
      'which is usually provided by NavigationBar.',
    );
    return result!;
  }

  @override
  bool updateShouldNotify(_NavigationDestinationInfo oldWidget) {
    return index != oldWidget.index ||
        totalNumberOfDestinations != oldWidget.totalNumberOfDestinations ||
        selectedAnimation != oldWidget.selectedAnimation ||
        labelBehavior != oldWidget.labelBehavior ||
        onTap != oldWidget.onTap;
  }
}

class _NavigationBarDestinationLayout extends StatelessWidget {
  const _NavigationBarDestinationLayout({
    required this.icon,
    required this.iconKey,
    required this.label,
  });

  final Widget icon;

  final GlobalKey iconKey;

  final Widget label;

  @override
  Widget build(BuildContext context) {
    return _DestinationLayoutAnimationBuilder(
      builder: (context, animation) {
        return CustomMultiChildLayout(
          delegate: _NavigationDestinationLayoutDelegate(animation: animation),
          children: <Widget>[
            LayoutId(
              id: _NavigationDestinationLayoutDelegate.iconId,
              child: KeyedSubtree(key: iconKey, child: icon),
            ),
            LayoutId(
              id: _NavigationDestinationLayoutDelegate.labelId,
              child: FadeTransition(
                alwaysIncludeSemantics: true,
                opacity: animation,
                child: label,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DestinationLayoutAnimationBuilder extends StatelessWidget {
  const _DestinationLayoutAnimationBuilder({required this.builder});

  final Widget Function(BuildContext, Animation<double>) builder;

  @override
  Widget build(BuildContext context) {
    final info = _NavigationDestinationInfo.of(context);
    switch (info.labelBehavior) {
      case NavigationDestinationLabelBehavior.alwaysShow:
        return builder(context, kAlwaysCompleteAnimation);
      case NavigationDestinationLabelBehavior.alwaysHide:
        return builder(context, kAlwaysDismissedAnimation);
      case NavigationDestinationLabelBehavior.onlyShowSelected:
        // [_Emphasis] 的值由气泡位置算出来、不会「反向」，所以只需要一条正向
        // 曲线；父级 AnimatedBuilder 每帧都会重建这一层，不必再套一层监听。
        return builder(
          context,
          CurveTween(curve: Curves.easeInOutCubicEmphasized).animate(
            info.selectedAnimation,
          ),
        );
    }
  }
}

class _NavigationBarDestinationTooltip extends StatelessWidget {
  const _NavigationBarDestinationTooltip({
    required this.message,
    required this.child,
  });

  final String message;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      verticalOffset: 34,
      excludeFromSemantics: true,
      preferBelow: false,
      child: child,
    );
  }
}

class _NavigationDestinationLayoutDelegate extends MultiChildLayoutDelegate {
  _NavigationDestinationLayoutDelegate({required this.animation})
    : super(relayout: animation);

  final Animation<double> animation;

  static const int iconId = 1;

  static const int labelId = 2;

  @override
  void performLayout(Size size) {
    double halfWidth(Size size) => size.width / 2;
    double halfHeight(Size size) => size.height / 2;

    final Size iconSize = layoutChild(iconId, BoxConstraints.loose(size));
    final Size labelSize = layoutChild(labelId, BoxConstraints.loose(size));

    final double yPositionOffset = Tween<double>(
      begin: halfHeight(iconSize),

      end: halfHeight(iconSize) + halfHeight(labelSize),
    ).transform(animation.value);
    // IT之家 的图标/文字整体略微下沉，文字离底边更近，所以这里加一点向下偏移
    final double iconYPosition = halfHeight(size) - yPositionOffset + 1.5;

    positionChild(
      iconId,
      Offset(
        halfWidth(size) - halfWidth(iconSize),
        iconYPosition,
      ),
    );

    positionChild(
      labelId,
      Offset(
        halfWidth(size) - halfWidth(labelSize),

        iconYPosition + iconSize.height,
      ),
    );
  }

  @override
  bool shouldRelayout(_NavigationDestinationLayoutDelegate oldDelegate) {
    return oldDelegate.animation != animation;
  }
}

const _indicatorDark = Color(0x15FFFFFF);
const _indicatorLight = Color(0x10000000);

class _NavigationBarDefaultsM3 extends NavigationBarThemeData {
  _NavigationBarDefaultsM3(this.context)
    : super(
        height: _kNavigationHeight,
        elevation: 3.0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      );

  final BuildContext context;
  late final _colors = Theme.of(context).colorScheme;
  late final _textTheme = Theme.of(context).textTheme;

  bool get isDark => _colors.isDark;

  /// 选中态强调色（图标 / 文字 / 气泡染色都用它）
  Color get accent => _colors.primary;

  BorderSide get borderSide => _colors.isDark
      ? const BorderSide(color: Color(0x08FFFFFF))
      : const BorderSide(color: Color(0x08000000));

  @override
  Color? get backgroundColor => _colors.surfaceContainer;

  @override
  Color? get shadowColor => Colors.transparent;

  @override
  Color? get surfaceTintColor => Colors.transparent;

  @override
  WidgetStateProperty<IconThemeData?>? get iconTheme {
    return WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      return IconThemeData(
        size: 22.0,
        color: states.contains(WidgetState.disabled)
            ? _colors.onSurface.withValues(alpha: 0.38)
            : states.contains(WidgetState.selected)
            ? accent
            : _colors.onSurface,
      );
    });
  }

  @override
  Color? get indicatorColor =>
      _colors.isDark ? _indicatorDark : _indicatorLight;

  @override
  ShapeBorder? get indicatorShape => const StadiumBorder();

  @override
  WidgetStateProperty<TextStyle?>? get labelTextStyle {
    return WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      final TextStyle style = _textTheme.labelMedium!;
      return style.apply(
        color: states.contains(WidgetState.disabled)
            ? _colors.onSurface.withValues(alpha: 0.38)
            : states.contains(WidgetState.selected)
            ? accent
            : _colors.onSurface,
      );
    });
  }

  @override
  EdgeInsetsGeometry? get labelPadding => const EdgeInsets.only(top: 2);
}
