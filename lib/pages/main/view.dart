import 'dart:io';

import 'package:PiliPlus/common/widgets/floating_navigation_bar.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/liquid_glass.dart';
import 'package:PiliPlus/common/widgets/main_layout.dart';
import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/pages/home/view.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/desktop/tray_controller.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/mobile_observer.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi;

/// 底栏玻璃形状：只在上面两个角做圆角，像一张悬浮的玻璃板
const _kBottomNavShape = RoundedRectangleBorder(
  borderRadius: .vertical(top: .circular(18)),
);

/// 玻璃模糊强度：iOS 26 那种玻璃是“重度磨砂”。
///
/// 28 在 1.5K@120Hz 上滚动时每个模糊 pass 的核半径约 84px，实测代价过高，
/// 降到与顶栏一致的 16（视觉差异很小，滚动帧时间明显改善）。
const _kBottomNavBlur = 16.0;

class MainApp extends StatefulWidget {
  const MainApp({super.key});
  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends PopScopeState<MainApp>
    with RouteAware, RouteAwareMixin, WidgetsBindingObserver {
  final _mainController = Get.put(MainController());
  late EdgeInsets _padding;
  late ColorScheme _colorScheme;
  Brightness? _brightness;

  @override
  bool get initCanPop => false;

  @override
  void initState() {
    super.initState();
    addObserverMobile(this);
    if (Platform.isMacOS) {
      HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    }
    if (PlatformUtils.isDesktop) {
      WindowController.instance.init();
      TrayController.instance.init();
    }
    if (!Platform.isMacOS) {
      PiliScheme.init();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _padding = MediaQuery.viewPaddingOf(context);
    _colorScheme = ColorScheme.of(context);
    final brightness = _colorScheme.brightness;
    NetworkImgLayer.reduce =
        NetworkImgLayer.reduceLuxColor != null && brightness.isDark;
    if (PlatformUtils.isDesktop) {
      if (_brightness != brightness) {
        _brightness = brightness;
        nativeapi.Application.instance.setBrightness(
          brightness == .dark ? .dark : .light,
        );
      }
    }
    if (!_mainController.useSideBar) {
      _mainController.useBottomNav = MediaQuery.sizeOf(context).isPortrait;
    }
  }

  @override
  void didPopNext() {
    addObserverMobile(this);
    // 这 3 个未读检查都会发网络请求，等返回转场播完再跑，
    // 避免和转场收尾那一帧（整页首次实时绘制）抢帧
    runAfterRouteAnimation(() {
      _mainController
        ..checkUnreadDynamic()
        ..checkDefaultSearch(true)
        ..checkUnread(_mainController.useBottomNav);
    });
    super.didPopNext();
  }

  @override
  void didPushNext() {
    removeObserverMobile(this);
    super.didPushNext();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _mainController
        ..checkUnreadDynamic()
        ..checkDefaultSearch(true)
        ..checkUnread(_mainController.useBottomNav);
    }
  }

  @override
  void dispose() {
    if (Platform.isMacOS) {
      HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    }
    if (PlatformUtils.isDesktop) {
      WindowController.instance.dispose();
      TrayController.instance.dispose();
    }
    removeObserverMobile(this);
    PiliScheme.listener?.cancel();
    GStorage.close();
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    return event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyR &&
        HardwareKeyboard.instance.isMetaPressed &&
        _mainController.refreshRecommendations();
  }

  @pragma('vm:prefer-inline')
  static void _onBack() {
    if (Platform.isAndroid) {
      AndroidHelper.back();
    }
  }

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (_mainController.directExitOnBack) {
      _onBack();
    } else {
      if (_mainController.selectedIndex.value != 0) {
        _mainController
          ..setIndex(0)
          ..barOffset?.value = 0.0
          ..showBottomBar?.value = true
          ..setSearchBar();
      } else {
        _onBack();
      }
    }
  }

