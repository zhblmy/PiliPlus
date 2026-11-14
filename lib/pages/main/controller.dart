import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/grpc/dyn.dart';
import 'package:PiliPlus/grpc/im.dart';
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
import 'package:PiliPlus/services/message_notify_foreground.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/msg_notice.dart';
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
  bool useBottomNav = true;
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

  /// 前台未读汇总（HTTP，给角标用）的检查间隔
  static const _msgPollInterval = Duration(seconds: 60);

  /// 前台通知栏内容的刷新间隔。
  ///
  /// 用户直接看到的是通知栏里的会话名和消息内容，比角标数字更需要及时，
  /// 所以单独用更短的间隔（只多一个 gRPC 请求，HTTP 汇总仍按 60 秒走）。
  static const _noticePollInterval = Duration(seconds: 5);

  /// 底栏主页被二级页面（视频页、设置页等）覆盖时的通知刷新间隔：
  /// 角标不刷，但通知栏内容仍要在用户看别的内容时更新，只是降频到 60 秒
  static const _coveredNoticeInterval = Duration(seconds: 15);

  /// 后台轮询间隔（前台服务保活时）：低频，兼顾及时性与耗电
  static const _bgPollInterval = Duration(minutes: 2);

  Timer? _msgPollTimer;
  bool _isRefreshingMsgPage = false;
  bool _pendingManualMsgPageRefresh = false;
  late int _lastSelectTime = 0;
  int _lastBgPollAt = 0;
  int _lastNoticeRefreshAt = 0;

  /// 上一次发未读汇总（HTTP）的时间：失败也更新，避免断网时跟着 5 秒通知轮询重试
  int _lastUnreadPollAt = 0;

  /// 会话通知请求是否在飞：定时器与未读汇总可能并发触发，避免重复请求
  bool _isRefreshingNotice = false;

  /// 请求在飞期间收到的强制刷新，等这次回来再补
  bool _noticeRefreshPending = false;
  bool _isBackground = false;

  /// 底栏主页是否被二级页面覆盖（`MainApp.didPushNext` 会调 [onRouteCovered]）：
  /// 覆盖期间不刷角标，只按 [_coveredNoticeInterval] 低频率刷新通知栏内容
  bool _routeCovered = false;

  AppLifecycleListener? _appLifecycle;

  @override
  void onInit() {
    super.onInit();

    // 前台服务的启停跟着 App 的前后台走，和路由栈无关：
    // MainApp 在 didPushNext 时会摘掉自己的生命周期观察者（避免被覆盖时刷新角标），
    // 若把服务生命周期挂在那里，用户从视频页退到后台就不会再启动后台轮询了。
    _appLifecycle = AppLifecycleListener(
      onHide: onEnterBackground,
      onPause: onEnterBackground,
      // 进程即将销毁：不要在这里再拉起服务，直接收尾
      onDetach: onDetach,
      onResume: onEnterForeground,
    );

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
        (msgBadgeMode != DynamicBadgeMode.hidden ||
            Pref.enableMsgBadge ||
            Pref.enableMsgDetailNotify) &&
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
    // 角标与会话通知一起清：未登录/关闭开关/无消息类型时都不该残留通知
    MessageBadge.clearAll();
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
        (msgBadgeMode == DynamicBadgeMode.hidden &&
            !Pref.enableMsgBadge &&
            !Pref.enableMsgDetailNotify)) {
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
      // 私信汇总归零时不要按另一套口径直接清通知：群会话的未读不一定计入这个汇总，
      // 直接清会把群消息通知误删。改为强制对齐一次真实会话列表，由它决定剩几条。
      // 这次请求会顶替 _pollMsg 的常规刷新（共用同一节流），不会多打一次；
      // 本来就没有已发布的会话通知时不必查（零未读是常态）。
      if (msgUnReadTypes.contains(MsgUnReadType.pm) &&
          counts.first == 0 &&
          !isMsgPageVisible &&
          hasPublishedMsgNotices) {
        unawaited(_refreshMsgNotice(force: true));
      } else if (!isMsgPageVisible) {
        // 桌面角标和会话通知都由会话列表发布：查完未读后顺带对齐一次，
        // 冷启动时不必等满一轮轮询才出现角标。与 _pollMsg 共用 5 秒节流，
        // 不会多打请求；消息页可见时由该页的响应直接发布，这里跳过。
        unawaited(_refreshMsgNotice());
      }
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
        (msgBadgeMode != DynamicBadgeMode.hidden ||
            Pref.enableMsgBadge ||
            Pref.enableMsgDetailNotify)) {
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
  ///
  /// 返回本次是否真的刷到了会话列表数据，供调用方判断要不要另走会话通知刷新。
  Future<bool?> refreshMsgPage({bool quiet = false}) async {
    if (!Get.isRegistered<WhisperController>()) {
      return null;
    }
    if (_isRefreshingMsgPage) {
      _pendingManualMsgPageRefresh |= !quiet;
      return null;
    }
    _isRefreshingMsgPage = true;
    bool? refreshed;
    try {
      final controller = Get.find<WhisperController>();
      if (quiet) {
        refreshed = await controller.quietRefresh();
      } else {
        await controller.onRefresh();
        refreshed = true;
      }
    } finally {
      _isRefreshingMsgPage = false;
      if (_pendingManualMsgPageRefresh) {
        _pendingManualMsgPageRefresh = false;
        unawaited(refreshMsgPage());
      }
    }
    return refreshed;
  }

  /// 「消息」分类当前是否可见（仅底栏常驻 Tab 场景）
  bool get isMsgPageVisible =>
      hasMsg && navigationBars[selectedIndex.value] == NavigationBarType.msg;

  /// 前台时的周期检查；退到后台后由 [onEnterBackground] 接管并降频
  void startMsgPolling() {
    final wasCovered = _routeCovered;
    _routeCovered = false;
    _ensureMsgPollTimer();
    // 从二级页面/后台回到主页：覆盖期是 60 秒档，这里立刻对齐一次，
    // 免得刚返回时通知栏还停在旧内容（仍受 5 秒节流约束，不会多打请求）
    if (wasCovered) unawaited(_refreshMsgNotice());
  }

  /// 退到后台：前台服务只在后台需要，此时才拉起常驻通知并继续轮询
  ///
  /// 这里**不**停轮询定时器：[_pollMsg] 自己会按前后台状态与 `isRunning` 早退。
  Future<void> onEnterBackground() async {
    if (_isBackground) return;
    _isBackground = true;
    if (!(Pref.enableMsgDetailNotify && accountService.isLogin.value)) {
      return;
    }
    // 进后台先立刻查一次，不必等满一个后台间隔
    _lastBgPollAt = 0;
    // 定时器一般已在跑；从没有底栏/覆盖状态进来时补一个（已存在则什么也不做）
    _ensureMsgPollTimer();
    if (!await MessageNotifyForeground.start()) {
      // 前台服务起不来（权限被拒 / Android 12+ 后台启动限制）就不必空转
      return;
    }
    // 启动回执期间可能已经回到前台：立刻摘掉，别把常驻通知留到前台
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      unawaited(MessageNotifyForeground.stop());
      return;
    }
    unawaited(_pollMsg());
  }

  /// 回前台：摘掉常驻的「正在接收消息通知」，恢复常规轮询
  void onEnterForeground() {
    final wasBackground = _isBackground;
    _isBackground = false;
    // 真正从后台回来（不是拉一下通知栏那种 inactive）：立刻对齐一次通知栏内容。
    // 这里直接发，不依赖 resumed 回调的先后顺序（它的查询会被这里的节流挡掉）
    if (wasBackground) {
      _lastNoticeRefreshAt = 0;
      unawaited(_refreshMsgNotice());
    }
    // 不再按覆盖状态停表：覆盖期间也要刷新通知栏内容（见 [_pollMsg] 的覆盖分支）
    if (MessageNotifyForeground.isRunning) {
      unawaited(MessageNotifyForeground.stop());
    }
  }

  /// 进程即将销毁：不再尝试启动服务，直接停掉轮询
  void onDetach() {
    _isBackground = false;
    stopMsgPolling();
  }

  void _ensureMsgPollTimer() {
    if (_msgPollTimer != null || !(hasHome || hasMsg)) return;
    // 定时器按更短的通知间隔跑；HTTP 汇总在自己的节流里退化成 60 秒一次。
    // 两个开关都不需要时在 _pollMsg 里几行判断就返回，5 秒一次的唤醒可以忽略。
    _msgPollTimer = Timer.periodic(_noticePollInterval, (_) => _pollMsg());
  }

  /// 底栏主页被二级页面覆盖（`MainApp.didPushNext`）。
  ///
  /// 角标不再刷新，但定时器留着：通知栏内容要在用户看视频、逛设置时继续更新，
  /// 否则那时收到的消息要等回到主页才出现。
  void onRouteCovered() {
    _routeCovered = true;
    _ensureMsgPollTimer();
  }

  /// 真正停表：只给 [onDetach] / [onClose] 用
  void stopMsgPolling() {
    _routeCovered = true;
    _msgPollTimer?.cancel();
    _msgPollTimer = null;
  }

  Future<void> _pollMsg() async {
    if (!accountService.isLogin.value) return;

    // 只有真正退到后台才算「后台」：inactive 只是失焦（下拉通知栏、系统弹窗），
    // 这时前台轮询应该照常跑
    final state = WidgetsBinding.instance.lifecycleState;
    final background =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (background) {
      // 后台只有「通知栏消息详情」开启且前台服务存活时才继续，并降频
      if (!Pref.enableMsgDetailNotify || !MessageNotifyForeground.isRunning) {
        return;
      }
      if (now - _lastBgPollAt < _bgPollInterval.inMilliseconds) return;
      _lastBgPollAt = now;
    } else if (_routeCovered) {
      // 前台但底栏主页被二级页面覆盖（视频页、设置页等）：角标不刷，
      // 但通知栏内容仍要更新，只是降频（见 _refreshMsgNotice 的间隔选择）
      await _refreshMsgNotice();
      return;
    }

    final badgeVisible =
        msgBadgeMode != DynamicBadgeMode.hidden ||
        Pref.enableMsgBadge ||
        Pref.enableMsgDetailNotify;
    // 未读汇总（HTTP）与通知内容（gRPC）互不依赖，并发发出：
    // 通知栏不必等角标那两个请求回来
    Future<void>? unread;
    if (badgeVisible &&
        (background ||
            now - _lastUnreadPollAt >= _msgPollInterval.inMilliseconds)) {
      // 先记时间再请求：失败时也按 60 秒退避，不要跟着 5 秒通知轮询重试
      _lastUnreadPollAt = now;
      unread = queryUnreadMsg();
    }
    // 消息页可见时由 WhisperController 顺带更新会话摘要；翻过页时它会跳过，需要兜底
    bool? refreshed;
    final msgPageRefreshInFlight =
        !background &&
        isMsgPageVisible &&
        (_isRefreshingMsgPage ||
            (Get.isRegistered<WhisperController>() &&
                Get.find<WhisperController>().isLoading));
    if (!background && isMsgPageVisible && !msgPageRefreshInFlight) {
      refreshed = await refreshMsgPage(quiet: true);
    }
    if (refreshed == null && !msgPageRefreshInFlight) {
      await _refreshMsgNotice();
    }
    if (unread != null) await unread;
  }

  /// 消息页不可见（含 quietRefresh 因翻过页跳过）时的会话通知刷新
  Future<void> _refreshMsgNotice({bool force = false}) async {
    if (!enableMsgNotice) return;
    // 未读汇总与定时器会并发触发：同一时刻只留一个请求，
    // 在飞的那次返回后会照常发布，不必再发一遍
    if (_isRefreshingNotice) {
      // 设置里切换开关这类强制刷新不能丢，等这次回来再补一次
      if (force) _noticeRefreshPending = true;
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    // 被二级页面覆盖时降频；后台的 2 分钟节流在 _pollMsg 里已经做过了
    final interval = _routeCovered
        ? _coveredNoticeInterval
        : _noticePollInterval;
    if (!force && now - _lastNoticeRefreshAt < interval.inMilliseconds) {
      return;
    }
    _lastNoticeRefreshAt = now;
    _isRefreshingNotice = true;
    try {
      final res = await AccountManager.silent(ImGrpc.sessionMain);
      if (res case Success(:final response)) {
        // 头像下载可能要好几秒，不要让它占着「刷新在飞」的标记挡住下一轮；
        // 发布入口内部有版本号，乱序回来的旧批次会被丢弃
        unawaited(publishMsgNotices(response.sessions));
      }
      // 失败保留上次已发布的会话通知，不要当成「已无未读」清除
    } finally {
      _isRefreshingNotice = false;
      if (_noticeRefreshPending) {
        _noticeRefreshPending = false;
        unawaited(_refreshMsgNotice(force: true));
      }
    }
  }

  /// 立即重建会话通知（设置里重新打开「通知栏消息详情」时不必等下一轮轮询）
  Future<void> refreshMsgNotices() => _refreshMsgNotice(force: true);

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
    _appLifecycle?.dispose();
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
      resetMsgNoticeState();
      unawaited(MessageNotifyForeground.stop());
    }
  }
}
