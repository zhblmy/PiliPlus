import 'dart:async';
import 'dart:math';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/home_tab_type.dart';
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/wbi_sign.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class HomeController extends GetxController
    with GetSingleTickerProviderStateMixin, ScrollOrRefreshMixin {
  late List<HomeTabType> tabs;
  late TabController tabController;

  /// 即时模式下顶栏的「显示 / 隐藏」两态标志；`null` 表示不是即时模式。
  ///
  /// 顶栏收起动画已经不再读它的值（展开请求改由 [showTopBarRequest] 发事件），
  /// 它的实际用途是让 `CommonPageState` 判断「要不要挂方向监听」——同一个监听
  /// 还负责底栏两态切换，所以这个字段本身不能删。
  RxBool? showTopBar;
  late final bool hideTopBar;

  /// 「把顶栏展开」的请求事件：每 +1 当作一次新请求。
  ///
  /// 不复用 [showTopBar]：它已经是滚动方向的两态标志，
  /// 在它本来就是 true 时再置 true 不会触发任何监听。
  final RxInt showTopBarRequest = 0.obs;

  void requestShowTopBar() => showTopBarRequest.value++;

  bool enableSearchWord = Pref.enableSearchWord;
  late final RxString defaultSearch = ''.obs;
  late int lateCheckSearchAt = 0;

  ScrollOrRefreshMixin get controller => tabs[tabController.index].ctr();

  @override
  ScrollController get scrollController => controller.scrollController;

  AccountService accountService = Get.find<AccountService>();

  @override
  void onInit() {
    super.onInit();

    hideTopBar = !Pref.useSideBar && Pref.hideTopBar;
    if (hideTopBar) {
      final mainCtr = Get.find<MainController>();
      switch (mainCtr.barHideType) {
        case .instant:
          showTopBar = RxBool(true);
        case .sync:
          mainCtr.barOffset ??= RxDouble(0.0);
      }
    }

    if (enableSearchWord) {
      lateCheckSearchAt = DateTime.now().millisecondsSinceEpoch;
      // 启动期只读上次成功的搜索词（Hive 同步读），不发请求
      final cached = GStorage.localCache.get(LocalCacheKey.searchDefault);
      if (cached is String && cached.isNotEmpty) {
        defaultSearch.value = cached;
      }
      // 首屏之后再静默刷新一次，避免 build 期就发起网络请求
      WidgetsBinding.instance.addPostFrameCallback((_) {
        querySearchDefault();
      });
    }

    setTabConfig();
  }

  @override
  Future<void> onRefresh() => controller.onRefresh();

  @override
  Future<void> showRefresh() => controller.showRefresh();

  void setTabConfig() {
    final tabs = GStorage.setting.get(SettingBoxKey.tabBarSort) as List?;
    if (tabs != null) {
      this.tabs = tabs.map((i) => HomeTabType.values[i]).toList();
    } else {
      this.tabs = HomeTabType.values;
    }

    tabController = TabController(
      initialIndex: max(0, this.tabs.indexOf(HomeTabType.rcmd)),
      length: this.tabs.length,
      vsync: this,
    );
  }

  @override
  void dispose() {
    tabController.dispose();
    super.dispose();
  }

  Future<void> querySearchDefault() async {
    try {
      final res = await Request().get(
        Api.searchDefault,
        queryParameters: await WbiSign.makSign({'web_location': 333.1365}),
      );
      if (res.data['code'] == 0) {
        final String name = res.data['data']?['name'] ?? '';
        // 空结果不能把首帧从缓存恢复出来的提示词清掉
        if (name.isNotEmpty) {
          defaultSearch.value = name;
          GStorage.localCache.put(LocalCacheKey.searchDefault, name);
        }
        // defaultSearch.value = res.data['data']?['show_name'] ?? '';
      }
    } catch (_) {}
  }
}