  Widget? get _bottomNav {
    Widget? bottomNav;
    if (_mainController.navigationBars.length > 1) {
      if (_mainController.floatingNavBar) {
        bottomNav = Obx(
          () => FloatingNavigationBar(
            onDestinationSelected: (index) =>
                _mainController.setIndex(index, feedback: false),
            selectedIndex: _mainController.selectedIndex.value,
            destinations: _mainController.navigationBars
                .map(
                  (e) => FloatingNavigationDestination(
                    label: e.label,
                    icon: _buildIcon(type: e),
                    selectedIcon: _buildIcon(type: e, selected: true),
                  ),
                )
                .toList(),
          ),
        );
      } else if (_mainController.enableMYBar) {
        bottomNav = LiquidGlass(
          shape: _kBottomNavShape,
          blur: _kBottomNavBlur,
          // iOS 26 的玻璃更“透”，alpha 要比顶栏低不少才看得出玻璃感
          color: _colorScheme.surfaceContainer.withValues(
            alpha: _colorScheme.isDark ? 0.32 : 0.22,
          ),
          highlightColor: Colors.white,
          // 左上亮、右下渐隐的高光边
          highlightGradient: _colorScheme.isDark
              ? kGlassRimGradientDark
              : kGlassRimGradient,
          borderWidth: 1.2,
          shadowColor: Colors.black.withValues(
            alpha: _colorScheme.isDark ? 0.35 : 0.12,
          ),
          // 按压缩动反馈（跟随设置 → 其它设置 → 震动反馈）。
          // 用 Listener（原始指针事件），不参与手势竞技场，不影响点击。
          child: Listener(
            onPointerDown: (_) => feedBack(),
            child: Obx(
              () => NavigationBar(
                maintainBottomViewPadding: true,
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                // 约 80 的 7/10
                height: 56,
                onDestinationSelected: (index) =>
                    _mainController.setIndex(index, feedback: false),
                selectedIndex: _mainController.selectedIndex.value,
                destinations: _mainController.navigationBars
                    .map(
                      (e) => NavigationDestination(
                        label: e.label,
                        icon: _buildIcon(type: e),
                        selectedIcon: _buildIcon(type: e, selected: true),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        );
      } else {
        bottomNav = LiquidGlass(
          shape: _kBottomNavShape,
          blur: _kBottomNavBlur,
          // iOS 26 的玻璃更“透”，alpha 要比顶栏低不少才看得出玻璃感
          color: _colorScheme.surfaceContainer.withValues(
            alpha: _colorScheme.isDark ? 0.32 : 0.22,
          ),
          highlightColor: Colors.white,
          // 左上亮、右下渐隐的高光边
          highlightGradient: _colorScheme.isDark
              ? kGlassRimGradientDark
              : kGlassRimGradient,
          borderWidth: 1.2,
          shadowColor: Colors.black.withValues(
            alpha: _colorScheme.isDark ? 0.35 : 0.12,
          ),
          // 按压缩动反馈（跟随设置 → 其它设置 → 震动反馈）
          child: Listener(
            onPointerDown: (_) => feedBack(),
            child: Obx(
              () => BottomNavigationBar(
                currentIndex: _mainController.selectedIndex.value,
                onTap: (index) =>
                    _mainController.setIndex(index, feedback: false),
                iconSize: 16,
                selectedFontSize: 12,
                unselectedFontSize: 12,
                type: .fixed,
                backgroundColor: Colors.transparent,
                elevation: 0,
                items: _mainController.navigationBars
                    .map(
                      (e) => BottomNavigationBarItem(
                        label: e.label,
                        icon: _buildIcon(type: e),
                        activeIcon: _buildIcon(type: e, selected: true),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        );
      }

      if (_mainController.hideBottomBar) {
        if (_mainController.showBottomBar case final showBottomBar?) {
          // 两态：滚动方向一变就整条收起/弹出，不停在半路。
          // 用 AnimatedSlide（Transform 平移，不触发布局）+ RepaintBoundary，
          // 动画期间底栏那棵玻璃子树实例不变、不会被重建。
          final bar = RepaintBoundary(child: bottomNav);
          return Obx(
            () => AnimatedSlide(
              curve: Curves.easeOutCubic,
              duration: const Duration(milliseconds: 220),
              offset: Offset(0, showBottomBar.value ? 0 : 1),
              child: bar,
            ),
          );
        }
      }
    }

    return bottomNav;
  }

  Widget _sideBar() {
    if (_mainController.navigationBars.length > 1) {
      if (context.isTablet && _mainController.optTabletNav) {
        return Padding(
          padding: const .only(top: 25),
          child: MediaQuery.removePadding(
            context: context,
            removeRight: true,
            child: Obx(
              () => DrawerTheme(
                data: DrawerThemeData(
                  width:
                      (_mainController.hideSideBarLabel ? 80 : 130) +
                      _padding.left,
                ),
                child: NavigationDrawer(
                  /// apply `lib/scripts/navigation_drawer.patch`
                  flex: 5,
                  backgroundColor: Colors.transparent,
                  onDestinationSelected: _mainController.setIndex,
                  selectedIndex: _mainController.selectedIndex.value,
                  header: Expanded(flex: 4, child: userAndSearchVertical()),
                  tilePadding: const .symmetric(vertical: 5, horizontal: 12),
                  indicatorShape: _mainController.hideSideBarLabel
                      ? const RoundedRectangleBorder(
                          borderRadius: .all(.circular(12)),
                        )
                      : const RoundedRectangleBorder(
                          borderRadius: .all(.circular(16)),
                        ),
                  children: _mainController.navigationBars
                      .map(
                        (e) => NavigationDrawerDestination(
                          label: _mainController.hideSideBarLabel
                              ? Semantics(
                                  label: e.label,
                                  child: const SizedBox.shrink(),
                                )
                              : Text(e.label),
                          icon: _buildIcon(type: e),
                          selectedIcon: _buildIcon(
                            type: e,
                            selected: true,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
        );
      }
      return Obx(
        () => NavigationRail(
          groupAlignment: 0.5,
          labelType: _mainController.hideSideBarLabel ? .none : .selected,
          leading: userAndSearchVertical(),
          backgroundColor: Colors.transparent,
          onDestinationSelected: _mainController.setIndex,
          selectedIndex: _mainController.selectedIndex.value,
          destinations: _mainController.navigationBars
              .map(
                (e) => NavigationRailDestination(
                  label: Text(e.label),
                  icon: _buildIcon(type: e),
                  selectedIcon: _buildIcon(type: e, selected: true),
                ),
              )
              .toList(),
        ),
      );
    }
    return Container(
      width: 80,
      margin: .only(top: 12 + _padding.top, left: _padding.left),
      child: userAndSearchVertical(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 竖屏底栏模式下 body 铺满全屏（含状态栏），状态栏那片交给页面自己：
    // 首页、动态页是盖住状态栏的悬浮顶栏，其它页面补一个顶部内边距。
    // 两种模式下都包一层 Padding（为 0 时无副作用），这样横竖屏切换时
    // 页面的 element 不会被重建、状态不会丢。
    final bool useBottomNav = _mainController.useBottomNav;
    final EdgeInsets pagePadding = useBottomNav
        ? .only(top: _padding.top)
        : EdgeInsets.zero;
    Widget pageOf(NavigationBarType type) {
      final page = type.page;
      // 消息页自带 AppBar（会自己补状态栏内边距），和别的页面不一样：
      // 底栏模式下外层不补内边距；侧栏模式下外层 Padding 已经补过状态栏，
      // 得把 MediaQuery 的顶部安全区去掉，否则 AppBar 会再补一遍。
      // 两种模式都用同一个 _MsgPageHost（结构固定），横竖屏 / 平板切换模式时
      // 消息页的 element 不会被重建，滚动位置和 keep-alive 状态都不会丢。
      if (type == .msg) {
        return _MsgPageHost(page: page, removeTop: !useBottomNav);
      }
      return Padding(
        padding: switch (type) {
          // 首页、动态页是盖住状态栏的悬浮顶栏
          .home || .dynamics => EdgeInsets.zero,
          _ => pagePadding,
        },
        child: page,
      );
    }

    Widget child;
    if (_mainController.mainTabBarView) {
      child = TabBarView(
        controller: _mainController.controller,
        physics: const NeverScrollableScrollPhysics(),
        scrollDirection: useBottomNav ? .horizontal : .vertical,
        children: _mainController.navigationBars.map(pageOf).toList(),
      );
    } else {
      child = PageView(
        controller: _mainController.controller,
        physics: const NeverScrollableScrollPhysics(),
        children: _mainController.navigationBars.map(pageOf).toList(),
      );
    }

    Widget? sideBar;
    Widget? bottomNav;
    final EdgeInsets padding;
    if (_mainController.useBottomNav) {
      bottomNav = _bottomNav;
      if (bottomNav != null) {
        bottomNav = MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: bottomNav,
        );
      }
      padding = _padding.copyWith(top: 0, bottom: 0);
    } else {
      sideBar = DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: _colorScheme.outline.withValues(alpha: 0.06),
            ),
          ),
        ),
        child: _sideBar(),
      );
      padding = .only(top: _padding.top, right: _padding.right);
    }

    child = Material(
      child: MainLayout(
        sideBar: sideBar,
        bottomNav: bottomNav,
        body: Padding(padding: padding, child: child),
      ),
    );

    if (PlatformUtils.isMobile) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarBrightness: _colorScheme.brightness,
          statusBarIconBrightness: _colorScheme.brightness.reverse,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: _colorScheme.brightness.reverse,
        ),
        child: child,
      );
    }

    return child;
  }

  Widget _buildIcon({required NavigationBarType type, bool selected = false}) {
    final icon = selected ? type.selectIcon : type.icon;
    return switch (type) {
      .dynamics => Obx(
        () {
          final dynCount = _mainController.dynCount.value;
          return Badge(
            isLabelVisible: dynCount > 0,
            label: _mainController.dynamicBadgeMode == .number
                ? Text(dynCount.toString())
                : null,
            padding: const .symmetric(horizontal: 6),
            child: icon,
          );
        },
      ),
      .msg => msgUnreadBadge(
        mainController: _mainController,
        padding: const .symmetric(horizontal: 6),
        child: icon,
      ),
      _ => icon,
    };
  }

  Widget userAndSearchVertical() {
    return Column(
      children: [
        userAvatar(colorScheme: _colorScheme, mainController: _mainController),
        const SizedBox(height: 8),
        // 侧栏里已经有「消息」分类时，顶部不再重复放一个消息入口
        if (!_mainController.navigationBars.contains(NavigationBarType.msg))
          msgBadge(_mainController),
        IconButton(
          tooltip: '搜索',
          icon: const Icon(
            Icons.search_outlined,
            semanticLabel: '搜索',
          ),
          onPressed: () => Get.toNamed('/search'),
        ),
      ],
    );
  }
}

/// 消息页的容器。
///
/// 消息页自带 AppBar、会自己补状态栏内边距，所以：
/// * 底栏模式（body 铺到状态栏底下）：什么都不用做，让 AppBar 自己补；
/// * 侧栏模式（外层 `Padding` 已经补过状态栏）：把顶部安全区去掉，否则补两遍。
///
/// 两种模式都用这个 widget（结构固定，只有 `MediaQueryData` 变），
/// 横竖屏切换时消息页的 element 不会被重建；`MediaQuery.of` 的依赖也收在这一层，
/// 不会让整个主页跟着键盘弹起一起重建。
class _MsgPageHost extends StatelessWidget {
  const _MsgPageHost({required this.page, required this.removeTop});

  final Widget page;
  final bool removeTop;

  @override
  Widget build(BuildContext context) {
    // 结构固定（MediaQuery → page）：切换模式/横竖屏时只有数据变，element 不重建
    return MediaQuery(
      data: MediaQuery.of(context).removePadding(removeTop: removeTop),
      child: page,
    );
  }
}
