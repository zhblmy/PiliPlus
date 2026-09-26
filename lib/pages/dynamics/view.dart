import 'package:PiliPlus/common/style.dart';
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
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide DraggableScrollableSheet;

/// 分类 Tab 栏高度（与首页一致：文字垂直居中，下划线上移 6 后空隙约 6）
const double _kAppBarHeight = Style.tabBarHeight;

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
        width: 34,
        height: 34,
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
            size: 18,
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
        height: isTop ? 76 : null,
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
    // 内容从它下方穿过并被模糊；其它模式保持原样（顶栏参与排版）。
    final bool glassBar =
        !_mainController.useSideBar && MediaQuery.sizeOf(context).isPortrait;
    final double statusBarHeight = MediaQuery.viewPaddingOf(context).top;
    // 玻璃顶栏占掉的高度：状态栏那片 + 分类 Tab 栏
    final double barInset = glassBar ? statusBarHeight + _kAppBarHeight : 0.0;

    switch (upPanelPosition) {
      case .top:
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
        actions = _createDynamicBtn(colorScheme);
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
    // 所以内容要自己让出 barInset，见 TopBarInsetSpacer。
    return Scaffold(
      primary: false,
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.transparent,
      drawer: drawer,
      endDrawer: endDrawer,
      body: Stack(
        children: [
          Positioned.fill(
            child: TopBarInset(value: barInset, child: onBuild(child)),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlass(
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
                  // preferredSize(46+2=48) 把玻璃顶栏撑高，比 barInset 多 6px
                  SizedBox(height: _kAppBarHeight, child: appBar),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
