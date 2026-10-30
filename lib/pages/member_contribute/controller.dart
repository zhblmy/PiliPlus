import 'dart:math';

import 'package:PiliPlus/models_new/space/space/tab2.dart';
import 'package:PiliPlus/pages/member/controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class MemberContributeCtr extends GetxController
    with GetSingleTickerProviderStateMixin {
  MemberContributeCtr({
    required this.heroTag,
    required this.initialIndex,
  });
  final String? heroTag;
  final int? initialIndex;

  TabController? tabController;
  List<Tab>? tabs;
  late final _ctr = Get.find<MemberController>(tag: heroTag);
  List<SpaceTab2Item>? items;

  @override
  void onInit() {
    super.onInit();
    final tab2 = _ctr.tab2;
    if (tab2 == null) return;
    final index = tab2.indexWhere((item) => item.param == 'contribute');
    if (index == -1) return;
    final contribute = tab2[index];
    final items = contribute.items;
    if (items != null && items.isNotEmpty) {
      this.items = items;
      if (contribute.items!.length > 1) {
        // show if exist
        if (_ctr.hasSeasonOrSeries == true) {
          items.add(const SpaceTab2Item(param: 'ugcSeason', title: '全部合集/列表'));
        }
        tabs = items.map((item) => Tab(text: item.title)).toList();
        tabController = TabController(
          vsync: this,
          length: items.length,
          initialIndex: max(0, initialIndex ?? 0),
        );
      }
    }
  }

  @override
  void onClose() {
    tabController?.dispose();
    super.onClose();
  }
}
