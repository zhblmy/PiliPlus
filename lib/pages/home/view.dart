import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/custom_height_widget.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/liquid_glass.dart';
import 'package:PiliPlus/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:PiliPlus/pages/common/common_page.dart';
import 'package:PiliPlus/pages/home/controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends CommonPageState<HomePage>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  late ColorScheme _colorScheme;
  final _homeController = Get.putOrFind(HomeController.new);
  final _mainController = Get.find<MainController>();

  @override
  bool get needsCorrection => _homeController.hideTopBar;

  @override
  bool get wantKeepAlive => true;

  /// 顶栏收起由滚动通知驱动（见 _onScrollNotification），不再写全局 barOffset
  @override
  bool get useBarOffset => false;

  /// 收起量程 = 搜索栏高度（玻璃顶栏可收起的部分）。
  /// 生效条件跟上面玻璃顶栏一致（横屏/侧边栏模式顶栏是参与排版的，不需要补间）；
  /// 即时模式不需要补间（动画自己会到端点）。
  @override
  double get pinnedHeaderExtent {
    if (_instant ||
        !_homeController.hideTopBar ||
        _mainController.useSideBar ||
        !MediaQuery.sizeOf(context).isPortrait) {
      return 0.0;
    }
    return Style.topBarHeight;
  }

  @override
  ScrollController? get pinnedHeaderScrollController => _safeScrollController();

  /// 当前 Tab 的滚动控制器。
  ///
  /// `HomeTabType.ctr` 是 `Get.find`：切到还没建好的 Tab 时（TabBarView 的页面
  /// 是懒建的，而且是在 layout 阶段才建）会抛异常，所以这里必须兜住，
  /// 否则切 Tab 那一帧会直接报错。
  ScrollController? _safeScrollController() {
    try {
      return _homeController.scrollController;
    } catch (_) {
      return null;
    }
  }

  /// 顶栏当前收起进度（px，0..量程）。玻璃、让位 sliver、排行榜左侧竖栏
  /// 都用同一个值，天然不会对不上。
  ///
  /// * 同步模式：= 可见列表的滚动位置（滚动通知驱动，跟手 1:1）；
  /// * 即时模式：= 收起动画的当前进度（上滑收起、下滑出现）。
  ///
  /// 不用 ScrollPosition 直接驱动：TabBarView 的页面是懒建的（在 layout 阶段才建），
  /// 首帧 / 切到没访问过的 Tab 时根本拿不到 position。
  final ValueNotifier<double> _barCollapse = ValueNotifier<double>(0.0);

  /// 即时模式的收起动画（0 = 完全展开，1 = 完全收起）
  late final AnimationController _barAnim;

  /// 当前认下的那个列表（切 Tab / 切分区会变）
  ScrollPosition? _activePosition;

  /// 「即时」模式：按滚动方向两态收起/出现（与设置里的「顶/底栏收起类型」对应）
  bool get _instant => _mainController.barHideType == .instant;

  /// 收起量程
  double get _collapseExtent => Style.topBarHeight;

  void _onBarAnimTick() {
    _barCollapse.value = _collapseExtent * _barAnim.value;
  }

  /// 即时模式：上滑（内容上移 = [ScrollDirection.reverse]）收起、下滑出现
  void _animateBar(bool hide) {
    if (hide) {
      _barAnim.forward();
    } else {
      _barAnim.reverse();
    }
  }

  @override
  void initState() {
    super.initState();
    _homeController.tabController.addListener(_onTabChanged);
    _barAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(_onBarAnimTick);
  }

  /// 切分类：换列表了，先把收起进度对齐到新 Tab 的真实位置
  /// （保活的 Tab 可能自己就滚在某处，直接归零会与它的让位对不上）。
  /// 即时模式不看滚动位置，顶栏状态不跟着 Tab 重置。
  void _onTabChanged() {
    _activePosition = null;
    if (_instant) return;
    _barCollapse.value =
        _currentScrollPosition()?.pixels.clamp(0.0, _collapseExtent) ?? 0.0;
  }

  @override
  void dispose() {
    _homeController.tabController.removeListener(_onTabChanged);
    _barAnim.dispose();
    _barCollapse.dispose();
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    // 顶栏不参与收起时（开关关掉）不需要做任何事
    if (!_homeController.hideTopBar) return false;
    final metrics = notification.metrics;
    if (metrics.axis != .vertical) return false;
    final bool isUser = notification is UserScrollNotification;
    if (!isUser &&
        notification is! ScrollUpdateNotification &&
        notification is! ScrollMetricsNotification) {
      return false;
    }
    if (_instant) {
      // 即时模式只关心方向（方向是全局 UI 状态），不关心是哪个列表，
      // 也不依赖 ScrollController 能不能解析出来 —— 免得漏掉收起/出现。
      if (isUser) {
        switch (notification.direction) {
          case .forward:
            // 下滑（内容下移）：出现
            _animateBar(false);
          case .reverse:
            // 上滑（内容上移）：收起隐藏
            _animateBar(true);
          case .idle:
            // 滚动结束时还会再发一个 idle，不能当成「出现」
            break;
        }
      }
      return false;
    }
    // 同步模式：必须知道是哪个列表 —— 收起进度就是它的滚动位置。
    // 冒泡上来的不只当前 Tab 的列表（保活的其他 Tab、卡片里内嵌的竖直列表
    // 等），只认当前可见 Tab 的那个；切分区时会重新认一次并立即对齐。
    final position = dispatchPositionOf(notification);
    if (position == null) return false;
    if (!identical(position, _activePosition)) {
      final current = _currentScrollPosition();
      if (current == null || !identical(position, current)) return false;
      _activePosition = position;
    }
    if (!isUser) {
      _barCollapse.value = metrics.pixels.clamp(0.0, _collapseExtent);
    }
    return false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _colorScheme = ColorScheme.of(context);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 搜索栏只在下半屏（竖屏、无侧栏）显示
    final bool showAppBar =
        !_mainController.useSideBar && MediaQuery.sizeOf(context).isPortrait;
    final bool hasTabBar = _homeController.tabs.length > 1;

    Widget tabBar;
    if (hasTabBar) {
      tabBar = SizedBox(
        height: Style.tabBarHeight,
        width: double.infinity,
        child: TabBar(
          controller: _homeController.tabController,
          tabs: _homeController.tabs.map((e) => Tab(text: e.label)).toList(),
          isScrollable: true,
          dividerColor: Colors.transparent,
          dividerHeight: 0,
          splashBorderRadius: Style.mdRadius,
          tabAlignment: TabAlignment.center,
          // 与 M3 默认指示线（3px、圆角、primary 色）一致，只把下划线上移，
          // 让它与标签文字的距离约缩小一半（42 高的 Tab 栏下约 12 → 约 6）
          indicator: UnderlineTabIndicator(
            insets: const EdgeInsets.only(bottom: 6),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(3),
            ),
            borderSide: BorderSide(width: 3, color: _colorScheme.primary),
          ),
          onTap: (_) {
            feedBack();
            if (!_homeController.tabController.indexIsChanging) {
              _homeController.animateToTop();
            }
          },
        ),
      );
    } else {
      tabBar = const SizedBox(height: 6);
    }

    final body = onBuild(
      NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: tabBarView(
          controller: _homeController.tabController,
          children: _homeController.tabs.map((e) => e.page).toList(),
        ),
      ),
    );

    if (!showAppBar) {
      if (_homeController.hideTopBar &&
          _mainController.barHideType == .instant) {
        tabBar = Material(
          color: _colorScheme.surface,
          child: tabBar,
        );
      }
      return Column(
        children: [
          tabBar,
          Expanded(child: body),
        ],
      );
    }

    // 顶栏（搜索栏 + 分类 Tab）是液体玻璃悬浮层，铺满整宽、盖住状态栏，
    // 内容从它下方穿过并被模糊。
    //
    // 分工：
    // * 让位：各 Tab 页滚动视图首位的 TopBarInsetSpacer（不可见的 pinned sliver，
    //   高度随滚动收缩）—— 原生跟手、不需要 correctBy 偷滚动；
    // * 外观：下面这层玻璃，用**同一个滚动位置**驱动收起，两者不会对不上。
    // * 性能：玻璃实例在这里建一次，滚动时只重建搜索行那一层包装。
    final double statusBarHeight = MediaQuery.viewPaddingOf(context).top;
    final double tabAreaHeight = hasTabBar ? Style.tabBarHeight : 6.0;
    final bool collapsible = _homeController.hideTopBar;

    Widget glassTopBar() {
      final bool isDark = _colorScheme.isDark;
      // 静态的搜索行内容（只跟主题/登录态有关）
      final searchRow = _searchRow();
      return LiquidGlass(
        shape: kGlassTopBarShape,
        blur: 16,
        color: _colorScheme.surface.withValues(alpha: isDark ? 0.5 : 0.62),
        shadowColor: Colors.black.withValues(alpha: isDark ? 0.4 : 0.1),
        child: Column(
          mainAxisSize: .min,
          children: [
            SizedBox(height: statusBarHeight),
            // CustomHeightWidget 收起时只会把内容挪走、并不裁剪，
            // 超出搜索栏那块的会画到状态栏那片玻璃上，必须裁掉。
            ClipRect(
              child: collapsible
                  ? _scrollDrivenSearchArea(searchRow)
                  : _staticSearchArea(searchRow),
            ),
            tabBar,
          ],
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          // 让位交给 TopBarInsetSpacer；collapse 是玻璃/让位/固定元素共用的收起进度，
          // followScroll 区分「同步（滚动自己让位）」与「即时（让位跟动画收缩）」。
          // 不收起时 minValue 必须等于 value，否则内容会缩到搜索栏里去。
          child: TopBarInset(
            value: statusBarHeight + Style.topBarHeight + tabAreaHeight,
            minValue: collapsible
                ? statusBarHeight + tabAreaHeight
                : statusBarHeight + Style.topBarHeight + tabAreaHeight,
            collapse: _barCollapse,
            followScroll: !_instant,
            child: body,
          ),
        ),
        Positioned(top: 0, left: 0, right: 0, child: glassTopBar()),
      ],
    );
  }

  /// 顶栏这一行（搜索框 + 消息按钮 + 头像）的高度。
  /// 「行高 + 上下内边距」必须刚好等于 [Style.topBarHeight]：
  /// 否则收起/展开时内容会超出顶栏区域被 ClipRect 裁掉，
  /// 看起来就是「收起隐藏不全 / 下拉展开不全」。
  static const double _searchRowHeight = 48;
  static const double _searchRowVPadding =
      (Style.topBarHeight - _searchRowHeight) / 2;
  static const EdgeInsets _searchRowPadding = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: _searchRowVPadding,
  );

  /// 搜索行内容（静态实例，不读 barOffset，所以不会每帧重建）
  Widget _searchRow() => SizedBox(
    height: _searchRowHeight,
    child: Row(
      children: [
        searchBar(),
        const SizedBox(width: 4),
        msgBadge(_mainController),
        const SizedBox(width: 8),
        userAvatar(colorScheme: _colorScheme, mainController: _mainController),
      ],
    ),
  );

  /// 顶栏常驻（不收起）时的搜索行
  Widget _staticSearchArea(Widget content) => Container(
    height: Style.topBarHeight,
    padding: _searchRowPadding,
    child: content,
  );

  /// 用收起进度驱动搜索区（同步模式跟手 1:1；即时模式跟随收起动画）
  Widget _scrollDrivenSearchArea(Widget content) {
    return ValueListenableBuilder<double>(
      valueListenable: _barCollapse,
      // child 是那个静态搜索行实例：每帧只重建这层包装（改高度 + 位移），
      // 搜索行本身与玻璃（BackdropFilter）都不在这层的重建范围里
      child: content,
      builder: (context, collapse, child) =>
          _collapsibleSearchArea(child!, collapse),
    );
  }

  ScrollPosition? _currentScrollPosition() {
    final controller = _safeScrollController();
    if (controller == null || !controller.hasClients) return null;
    final positions = controller.positions;
    return positions.length == 1 ? positions.first : null;
  }

  /// 收起模式下每帧重建的那一层包装（child 是上面那个静态实例）
  Widget _collapsibleSearchArea(Widget content, double collapse) {
    return CustomHeightWidget(
      offset: Offset(0, -collapse),
      height: Style.topBarHeight - collapse,
      child: Padding(padding: _searchRowPadding, child: content),
    );
  }

  Widget searchBar() {
    // 原 25 / 44，按 0.8 倍缩小
    const borderRadius = BorderRadius.all(Radius.circular(20));
    return Expanded(
      child: SizedBox(
        height: 35,
        child: Material(
          borderRadius: borderRadius,
          color: _colorScheme.onSecondaryContainer.withValues(alpha: 0.05),
          child: InkWell(
            borderRadius: borderRadius,
            splashColor: _colorScheme.primaryContainer.withValues(
              alpha: 0.3,
            ),
            onTap: () => Get.toNamed(
              '/search',
              parameters: _homeController.enableSearchWord
                  ? {'hintText': _homeController.defaultSearch.value}
                  : null,
            ),
            child: Row(
              children: [
                const SizedBox(width: 11),
                Icon(
                  Icons.search_outlined,
                  size: 19,
                  color: _colorScheme.onSecondaryContainer,
                  semanticLabel: '搜索',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Obx(
                    () => Text(
                      _homeController.defaultSearch.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _colorScheme.outline),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget userAvatar({
  required ColorScheme colorScheme,
  required MainController mainController,
}) {
  return Semantics(
    label: "我的",
    child: Obx(
      () {
        if (mainController.accountService.isLogin.value) {
          return Stack(
            clipBehavior: .none,
            children: [
              NetworkImgLayer(
                type: .avatar,
                width: 34,
                height: 34,
                src: mainController.accountService.face.value,
              ),
              Positioned.fill(
                child: Material(
                  type: .transparency,
                  child: InkWell(
                    onTap: mainController.toMinePage,
                    splashColor: colorScheme.primaryContainer.withValues(
                      alpha: 0.3,
                    ),
                    customBorder: const CircleBorder(),
                  ),
                ),
              ),
              Positioned(
                right: -4,
                bottom: -4,
                child: Obx(
                  () => MineController.anonymity.value
                      ? IgnorePointer(
                          child: Container(
                            padding: const .all(2),
                            decoration: BoxDecoration(
                              shape: .circle,
                              color: colorScheme.secondaryContainer,
                            ),
                            child: Icon(
                              size: 14,
                              MdiIcons.incognito,
                              color: colorScheme.onSecondaryContainer,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          );
        }
        return SizedBox(
          width: 38,
          height: 38,
          child: IconButton(
            tooltip: '点击登录',
            style: IconButton.styleFrom(
              padding: .zero,
              backgroundColor: colorScheme.onInverseSurface,
            ),
            onPressed: mainController.toMinePage,
            icon: Icon(
              Icons.person_rounded,
              size: 22,
              color: colorScheme.primary,
            ),
          ),
        );
      },
    ),
  );
}

Widget msgBadge(MainController mainController) {
  return Obx(
    () {
      if (mainController.accountService.isLogin.value) {
        final count = mainController.msgUnReadCount.value;
        final isNumBadge = mainController.msgBadgeMode == .number;
        return IconButton(
          tooltip: '消息',
          onPressed: () {
            mainController
              ..clearUnreadMsg()
              ..lastCheckUnreadAt = DateTime.now().millisecondsSinceEpoch;
            Get.toNamed('/whisper');
          },
          icon: Badge(
            isLabelVisible:
                mainController.msgBadgeMode != .hidden && count != null,
            alignment: isNumBadge
                ? const Alignment(0.0, -0.85)
                : const Alignment(1.0, -0.85),
            label: isNumBadge && count != null ? Text(count) : null,
            child: const Icon(Icons.notifications_none),
          ),
        );
      }
      return const SizedBox.shrink();
    },
  );
}
