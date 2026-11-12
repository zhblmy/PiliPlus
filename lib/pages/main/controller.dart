import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/grpc/dyn.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/msg.dart';
import 'package:PiliPlus/models/common/dynamic/dynamic_badge_mode.dart';
import 'package:PiliPlus/models/common/home_tab_type.dart';
import 'package:PiliPlus/models/common/msg/msg_unread_type.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/pages/dynamics/controller.dart';
import 'package:PiliPlus/pages/home/controller.dart';
import 'package:PiliPlus/pages/mine/view.dart';
import 'package:PiliPlus/pages/whisper/controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/services/message_badge.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/msg_session_mute.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/update.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class MainController extends GetxController
    with GetSingleTickerProviderStateMixin, AccountMixin {
  @override
  final AccountService accountService = Get.find<AccountService>();

  List<NavigationBarType> navigationBars = <NavigationBarType>[];

  RxDouble? barOffset;
  RxBool? showBottomBar;
  late final bool hideBottomBar;
  late final barHideType = Pref.barHideType;
  bool useBottomNav = false;
  late dynamic controller;
  final RxInt selectedIndex = 0.obs;

  final RxInt dynCount = 0.obs;
  late DynamicBadgeMode dynamicBadgeMode;
  late bool checkDynamic = Pref.checkDynamic;
  late int dynamicPeriod = Pref.dynamicPeriod * 60 * 1000;
  late int _lastCheckDynamicAt = 0;
  late bool hasDyn = false;
  late final dynamicController = Get.putOrFind(DynamicsController.new);

  late bool hasHome = false;
  late final homeController = Get.putOrFind(HomeController.new);

  /// 底栏里是否有「消息」分类（有的话未读数走这个分类的角标）
  late bool hasMsg = false;

  late final disableLikeMsg = Pref.disableLikeMsg;
  late DynamicBadgeMode msgBadgeMode = Pref.msgBadgeMode;
  late Set<MsgUnReadType> msgUnReadTypes = Pref.msgUnReadTypeV2;
  late final RxnString msgUnReadCount = RxnString(null);
  late int lastCheckUnreadAt = 0;

  final enableMYBar = Pref.enableMYBar;
  final floatingNavBar = Pref.floatingNavBar;
  final useSideBar = Pref.useSideBar;
  final hideSideBarLabel = Pref.hideSideBarLabel;
  final mainTabBarView = Pref.mainTabBarView;
  late final optTabletNav = Pref.optTabletNav;

  late bool directExitOnBack = Pref.directExitOnBack;

  static const _period = 5 * 60 * 1000;

  /// 前台未读检查间隔：角标与「消息」页会话列表共用
  static const _msgPollInterval = Duration(seconds: 60);

  Timer? _msgPollTimer;
  bool _isRefreshingMsgPage = false;
  bool _pendingManualMsgPageRefresh = false;
  late int _lastSelectTime = 0;

  @override
  void onInit() {
    super.onInit();

    setNavBarConfig();

    controller = mainTabBarView
        ? TabController(
            vsync: this,
            initialIndex: selectedIndex.value,
            length: navigationBars.length,
          )
        : PageController(initialPage: selectedIndex.value);

    hideBottomBar =
        !useSideBar && navigationBars.length > 1 && Pref.hideBottomBar;
    if (hideBottomBar) {
      // 底栏现在是两态（上滑一次收起 / 下滑一次弹出），两种“收起方式”
      // 都靠这个开关，所以无条件建；barOffset 仍留给动态页顶部面板用。
      showBottomBar = RxBool(true);
      if (barHideType == .sync) {
        barOffset ??= RxDouble(0.0);
      }
    }

    dynamicBadgeMode = Pref.dynamicBadgeMode;

    hasDyn = navigationBars.contains(NavigationBarType.dynamics);
    final checkDynBadge =
        dynamicBadgeMode != DynamicBadgeMode.hidden &&
        hasDyn &&
        navigationBars[selectedIndex.value] != .dynamics;
    if (checkDynBadge && checkDynamic) {
      _lastCheckDynamicAt = DateTime.now().millisecondsSinceEpoch;
    }

    hasHome = navigationBars.contains(NavigationBarType.home);
    hasMsg = navigationBars.contains(NavigationBarType.msg);
    final checkMsgBadge =
        (msgBadgeMode != DynamicBadgeMode.hidden || Pref.enableMsgBadge) &&
        (hasHome || hasMsg);
    if (checkMsgBadge) {
      lastCheckUnreadAt = DateTime.now().millisecondsSinceEpoch;
    }

    // 冷启动优化：更新检查（GitHub）、动态红点、未读数都是「角标类」请求，
    // 与首页首屏的推荐请求同一时刻抢冷连接没有收益。推到首帧之后发，
    // 那时推荐请求已经发出去，角标最多晚一帧刷新。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Pref.autoUpdate) {
        Update.checkUpdate();
      }
      if (checkDynBadge) getUnreadDynamic();
      if (checkMsgBadge) queryUnreadMsg();
      startMsgPolling();
    });
  }

  Future<int?> _msgUnread() async {
    if (msgUnReadTypes.contains(MsgUnReadType.pm)) {
      final res = await MsgHttp.msgUnread();
      if (res case Success(:final response)) {
        return response.followUnread +
            response.unfollowUnread +
            response.bizMsgFollowUnread +
            response.bizMsgUnfollowUnread +
            response.unfollowPushMsg +
            response.customUnread;
      }
      // 请求失败：返回 null，不要当成 0 把已有角标清掉
      return null;
    }
    return 0;
  }

  Future<int?> _msgFeedUnread() async {
    int count = 0;
    final remainTypes = Set<MsgUnReadType>.from(msgUnReadTypes)
      ..remove(MsgUnReadType.pm);
    if (remainTypes.isNotEmpty) {
      final res = await MsgHttp.msgFeedUnread();
      if (res case Success(:final response)) {
        for (final item in remainTypes) {
          switch (item) {
            case MsgUnReadType.pm:
              break;
            case MsgUnReadType.reply:
              count += response.reply;
              break;
            case MsgUnReadType.at:
              count += response.at;
              break;
            case MsgUnReadType.like:
              if (!disableLikeMsg) count += response.like;
              break;
            case MsgUnReadType.sysMsg:
              count += response.sysMsg;
              break;
          }
        }
      } else {
        return null;
      }
    }
    return count;
  }

  void clearUnreadMsg() {
    msgUnReadCount.value = null;
    MessageBadge.update(0);
  }

  bool _isQueryingUnread = false;
  bool _pendingUnreadRefresh = false;
  bool _pendingUnreadChangeType = false;

  Future<void> queryUnreadMsg([bool isChangeType = false]) async {
    if (_isQueryingUnread) {
      // 已读成功后需要立刻更新角标，不能因为上一轮未返回就丢掉这次刷新
      _pendingUnreadRefresh = true;
      _pendingUnreadChangeType = _pendingUnreadChangeType || isChangeType;
      return;
    }
    if (!accountService.isLogin.value ||
        !(hasHome || hasMsg) ||
        msgUnReadTypes.isEmpty ||
        (msgBadgeMode == DynamicBadgeMode.hidden && !Pref.enableMsgBadge)) {
      clearUnreadMsg();
      return;
    }

    _isQueryingUnread = true;
    try {
      final counts = await Future.wait([_msgUnread(), _msgFeedUnread()]);
      // 任一请求失败时保留上一次的角标，等下次轮询或用户操作再更新
      if (counts.any((e) => e == null)) return;
      final count = counts.fold<int>(0, (sum, e) => sum + e!);

      final countStr = count == 0
          ? null
          : count > 99
          ? '99+'
          : count.toString();
      if (msgUnReadCount.value == countStr) {
        if (isChangeType) {
          msgUnReadCount.refresh();
        }
      } else {
        msgUnReadCount.value = countStr;
      }
      // 记一次「刚查过」，避免 checkUnread 在轮询之后又重复发一次请求
      lastCheckUnreadAt = DateTime.now().millisecondsSinceEpoch;
      MessageBadge.update(count);
    } finally {
      _isQueryingUnread = false;
      if (_pendingUnreadRefresh) {
        _pendingUnreadRefresh = false;
        final changeType = _pendingUnreadChangeType;
        _pendingUnreadChangeType = false;
        queryUnreadMsg(changeType);
      }
    }
  }

  void getUnreadDynamic() {
    if (!accountService.isLogin.value || !hasDyn) {
      return;
    }
    DynGrpc.dynRed().then((res) {
      if (res != null) {
        setDynCount(res);
      }
    });
  }

  void setDynCount([int count = 0]) {
    if (!hasDyn) return;
    dynCount.value = count;
  }

  void checkUnreadDynamic() {
    if (!hasDyn ||
        !accountService.isLogin.value ||
        dynamicBadgeMode == DynamicBadgeMode.hidden ||
        !checkDynamic) {
      return;
    }
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastCheckDynamicAt >= dynamicPeriod) {
      _lastCheckDynamicAt = now;
      getUnreadDynamic();
    }
  }

  void setNavBarConfig() {
    List<int>? navBarSort =
        (GStorage.setting.get(SettingBoxKey.navBarSort) as List?)?.fromCast();
    if (navBarSort != null && navBarSort.isNotEmpty) {
      navBarSort = _migrateNavBarSort(navBarSort);
    }
    final int typeCount = NavigationBarType.values.length;
    final List<NavigationBarType> parsed =
        // 兜一层：老的 / 手改过的配置里可能有越界下标，直接 elementAt 会抛异常；
        // 顺便去重，避免同一个分类出现两次
        (navBarSort ?? const <int>[])
            .where((e) => e >= 0 && e < typeCount)
            .map(NavigationBarType.values.elementAt)
            .toSet()
            .toList();
    navigationBars = parsed.isEmpty
        ? List.of(NavigationBarType.defaultOrder)
        : parsed;
    final defPage = Pref.defaultHomePage;
    selectedIndex.value = math.max(0, navigationBars.indexOf(defPage));
  }

  /// 「消息」是后加的分类，老的 `navBarSort` 里没有它。
  ///
  /// 只补一次（用 [SettingBoxKey.navBarSortMigrated] 记住）：否则用户主动
  /// 在「Navbar编辑」里删掉消息后，下次启动又会被塞回来。
  List<int> _migrateNavBarSort(List<int> cache) {
    if (GStorage.setting.get(SettingBoxKey.navBarSortMigrated) == true) {
      return cache;
    }
    final int msgIndex = NavigationBarType.msg.index;
    if (!cache.contains(msgIndex)) {
      // 插在「我的」前面：首页 → 动态 → 消息 → 我的
      final int mineIndex = cache.indexOf(NavigationBarType.mine.index);
      cache = List.of(cache)
        ..insert(mineIndex == -1 ? cache.length : mineIndex, msgIndex);
      GStorage.setting.put(SettingBoxKey.navBarSort, cache);
    }
    GStorage.setting.put(SettingBoxKey.navBarSortMigrated, true);
    return cache;
  }

  void checkDefaultSearch([bool shouldCheck = false]) {
    if (hasHome && homeController.enableSearchWord) {
      if (shouldCheck &&
          navigationBars[selectedIndex.value] != NavigationBarType.home) {
        return;
      }
      int now = DateTime.now().millisecondsSinceEpoch;
      if (now - homeController.lateCheckSearchAt >= _period) {
        homeController
          ..lateCheckSearchAt = now
          ..querySearchDefault();
      }
    }
  }

  void checkUnread([bool shouldCheck = false]) {
    if (accountService.isLogin.value &&
        (hasHome || hasMsg) &&
        (msgBadgeMode != DynamicBadgeMode.hidden || Pref.enableMsgBadge)) {
      if (shouldCheck &&
          navigationBars[selectedIndex.value] != NavigationBarType.home) {
        return;
      }
      int now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastCheckUnreadAt >= _period) {
        lastCheckUnreadAt = now;
        queryUnreadMsg();
      }
    }
  }

  /// 打开消息页。
  ///
  /// 底栏里有「消息」分类就直接切过去（不叠页面），没有才压一层 /whisper 路由。
  /// 首页 / 侧栏那个「消息」入口都走这里，逻辑只留一份。
  ///
  /// 这里只负责导航：未读角标以服务端已读汇总为准，打开列表本身不能算已读。
  void openMsgPage() {
    final int index = navigationBars.indexOf(NavigationBarType.msg);
    if (index != -1) {
      setIndex(index);
    } else {
      Get.toNamed('/whisper');
    }
  }

  int? _mineIndex;
  void toMinePage() {
    _mineIndex ??= navigationBars.indexOf(NavigationBarType.mine);
    if (_mineIndex != -1) {
      setIndex(_mineIndex!);
    } else {
      Get.to(
        const Material(
          child: ViewSafeArea(
            top: true,
            child: MinePage(showBackBtn: true),
          ),
        ),
      );
    }
  }

  /// 消息页现在是常驻 Tab（keep-alive），只在第一次打开时 `onInit` 拉一次数据。
  ///
  /// 进入消息分类、前台轮询、从详情返回后都要补一次刷新，否则「角标是新的、
  /// 列表还是旧的」。
  ///
  /// [quiet] 用于定时/自动刷新：失败时不弹 toast，也不把已有列表替换成错误页。
  Future<void> refreshMsgPage({bool quiet = false}) async {
    if (!Get.isRegistered<WhisperController>()) {
      return;
    }
    if (_isRefreshingMsgPage) {
      _pendingManualMsgPageRefresh |= !quiet;
      return;
    }
    _isRefreshingMsgPage = true;
    try {
      final controller = Get.find<WhisperController>();
      if (quiet) {
        await controller.quietRefresh();
      } else {
        await controller.onRefresh();
      }
    } finally {
      _isRefreshingMsgPage = false;
      if (_pendingManualMsgPageRefresh) {
        _pendingManualMsgPageRefresh = false;
        refreshMsgPage();
      }
    }
  }

  /// 「消息」分类当前是否可见（仅底栏常驻 Tab 场景）
  bool get isMsgPageVisible =>
      hasMsg && navigationBars[selectedIndex.value] == NavigationBarType.msg;

  /// 前台时的周期检查：后台由 main/view 的生命周期回调暂停。
  void startMsgPolling() {
    if (_msgPollTimer != null || !(hasHome || hasMsg)) return;
    _msgPollTimer = Timer.periodic(_msgPollInterval, (_) => _pollMsg());
  }

  void stopMsgPolling() {
    _msgPollTimer?.cancel();
    _msgPollTimer = null;
  }

  Future<void> _pollMsg() async {
    if (!accountService.isLogin.value) return;
    // 兜底：被路由覆盖期间 didPushNext 已停表，这里再挡一次后台状态
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final badgeVisible =
        msgBadgeMode != DynamicBadgeMode.hidden || Pref.enableMsgBadge;
    if (!badgeVisible && !isMsgPageVisible) return;
    if (badgeVisible) {
      await queryUnreadMsg();
    }
    // 消息页可见时连会话摘要一起更新；gRPC 请求在 quietRefresh 内部做了静默处理
    if (isMsgPageVisible) {
      await refreshMsgPage(quiet: true);
    }
  }

  void setIndex(int value, {bool feedback = true}) {
    // 底栏自己已经在「手指按下」时震过了（见 FloatingNavigationBar / main/view.dart
    // 的 Listener），从这里传 feedback: false 进来，避免按一下震两次。
    if (feedback) feedBack();

    final currentNav = navigationBars[value];
    if (value != selectedIndex.value) {
      selectedIndex.value = value;
      if (mainTabBarView) {
        controller.animateTo(value);
      } else {
        controller.jumpToPage(value);
      }
      if (currentNav == NavigationBarType.home) {
        checkDefaultSearch();
        checkUnread();
      } else if (currentNav == NavigationBarType.dynamics) {
        setDynCount();
      } else if (currentNav == NavigationBarType.msg) {
        // 只刷新列表，不清角标：角标等具体会话 ack 成功后由服务端汇总决定
        refreshMsgPage();
      }
    } else {
      int now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastSelectTime < 500) {
        EasyThrottle.throttle(
          'topOrRefresh',
          const Duration(milliseconds: 500),
          () => switch (currentNav) {
            .home => homeController.showRefresh(),
            .dynamics => dynamicController.showRefresh(),
            .msg || .mine => null,
          },
        );
      } else {
        if (currentNav == NavigationBarType.home) {
          homeController.toTopOrRefresh();
        } else if (currentNav == NavigationBarType.dynamics) {
          dynamicController.toTopOrRefresh();
        }
      }
      _lastSelectTime = now;
    }
  }

  void setSearchBar() {
    if (hasHome) {
      homeController.showTopBar?.value = true;
      homeController.requestShowTopBar();
    }
  }

  bool refreshRecommendations() {
    if (navigationBars[selectedIndex.value] == NavigationBarType.home &&
        homeController.tabs[homeController.tabController.index] ==
            HomeTabType.rcmd) {
      homeController.showRefresh();
      return true;
    }
    return false;
  }

  @override
  void onClose() {
    stopMsgPolling();
    barOffset?.close();
    controller.dispose();
    super.onClose();
  }

  @override
  void onChangeAccount(bool isLogin) {
    if (isLogin) {
      queryUnreadMsg();
      getUnreadDynamic();
    } else {
      // 免打扰覆盖按账号隔离，退出登录后旧账号的记录已经没用
      MsgSessionMute.clear();
      setDynCount();
      clearUnreadMsg();
    }
  }
}
