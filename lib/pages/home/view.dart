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

/// 玻璃顶栏外形：铺满屏幕上方的一条（不带圆角）
const _kTopBarShape = RoundedRectangleBorder();

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends CommonPageState<HomePage>
    with AutomaticKeepAliveClientMixin {
  late ColorScheme _colorScheme;
  final _homeController = Get.putOrFind(HomeController.new);
  final _mainController = Get.find<MainController>();

  @override
  bool get needsCorrection => _homeController.hideTopBar;

  @override
  bool get wantKeepAlive => true;

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
    // 分类 Tab 栏的固定高度：4 的顶部间距 + 42
    const double tabBarHeight = 46.0;

    Widget tabBar;
    if (hasTabBar) {
      tabBar = Padding(
        padding: const EdgeInsets.only(top: 4),
        child: SizedBox(
          height: 42,
          width: double.infinity,
          child: TabBar(
            controller: _homeController.tabController,
            tabs: _homeController.tabs.map((e) => Tab(text: e.label)).toList(),
            isScrollable: true,
            dividerColor: Colors.transparent,
            dividerHeight: 0,
            splashBorderRadius: Style.mdRadius,
            tabAlignment: TabAlignment.center,
            onTap: (_) {
              feedBack();
              if (!_homeController.tabController.indexIsChanging) {
                _homeController.animateToTop();
              }
            },
          ),
        ),
      );
    } else {
      tabBar = const SizedBox(height: 6);
    }

    final body = onBuild(
      tabBarView(
        controller: _homeController.tabController,
        children: _homeController.tabs.map((e) => e.page).toList(),
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

    // 顶栏（搜索栏 + 分类 Tab）改为液体玻璃悬浮层，
    // 列表内容不再被挤在它下面，而是从它下方穿过并被模糊。
    Widget glassTopBar() {
      final (appBar, appBarHeight) = _appBarArea();
      final double inset = appBarHeight + (hasTabBar ? tabBarHeight : 6.0);
      final bool isDark = _colorScheme.isDark;
      return Stack(
        children: [
          Positioned.fill(child: _topBarInset(inset, body)),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlass(
              shape: _kTopBarShape,
              blur: 16,
              color: _colorScheme.surface.withValues(
                alpha: isDark ? 0.5 : 0.62,
              ),
              shadowColor: Colors.black.withValues(
                alpha: isDark ? 0.4 : 0.1,
              ),
              child: Column(
                mainAxisSize: .min,
                children: [appBar, tabBar],
              ),
            ),
          ),
        ],
      );
    }

    // hideTopBar 时顶栏会随滚动收起，需要在同一次刷新里取到最新高度
    return _homeController.hideTopBar ? Obx(glassTopBar) : glassTopBar();
  }

  /// 让滚动内容为玻璃顶栏让出空间；instant 模式下顶栏是整体收起/展开的，
  /// 内边距要跟着一起动画，否则会闪出一条空白。
  Widget _topBarInset(double inset, Widget child) {
    if (_homeController.hideTopBar && _mainController.barHideType == .instant) {
      return TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOutCubicEmphasized,
        tween: Tween<double>(end: inset),
        builder: (context, value, child) =>
            TopBarInset(value: value, child: child!),
        child: child,
      );
    }
    return TopBarInset(value: inset, child: child);
  }

  /// 玻璃顶栏的顶部区域：状态栏那片 + 搜索栏。
  /// 状态栏高度单独占一块（不跟着搜索栏收起），这样玻璃始终盖住状态栏。
  /// 第二项是这一区域当前的高度（收起动画中会变化）。
  (Widget, double) _appBarArea() {
    final double statusBarHeight = MediaQuery.viewPaddingOf(context).top;
    final (appBar, appBarHeight) = _searchBarArea();
    return (
      Column(
        mainAxisSize: .min,
        children: [
          SizedBox(height: statusBarHeight),
          // CustomHeightWidget / AnimatedContainer 收起时只会把内容挪走、并不裁剪，
          // 超出搜索栏那块的会画到状态栏那片玻璃（或分类 Tab）上，必须裁掉。
          // 以前是靠外层 TabBarView 的裁剪兜住的。
          ClipRect(child: appBar),
        ],
      ),
      statusBarHeight + appBarHeight,
    );
  }

  /// 顶部搜索栏本身（不含状态栏那片），第二项是它当前的高度
  (Widget, double) _searchBarArea() {
    const padding = EdgeInsets.fromLTRB(14, 6, 14, 0);
    final child = Row(
      children: [
        searchBar(),
        const SizedBox(width: 4),
        msgBadge(_mainController),
        const SizedBox(width: 8),
        userAvatar(colorScheme: _colorScheme, mainController: _mainController),
      ],
    );
    if (_homeController.hideTopBar) {
      if (_mainController.barOffset case final barOffset?) {
        final offset = barOffset.value;
        return (
          CustomHeightWidget(
            offset: Offset(0, -offset),
            height: Style.topBarHeight - offset,
            child: Padding(
              padding: padding,
              child: child,
            ),
          ),
          Style.topBarHeight - offset,
        );
      }
      if (_homeController.showTopBar case final showTopBar?) {
        final showSearchBar = showTopBar.value;
        return (
          AnimatedOpacity(
            opacity: showSearchBar ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            child: AnimatedContainer(
              curve: Curves.easeInOutCubicEmphasized,
              duration: const Duration(milliseconds: 500),
              height: showSearchBar ? Style.topBarHeight : 0,
              padding: padding,
              child: child,
            ),
          ),
          showSearchBar ? Style.topBarHeight : 0,
        );
      }
    }
    return (
      Container(
        height: Style.topBarHeight,
        padding: padding,
        child: child,
      ),
      Style.topBarHeight,
    );
  }

  Widget searchBar() {
    const borderRadius = BorderRadius.all(Radius.circular(25));
    return Expanded(
      child: SizedBox(
        height: 44,
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
                const SizedBox(width: 14),
                Icon(
                  Icons.search_outlined,
                  color: _colorScheme.onSecondaryContainer,
                  semanticLabel: '搜索',
                ),
                const SizedBox(width: 10),
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
                const SizedBox(width: 5),
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
