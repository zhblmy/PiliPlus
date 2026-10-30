import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/common/widgets/nav_msg_icon.dart';
import 'package:PiliPlus/models/common/enum_with_label.dart';
import 'package:PiliPlus/pages/dynamics/view.dart';
import 'package:PiliPlus/pages/home/view.dart';
import 'package:PiliPlus/pages/mine/view.dart';
import 'package:PiliPlus/pages/whisper/view.dart';
import 'package:material_ui/material_ui.dart';

enum NavigationBarType implements EnumWithLabel {
  home(
    '首页',
    Icon(Icons.home_outlined),
    Icon(Icons.home),
    HomePage(),
  ),
  dynamics(
    '动态',
    Icon(CustomIcons.motion_photos_on_outlined),
    Icon(CustomIcons.motion_photos_on),
    DynamicsPage(),
  ),
  mine(
    '我的',
    Icon(Icons.person_outline),
    Icon(Icons.person),
    MinePage(),
  ),
  // 新分类追加在末尾：已有的「Navbar编辑 / 默认启动页」存的是枚举下标，
  // 插到中间会让老用户设置错位。展示顺序看 [defaultOrder]。
  msg(
    '消息',
    NavMsgIcon(),
    NavMsgIcon(selected: true),
    WhisperPage(),
  ),
  ;

  @override
  final String label;
  final Widget icon;
  final Widget selectIcon;
  final Widget page;

  const NavigationBarType(this.label, this.icon, this.selectIcon, this.page);

  /// 默认的底栏顺序：首页 → 动态 → 消息 → 我的
  static const List<NavigationBarType> defaultOrder = [
    home,
    dynamics,
    msg,
    mine,
  ];
}
