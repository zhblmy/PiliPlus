import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/custom_height_widget.dart';
import 'package:PiliPlus/common/widgets/liquid_glass.dart';
import 'package:PiliPlus/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/dynamic/dynamics_type.dart';
import 'package:PiliPlus/models/common/dynamic/up_panel_position.dart';
import 'package:PiliPlus/models/dynamics/up.dart';
import 'package:PiliPlus/pages/common/common_page.dart';
import 'package:PiliPlus/pages/dynamics/controller.dart';
import 'package:PiliPlus/pages/dynamics/widgets/up_panel.dart';
import 'package:PiliPlus/pages/dynamics_create/view.dart';
import 'package:PiliPlus/pages/dynamics_tab/view.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide DraggableScrollableSheet;

/// 分类 Tab 栏高度（与首页一致：文字垂直居中，下划线上移 6 后空隙约 6）
const double _kAppBarHeight = Style.tabBarHeight;

/// 「顶部」位置 UP 面板的高度（与 upPanelPart 里的一致）
const double _kUpPanelTopHeight = 76.0;

class DynamicsPage extends StatefulWidget {
  const DynamicsPage({super.key});

  @override
  State<DynamicsPage> createState() => _DynamicsPageState();
}

class _DynamicsPageState extends CommonPageState<DynamicsPage>
    with AutomaticKeepAliveClientMixin {
  final _dynamicsController = Get.putOrFind(DynamicsController.new);
  UpPanelPosition get upPanelPosition => _dynamicsController.upPanelPosition;
  late final MainController _mainController = Get.find<MainController>();

  @override
  bool get wantKeepAlive => true;

  Widget _createDynamicBtn(ColorScheme colorScheme, {bool isRight = true}) =>
      Container(
        // 34 高的按钮装在 42 高的分类 Tab 行里只剩 4px 余量（大字号/不同
        // 密度下容易被切到），缩到 30 并留 6px，图标同步 18 → 16
        width: 30,
        height: 30,
        margin: isRight ? const .only(right: 16) : const .only(left: 16),
        child: IconButton(
          tooltip: '发布动态',
          style: ButtonStyle(
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            backgroundColor: WidgetStatePropertyAll(
              colorScheme.secondaryContainer,
            ),
          ),
          onPressed: () => CreateDynPanel.onCreateDyn(context),
          icon: Icon(
            Icons.add,
            size: 16,
            color: colorScheme.onSecondaryContainer,
          ),
        ),
      );

  Widget upPanelPart(ColorScheme colorScheme) {
    final isTop = upPanelPosition == .top;
    final needBg = upPanelPosition.index > 2;
    return Material(
      type: needBg ? .canvas : .transparency,
      color: needBg ? colorScheme.surface : null,
      child: SizedBox(
        width: isTop ? null : 64,
        height: isTop ? _kUpPanelTopHeight : null,
        child: NotificationListener<ScrollEndNotification>(
          onNotification: (notification) {
            final metrics = notification.metrics;
            if (metrics.pixels >= metrics.maxScrollExtent - 300) {
              _dynamicsController.onLoadMore();
            }
            return false;
          },
          child: Obx(
            () => _buildUpPanel(_dynamicsController.loadingState.value),
          ),
        ),
      ),
    );
  }

  Widget _buildUpPanel(LoadingState<FollowUpModel> upState) {
    return switch (upState) {
      Loading() => const SizedBox.shrink(),
      Success(:final response) => UpPanel(
        upData: response,
        dynamicsController: _dynamicsController,
      ),
      Error() => Center(
        child: IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _dynamicsController.onReload,
        ),
      ),
    };
  }

  bool get checkPage =>
      _mainController.navigationBars[0] != .dynamics &&
      _mainController.selectedIndex.value == 0;

  @override
  bool onNotificationType1(UserScrollNotification notification) {
    if (checkPage) {
      return false;
    }
    return super.onNotificationType1(notification);
  }

  @override
  bool onNotificationType2(ScrollNotification notification) {
    if (checkPage) {
      return false;
    }
    return super.onNotificationType2(notification);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = ColorScheme.of(context);

    Widget? drawer;
    Widget? endDrawer;

    Widget? leading;
    Widget actions;

    Widget child = tabBarView(
      controller: _dynamicsController.tabController,
      children: DynamicsTabType.values
          .map((e) => DynamicsTabPage(dynamicsType: e))
          .toList(),
    );

    // 竖屏底栏模式：与首页一致，顶栏改成“盖住状态栏的液体玻璃悬浮层”，
    // 内容从它下方穿过并被模糊；其它模式（侧边栏/横屏）保持原样（顶栏参与排版）。
    // 判定用 MainLayout 布局模式的那个唯一来源（useBottomNav，等价于首页的
    // showAppBar = !useSideBar && isPortrait），避免在页面里再算一遍。
    // 这里仍然要读一次 MediaQuery.sizeOf：useBottomNav 是 MainLayout 里的普通
    // bool，本页不会因为它变化而重建；读 size 才能让旋转屏幕时本页重跑 build，
    // 否则横屏后玻璃布局会残留下来（还会把状态栏那片算两次）。
    final bool glassBar =
        _mainController.useBottomNav && MediaQuery.sizeOf(context).isPortrait;
    final double statusBarHeight = MediaQuery.viewPaddingOf(context).top;
    // 「顶部」位置的 UP 面板会像首页的搜索栏那样放进玻璃顶栏里
    final bool topPanelInGlass = glassBar && upPanelPosition == .top;
    // 面板随滚动收起 / 下拉再展开：开关与首页搜索栏共用同一个「滚动隐藏顶栏」，
    // 收起进度也共用同一个 barOffset（首页那套跟随手指的同步机制）。
    // 注：「瞬时」隐藏模式下 barOffset 为空，此处面板保持不变（不收起）。
    final RxDouble? upPanelOffset = topPanelInGlass && Pref.hideTopBar
        ? _mainController.barOffset
        : null;
    // 玻璃顶栏占掉的高度：状态栏那片 + 分类 Tab 栏（+ 顶部 UP 面板）
    final double barInset = glassBar
        ? statusBarHeight +
              _kAppBarHeight +
              (topPanelInGlass ? _kUpPanelTopHeight : 0.0)
        : 0.0;
    // 放进玻璃顶栏的顶部 UP 面板
    Widget? topPanel;

    switch (upPanelPosition) {
      case .top:
        actions = _createDynamicBtn(colorScheme);
        if (topPanelInGlass) {
          // 与首页同款：面板放进玻璃顶栏（相当于首页的搜索栏那段），
          // 列表铺满整屏，滚动时从它下面穿过并被模糊
          topPanel = upPanelPart(colorScheme);
        } else {
          child = Column(
            children: [
              Padding(
                padding: .only(top: barInset),
                child: upPanelPart(colorScheme),
              ),
              // 顶栏已经让过位了，Tab 内容不再重复让一次
              Expanded(child: TopBarInset(value: 0, child: child)),
            ],
          );
        }
      case .leftFixed:
        child = Row(
          children: [
            Padding(
              padding: .only(top: barInset),
              child: upPanelPart(colorScheme),
            ),
            Expanded(child: child),
          ],
        );
        actions = _createDynamicBtn(colorScheme);
      case .rightFixed:
        child = Row(
          children: [
            Expanded(child: child),
            Padding(
              padding: .only(top: barInset),
              child: upPanelPart(colorScheme),
            ),
          ],
        );
        actions = _createDynamicBtn(colorScheme);
      case .leftDrawer:
        drawer = upPanelPart(colorScheme);
        actions = _createDynamicBtn(colorScheme);
        leading = const DrawerButton();
      case .rightDrawer:
        endDrawer = upPanelPart(colorScheme);
        leading = _createDynamicBtn(colorScheme, isRight: false);
        actions = const EndDrawerButton();
    }

    final appBar = Row(
      children: [
        ?leading,
        Expanded(
          child: TabBar(
            dividerHeight: 0,
            isScrollable: true,
            tabAlignment: .start,
            dividerColor: Colors.transparent,
            labelColor: colorScheme.primary,
            indicatorColor: colorScheme.primary,
            // 与 M3 默认指示线（3px、圆角、primary 色）一致，只把下划线上移，
            // 让它与标签文字的距离约缩小一半（42 高的 Tab 栏下约 12 → 约 6）
            indicator: UnderlineTabIndicator(
              insets: const EdgeInsets.only(bottom: 6),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(3),
              ),
              borderSide: BorderSide(width: 3, color: colorScheme.primary),
            ),
            controller: _dynamicsController.tabController,
            unselectedLabelColor: colorScheme.onSurface,
            tabs: DynamicsTabType.values
                .map((e) => Tab(text: e.label))
                .toList(),
            onTap: (index) {
              if (!_dynamicsController.tabController.indexIsChanging) {
                _dynamicsController.animateToTop();
              }
            },
          ),
        ),
        actions,
      ],
    );

    if (!glassBar) {
      return Scaffold(
        primary: false,
        resizeToAvoidBottomInset: false,
        backgroundColor: Colors.transparent,
        appBar: PreferredSize(
          // 与首页分类 Tab 栏一致：42 高（文字垂直居中，下划线上移后空隙约 6）
          preferredSize: const .fromHeight(_kAppBarHeight),
          child: appBar,
        ),
        drawer: drawer,
        endDrawer: endDrawer,
        body: onBuild(child),
      );
    }

    // 与首页同款：状态栏那片也交给玻璃顶栏（不跟着内容收起/展开），
    // 所以内容要自己让出 inset，见 TopBarInsetSpacer。
    final Widget content = onBuild(child);

    /// 「顶部」UP 面板的当前高度（0 = 已完全收起）。
    /// barOffset 的量程是 Style.topBarHeight(52)、而面板高 76，要按比例换算，
    /// 否则收到底时面板高度减不到 0，会剩下一条空玻璃。
    double upPanelHeight() {
      if (!topPanelInGlass) return 0.0;
      if (upPanelOffset case final offset?) {
        return _kUpPanelTopHeight * (1 - offset.value / Style.topBarHeight);
      }
      return _kUpPanelTopHeight;
    }

    /// 玻璃顶栏里的「顶部」UP 面板，收起过程中按当前高度裁切。
    /// CustomHeightWidget 只会把内容往上挪、并不自己裁剪（和 AnimatedContainer
    /// 一样），所以外面必须套一层 ClipRect，否则会画到分类 Tab 栏上；
    /// 这与首页搜索栏的处理完全一致。
    Widget topPanelArea(double panelHeight) {
      final panel = topPanel;
      if (panel == null) return const SizedBox.shrink();
      if (upPanelOffset == null) return panel;
      return ClipRect(
        child: CustomHeightWidget(
          height: panelHeight,
          offset: Offset(0, panelHeight - _kUpPanelTopHeight),
          child: panel,
        ),
      );
    }

    // 与首页完全同款：顶栏是「悬浮在本页内容之上的液体玻璃层」，
    // 中间不隔 Scaffold/Material（否则 BackdropFilter 取不到下层内容，
    // 看着就是一条纯色条）。玻璃铺满整宽、盖住状态栏，内容从它下方穿过。
    //
    // 结构：状态栏那片 → 分类 Tab 栏 → 可收起的「顶部」UP 面板（在 Tab 栏下方）。
    // 性能：玻璃实例建一次，收起过程中**只重建 UP 面板那一层包装**，
    // 不会每帧重建 BackdropFilter。
    Widget glassTopBar() {
      final panel = topPanel;
      return LiquidGlass(
        shape: kGlassTopBarShape,
        blur: 16,
        color: colorScheme.surface.withValues(
          alpha: colorScheme.isDark ? 0.5 : 0.62,
        ),
        shadowColor: Colors.black.withValues(
          alpha: colorScheme.isDark ? 0.4 : 0.1,
        ),
        child: Column(
          mainAxisSize: .min,
          children: [
            SizedBox(height: statusBarHeight),
            // 卡死 42 高：Column 高度自适应时 TabBar 会按自己的
            // preferredSize(46+2=48) 把玻璃顶栏撑高，比 inset 多 6px
            SizedBox(height: _kAppBarHeight, child: appBar),
            // 「顶部」UP 面板（跟首页搜索栏一样长在玻璃上，一起收起）
            if (panel != null)
              if (upPanelOffset == null)
                panel
              else
                Obx(() => topPanelArea(upPanelHeight())),
          ],
        ),
      );
    }

    // 让内容为玻璃顶栏让位（面板收起过程中高度随之变小）
    Widget bodyWithInset() => TopBarInset(
      value: statusBarHeight + _kAppBarHeight + upPanelHeight(),
      child: content,
    );

    final Widget stack = Stack(
      children: [
        Positioned.fill(
          child: upPanelOffset == null ? bodyWithInset() : Obx(bodyWithInset),
        ),
        Positioned(top: 0, left: 0, right: 0, child: glassTopBar()),
      ],
    );

    // 抽屉模式必须要 Scaffold（DrawerButton/EndDrawerButton 要能 Scaffold.of
    // 找到它），这时玻璃只能放在 Scaffold.body 里；其余情况（默认的左/右/顶部
    // UP 面板）与首页一样，页面根就是 Stack、中间不再隔一层。
    if (drawer != null || endDrawer != null) {
      return Scaffold(
        primary: false,
        resizeToAvoidBottomInset: false,
        backgroundColor: Colors.transparent,
        drawer: drawer,
        endDrawer: endDrawer,
        body: stack,
      );
    }

    return stack;
  }
}
