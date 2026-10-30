import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// 「消息 / 圈子」图标：带小尾巴的气泡 + 里面一道笑弧
/// （复刻 IT之家 底栏那个圈子图标）。
///
/// 未选中是描边，选中是实心（笑弧挖空，透出底下的玻璃）。
/// 颜色与尺寸都跟随 [IconTheme]，所以在底栏里能跟着选中态一起变色。
class NavMsgIcon extends StatelessWidget {
  const NavMsgIcon({super.key, this.selected = false});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final double size = iconTheme.size ?? 24.0;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _NavMsgIconPainter(
          color: iconTheme.color ?? ColorScheme.of(context).onSurface,
          filled: selected,
        ),
      ),
    );
  }
}

class _NavMsgIconPainter extends CustomPainter {
  const _NavMsgIconPainter({required this.color, required this.filled});

  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final Offset center = Offset(size.width / 2, size.height / 2);
    // 外径 0.75 槽位（含描边）：Material 同一槽位下 home_outlined 是 0.82×0.70、
    // person_outline 是 0.67×0.66、circle_outlined 是 0.83×0.84（圆环最占地方）。
    // 0.75 正好落在邻居之间，实心状态下也不会显得比它们大
    final double radius = s * 0.335; // 描边版本的**中心线**半径
    final double stroke = s * 0.08;

    // 描边版本的可见外沿是 radius + stroke/2；实心版本必须填到同一条线，
    // 否则选中时会「缩小一圈」。
    final double outerRadius = radius + stroke / 2;

    // 笑弧两种状态共用同一条路径、同一个线宽：未选中是描出来的黑线，
    // 选中是挖掉的透明缝，两者必须严丝合缝地重合（所以不能靠缩放画布来实现
    // 「放大外圈」，那会把笑弧一起推离圆心，看起来就是「线跑了」）。
    final smile = _smile(center, radius);

    if (filled) {
      // 笑弧要真的“挖空”才能透出下面的玻璃：saveLayer + BlendMode.clear。
      // 直接描一条白色在深色主题 / 彩色玻璃上会显脏。
      final clear = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..blendMode = BlendMode.clear;
      canvas
        ..saveLayer(Offset.zero & size, Paint())
        ..drawPath(_bubble(center, outerRadius), Paint()..color = color)
        ..drawPath(smile, clear)
        ..restore();
    } else {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..color = color;
      canvas
        ..drawPath(_bubble(center, radius), paint)
        ..drawPath(smile, paint);
    }
  }

  /// 圆形气泡 + 右下方一个小尖尾巴。
  ///
  /// 尾巴底边落在圆内部，并集后是一条光滑弧 + 一个尖角，接缝看不见。
  static Path _bubble(Offset center, double radius) {
    Offset at(double degrees, double r) {
      final double rad = degrees * math.pi / 180;
      return center + Offset(math.cos(rad), math.sin(rad)) * r;
    }

    final circle = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));

    final baseStart = at(20, radius * 0.92);
    final baseEnd = at(56, radius * 0.92);
    final apex = at(37, radius * 1.16);
    final tail = Path()
      ..moveTo(baseStart.dx, baseStart.dy)
      ..lineTo(apex.dx, apex.dy)
      ..lineTo(baseEnd.dx, baseEnd.dy)
      ..close();

    return Path.combine(PathOperation.union, circle, tail);
  }

  /// 笑弧：比圆心略高、半径略大的一小段下凸圆弧（比例照参考图量出来的）
  static Path _smile(Offset center, double radius) {
    return Path()..addArc(
      Rect.fromCircle(
        center: center - Offset(0, radius * 0.18),
        radius: radius * 0.77,
      ),
      28 * math.pi / 180,
      124 * math.pi / 180,
    );
  }

  @override
  bool shouldRepaint(_NavMsgIconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.filled != filled;
}
