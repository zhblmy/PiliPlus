import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart'
    show displacement, kIndicatorSize;
import 'package:PiliPlus/common/widgets/slotted_layout_helper.dart';
import 'package:PiliPlus/common/widgets/top_bar_inset.dart' show TopBarInset;
import 'package:flutter/foundation.dart'
    show DiagnosticPropertiesBuilder, DoubleProperty;
import 'package:flutter/rendering.dart'
    show BoxHitTestResult, ClipRectLayer, PipelineOwner;
import 'package:material_ui/material_ui.dart' hide RefreshIndicatorStatus;

enum RefreshType { indicator, body }

class RefreshLayout
    extends SlottedMultiChildRenderObjectWidget<RefreshType, RenderBox> {
  const RefreshLayout({
    super.key,
    required this.scale,
    required this.position,
    required this.indicator,
    required this.body,
  });

  final Animation<double> scale;
  final Animation<double> position;
  final Widget? indicator;
  final Widget body;

  @override
  Iterable<RefreshType> get slots => RefreshType.values;

  @override
  Widget? childForSlot(slot) => switch (slot) {
    .indicator => indicator,
    .body => body,
  };

  @override
  RenderRefreshLayout createRenderObject(BuildContext context) {
    return RenderRefreshLayout(
      scale: scale,
      position: position,
      // 内容会穿过悬浮的顶栏，转圈要往下让开。
      // 这里取的是**展开高度**：下拉刷新时列表先回到顶部、顶栏必然完全展开
      topOffset: TopBarInset.of(context),
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderRefreshLayout renderObject,
  ) {
    super.updateRenderObject(context, renderObject);
    // 顶栏高度只在状态栏 / 分类 Tab 栏 / 相关开关变化时才变，滚动期间恒定，
    // 所以不需要"转圈不可见就跳过重排"的守卫
    final topOffset = TopBarInset.of(context);
    if (renderObject.topOffset != topOffset) {
      renderObject
        ..topOffset = topOffset
        ..markNeedsLayout();
    }
  }
}

class RenderRefreshLayout extends RenderBox
    with SlottedContainerRenderObjectMixin<RefreshType, RenderBox> {
  RenderRefreshLayout({
    required this.scale,
    required this.position,
    this.topOffset = 0.0,
  }) : _heightFactor = position.value,
       _scaleFactor = scale.value;

  final Animation<double> scale;

  final Animation<double> position;

  /// 视口顶部被悬浮的顶栏盖住时，转圈要往下让开的距离
  double topOffset;

  /// 位移因子（0 ~ 1.5），由 [position] 驱动
  double _heightFactor;
  double get heightFactor => _heightFactor;
  set heightFactor(double value) {
    if (_heightFactor == value) {
      return;
    }
    _heightFactor = value;
    // 位置由布局期的 setOffset 决定、尺寸由 tightFor 决定，两者都变了；
    // 但重排交给管线做，不能在动画回调里直接对 child 调 layout()
    markNeedsLayout();
  }

  /// 缩放因子（0 ~ 1），由 [scale] 驱动
  double _scaleFactor;
  double get scaleFactor => _scaleFactor;
  set scaleFactor(double value) {
    if (_scaleFactor == value) {
      return;
    }
    _scaleFactor = value;
    markNeedsLayout();
  }

  void _scaleListener() {
    scaleFactor = scale.value;
  }

  void _positionListener() {
    heightFactor = position.value;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    scale.addListener(_scaleListener);
    position.addListener(_positionListener);
    // 重新挂载时动画可能已经是非零值（keep-alive 复活 / 热重载），
    // 不同步一次的话首帧转圈会停在顶栏后面
    _scaleListener();
    _positionListener();
  }

  @override
  void detach() {
    scale.removeListener(_scaleListener);
    position.removeListener(_positionListener);
    super.detach();
  }

  @override
  void dispose() {
    scale.removeListener(_scaleListener);
    position.removeListener(_positionListener);
    super.dispose();
  }

  RenderBox? get indicator => childForSlot(.indicator);
  RenderBox get body => childForSlot(.body)!;

  @override
  bool get sizedByParent => true;

  @override
  void performResize() {
    final constraints = this.constraints;
    assert(
      constraints.hasBoundedWidth && constraints.hasBoundedHeight,
      'RefreshLayout 需要确定的高度，实际拿到 $constraints',
    );
    // 尺寸只由约束决定、与子节点无关，所以声明 sizedByParent：
    // 这样本节点永远是 relayout boundary，下拉期间的重排不会往上冒泡
    size = constraints.biggest;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final constraints = this.constraints;

    final body = this.body..layout(constraints);
    setOffset(body, .zero);

    final indicator = this.indicator;
    if (indicator != null) {
      final scaleSize = kIndicatorSize * _scaleFactor;
      indicator.layout(
        BoxConstraints.tightFor(width: scaleSize, height: scaleSize),
      );
      setOffset(
        indicator,
        Offset(
          (constraints.maxWidth - scaleSize) / 2,
          topOffset +
              (kIndicatorSize + displacement) * _heightFactor -
              kIndicatorSize +
              (kIndicatorSize - scaleSize) / 2,
        ),
      );
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.paintChild(body, getOffset(body) + offset);

    final indicator = this.indicator;
    if (indicator == null || _heightFactor <= 0 || _scaleFactor <= 0) {
      layer = null;
      return;
    }

    final indicatorOffset = getOffset(indicator);
    if (indicatorOffset.dy > 0) {
      context.paintChild(indicator, indicatorOffset + offset);
      layer = null;
    } else {
      layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        (context, offset) {
          context.paintChild(indicator, indicatorOffset + offset);
        },
        clipBehavior: .hardEdge,
        oldLayer: layer as ClipRectLayer?,
      );
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    // 只命中 body：转圈是纯展示，不参与命中测试
    // （这也是没有直接混入 SlottedLayoutMixin 的原因）
    final body = this.body;
    return result.addWithPaintOffset(
      offset: getOffset(body),
      position: position,
      hitTest: (BoxHitTestResult result, Offset transformed) {
        return body.hitTest(result, position: transformed);
      },
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DoubleProperty('heightFactor', _heightFactor))
      ..add(DoubleProperty('scaleFactor', _scaleFactor))
      ..add(DoubleProperty('topOffset', topOffset));
  }
}
