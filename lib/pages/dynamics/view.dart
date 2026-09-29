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
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  final _dynamicsController = Get.putOrFind(DynamicsController.new);
  UpPanelPosition get upPanelPosition => _dynamicsController.upPanelPosition;
  late final MainController _mainController = Get.find<MainController>();

  @override
  bool get wantKeepAlive => true;

  /// 顶栏收起由滚动通知驱动（见 _onScrollNotification），不再写全局 barOffset
  @override
  bool get useBarOffset => false;

  /// 是否竖屏。
  /// `pinnedHeaderExtent` / `_panelCollapsible` 会被滚动回调读到，那里读
  /// MediaQuery 会顺手注册依赖，改成在 didChangeDependencies 里缓存一次。
  bool _isPortrait = true;

  /// 收起量程 = 「顶部」UP 面板高度，生效条件与 [_panelCollapsible] 一致；
  /// 即时模式不需要补间（动画自己会到端点）。
  @override
  double get pinnedHeaderExtent =>
      !_instant && _panelCollapsible ? _collapseExtent : 0.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isPortrait = MediaQuery.sizeOf(context).isPortrait;
  }

  @override
  ScrollController? get pinnedHeaderScrollController =>
      _dynamicsController.controller?.scrollController;

  /// 当前可见 Tab 的滚动位置（未挂载/多实例时返回 null）
  ScrollPosition? _currentScrollPosition() {
    final controller = _dynamicsController.controller?.scrollController;
    if (controller == null || !controller.hasClients) return null;
    final positions = controller.positions;
    return positions.length == 1 ? positions.first : null;
  }

  /// 顶栏当前收起进度（px，0..量程）；玻璃、让位 sliver 共用同一个值。
  ///
  /// * 同步模式：= 可见列表的滚动位置（滚动通知驱动，跟手 1:1）；
  /// * 即时模式：= 收起动画的当前进度（上滑收起、下滑出现）。
  final ValueNotifier<double> _barCollapse = ValueNotifier<double>(0.0);

  /// 即时模式的收起动画（0 = 完全展开，1 = 完全收起）
  late final AnimationController _barAnim;

  /// 当前认下的那个列表（切 Tab / 切分区会变）
  ScrollPosition? _activePosition;

  /// 「即时」模式：按滚动方向两态收起/出现
  bool get _instant => _mainController.barHideType == .instant;

  /// 收起量程 = 「顶部」UP 面板高度（玻璃里可以被收起掉的那部分）
  double get _collapseExtent => _kUpPanelTopHeight;

  /// 面板是否可收起（与 build 里的 `collapsiblePanel` 同义：
  /// 玻璃模式 + 竖屏 + 开关打开 + 面板在顶部。横屏/侧栏模式下面板参与排版，
  /// 不能跟着收起，所以这里必须和 build 判得一样）
  bool get _panelCollapsible =>
      _mainController.useBottomNav &&
      _isPortrait &&
      Pref.hideTopBar &&
      upPanelPosition == .top;

  void _onBarAnimTick() {
    // 同步模式的收起进度 = 滚动位置，动画只属于即时模式
    if (!_instant) return;
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
    _dynamicsController.tabController.addListener(_onTabChanged);
    _barAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(_onBarAnimTick);
  }

  /// 切分类：换列表了，先把收起进度对齐到新 Tab 的真实位置。
  /// 即时模式不看滚动位置，顶栏状态不跟着 Tab 重置；
  /// 面板不参与收起时（横屏/侧栏/面板不在顶部/开关关掉）没人读这个值，也不必算。
  void _onTabChanged() {
    _activePosition = null;
    if (_instant || !_panelCollapsible) return;
    if (_syncCollapseToCurrent()) return;
    // TabBarView 的页面是懒建的（在 layout 阶段才建），刚切过去时可能还没有
    // ScrollPosition。等这一帧布局结束再对齐一次，否则收起进度会留在 0。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncCollapseToCurrent();
    });
  }

  /// 把收起进度对齐到当前可见 Tab 的滚动位置；拿不到 position 返回 false
  bool _syncCollapseToCurrent() {
    final position = _currentScrollPosition();
    if (position == null) return false;
    _barCollapse.value = position.pixels.clamp(0.0, _collapseExtent);
    return true;
  }

  @override
  void dispose() {
    _dynamicsController.tabController.removeListener(_onTabChanged);
    _barAnim.dispose();
    _barCollapse.dispose();
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (!_panelCollapsible) return false;
    final metrics = notification.metrics;
    if (metrics.axis != .vertical) return false;
    final bool isUser = notification is UserScrollNotification;
    // `ScrollMetricsNotification` 不是 `ScrollNotification` 的子类（它单独在
    // metrics 变化时发），在这里判断它永远是 false。
    if (!isUser && notification is! ScrollUpdateNotification) {
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
    // 只认「当前 Tab 的列表」：保活的其他 Tab、内嵌的竖直列表（含非玻璃模式
    // 下位于 body 里的 UP 面板）都会把通知冒泡上来。
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
    // 面板随滚动收起 / 下拉再展开：与首页搜索栏共用同一个「滚动隐藏顶栏」开关。
    // 收起进度由「当前 Tab 的滚动位置」直接驱动（不再用全局 barOffset）。
    final bool collapsiblePanel = topPanelInGlass && Pref.hideTopBar;
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
    final Widget content = onBuild(
      NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: child,
      ),
    );

    /// 玻璃顶栏里的「顶部」UP 面板，收起时按当前高度裁切。
    /// CustomHeightWidget 只会把内容往上挪、并不自己裁剪（和 AnimatedContainer
    /// 一样），所以外面必须套一层 ClipRect，否则会画到分类 Tab 栏上；
    /// 这与首页搜索栏的处理完全一致。
    Widget topPanelArea(double panelHeight, Widget panel) {
      return ClipRect(
        child: CustomHeightWidget(
          height: panelHeight,
          offset: Offset(0, panelHeight - _kUpPanelTopHeight),
          child: panel,
        ),
      );
    }

    /// 用收起进度驱动面板收起（同步模式跟手 1:1；即时模式跟随收起动画）
    Widget scrollDrivenPanel(Widget panel) {
      return ValueListenableBuilder<double>(
        valueListenable: _barCollapse,
        // child 是那个静态面板实例：每帧只重建裁切那一层
        child: panel,
        builder: (context, collapse, child) => topPanelArea(
          _collapseExtent - collapse.clamp(0.0, _collapseExtent),
          child!,
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
              collapsiblePanel ? scrollDrivenPanel(panel) : panel,
          ],
        ),
      );
    }

    final Widget stack = Stack(
      children: [
        Positioned.fill(
          // 让位交给 TopBarInsetSpacer；collapse 是玻璃/让位共用的收起进度，
          // followScroll 区分「同步（滚动自己让位）」与「即时（让位跟动画收缩）」。
          // 不收起时 minValue 必须等于 value，否则内容会缩到面板里去。
          child: TopBarInset(
            value: barInset,
            // 收起后仍要保留的：状态栏那片 + 分类 Tab 栏
            minValue: barInset - (collapsiblePanel ? _collapseExtent : 0.0),
            collapse: _barCollapse,
            followScroll: !_instant,
            child: content,
          ),
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
