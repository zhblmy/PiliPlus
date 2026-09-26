import 'package:material_ui/material_ui.dart'
    show
        BorderRadius,
        Radius,
        BoxConstraints,
        BorderSide,
        ButtonStyle,
        Color,
        EdgeInsets,
        UnderlineTabIndicator,
        VisualDensity;

abstract final class Style {
  static const cardSpace = 8.0;
  static const safeSpace = 12.0;
  static const mdRadius = BorderRadius.all(imgRadius);
  static const imgRadius = Radius.circular(10);
  static const aspectRatio = 16 / 10;
  static const aspectRatio16x9 = 16 / 9;
  static const imgMaxRatio = 2.6;
  static const bottomSheetRadius = BorderRadius.vertical(top: .circular(18));
  static const dialogFixedConstraints = BoxConstraints.tightFor(width: 420);
  static const topBarHeight = 52.0;

  /// 与首页一致的分类 Tab 栏高度（栏内文字垂直居中，下划线上移 6 后空隙约 3）
  static const tabBarHeight = 42.0;

  /// 与首页分类 Tab 栏一致的下划指示线：M3 的 3px / 圆角 3 / primary 色，
  /// 只是把下划线上移，让「文字到下划线」的空隙与首页一致。
  ///
  /// 栏高 42 时 `bottom: 6` → 空隙约 3px；
  /// 空隙 ≈ (栏高 - 4 - 标签内容高) / 2 - insets（纯文字标签内容高 20）。
  static UnderlineTabIndicator tabIndicator(
    Color color, {
    double bottom = 6,
  }) => UnderlineTabIndicator(
    insets: EdgeInsets.only(bottom: bottom),
    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
    borderSide: BorderSide(width: 3, color: color),
  );
  static const buttonStyle = ButtonStyle(
    visualDensity: VisualDensity(horizontal: -2, vertical: -1.25),
    tapTargetSize: .shrinkWrap,
  );
  static const placeHolder = '\uFFFC';
}
