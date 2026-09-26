# PiliPlus Android 客户端 —— 动画完整清单（目录 / 代码位置 / 源码 / 说明）

> 本文档面向「想看动画、想改动画」的使用者。
> 项目是 **Flutter** 写的，所以 Android 端的动画全部由 Dart 代码 + Flutter 渲染引擎完成，
> `android/` 目录里（Java/Kotlin）几乎没有动画代码 —— **改动画请改 `lib/` 下的 Dart 文件**。
>
> 路径约定：所有路径都相对项目根目录 `f:\Github\PiliPlus\`。
> 行号基于 2026-09-26 的代码，改动后行号可能漂移，用「文件路径 + 关键词」搜索更稳。

---

## 第 0 章 总览：这个项目的动画是怎么实现的

### 0.1 结论速查

| 事项 | 结论 |
| --- | --- |
| 动画实现语言 | Dart（`lib/` 目录），Android 原生层无动画 |
| 是否用了第三方动画库 | **没有**。无 lottie / rive / flutter_animate / motion 等依赖 |
| 使用的框架能力 | Flutter SDK 内建的 4 类动画 + 1 个弹幕库 |
| 弹幕动画 | 由第三方包 `canvas_danmaku`（git 依赖）实现，本仓库只做开关与透明度控制 |
| 唯一的动画图片资源 | `assets/images/live/live.gif`（直播相关）；其余动效全是代码绘制 |
| 主要可调设置入口 | 设置 → 样式 → 「页面过渡动画」「滑动动画弹簧参数」；设置 → 其它 → 「首页切换页面动画」 |

### 0.2 Flutter 的四类动画（后面章节按这四类组织）

Flutter 里做动画有 4 种写法，本项目 4 种都用到了：

1. **隐式动画（Implicit Animation）**
   只改属性值，Flutter 自动补间。代表组件：`AnimatedOpacity`、`AnimatedContainer`、
   `AnimatedSlide`、`AnimatedSwitcher`、`AnimatedScale`、`AnimatedAlign`、`AnimatedSize`、
   `TweenAnimationBuilder`。
   → 见第 3、4、5 章。**改颜色/时长最简单的一类。**

2. **显式动画（Explicit Animation）**
   自己建 `AnimationController`（需要 `vsync`）+ `AnimatedBuilder`/`Transition` 组件。
   代表：`SlideTransition`、`FadeTransition`、`ScaleTransition`、`RotationTransition`、`SizeTransition`。
   → 见第 2、3、6、7、8、9、10 章。**功能最强，代码也最多。**

3. **路由转场动画（Page Transition）**
   页面跳转时的进场/退场。项目用 GetX 的 `defaultTransition` + 自定义 `Route`。
   → 见第 1 章。

4. **Hero 共享元素动画**
   两个页面之间「同一个元素飞过去」。项目大量用于图片查看。
   → 见第 5 章。

另有 2 个**自定义 RenderObject 动画**（本项目自己实现的、Flutter 官方没有的组件）：
`AnimatedHeightWidget` / `AnimatedMultiHeight`（见第 4 章），以及 1 个自定义 **Ticker + Simulation** 的跑马灯
（`marquee.dart`，见 4.3）。

### 0.3 一张表看全部动画（按「用户在哪看到」索引）

| 用户看到的动效 | 在哪个文件 | 用到的组件 | 时长 |
| --- | --- | --- | --- |
| 页面切换（进入/返回） | `lib/main.dart` + GetX | `defaultTransition` | 300ms |
| 悬浮底栏「气泡」跟随滑动 | `lib/common/widgets/floating_navigation_bar.dart` | `AnimationController` + `Transform.translate` | 500ms |
| 顶栏/底栏随滚动收起 | `lib/pages/common/common_page.dart` | `Timer` + `Curves.easeOutCubic` | 220ms |
| 底栏瞬间模式收起 | `lib/pages/main/view.dart` | `AnimatedSlide` | 500ms |
| 首页顶栏搜索框收起 | `lib/pages/home/view.dart` | `TweenAnimationBuilder` / `AnimatedContainer` / `AnimatedOpacity` | 500/300ms |
| 下拉刷新转圈 | `lib/common/widgets/refresh_indicator.dart` | `AnimationController` + `ScaleTransition` | 200ms + 无限循环 |
| 骨架屏 shimmer | `lib/common/skeleton/skeleton.dart` | 全局 `AnimationController` + `ShaderMask` | 1000ms 循环 |
| 加载指示器（M3 Expressive） | `lib/common/widgets/loading_widget/m3e_loading_indicator.dart` | `AnimationController` + `SpringSimulation` | 650ms/段 |
| 图片点开查看（放大飞入） | `lib/common/widgets/image_viewer/` | `Hero` + `FadeTransition` + `ColorTween` | 300/750ms |
| 图片双击放大/缩小 | `lib/common/widgets/image_viewer/viewer.dart` | `AnimationController` + `Matrix4` | 300ms |
| 播放器控件显隐 | `lib/plugin/pl_player/view/view.dart` | `AnimationController` | 100ms |
| 播放/暂停按钮形变 | `lib/plugin/pl_player/widgets/play_pause_btn.dart` | `AnimatedIcon` | 200ms |
| 长按倍速提示 | `lib/plugin/pl_player/view/view.dart` | `AnimatedOpacity` | 150ms |
| 视频页展开/收起（点视频全屏） | `lib/pages/video/controller.dart` | `AnimationController` + `_calcAnimHeight` | 200ms |
| 点赞数变化 | `lib/pages/dynamics/widgets/action_panel.dart` | `AnimatedSwitcher` + `ScaleTransition` | 400ms |
| 评论/屏蔽词列表增删 | `lib/pages/video/view.dart` | `AnimatedList` | 默认 |
| 拖拽排序 | `lib/pages/fav_sort/view.dart` 等 | `ReorderableListView` | 默认 |
| 投币动画 | `lib/pages/video/pay_coins/view.dart` | 4 个 `AnimationController` | 50~300ms |
| 一键三连动画 | `lib/pages/video/introduction/ugc/widgets/triple_mixin.dart` | `AnimationController` | 1200ms |
| 评论页滑入滑出 | `lib/pages/common/slide/common_slide_page.dart` | `AnimationController` + `Align` | 500ms |
| 弹幕透明度 | `lib/pages/danmaku/view.dart` | `AnimatedOpacity` | 100ms |

---

## 第 1 章 页面转场（路由）动画

### 1.1 全局默认转场：`lib/main.dart:336`

这是**所有页面跳转**的默认动画来源，改这里等于全 App 生效。

```dart
// lib/main.dart
return GetMaterialApp(
  title: Constants.appName,
  theme: light,
  darkTheme: dark,
  themeMode: ThemeUtils.themeMode = Pref.themeMode,
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  locale: const Locale("zh", "CN"),
  fallbackLocale: const Locale("zh", "CN"),
  supportedLocales: const [Locale("zh", "CN"), Locale("en", "US")],
  initialRoute: '/',
  getPages: Routes.getPages,
  defaultTransition: Pref.pageTransition,   // ← 就是这一行
  builder: FlutterSmartDialog.init(
    toastBuilder: CustomToast.new,
    loadingBuilder: LoadingWidget.new,
    notifyStyle: const FlutterSmartNotifyStyle(
      warningBuilder: NotifyWarning.new,
    ),
    builder: _builder,
  ),
  navigatorObservers: [
    routeObserver,
    FlutterSmartDialog.observer,
  ],
  ...
);
```

**说明**
- `GetMaterialApp.defaultTransition` 是 GetX 提供的参数，取值是 `Transition` 枚举
  （`native` / `fade` / `sharedAxis` / `cupertino` / `noTransition` / `zoom` …）。
- 项目把它接到用户设置 `Pref.pageTransition`，所以用户能在设置里换转场风格。

### 1.2 默认值：Android 用 `sharedAxis`（不是 Flutter 原生的 `native`）

位置：`lib/utils/storage_pref.dart:795-810`

```dart
  /// 页面过渡动画。
  ///
  /// Android 默认用 [Transition.sharedAxis]（Material X 轴推进 + 淡入，观感和
  /// Android 14 系统自带的 fade forwards 一致），而不是 [Transition.native]：
  /// native 在 Android 上走 Zoom 缩放 + 快照，**转场结束那一帧**会把快照丢掉、
  /// 让整页首次实时绘制（`_ZoomTransitionBase.onAnimationStatusChange`），体感
  /// 就是「动画收尾卡一下」。sharedAxis 不产生快照，成本被摊平到整段动画里。
  ///
  /// 另外注意：GetX 的路由不走 `ThemeData.pageTransitionsTheme`，
  /// 改 `lib/utils/theme_utils.dart` 里的 `pageTransitionsTheme` 对本 App 无效。
  static Transition get pageTransition => Transition.values[_setting.get(
    SettingBoxKey.pageTransition,
    defaultValue: _defaultPageTransition.index,
  )];

  static Transition get _defaultPageTransition => Platform.isAndroid
      ? Transition.sharedAxis
      : Transition.native;
```

**说明**
- 关键点：**想换转场动画，改 `Pref.pageTransition` 的默认值或设置项即可**。
- 注释里已写明一个坑：`lib/utils/theme_utils.dart:162` 的 `pageTransitionsTheme`
  对 GetX 命名路由**不生效**（因为 GetX 自己实现转场），不要改那里。

### 1.3 设置页里「页面过渡动画」的下拉项

位置：`lib/pages/setting/models/style_settings.dart:650-666`

```dart
Future<void> _showTransitionDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<Transition>(
    context: context,
    builder: (context) => SelectDialog<Transition>(
      title: '页面过渡动画',
      value: Pref.pageTransition,
      values: Transition.values.map((e) => (e, e.name)).toList(),
    ),
  );
  if (res != null) {
    Get.rootController.defaultTransition = res;   // 立即生效
    await GStorage.setting.put(SettingBoxKey.pageTransition, res.index);
    setState();
  }
}
```

**说明**：改完立刻写 `Get.rootController.defaultTransition`，所以不用重启就生效。
设置项列表（`Transition.values`）由 GetX 提供，可选项有
`fade`、`fadeIn`、`rightToLeft`、`leftToRight`、`upToDown`、`downToUp`、`zoom`、
`cupertino`、`size`、`native`、`sharedAxis`、`noTransition` 等。

### 1.4 自定义弹出路由 `PublishRoute`（底部滑入 / 自定义过渡）

位置：`lib/pages/common/publish/publish_route.dart`（**全文件**）

```dart
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:material_ui/material_ui.dart';

class PublishRoute<T> extends PopupRoute<T> {
  PublishRoute({
    required this.pageBuilder,
    this.barrierDismissible = true,
    this.barrierLabel,
    this.barrierColor = const Color(0x80000000),
    Duration? transitionDuration,
    this._transitionBuilder,
    super.settings,
  }) : transitionDuration =
           transitionDuration ??
           (PlatformUtils.isDesktop ? Durations.medium4 : Durations.long2);

  final RoutePageBuilder pageBuilder;

  @override
  final bool barrierDismissible;

  @override
  final String? barrierLabel;

  @override
  final Color barrierColor;

  @override
  final Duration transitionDuration;

  final RouteTransitionsBuilder? _transitionBuilder;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: pageBuilder(context, animation, secondaryAnimation),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (_transitionBuilder != null) {
      return _transitionBuilder(context, animation, secondaryAnimation, child);
    }
    return SlideTransition(                          // ← 默认：从底部滑入
      position: animation.drive(
        Tween<Offset>(
          begin: const Offset(0.0, 1.0),
          end: Offset.zero,
        ),
      ),
      child: child,
    );
  }
}
```

**说明**
- `PublishRoute` 继承 `PopupRoute`（半透明遮罩的弹出路由）。
- **默认动画 = 从屏幕底部滑上来**（`begin: Offset(0, 1)`）。
- 想换动画：调用处传 `transitionBuilder` 即可（见 1.5、1.6、1.7）。
- 时长默认桌面 `Durations.medium4`(400ms)、移动端 `Durations.long2`(500ms)；
  这些常量来自 Material 3 的 motion tokens（`material_ui` 包的 `src/motion.dart`）。
- 用 `PublishRoute` 的位置：
  `lib/utils/page_utils.dart:475`（`showVideoBottomSheet`）、
  `lib/pages/save_panel/view.dart:47`（收藏面板）、
  `lib/pages/video/pay_coins/view.dart:41`（投币页）。

### 1.5 视频底部面板：按屏幕方向决定滑入方向

位置：`lib/utils/page_utils.dart:471-510`

```dart
  static Future<void>? showVideoBottomSheet(
    BuildContext context, {
    required Widget child,
    ValueGetter<EdgeInsets>? padding,
    double maxWidth = 500,
  }) {
    if (!context.mounted) {
      return null;
    }
    return Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (context, animation, secondaryAnimation) {
          final isPortrait = context.isPortrait;
          return SafeArea(
            child: CustomFractionallySizedBox(
              maxWidth: maxWidth,
              widthFactor: isPortrait ? 1.0 : 0.5,
              heightFactor: isPortrait ? 0.7 : 1.0,
              alignment: isPortrait ? .bottomCenter : .centerRight,
              child: Padding(
                padding: isPortrait ? padding?.call() ?? .zero : .zero,
                child: child,
              ),
            ),
          );
        },
        transitionDuration: Durations.medium2,          // 300ms
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          final begin = context.isPortrait
              ? const Offset(0.0, 1.0)      // 竖屏：从下往上
              : const Offset(1.0, 0.0);     // 横屏：从右往左
          return SlideTransition(
            position: animation.drive(
              Tween<Offset>(
                begin: begin,
                end: Offset.zero,
              ).chain(CurveTween(curve: Easing.emphasizedDecelerate)),
            ),
            child: child,
          );
        },
        settings: RouteSettings(arguments: Get.arguments),
      ),
    );
  }
```

**说明**：这是「竖屏从下滑入、横屏从右滑入」的写法。
`Easing.emphasizedDecelerate` 是 M3 标准曲线（快出慢停）。**改方向/时长看这里。**

### 1.6 收藏面板：淡入

位置：`lib/pages/save_panel/view.dart:47-60`

```dart
  static void toSavePanel({dynamic upMid, dynamic item}) {
    Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (context, animation, secondaryAnimation) {
          return SavePanel(upMid: upMid, item: item);
        },
        transitionDuration: Durations.medium1,          // 250ms
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation.drive(CurveTween(curve: Easing.standard)),
            child: child,
          );
        },
        settings: RouteSettings(arguments: Get.arguments),
      ),
    );
  }
```

### 1.7 投币页：快速淡入

位置：`lib/pages/video/pay_coins/view.dart:45-58`

```dart
    Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (buildContext, animation, secondaryAnimation) {
          return PayCoinsPage(
            onPayCoin: onPayCoin,
            hasCoin: hasCoin,
            hasCopyright: hasCopyright,
          );
        },
        transitionDuration: Durations.short4,           // 200ms
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
      ),
    );
```

### 1.8 图片保存对话框：缩放弹出

位置：`lib/common/widgets/image/image_save.dart:118-125`

```dart
        ...
      },                                                     // showDialog 的 builder 结束
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          ScaleTransition(
            scale: animation,
            child: child,
          ),
    ),
  );
}
```

**说明**：`ScaleTransition(scale: animation)` 从 0 放大到 1，是「对话框弹出」的常见写法。

### 1.9 图片查看器的淡入路由 `HeroDialogRoute`

位置：`lib/common/widgets/image_viewer/hero_dialog_route.dart`（**全文件**）

```dart
import 'package:material_ui/material_ui.dart';

/// https://github.com/qq326646683/interactiveviewer_gallery

/// A [PageRoute] with a semi transparent background.
///
/// Similar to calling [showDialog] except it can be used with a [Navigator] to
/// show a [Hero] animation.
class HeroDialogRoute<T> extends PageRoute<T> {
  HeroDialogRoute({
    required this.pageBuilder,
  });

  final RoutePageBuilder pageBuilder;

  @override
  bool get opaque => false;          // 半透明 → 能看到下层的 Hero 飞行

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => Durations.medium2;   // 300ms

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
      child: child,
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: pageBuilder(context, animation, secondaryAnimation),
    );
  }
}
```

**说明**：`opaque = false` 是 Hero 动画能「看到下层页面」的关键。

### 1.10 各列表页「回到顶部」FAB 的滑入滑出

位置：`lib/pages/common/fab_mixin.dart`（**全文件**）

```dart
import 'package:material_ui/material_ui.dart';

mixin BaseFabMixin<T extends StatefulWidget> on State<T>, TickerProvider {
  late bool _isFabVisible = true;
  AnimationController get fabAnimationCtr;
  Animation<Offset> get fabAnimation;

  AnimationController _initController() {
    return AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
  }

  Animation<Offset> _initAnimation() {
    return fabAnimationCtr.drive(
      Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(0.0, 1.0),      // 向下滑出屏幕
      ).chain(CurveTween(curve: Curves.easeInOut)),
    );
  }

  void showFab() {
    if (!_isFabVisible) {
      _isFabVisible = true;
      fabAnimationCtr.reverse();
    }
  }

  void hideFab() {
    if (_isFabVisible) {
      _isFabVisible = false;
      fabAnimationCtr.forward();
    }
  }

  Widget fabAnimWrapper({required Widget child}) {
    return NotificationListener<UserScrollNotification>(
      onNotification: onNotification,
      child: child,
    );
  }

  bool onNotification(UserScrollNotification notification) {
    switch (notification.direction) {
      case .forward:
        showFab();
      case .reverse:
        hideFab();
      default:
    }
    return false;
  }
}

mixin FabMixin<T extends StatefulWidget> on BaseFabMixin<T> {
  @override
  late final AnimationController fabAnimationCtr;
  @override
  late final Animation<Offset> fabAnimation;

  @override
  void initState() {
    super.initState();
    fabAnimationCtr = _initController();
    fabAnimation = _initAnimation();
  }

  @override
  void dispose() {
    fabAnimationCtr.dispose();
    super.dispose();
  }
}

mixin LazyFabMixin<T extends StatefulWidget> on BaseFabMixin<T> {
  AnimationController? _fabAnimationCtr;
  Animation<Offset>? _fabAnimation;
  ...
}
```

**说明**：所有带 `fab: SlideTransition(position: ...)` 的页面都用这套 mixin。
想改 FAB 动画只改 `_initAnimation()`。
使用位置（grep `fab: SlideTransition`）：
`lib/pages/article/view.dart:66`、`lib/pages/dynamics_detail/view.dart:125`、
`lib/pages/dynamics_topic/view.dart:144`、`lib/pages/follow/view.dart:71`、
`lib/pages/main_reply/view.dart:84`、`lib/pages/match_info/view.dart:58`、
`lib/pages/member_opus/view.dart:81`、`lib/pages/member_video/view.dart:157`、
`lib/pages/video/reply/view.dart:122`。

---

## 第 2 章 悬浮底栏（玻璃导航栏）的动画

文件：`lib/common/widgets/floating_navigation_bar.dart`

这是本项目**最复杂、最值得看**的一个动画，位置在：
`lib/common/widgets/floating_navigation_bar.dart:68-180`（气泡滑动）+ `:440-700`（图标/文字动画）。

### 2.1 尺寸常量（想改底栏大小改这里）

位置：`lib/common/widgets/floating_navigation_bar.dart:8-20`

```dart
const double _kMaxLabelTextScaleFactor = 1.3;

/// 悬浮底栏整体尺寸
const _kNavigationHeight = 55.0;
const _kIndicatorHeight = _kNavigationHeight - 2 * _kIndicatorPaddingInt;
/// 每一格的宽度（同时也是选中气泡的宽度；整条宽 = 格数 × 该值）
const _kIndicatorWidth = 90.0;
const _kIndicatorPaddingInt = 4.0;
const _kBlurSigma = 14.0;
const _kIndicatorPadding = EdgeInsets.all(_kIndicatorPaddingInt);
const _kBorderRadius = BorderRadius.all(.circular(_kNavigationHeight / 2));
const _kNavigationShape = RoundedSuperellipseBorder(
  borderRadius: _kBorderRadius,
);
```

### 2.2 气泡跟随滑动的控制器

位置：`lib/common/widgets/floating_navigation_bar.dart:66-110`

```dart
class _FloatingNavigationBarState extends State<FloatingNavigationBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.animationDuration,       // 默认 500ms
  );

  /// 气泡滑动的起点 / 终点（单位：第几格）；动画途中再次切换时从当前位置续接
  late double _from = widget.selectedIndex.toDouble();
  late double _to = _from;

  /// 气泡当前所在的格（带小数 = 正在滑动）
  double get _position =>
      _from +
      (_to - _from) *
          Curves.easeInOutCubicEmphasized.transform(_controller.value);

  @override
  void didUpdateWidget(covariant FloatingNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animationDuration != widget.animationDuration) {
      _controller.duration = widget.animationDuration;
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _from = _position;                 // ← 关键：从「当前位置」续接，
      _to = widget.selectedIndex.toDouble();  //   所以连点不会跳变
      _controller
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
```

### 2.3 气泡的绘制（用 Transform 平移，不用改 left）

位置：`lib/common/widgets/floating_navigation_bar.dart:150-190`

```dart
    final int count = widget.destinations.length;
    final double cellWidth =
        (count * _kIndicatorWidth - 2 * _kIndicatorPaddingInt) / count;
    ...
            child: Stack(
              // 气泡宽度 == 格子宽度时会比格子略宽一点点（沿用原实现的取值），
              // 不裁剪才不会在第一/最后一格边缘切出一小块平面
              clipBehavior: Clip.none,
              children: [
                // 选中气泡只画一个，跟着选中项横向滑动
                // （用 Transform 平移，不会触发重新布局；放在格子下面）
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: _kIndicatorWidth,
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(
                        cellWidth * _position +
                            (cellWidth - _kIndicatorWidth) / 2,
                        0,
                      ),
                      child: child,
                    ),
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: _kNavigationShape,
                        color: bubbleColor,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                Row(
                  crossAxisAlignment: .stretch,
                  children: <Widget>[
                    for (int i = 0; i < count; i++)
                      Expanded(
                        child: _SelectableAnimatedBuilder(
                          duration: widget.animationDuration,
                          isSelected: i == widget.selectedIndex,
                          builder: (context, animation) {
                            return _NavigationDestinationInfo(
                              index: i,
                              ...
```

**说明**
- 用 `Transform.translate` 而**不是**改 `Positioned.left`：前者只重绘、不重新布局，性能更好。
- `clipBehavior: Clip.none` 是必需的（否则第一/最后一格边缘会被切出小平面）。

### 2.4 图标 / 文字「选中才显示」的动画

位置：`lib/common/widgets/floating_navigation_bar.dart:486-620`

```dart
class _NavigationBarDestinationLayout extends StatelessWidget {
  const _NavigationBarDestinationLayout({
    required this.icon,
    required this.iconKey,
    required this.label,
  });

  final Widget icon;
  final GlobalKey iconKey;
  final Widget label;

  @override
  Widget build(BuildContext context) {
    return _DestinationLayoutAnimationBuilder(
      builder: (context, animation) {
        return CustomMultiChildLayout(
          delegate: _NavigationDestinationLayoutDelegate(animation: animation),
          children: <Widget>[
            LayoutId(
              id: _NavigationDestinationLayoutDelegate.iconId,
              child: KeyedSubtree(key: iconKey, child: icon),
            ),
            LayoutId(
              id: _NavigationDestinationLayoutDelegate.labelId,
              child: FadeTransition(
                alwaysIncludeSemantics: true,
                opacity: animation,
                child: label,
              ),
            ),
          ],
        );
      },
    );
  }
}
```

位置插值（图标上移、文字出现在下方）：

```dart
  @override
  void performLayout(Size size) {
    double halfWidth(Size size) => size.width / 2;
    double halfHeight(Size size) => size.height / 2;

    final Size iconSize = layoutChild(iconId, BoxConstraints.loose(size));
    final Size labelSize = layoutChild(labelId, BoxConstraints.loose(size));

    final double yPositionOffset = Tween<double>(
      begin: halfHeight(iconSize),
      end: halfHeight(iconSize) + halfHeight(labelSize),
    ).transform(animation.value);
    final double iconYPosition = halfHeight(size) - yPositionOffset;

    positionChild(
      iconId,
      Offset(halfWidth(size) - halfWidth(iconSize), iconYPosition),
    );

    positionChild(
      labelId,
      Offset(
        halfWidth(size) - halfWidth(labelSize),
        iconYPosition + iconSize.height,
      ),
    );
  }
```

**说明**：选中时图标向上让位、文字淡入 —— 这是 `NavigationBar` 的标准行为，
但这里是**手写**的（`CustomMultiChildLayout` + `MultiChildLayoutDelegate`）。

### 2.5 旧的 `NavigationIndicator`（已弃用，可删）

位置：`lib/common/widgets/floating_navigation_bar.dart:440-540`

```dart
class _NavigationIndicator extends StatelessWidget {
  const _NavigationIndicator({
    super.key,
    required this.animation,
    this.color,
    this.width = _kIndicatorWidth,
    this.height = _kIndicatorHeight,
  });

  final Animation<double> animation;
  final Color? color;
  final double width;
  final double height;

  static final _anim = Tween<double>(
    begin: .5,
    end: 1.0,
  ).chain(CurveTween(curve: Curves.easeInOutCubicEmphasized));

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final double scale = animation.isDismissed
            ? 0.0
            : _anim.evaluate(animation);
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(scale, 1.0, 1.0),
          child: child,
        );
      },
      ...
```

**说明**：这个类是**旧的「就地缩放淡入」气泡**，改成「单个气泡跟随滑动」后，
全库已无人引用（类保留未删）。**看到它不要改，直接忽略。**

---

## 第 3 章 顶栏 / 底栏随滚动收起

### 3.1 拖动跟手 + 抬手后的「收尾补间」

位置：`lib/pages/common/common_page.dart:73-180`

```dart
  /// 记录本次位移：收尾补间靠累计方向判断该收起还是展开。
  /// 一旦又有滚动位移，说明手指/惯性重新接管，立即停掉收尾动画。
  void _trackOffset(double scrollDelta) {
    _gestureDelta += scrollDelta;
    _pendingSettle = true;
    _stopSettle();
  }

  void _updateOffset(double scrollDelta) {
    _trackOffset(scrollDelta);
    _barOffset!.value = clampDouble(
      _barOffset!.value + scrollDelta,
      0.0,
      Style.topBarHeight,
    );
  }

  void _stopSettle() {
    _settleTimer?.cancel();
    _settleTimer = null;
  }

  /// 滚动结束后把栏滑到底（完全收起 / 完全展开）：
  /// 拖动时依旧 1:1 跟随手指，抬手后补一段缓出动画，
  /// 这样惯性滑动、慢速拖动都不会把栏留在半路。
  void _settleBarOffset() {
    final barOffset = _barOffset;
    if (barOffset == null) return;
    final double from = barOffset.value;
    final double to;
    if (_gestureDelta > 0) {
      // 内容上滑 → 完全收起
      to = Style.topBarHeight;
    } else if (_gestureDelta < 0) {
      // 内容下滑 → 完全展开
      to = 0.0;
    } else {
      // 方向未知（位移被别的 ScrollEnd 清掉了）：就近收尾，总之别留在半路
      to = from < Style.topBarHeight / 2 ? 0.0 : Style.topBarHeight;
    }
    if (from == to) return;
    _stopSettle();
    final double delta = to - from;
    final stopwatch = Stopwatch()..start();
    // 上一次写入的值：barOffset 是所有页面共用的，中途被别人改过就让位
    double last = from;
    _settleTimer = Timer.periodic(_settleStep, (_) {
      final double elapsed = stopwatch.elapsedMilliseconds / _settleDuration;
      if (elapsed >= 1.0) {
        barOffset.value = to;
        _stopSettle();
        return;
      }
      if ((barOffset.value - last).abs() > 0.001) {
        // 别的页滚动 / 返回首页把 offset 归零 等等：不再抢这个值
        _stopSettle();
        return;
      }
      final double value = from + delta * Curves.easeOutCubic.transform(elapsed);
      barOffset.value = value;
      last = value;
    });
  }
```

**说明**
- 时长：`_settleStep` = 16ms 一帧，`_settleDuration` = 220ms，曲线 `Curves.easeOutCubic`。
- **注意**：这个动画**不是** `Animated*` 组件，而是「`Timer.periodic` + 手动算曲线」。
  想改成更顺滑可以换成 `AnimationController`，但注释里列了 3 道防线（别删），改动要小心。

### 3.2 底栏「瞬间」模式：`AnimatedSlide`

位置：`lib/pages/main/view.dart:417-440`

```dart
      if (_mainController.hideBottomBar) {
        if (_mainController.barOffset case final barOffset?) {
          return Obx(
            () => FractionalTranslation(
              translation: Offset(
                0.0,
                barOffset.value / Style.topBarHeight,
              ),
              child: bottomNav,
            ),
          );
        }
        if (_mainController.showBottomBar case final showBottomBar?) {
          return Obx(
            () => AnimatedSlide(
              curve: Curves.easeInOutCubicEmphasized,
              duration: const Duration(milliseconds: 500),
              offset: Offset(0, showBottomBar.value ? 0 : 1),
              child: bottomNav,
            ),
          );
        }
      }
```

**说明**：`sync` 模式用 `FractionalTranslation`（跟手、无补间）；
`instant` 模式用 `AnimatedSlide`（500ms 整体收起）。

### 3.3 首页玻璃顶栏搜索框的收起动画

位置：`lib/pages/home/view.dart:150-260`

```dart
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
```

```dart
    if (_homeController.hideTopBar) {
      if (_mainController.barOffset case final barOffset?) {
        final offset = barOffset.value;
        return (
          CustomHeightWidget(                    // ← 跟手：直接改高度 + 偏移
            offset: Offset(0, -offset),
            height: Style.topBarHeight - offset,
            child: Padding(padding: padding, child: child),
          ),
          Style.topBarHeight - offset,
        );
      }
      if (_homeController.showTopBar case final showTopBar?) {
        final showSearchBar = showTopBar.value;
        return (
          AnimatedOpacity(                        // ← 整体模式：淡出
            opacity: showSearchBar ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            child: AnimatedContainer(              // ← + 高度变 0
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
```

**说明**：这里同时用了 `TweenAnimationBuilder`、`AnimatedOpacity`、`AnimatedContainer`
三种隐式动画，外加自定义的 `CustomHeightWidget`（见 4.5）。
`ClipRect` 是必需的（`lib/pages/home/view.dart:186`），否则收起的内容会画到状态栏区域。

### 3.4 「首页切换页面动画」开关（TabBarView vs PageView）

位置：`lib/pages/main/controller.dart:84`、`lib/pages/main/view.dart:528`

```dart
    controller = mainTabBarView
        ? TabController(
            vsync: this,
            initialIndex: selectedIndex.value,
            length: navigationBars.length,
          )
        : PageController(initialPage: selectedIndex.value);
```

```dart
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
```

**说明**：开关在设置 → 其它 → 「首页切换页面动画」（`lib/pages/setting/models/extra_settings.dart:325`）。
开 = `TabBarView`（切换有滑动动画），关 = `PageView`（切换瞬间完成）。

### 3.5 切换页面的「弹簧参数」也是可调的

位置：`lib/common/widgets/scroll_physics.dart:17-38`

```dart
SpringDescription kSpringDescription = _customSpringDescription();

SpringDescription _customSpringDescription() {
  final List<double> springDescription = Pref.springDescription;
  return SpringDescription(
    mass: springDescription[0],
    stiffness: springDescription[1],
    damping: springDescription[2],
  );
}

const tabBarScrollPhysics = _TabBarViewScrollPhysics();

class _TabBarViewScrollPhysics extends ClampingScrollPhysics {
  const _TabBarViewScrollPhysics({super.parent});

  @override
  _TabBarViewScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _TabBarViewScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring => kSpringDescription;
}
```

**说明**：设置 → 样式 → 「滑动动画弹簧参数」（`lib/pages/setting/models/style_settings.dart:347`）
可以调 `mass / stiffness / damping`，也可以按「时长 + 弹性(bounce)」换算。

---

## 第 4 章 通用动画组件库 `lib/common/widgets/`

> 这一章的组件是整个 App 复用的「动画积木」。改一个，全 App 一起变。

### 4.1 `AnimatedHeightWidget` / `AnimatedHeightExt` —— 高度展开收起（自定义 RenderObject）

文件：`lib/common/widgets/animated_height.dart`（**全文件重点**）

```dart
class AnimatedHeightWidget extends StatefulWidget {
  const AnimatedHeightWidget({
    super.key,
    required this.child,
    this.curve = Curves.linear,
    required this.duration,
    this.reverseDuration,
    this.clipBehavior = .hardEdge,
    required this.expand,
  });

  final Widget child;
  final Curve curve;
  final Duration duration;
  final Duration? reverseDuration;
  final Clip clipBehavior;
  final bool expand;

  @override
  State<AnimatedHeightWidget> createState() => _AnimatedHeightWidgetState();
}

class _AnimatedHeightWidgetState extends State<AnimatedHeightWidget>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    return AnimatedHeight(
      curve: widget.curve,
      duration: widget.duration,
      reverseDuration: widget.reverseDuration,
      vsync: this,
      clipBehavior: widget.clipBehavior,
      expand: widget.expand,
      child: widget.child,
    );
  }
}
```

真正干活的是 RenderObject：

```dart
/// ref [RenderAnimatedSize]
class RenderAnimatedHeight extends RenderProxyBox {
  RenderAnimatedHeight({
    required this._vsync,
    required Duration duration,
    Duration? reverseDuration,
    this._curve = Curves.linear,
    this._clipBehavior = .hardEdge,
    required this._expand,
  }) {
    _controller =
        AnimationController(
          vsync: vsync,
          value: expand ? 1.0 : 0.0,
          duration: duration,
          reverseDuration: reverseDuration,
        )..addListener(() {
          if (_controller.value != _lastValue) {
            markNeedsLayout();       // ← 每帧只重新布局，不 rebuild widget 树
          }
        });
  }

  bool _expand;
  bool get expand => _expand;
  set expand(bool value) {
    if (_expand == value) return;
    _expand = value;
    _lastValue = 0.0;
    _controller.forward(from: 0);    // ← 每次都从头跑（保证展开/收起对称）
  }
  ...
```

**它和官方 `AnimatedSize` 的区别**：这个是「展开时从 0 长到子组件真实高度」，
语义更像 `AnimatedCrossFade` 的 size 部分，而且**支持 `reverseDuration`**。
`AnimatedHeightWidgetExt` 是它的简化版（`expand` 变化时自动播放，不需要外部管理）。

**使用位置**
- `lib/pages/dynamics_repost/view.dart:120`（转发动态的展开面板）
- `lib/pages/pgc_index/view.dart:79`（番剧索引筛选面板）
- `lib/pages/video/introduction/ugc/view.dart:144`
- `lib/pages/setting/pages/color_select.dart:192`
  ```dart
  Widget _buildColorPanel() {
    final currentColor = ctr.currentColor.value;
    return AnimatedHeightWidgetExt(
      expand: !ctr.dynamicColor.value,
      duration: const Duration(milliseconds: 200),
      child: Wrap(spacing: 22, runSpacing: 18, alignment: .center, children: [
  ```

### 4.2 `AnimatedMultiHeight` + `ExpandablePanel` —— 折叠面板

文件：`lib/common/widgets/animated_multi_height.dart`（跟 4.1 几乎一样，多了 `onEnd` 回调）
和 `lib/common/widgets/expandable.dart`（**全文件**）

```dart
import 'package:PiliPlus/common/widgets/animated_multi_height.dart';
import 'package:material_ui/material_ui.dart';

class ExpandablePanel extends StatelessWidget {
  final bool expand;
  final Widget collapsed;
  final Widget expanded;

  const ExpandablePanel({
    super.key,
    required this.expand,
    required this.collapsed,
    required this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    return _AnimatedCross(
      alignment: .topLeft,
      firstChild: collapsed,
      secondChild: expanded,
      sizeCurve: Curves.linear,
      crossFadeState: expand ? .showSecond : .showFirst,
      duration: const Duration(milliseconds: 300),
    );
  }
}
```

**说明**：`ExpandablePanel` = 「收起态 + 展开态两个 widget 二选一 + 高度动画 + 淡入淡出」，
是 `AnimatedCrossFade` 的加强版（官方 `AnimatedCrossFade` 不能只做高度动画）。

### 4.3 跑马灯 `MarqueeText`（自定义 Ticker + Simulation）

文件：`lib/common/widgets/marquee.dart`

```dart
class MarqueeText extends StatelessWidget {
  ...
  @override
  Widget build(BuildContext context) { ... }
}

abstract class Marquee extends SingleChildRenderObjectWidget { ... }

class NormalMarquee extends Marquee { ... }   // 一直往一个方向滚
class BounceMarquee extends Marquee { ... }    // 来回反弹

abstract class MarqueeRender extends RenderBox ... {
  ...
  bool get hasTicker => _ticker._ticker != null;

  @override
  bool get isRepaintBoundary => hasTicker;

  void paintCenter(PaintingContext context, Offset offset) {
    if (_direction == Axis.horizontal) {
      context.paintChild(child!, Offset(offset.dx - _distance / 2, offset.dy));
    } else {
      context.paintChild(child!, Offset(offset.dx, offset.dy - _distance / 2));
    }
  }

  void _onTick(Duration elapsed) {
    delta = _simulation!.x(
      elapsed.inMicroseconds.toDouble() / Duration.microsecondsPerSecond,
    );
  }

  void updateSize();
}

class _MarqueeSimulation extends Simulation { ... }

class ContextSingleTicker implements TickerProvider { ... }
```

**说明**：这是**纯手写**的动画 —— 用 `Ticker` + `Simulation`（物理模拟）驱动 `RenderBox` 重绘，
没有用 `AnimationController`。改动风险高，一般只改 `velocity`（滚动速度）、`spacing`。

### 4.4 M3 Expressive 加载指示器

文件：`lib/common/widgets/loading_widget/m3e_loading_indicator.dart:46-130`

```dart
class _M3ELoadingIndicatorState extends State<M3ELoadingIndicator>
    with SingleTickerProviderStateMixin {
  static const int _morphIntervalMs = 650;
  static const double _fullRotation = 2 * math.pi;
  static const int _globalRotationDurationMs = 4666;
  static const double _quarterRotation = _fullRotation / 4;

  late final List<Morph> _morphs;
  late final AnimationController _controller;

  int _morphIndex = 1;
  double _morphRotationTarget = _quarterRotation;

  static final _morphAnimationSpec = SpringSimulation(
    SpringDescription.withDampingRatio(ratio: 0.6, stiffness: 200.0, mass: 1.0),
    0.0,
    1.0,
    5.0,
    snapToEnd: true,
  );

  void _statusListener(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _startAnimation();          // ← 每一段结束就接着下一段（无限循环）
    }
  }

  void _startAnimation() {
    _morphIndex++;
    _morphRotationTarget =
        (_morphRotationTarget + _quarterRotation) % _fullRotation;
    _controller.animateWith(_morphAnimationSpec);   // 弹簧驱动
  }

  @override
  void initState() {
    super.initState();
    _morphs = widget.morphs ?? Morphs.loadingMorphs;
    _controller =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: _morphIntervalMs),
          )
          ..addStatusListener(_statusListener)
          ..animateWith(_morphAnimationSpec);
  }
  ...
  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? ColorScheme.of(context).secondaryFixedDim;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        return RawM3ELoadingIndicator(
          morph: _morphs[_morphIndex % _morphs.length],
          progress: progress,
          angle: _calcAngle(progress),
          color: color,
          size: widget.size,
        );
      },
    );
  }
}
```

**说明**：这是 Material 3 Expressive 的「形状形变」加载动画（圆形→方形→三角…），
用**弹簧模拟**（`SpringSimulation`）驱动，比普通线性插值更有「弹性」。
改形状序列 → 改 `Morphs.loadingMorphs`；改节奏 → `_morphIntervalMs`。

### 4.5 下拉刷新转圈

位置：`lib/common/widgets/refresh_indicator.dart`（**全文件**）

```dart
class _RefreshIndicatorState extends State<RefreshIndicator_>
    with TickerProviderStateMixin {
  late final AnimationController _scaleController;
  late final AnimationController _progressController;
  late Color _color;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _progressController = AnimationController(
      vsync: this,
      duration: CircularProgressIndicator.defaultAnimationDuration,
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(RefreshIndicator_ oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRefreshing != widget.isRefreshing) {
      if (widget.isRefreshing) {
        _scaleController.value = 1;
        _progressController
          ..value = 0.0
          ..repeat();                      // ← 无限循环
      } else {
        _scaleController.reverse();        // ← 缩回去
        _progressController.stop();
      }
    }
  }
  ...
  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleController,
      child: Center(
        child: SizedBox.square(
          dimension: 40,
          child: Material(
            type: .circle,
            elevation: 2.0,
            color: _color,
            child: Padding(
              padding: const .all(6),
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                controller: _progressController,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

**说明**：刷新中 = 圆圈「弹出来（200ms）+ 无限旋转」；结束 = 缩回去。
外面还有 `lib/common/widgets/refresh_layout.dart`（负责把转圈位置避让玻璃顶栏，不是动画）。

### 4.6 选择遮罩（对勾放大弹出）

位置：`lib/common/widgets/select_mask.dart`（**全文件**）

```dart
import 'package:PiliPlus/common/style.dart';
import 'package:material_ui/material_ui.dart';

Widget selectMask(
  ColorScheme colorScheme,
  bool checked, {
  BorderRadiusGeometry borderRadius = Style.mdRadius,
}) {
  return AnimatedOpacity(
    opacity: checked ? 1 : 0,
    duration: const Duration(milliseconds: 200),
    child: Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        color: Colors.black.withValues(alpha: 0.6),
      ),
      child: AnimatedScale(
        scale: checked ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: colorScheme.surface.withValues(alpha: 0.8),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.done_all_outlined,
            color: colorScheme.primary,
            semanticLabel: '取消选择',
          ),
        ),
      ),
    ),
  );
}
```

### 4.7 颜色切换专用 `ColoredBoxTransition`

位置：`lib/common/widgets/colored_box_transition.dart`（**全文件**）

```dart
import 'package:material_ui/material_ui.dart';

class ColoredBoxTransition extends AnimatedWidget {
  const ColoredBoxTransition({
    super.key,
    required this.color,
    this.child,
  }) : super(listenable: color);

  final Animation<Color?> color;

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color.value!,
      child: child,
    );
  }
}
```

**说明**：`AnimatedWidget` 是最省代码的显式动画写法（不用 `AnimatedBuilder`）。
主要用于图片查看器背景色从黑到透明的渐变。

### 4.8 底部弹窗（BottomSheet）的进场动画

位置：`lib/common/widgets/scaffold/mini_scaffold.dart:196-222`

```dart
class _StandardBottomSheetState extends StandardBottomSheetState {
  @override
  Widget build(BuildContext context) {
    final child = BottomSheet_(
      animationController: widget.animationController,
      enableDrag: widget.enableDrag,
      onDragStart: handleDragStart,
      onDragEnd: handleDragEnd,
      onClosing: widget.onClosing!,
      builder: widget.builder,
      constraints: widget.constraints,
    );
    if (widget.enableDrag) {
      return AnimatedBuilder(
        animation: widget.animationController,
        builder: (context, child) => Align(
          alignment: AlignmentDirectional.topStart,
          heightFactor: animationCurve.transform(
            widget.animationController.value,
          ),
          child: child,
        ),
        child: child,
      );
    }
    return AnimatedBuilder(
      animation: widget.animationController,
      builder: (context, child) => Opacity(
        opacity: widget.animationController.value,
        child: child,
      ),
      child: child,
    );
  }
}
```

**说明**：用 `Align(heightFactor:)` 做高度动画（而不是 `SizeTransition`），
配合 `Opacity` 就是「从底部推开 + 淡入」。

### 4.9 滚动时 AppBar 标题淡入

位置：`lib/common/widgets/dynamic_sliver_app_bar/dynamic_sliver_app_bar.dart:113-125`

```dart
    final bool isScrolledUnder =
        overlapsContent ||
        forceElevated ||
        (shrinkOffset > maxExtent - minExtent);
    final effectiveTitle = AnimatedOpacity(
      opacity: isScrolledUnder ? 1 : 0,
      duration: const Duration(milliseconds: 500),
      curve: const Cubic(0.2, 0.0, 0.0, 1.0),      // ← M3 emphasized 曲线
      child: title,
    );
```

---

## 第 5 章 图片与 Hero（共享元素）动画

### 5.1 Hero 的封装：`fromHero`

位置：`lib/common/widgets/image_viewer/hero.dart`（**全文件**）

```dart
import 'package:flutter/widgets.dart';

Widget fromHero({
  required Object tag,
  required Widget child,
}) => Hero(
  tag: tag,
  createRectTween: createEndRectTween,
  child: child,
);

RectTween createEndRectTween(Rect? begin, Rect? end) {
  if (begin != null && end != null) {
    final endWidth = end.width;
    final endHeight = end.height;
    // TODO: use real image rect
    final beginRect = Rect.fromLTWH(
      begin.left + (begin.width - endWidth) / 2,
      begin.top + (begin.height - endHeight) / 2,
      endWidth,
      endHeight,
    );
    return RectTween(begin: beginRect, end: end);
  }
  return RectTween(begin: begin, end: end);
}
```

**说明**
- `fromHero({tag, child})` 是项目对 `Hero` 的统一封装，**加了个自定义 `RectTween`**：
  让「小图」在飞行时保持和「大图」相同的宽高比（居中裁剪），而不是被拉伸变形。
- **想改 Hero 的飞行轨迹/形变，改 `createEndRectTween`。**

### 5.2 图片查看器：背景淡出 + 750ms 控制

位置：`lib/common/widgets/image_viewer/gallery_viewer.dart:103-180`

```dart
  late final AnimationController _animateController;
  late final Animation<Color?> _opacityAnimation;
  ...
    _animateController = AnimationController(
      duration: const Duration(
        milliseconds: 750,
      ), // reverse only if value <= 0.2
      vsync: this,
    );

    _opacityAnimation = _animateController.drive(
      ColorTween(
        begin: Colors.black,
        end: Colors.transparent,
      ),
    );
```

**说明**：这个控制器驱动**背景从纯黑到透明**（退出时反向）。
`_opacityAnimation` 用 `ColorTween` + `ColoredBoxTransition`（4.7）实现。

同文件里还有让网格图片变成 Hero 的代码：

```dart
    return Hero(tag: '${item.url}${widget.tag}', child: child);
```

位置：`lib/common/widgets/image_viewer/gallery_viewer.dart:529`

### 5.3 单张图片查看器：双击缩放 / 惯性滑动

位置：`lib/common/widgets/image_viewer/viewer.dart:107-280`

```dart
  Offset? _downPos;
  late final AnimationController _animationController;

  late double _scaleFrom, _scaleTo;
  late Offset _positionFrom, _positionTo;

  void _listener() {
    final t = Curves.easeOut.transform(_animationController.value);
    _scale = t.lerp(_scaleFrom, _scaleTo);
    _position = Offset.lerp(_positionFrom, _positionTo, t)!;
    setState(() {});
  }
  ...
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(_listener);
```

双击时算好起止点再跑：

```dart
  void _handleDoubleTap() {
    if (!mounted) return;
    if (_animationController.isAnimating) return;
    _scaleFrom = _scale;
    _positionFrom = _position;

    double endScale;
    if (_scale == widget.minScale) {
      endScale = widget.maxScale * 0.6;
      if (endScale <= widget.minScale) {
        endScale = widget.maxScale;
      }
    } else {
      endScale = widget.minScale;
    }
    final position = _clampPosition(
      Offset.lerp(_downPos!, _position, endScale / _scale)!,
      endScale,
    );

    _scaleTo = endScale;
    _positionTo = position;

    _animationController
      ..duration = const Duration(milliseconds: 300)
      ..forward(from: 0);
  }
```

**说明**：这是 `Matrix4` + `AnimationController` 手写的「双击放大/缩小」，
比 `InteractiveViewer` 更可控（能限制长图边界）。手势动画见同文件的 `_onScaleStart`。

鼠标滚轮缩放（桌面端）在 `lib/common/widgets/gesture/mouse_interactive_viewer.dart:84-100, 455-500`：

```dart
class _MouseInteractiveViewerState extends State<MouseInteractiveViewer>
    with TickerProviderStateMixin {
  late AnimationController _controller;
  late AnimationController _scaleController;
  ...
          Tween<Offset>(...)
          Tween<double>(...)
  ...
    _controller = AnimationController(vsync: this);
    _scaleController = AnimationController(vsync: this);
```

### 5.4 所有 Hero 使用位置（想找「哪张图点开会飞」看这里）

| 位置 | 说明 |
| --- | --- |
| `lib/common/widgets/image_grid/image_grid_view.dart:254` | 动态九宫格 → 查看器 |
| `lib/common/widgets/image_viewer/gallery_viewer.dart:529` | 查看器里的图片本体 |
| `lib/pages/article/widgets/html_render.dart:59` | 专栏文章内图片 |
| `lib/pages/article/widgets/opus_content.dart:271` | 图文动态内图片 |
| `lib/pages/article/view.dart:533` | 专栏封面 |
| `lib/pages/audio/view.dart:926` | 音频封面 |
| `lib/pages/dynamics/widgets/module_panel.dart:253` | 动态卡片封面 |
| `lib/pages/fav_detail/view.dart:397` | 收藏夹某条视频封面 |
| `lib/pages/fav/video/widgets/item.dart:45` | 收藏的视频 |
| `lib/pages/member/widget/user_info_card.dart:544,642,697` | 用户头像/横幅 |
| `lib/pages/mine/widgets/item.dart:51` | 我的页头像 |
| `lib/pages/music/view.dart:435` | 音乐封面 |
| `lib/pages/subscription/widgets/item.dart:74` | 订阅封面 |
| `lib/pages/subscription_detail/view.dart:131` | 订阅详情封面 |
| `lib/pages/video/introduction/pgc/view.dart:149` | 番剧介绍页封面 |
| `lib/pages/whisper_detail/widget/chat_item.dart:630` | 私信图片 |

**改 Hero 动画的做法**：所有地方都调 `fromHero(...)`，改 `hero.dart` 的
`createRectTween` 或 `Hero` 参数即可全局生效。

---

## 第 6 章 视频播放器动画 `lib/plugin/pl_player/`

> 播放器是本项目动画最密集的模块。

### 6.1 控制条显隐的总控制器（100ms）

位置：`lib/plugin/pl_player/view/view.dart:131-135`、`188-230`、`263-267`

```dart
class _PLVideoPlayerState extends State<PLVideoPlayer>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late AnimationController _animationController;
  ...
```

```dart
  int? tmpSubtitlePaddingB;
  StreamSubscription? _controlsListener;
  void _onControlChanged(bool val) {
    final visible = val && !plPlayerController.controlsLock.value;

    if ((widget.headerControl.key as GlobalKey<TimeBatteryMixin>).currentState
        case final state?) {
      if (state.mounted) {
        state.getBatteryLevelIfNeeded();
        state.provider
          ?..startIfNeeded()
          ..muted = !visible;
        if (visible) {
          state.startClock();
        } else {
          state.stopClock();
        }
      }
    }

    if (visible) {
      _animationController.forward();      // ← 控件显示
    } else {
      _animationController.reverse();      // ← 控件隐藏
    }
    ...
  }
```

```dart
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
```

**说明**：`plPlayerController.showControls` 是个 Rx 流，值一变就正放/倒放这个控制器，
100ms 内淡入淡出上下控制栏。**改播放器控件显隐速度就改这个 100ms。**

### 6.2 上下控制栏的位置动画 `AppBarAni`

位置：`lib/plugin/pl_player/widgets/app_bar_ani.dart`（**全文件**）

```dart
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:material_ui/material_ui.dart';

class AppBarAni extends StatelessWidget {
  const AppBarAni({
    super.key,
    required this.child,
    required this.controller,
    required this.isTop,
    required this.isFullScreen,
    required this.removeSafeArea,
  });

  final Widget child;
  final AnimationController controller;
  final bool isTop;
  final bool isFullScreen;
  final bool removeSafeArea;

  static final _topPos = Tween<Offset>(
    begin: const Offset(0.0, -1.0),      // 从屏幕上方外面滑进来
    end: Offset.zero,
  );

  static const _topDecoration = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: <Color>[
      Colors.transparent,
      Color(0xBF000000),                  // 黑色渐变蒙版，让白字更清楚
    ],
    tileMode: TileMode.mirror,
  );

  static final _bottomPos = Tween<Offset>(
    begin: const Offset(0, 1.2),          // 从屏幕下方外面滑进来
    end: Offset.zero,
  );

  static const _bottomDecoration = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[
      Colors.transparent,
      Color(0xBF000000),
    ],
    tileMode: TileMode.mirror,
  );

  @override
  Widget build(BuildContext context) { ... }
}
```

**说明**：顶部栏从 `-1.0`（屏幕上方外）滑入，底部栏从 `1.2`（屏幕下方外）滑入，
配合黑→透明的渐变蒙版。**改滑入距离/方向改 `_topPos` / `_bottomPos`。**

### 6.3 播放/暂停按钮的形变

位置：`lib/plugin/pl_player/widgets/play_pause_btn.dart`（**全文件**）

```dart
class PlayOrPauseButtonState extends State<PlayOrPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  late final StreamSubscription<bool> subscription;
  late Player player;

  @override
  void initState() {
    super.initState();
    player = widget.plPlayerController.videoPlayerController!;
    controller = AnimationController(
      vsync: this,
      value: player.state.playing ? 1 : 0,
      duration: const Duration(milliseconds: 200),
    );
    subscription = player.stream.playing.listen((playing) {
      if (playing) {
        controller.forward();
      } else {
        controller.reverse();
      }
    });
  }

  @override
  void dispose() {
    subscription.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      height: 34,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.plPlayerController.onDoubleTapCenter,
        child: Center(
          child: AnimatedIcon(
            semanticLabel: player.state.playing ? '暂停' : '播放',
            progress: controller,
            icon: AnimatedIcons.play_pause,      // ← 官方内置的「播放↔暂停」形变
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}
```

**说明**：`AnimatedIcons.play_pause` 是 Flutter 官方内置的图标动画，
三角形↔双竖线之间做形变，比自己写容易得多。200ms。

### 6.4 长按倍速提示（150ms 淡入）

位置：`lib/plugin/pl_player/view/view.dart:1400-1445`

```dart
        /// 长按倍速 toast
        if (!isLive)
          IgnorePointer(
            ignoring: true,
            child: Align(
              alignment: Alignment.topCenter,
              child: FractionalTranslation(
                translation: isFullScreen
                    ? const Offset(0.0, 1.2)
                    : const Offset(0.0, 0.8),
                child: Obx(
                  () => AnimatedOpacity(
                    curve: Curves.easeInOut,
                    opacity: plPlayerController.longPressStatus.value
                        ? 1.0
                        : 0.0,
                    duration: const Duration(milliseconds: 150),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        color: Color(0x88000000),
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                      child: Obx(
                        () => Text(
                          '${plPlayerController.enableAutoLongPressSpeed ? (plPlayerController.longPressStatus.value ? plPlayerController.lastPlaybackSpeed : plPlayerController.playbackSpeed) * 2 : plPlayerController.longPressSpeed}倍速中',
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
```

### 6.5 拖动进度的时间提示（150ms 淡入）

位置：`lib/plugin/pl_player/view/view.dart:1448-1490`

```dart
        /// 时间进度 toast
        if (!isLive)
          IgnorePointer(
            ignoring: true,
            child: Align(
              alignment: Alignment.topCenter,
              child: FractionalTranslation(
                translation: isFullScreen
                    ? const Offset(0.0, 1.2)
                    : const Offset(0.0, 0.8),
                child: Obx(
                  () => AnimatedOpacity(
                    curve: Curves.easeInOut,
                    opacity: plPlayerController.isSeeking.value ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 150),
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Color(0x88000000),
                        borderRadius: BorderRadius.all(Radius.circular(64)),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                      child: Row(
                        ...
```

### 6.6 播放器其它相关文件（动画较少，列出便于查找）

| 文件 | 作用 |
| --- | --- |
| `lib/plugin/pl_player/widgets/bottom_control.dart` | 底部控制栏（进度条、倍速、全屏按钮） |
| `lib/plugin/pl_player/widgets/forward_seek.dart` / `backward_seek.dart` | 快进/快退按钮（双击快进的提示） |
| `lib/plugin/pl_player/widgets/common_btn.dart` | 通用图标按钮 |
| `lib/plugin/pl_player/widgets/mpv_convert_webp.dart` | 视频转 GIF/WebP（`late final` mpv 初始化） |
| `lib/plugin/pl_player/view/view.dart:384` | `_animationController.dispose()`（记得配对释放） |

---

## 第 7 章 视频详情页的「展开 / 收起」动画

这是「点一下视频就放大、往下滑就缩小」的核心动画。

### 7.1 控制器：`lib/pages/video/controller.dart:186-230`

```dart
  late bool isExpanding = false;
  late bool isCollapsing = false;

  late double minVideoHeight;
  late double maxVideoHeight;
  late double videoHeight;
  late double animHeight;

  AnimationController? animController;
  AnimationController get animationController =>
      animController ??= (AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      )..addListener(_animListener));

  void refreshPage() {
    scrollKey.currentState?.refresh();
  }

  void _animListener() {
    if (animationController.isForwardOrCompleted) {
      _calcAnimHeight();          // 每帧重算视频区高度
      refreshPage();              // 每帧让列表重排
    }
  }

  void _calcAnimHeight() {
    if (isExpanding) {
      animHeight = clampDouble(
        videoHeight * animationController.value,
        kToolbarHeight,
        videoHeight,
      );
    } else if (isCollapsing) {
      animHeight = clampDouble(
        maxVideoHeight -
            (maxVideoHeight - minVideoHeight) * animationController.value,
        minVideoHeight,
        maxVideoHeight,
      );
    }
  }
```

**说明**
- 展开 = 从 `kToolbarHeight`(56) 长到 `videoHeight`；收起 = 从 `maxVideoHeight` 缩到 `minVideoHeight`。
- 曲线是 `clampDouble`（线性区间限制），时长 200ms。
- ⚠️ 这个动画**每帧都会 `refreshPage()`**（`(context as Element).markNeedsBuild()`），
  是整个 App 比较重的动画之一，改动前请先 profile。

### 7.2 触发：`lib/pages/video/view.dart:205-240`

```dart
  // 播放器状态监听
  Future<void> playerListener(PlayerStatus status) async {
    final isPlaying = status.isPlaying;
    try {
      if (videoDetailController.scrollCtr.hasClients) {
        if (isPlaying) {
          if (!videoDetailController.isExpanding &&
              videoDetailController.scrollCtr.offset != 0 &&
              !videoDetailController.animationController.isAnimating) {
            videoDetailController.isExpanding = true;
            videoDetailController.animationController.forward(
              from:
                  1 -
                  videoDetailController.scrollCtr.offset /
                      videoDetailController.videoHeight,
            );
          } else {
            videoDetailController.refreshPage();
          }
        }
        ...
```

**说明**：开始播放时按「当前滚动位置」反推动画进度，所以从半途开始播放也不会跳变。

### 7.3 高度生效：`lib/pages/video/view.dart:540-565`

```dart
              if (videoDetailController.isExpanding &&
                  videoDetailController.animationController.value == 1) {
                videoDetailController.isExpanding = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  videoDetailController.scrollRatio.value = 0;
                  videoDetailController.refreshPage();
                });
              } else if (videoDetailController.isCollapsing &&
                  videoDetailController.animationController.value == 1) {
                videoDetailController.isCollapsing = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  videoDetailController.refreshPage();
                });
              }
              return pinnedHeight;
```

**说明**：动画跑完（`value == 1`）后在**下一帧**才把 `isExpanding/isCollapsing` 复位，
这样高度不会在最后一帧闪一下。

---

## 第 8 章 列表 / 内容动画

### 8.1 点赞数变化的「弹一下」

位置：`lib/pages/dynamics/widgets/action_panel.dart:120-135`

```dart
                label: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: Text(
                    like.count != null ? NumUtils.numFormat(like.count) : '点赞',
                    key: ValueKey<int?>(like.count),     // ← key 变化才会触发切换
                    style: TextStyle(color: like.status! ? primary : outline),
                  ),
                ),
```

视频页点赞（`lib/pages/video/introduction/ugc/widgets/action_item.dart:100-112`）：

```dart
    if (hasText) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: child),
        child: child,
      );
    }
    return child;
```

同一文件 `:50-62` 还有「长按点赞时转圈」的进度弧：

```dart
    if (animation != null) {
      child = Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: animation!,
            builder: (context, child) =>
                Arc(size: 28, color: primary, progress: -animation!.value),
          ),
          child,
        ],
      );
    } else {
      child = SizedBox.square(dimension: 28, child: child);
    }
```

### 8.2 直播间「点赞 xN」数字弹跳

位置：`lib/pages/live_room/view.dart:888-912`

```dart
                            child: Obx(() {
                              final likeClickTime =
                                  _liveRoomController.likeClickTime.value;
                              if (likeClickTime == 0) {
                                return const SizedBox.shrink();
                              }
                              return AnimatedSwitcher(
                                duration: const Duration(milliseconds: 160),
                                transitionBuilder: (child, animation) {
                                  return ScaleTransition(
                                    scale: animation,
                                    child: child,
                                  );
                                },
                                child: Text(
                                  key: ValueKey(likeClickTime),   // ← 数字变就重放
                                  'x$likeClickTime',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: colorScheme.isDark
                                        ? colorScheme.primary
                                        : colorScheme.inversePrimary,
                                  ),
                                ),
                              );
                            }),
```

### 8.3 评论列表增删（`AnimatedList`）

位置：`lib/pages/video/view.dart:1490-1515`

```dart
        if (videoDetailController.plPlayerController.enableBlock ||
            videoDetailController.continuePlayingPart)
          Positioned(
            left: 16,
            bottom: isFullScreen ? max(75, maxHeight * 0.25) : 75,
            width: MediaQuery.textScalerOf(context).scale(120),
            child: AnimatedList(
              padding: EdgeInsets.zero,
              key: videoDetailController.listKey,
              reverse: true,
              shrinkWrap: true,
              initialItemCount: videoDetailController.listData.length,
              itemBuilder: (context, index, animation) {
                return videoDetailController.buildItem(
                  videoDetailController.listData[index],
                  animation,
                );
              },
            ),
          ),
```

**说明**：`animation` 参数就是这条 item 的进场动画（插入时自动播放）。
`listKey` 定义在 `lib/pages/video/controller.dart` 的 `GlobalKey<AnimatedListState>`。
屏蔽词列表同理：`lib/pages/sponsor_block/block_mixin.dart:47`
`late final listKey = GlobalKey<AnimatedListState>();`

### 8.4 拖拽排序（`ReorderableListView`）

位置：
- `lib/pages/fav_sort/view.dart:99`
- `lib/pages/fav_folder_sort/view.dart:71`
- `lib/pages/follow_tag_sort/view.dart:80`
- `lib/pages/setting/pages/bar_set.dart:80`

```dart
    return ReorderableListView.builder(
      ...
    );
```

**说明**：`ReorderableListView` 自带「长按拖起 + 其它项让位」的动画，无需自己写。
相关手势逻辑：`lib/common/widgets/reorder_mixin.dart`。

### 8.5 动态页 / 收藏页的 `AnimatedSlide`（滑动出现）

位置（grep `AnimatedSlide`）：
`lib/pages/dynamics_mention/view.dart:198`、`lib/pages/fav_detail/view.dart:71`、
`lib/pages/fav/note/child_view.dart:58`、`lib/pages/fav/pgc/child_view.dart:65`、
`lib/pages/later/view.dart:85`、`lib/pages/main/view.dart:431`。

```dart
// lib/pages/dynamics_mention/view.dart:198
                  child: AnimatedSlide(
                    ...
                  ),
```

### 8.6 可拖拽面板 `DraggableScrollableSheet`

位置：`lib/common/widgets/draggable_sheet/dyn.dart`（**全文件**）

```dart
class DynDraggableScrollableSheet extends DraggableScrollableSheet {
  const DynDraggableScrollableSheet({
    ...
  });

  @override
  State<DraggableScrollableSheet> createState() =>
      _DynDraggableScrollableSheetState();
}

class _DynDraggableScrollableSheetState extends DraggableScrollableSheetState {
  ...
```
使用位置：`lib/pages/dynamics_create/view.dart:80`、`lib/pages/dynamics_repost/view.dart:126`、
`lib/pages/live_room/widgets/header_control.dart:315`。

`DraggableScrollableSheet`（官方版）使用位置：
`lib/pages/dynamics_mention/view.dart:42`、`lib/pages/dynamics_select_topic/view.dart:37`、
`lib/pages/live_area_detail/view.dart:196`、`lib/pages/video/controller.dart:1495`、
`lib/utils/page_utils.dart:166`、`lib/utils/request_utils.dart:209`。

---

## 第 9 章 评论页「左右滑动返回」动画

### 9.1 `CommonSlideMixin`

位置：`lib/pages/common/slide/common_slide_page.dart:1-110`

```dart
abstract class CommonSlidePage extends StatefulWidget {
  const CommonSlidePage({super.key, this.enableSlide = true});
  final bool enableSlide;
}

mixin CommonSlideMixin<T extends CommonSlidePage> on State<T>, TickerProvider {
  static const double offset = 30.0;
  double? _downDx;
  late double _maxWidth;
  double get maxWidth => _maxWidth;
  late bool _isRTL = false;
  late final bool enableSlide;
  late final AnimationController _animController;
  SlideDragGestureRecognizer? _slideDragGestureRecognizer;

  static bool slideDismissReplyPage = Pref.slideDismissReplyPage;

  bool isDxAllowed(double dx) {
    return enableSlide
        ? dx > CommonSlideMixin.offset &&
              dx < maxWidth - CommonSlideMixin.offset
        : true;
  }
  ...
  @override
  void initState() {
    super.initState();
    enableSlide = widget.enableSlide && slideDismissReplyPage;
    if (enableSlide) {
      _animController = AnimationController(
        vsync: this,
        reverseDuration: const Duration(milliseconds: 500),
      );
      _slideDragGestureRecognizer =
          SlideDragGestureRecognizer(
              isDxAllowed: (double dx) {
                final isLTR = dx <= offset;
                final isRTL = dx >= _maxWidth - offset;
                if (isLTR || isRTL) {
                  _isRTL = isRTL;
                  return true;
                }
                return false;
              },
            )
            ..onStart = _onDragStart
            ..onUpdate = _onDragUpdate
            ..onEnd = _onDragEnd
            ..onCancel = _onDragEnd;
    }
  }

  @override
  void dispose() {
    if (enableSlide) {
      _animController.dispose();
      _slideDragGestureRecognizer?.dispose();
      _slideDragGestureRecognizer = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (enableSlide) {
      return LayoutBuilder(
        builder: (context, constraints) {
          _maxWidth = constraints.maxWidth;
          return AnimatedBuilder(
            animation: _animController,
            builder: (context, child) {
              return Align(
                alignment: AlignmentDirectional.topStart,
                heightFactor: 1 - _animController.value,   // ← 收起时高度也压缩
                child: child,
              );
            },
            child: buildPage(theme),
          );
        },
      );
    }
    return buildPage(theme);
  }

  Widget buildPage(ThemeData theme);

  Widget buildList(ThemeData theme) => throw UnimplementedError();

  void _onDragEnd([_]) {
    if (_downDx == null) return;
    final dx = _downDx!;
    if (_animController.value * _maxWidth + (_isRTL ? (_maxWidth - dx) : dx) >=
        100) {
      Get.back();
    } else {
      ...
```

**说明**
- 手指左右拖动 → 页面跟着平移；松手超过 100px 就返回上一页。
- `heightFactor: 1 - value` 让页面在「收起」时高度也一起压缩，
  看起来像「卡片被抽走」。
- 开关：设置里的「滑动返回」（`Pref.slideDismissReplyPage`）。
- 使用该 mixin 的页面：`lib/pages/episode_panel/view.dart:89`、
  `lib/pages/video/ai_conclusion/view.dart:136`、
  `lib/pages/video/introduction/pgc/widgets/intro_detail.dart:33`、
  `lib/pages/video/medialist/view.dart:51`、`lib/pages/video/note/view.dart:39`、
  `lib/pages/video/post_panel/view.dart:242`、`lib/pages/video/reply/view.dart:41`、
  `lib/pages/video/reply_reply/view.dart:103`、`lib/pages/video/view_point/view.dart:29`。

### 9.2 楼中楼回复面板的进度控制器

位置：`lib/pages/video/reply_reply/controller.dart:42-46`

```dart
  AnimationController? _controller;
  AnimationController get animController => _controller ??= AnimationController(
    duration: const Duration(milliseconds: 1000),
    vsync: this,
  );
```

同文件 `lib/pages/video/reply_reply/view.dart:321` 有注释：
`// 前0.8s不变, 后0.2s开始动画`（配合上面的 1000ms 做「延迟启动」）。

---

## 第 10 章 其它动画

### 10.1 骨架屏（Shimmer 微光扫过）

文件：`lib/common/skeleton/skeleton.dart`（**全文件重点**）

```dart
/// 全局共享的骨架屏 shimmer 动画（性能报告 U-01）。
///
/// 原实现里每个骨架项各自持有一个 `AnimationController.repeat()`，并在这个
/// 控制器的监听里 `setState`：首屏常态 10~12 个占位项 = 10~12 个动画控制器
/// + 每帧 10~12 次「整棵卡片子树重建」+ 10~12 层每帧重建的 `ShaderMask`。
///
/// 这里改为全局唯一的 [Ticker] 驱动一个 [AnimationController]：
/// - 骨架项只用 `AnimatedBuilder` 重建最外层的 `ShaderMask`，卡片内部静态内容
///   通过 `child` 复用，完全不参与每帧重建；
/// - 没有可见骨架项时（或被 [TickerMode] 静音时）停止动画，避免空转耗电。
abstract final class SkeletonAnimation {
  static const Duration period = Duration(milliseconds: 1000);
  static const double minValue = -0.5;
  static const double maxValue = 1.5;
  static const List<double> stops = [0.1, 0.3, 0.5, 0.7];

  static final AnimationController controller = AnimationController.unbounded(
    vsync: const _SharedTickerProvider(),
  );

  static int _enabledCount = 0;

  static void _acquire() {
    if (_enabledCount++ > 0) return;
    controller.repeat(min: minValue, max: maxValue, period: period);
  }

  static void _release() {
    if (_enabledCount > 0 && --_enabledCount > 0) return;
    _enabledCount = 0;
    controller.stop();
  }
}

/// 直接用 [Ticker] 作为 vsync，不需要每个骨架项各自持有 TickerProvider
class _SharedTickerProvider implements TickerProvider {
  const _SharedTickerProvider();

  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}
```

`_SkeletonState` 里控制启停（避免不必要的耗电）：

```dart
  void _updateTicker(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) {
      if (_acquirePending) {
        _acquirePending = false;      // 还没来得及 acquire 就取消，等于从未启动
      } else {
        SkeletonAnimation._release();
      }
      return;
    }
    if (_acquirePending) return;
    _acquirePending = true;
    // 路由切进来时，TickerMode 翻转的这一帧往往正是转场收尾、整页首次实时绘制
    // 的那一帧。推迟一帧再启动 shimmer，避免把「每帧 saveLayer 的 ShaderMask」
    // 叠到那帧上。
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_acquirePending) return;
      _acquirePending = false;
      if (mounted && _enabled) {
        SkeletonAnimation._acquire();
      }
    });
  }

  ui.Shader _createShader(Rect bounds) {
    final width = bounds.width;
    final height = bounds.height;
    _matrix[12] = width * SkeletonAnimation.controller.value;
    return ui.Gradient.linear(
      Offset(0, 0.35 * height),
      Offset(width, 0.95 * height),
      _colors,
      SkeletonAnimation.stops,
      TileMode.clamp,
      _matrix.storage,
    );
  }
```

**说明**
- 这是「微光扫过」效果的实现：`ShaderMask` + 一个线性渐变 + 每帧平移矩阵。
- ⚠️ **重要约定**：全 App 只有这一个 shimmer 控制器。
  **不要**再往骨架项里加独立的 `AnimationController`（会退回到性能问题）。
- 想改效果：`period`（周期 1000ms）、`stops`（高光位置）、`_createShader` 里的角度。

### 10.2 投币动画（4 个控制器协作）

位置：`lib/pages/video/pay_coins/view.dart:63-200`

```dart
class _PayCoinsPageState extends State<PayCoinsPage>
    with TickerProviderStateMixin {
  ...
  late final AnimationController _slide22Controller;
  late final Animation<Offset> _slide22Anim;
  late final AnimationController _scale22Controller;
  late final AnimationController _coinController;
  late final Animation<Offset> _coinSlideAnim;
  late final Animation<double> _coinFadeAnim;
  late final AnimationController _boxAnimController;
  late final Animation<Offset> _boxAnim;
  ...
  @override
  void initState() {
    super.initState();
    if (_hasCopyright) {
      _controller = PageController(viewportFraction: 0.30);
    }

    _slide22Controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 50),
    );
    _slide22Anim = _slide22Controller.drive(
      Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(0.0, -0.2),
      ),
    );
    _scale22Controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 50),
      lowerBound: 1.0,          // ← 缩放只放大不变小：1.0 ~ 1.1
      upperBound: 1.1,
    );
    _coinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _coinSlideAnim = _coinController.drive(
      Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(0.0, -2.0),      // 硬币向上飞 2 个屏幕高
      ).chain(CurveTween(curve: const Interval(0.0, 2 / 3))),  // 前 2/3 段做位移
    );
    _coinFadeAnim = _coinController.drive(
      Tween<double>(
        begin: 1.0,
        end: 0.0,
      ).chain(CurveTween(curve: const Interval(2 / 3, 1.0))),  // 后 1/3 段淡出
    );
    _boxAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 50),
    );
    _boxAnim = _boxAnimController.drive(
      Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(0.0, -0.2),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback(_scale);
  }

  void _scale([_]) {
    _scale22Controller.forward().whenComplete(_scale22Controller.reverse);  // 弹一下再回来
  }

  void _onScroll(int index) {
    _controller?.animateToPage(
      index,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
    _scale();
  }
```

界面里组合使用：

```dart
  Widget _buildCoinWidget(int index, double factor) {
    final filter = _getPayFilter(index);
    final boxSize = 70 + (factor * 30);
    final coinSize = 35 + (factor * 15);
    return Stack(
      alignment: .center,
      clipBehavior: .none,
      children: [
        SlideTransition(
          position: _boxAnim,
          child: Image.asset(Assets.payBox, ...),
        ),
        SlideTransition(
          position: _coinSlideAnim,
          child: FadeTransition(
            opacity: _coinFadeAnim,
            child: Image.asset(
              height: coinSize, width: coinSize, ...,
              index == 0 ? Assets.coinsOne : Assets.coinsTwo,
            ),
          ),
        ),
      ],
    );
  }
```

**说明**：`Interval(0.0, 2/3)` / `Interval(2/3, 1.0)` 让**同一个控制器**分成两段使用
（前段飞、后段淡出），这是显式动画的一个常用技巧。

### 10.3 一键三连动画

位置：`lib/pages/video/introduction/ugc/widgets/triple_mixin.dart:56-90`

```dart
  // no need for pugv
  AnimationController? _tripleAnimCtr;
  Animation<double>? _tripleAnimation;

  AnimationController get tripleAnimCtr =>
      _tripleAnimCtr ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
        reverseDuration: const Duration(milliseconds: 400),
      );

  Animation<double> get tripleAnimation => _tripleAnimation ??= tripleAnimCtr
      .drive(CurveTween(curve: Curves.easeInOut));
```

**说明**：长按点赞 → 1.2s 内依次点亮「点赞 → 投币 → 收藏」（正放），
取消时 0.4s 回退。控制器挂在 `GetxController` 上（`GetTickerProviderStateMixin`），
所以不在 widget 树里；**注意它没有 dispose，属于长生命周期对象**。

### 10.4 音乐页 AppBar 标题淡入

位置：`lib/pages/music/view.dart:80-95`

```dart
          if (controller.infoState.value case Success(:final response)) {
            final showTitle = controller.showTitle.value;
            return AnimatedOpacity(
              opacity: showTitle ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              child: IgnorePointer(
                ignoring: !showTitle,
                child: Row(
                  spacing: 8,
                  children: [
                    NetworkImgLayer(src: response.mvCover, width: 36, height: 36, type: ImageType.avatar),
                    Text(response.musicTitle!),
                  ],
                ),
              ),
            );
          }
```

同文件还有跳转用的 `SlideTransition`：`lib/pages/music/view.dart:208`、`:247`。

### 10.5 弹幕透明度切换

位置：`lib/pages/danmaku/view.dart:172-190`

```dart
    return Obx(
      () => AnimatedOpacity(
        opacity: playerController.enableShowDanmaku.value
            ? playerController.danmakuOpacity.value
            : 0,
        duration: const Duration(milliseconds: 100),
        child: DanmakuScreen<DanmakuExtra>(
          createdController: (e) {
            playerController.danmakuController = _controller = e;
          },
          option: option,
          size: widget.size,
        ),
      ),
    );
```

**说明**：弹幕「开关」不是真的销毁，而是透明度切到 0（100ms）。
弹幕本身的滚动/描边动画由第三方包 `canvas_danmaku` 负责，本仓库只传 `option`。

### 10.6 直播间聊天气泡 / 超级留言淡入

位置：`lib/pages/live_room/widgets/chat_panel.dart:170-185`

```dart
        if (liveRoomController.showSuperChat)
          Positioned(
            top: 12,
            right: 12,
            child: Obx(() {
              final isEmpty = liveRoomController.superChatMsg.isEmpty;
              return AnimatedOpacity(
                opacity: isEmpty ? 0 : 1,
                duration: const Duration(milliseconds: 120),
                child: GestureDetector(
                  onTap: isEmpty
                      ? null
                      : () => liveRoomController.pageController?.animateToPage(
                          1,
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                        ),
                  ...
```

### 10.7 播放器/音频页的播放按钮

位置：`lib/pages/audio/view.dart:878-890`

```dart
          icon: AnimatedIcon(
            progress: ...,
            icon: AnimatedIcons.play_pause,
            ...
          ),
```

音频控制器里也有一个 200ms 的控制器：
`lib/pages/audio/controller.dart:84,203`

```dart
  late final AnimationController animController;
  ...
    animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
```

### 10.8 小尺寸输入框/报告弹窗的 `AnimatedSize`

- `lib/common/widgets/dialog/report.dart:77`：举报弹窗内容切换时高度动画
  ```dart
              child: AnimatedSize(
                ...
              ),
  ```
- `lib/pages/save_panel/view.dart:363`
- `lib/pages/login/controller.dart:719`

`AnimatedSize` 会自动在「子组件尺寸变化」时补间，不需要写时长以外的参数。

### 10.9 少量 `AnimatedDefaultTextStyle`（在 Flutter fork 里）

位置：`lib/common/widgets/flutter/list_tile.dart:869,883,901,910`、
`lib/common/widgets/flutter/popup_menu.dart:45`

**⚠️ 注意**：`lib/common/widgets/flutter/**` 是**项目 fork 出来的 Flutter 框架源码**，
不是业务代码。里面的动画（`AnimatedDefaultTextStyle`、`RefreshIndicator` 的
`_scaleController/_positionController`、`vertical_slider.dart` 的
`overlayController/valueIndicatorController/enableController/positionController`、
`editable_text.dart` 的光标闪烁等）都是 **Flutter 官方行为**。
**改这些文件风险极高，不要为了「看起来更好」去动。**

---

## 第 11 章 设置项总索引（用户能改的动画）

| 设置项 | 位置（界面代码） | 影响的动画 |
| --- | --- | --- |
| 页面过渡动画 | `lib/pages/setting/models/style_settings.dart:657` | 所有页面跳转的转场 |
| 滑动动画弹簧参数 | `lib/pages/setting/models/style_settings.dart:347` | 首页标签页横滑的弹簧手感 |
| 首页切换页面动画 | `lib/pages/setting/models/extra_settings.dart:325` | 首页切 Tab 是滑动还是瞬切 |
| 悬浮底栏 / 底栏样式 | `lib/pages/setting/models/style_settings.dart` | 底栏气泡滑动是否存在 |
| 顶栏/底栏滚动隐藏 | 同上（`hideTopBar` / `hideBottomBar` / `barHideType`） | 滚动收起/展开动画 |
| 纯黑主题 | `Pref.isPureBlackTheme` | `darkenTheme` 颜色过渡 |
| 动态取色 | 设置 → 样式 | 主题色变化（回调 `refreshDynamicColor()` 重建主题） |

---

## 第 12 章 修改指南与常见坑

### 12.1 想改「某处动画」，先按这张表定位

1. **页面切换动画** → `lib/utils/storage_pref.dart:803`（默认值）+ 设置项。
2. **底栏气泡滑动** → `lib/common/widgets/floating_navigation_bar.dart:41`（`animationDuration`）+
   `_kIndicatorWidth` / `_kNavigationHeight`（第 8-20 行）。
3. **滚动收起顶栏/底栏** → `lib/pages/common/common_page.dart`（`_settleDuration` / `_settleStep` / 曲线）。
4. **FAB 滑入滑出** → `lib/pages/common/fab_mixin.dart` 的 `_initController` / `_initAnimation`。
5. **图片 Hero 飞行** → `lib/common/widgets/image_viewer/hero.dart`。
6. **图片双击缩放** → `lib/common/widgets/image_viewer/viewer.dart`（300ms）。
7. **播放器控件显隐** → `lib/plugin/pl_player/view/view.dart:263`（100ms）。
8. **视频展开收起** → `lib/pages/video/controller.dart:190`（200ms）+ `_calcAnimHeight`。
9. **骨架屏微光** → `lib/common/skeleton/skeleton.dart`（`period` / `stops`）。
10. **下拉刷新** → `lib/common/widgets/refresh_indicator.dart`。
11. **底部弹窗** → `lib/pages/common/publish/publish_route.dart` 或调用处的 `transitionBuilder`。
12. **评论页滑出** → `lib/pages/common/slide/common_slide_page.dart`。

### 12.2 坑（本项目已踩过，改动画时务必注意）

1. **GetX 命名路由不走 `ThemeData.pageTransitionsTheme`。**
   改 `lib/utils/theme_utils.dart:162` 的 `pageTransitionsTheme` **不会**有任何效果，
   要改 `GetMaterialApp.defaultTransition`（`lib/main.dart:336`）。

2. **`Transition.native` 在 Android 上会「转场收尾卡一下」。**
   它走 `ZoomPageTransitionsBuilder`，动画结束那一帧会丢掉快照、
   让整页首次实时绘制，掉一帧。所以 Android 默认改成了 `sharedAxis`。
   如果用户自己把设置换回 `native` 并抱怨卡顿，这是已知原因，不是 bug。

3. **骨架屏不要新增 `AnimationController`。**
   全 App 只有 `SkeletonAnimation.controller` 一个 shimmer 控制器，
   并且用 `_acquire/_release` 引用计数控制启停。往骨架项里加独立控制器 = 性能回退。

4. **`CustomHeightWidget` 和 `AnimatedContainer` 都不裁剪内容。**
   收起时超出的部分会画到别的地方，必须自己套 `ClipRect`
   （见 `lib/pages/home/view.dart:186`）。

5. **`AnimatedSwitcher` 必须给子组件一个会变的 `key`。**
   否则 Flutter 认为「还是同一个 widget」，动画不会播放。
   例子：`ValueKey<int?>(like.count)`、`ValueKey(likeClickTime)`。

6. **`Transform.translate` 优于改 `Positioned.left`。**
   底栏气泡就是为此改成 `Transform` 的（改 left 会触发重新布局）。

7. **`Stack` 里做超出的动画要 `clipBehavior: Clip.none`。**
   气泡/投币硬币都用了这个（否则边缘被切平）。

8. **`AnimationController` 必须 `dispose()`。**
   搜索 `dispose()` 附近的 `_controller.dispose()` 可以确认；
   挂在 `GetxController` 上的（如 `triple_mixin`）是长生命周期，注意别泄漏。

9. **Material 3 的时长/曲线常量优先用 `Durations.*` / `Easing.*`**（来自 `material_ui` 包的
   `src/motion.dart`）。项目已统一：
   `Durations.short4`=200ms、`medium1`=250ms、`medium2`=300ms、`medium4`=400ms、`long2`=500ms；
   `Easing.standard` / `Easing.emphasizedDecelerate` 等。

10. **改完必须跑 `dart analyze lib` 和构建验证**（本机基线：36 条 info / 0 error；
    构建命令见项目记忆笔记）。语法错误（比如把常量粘到 import 前面）analyze 能报出来。

### 12.3 动画相关的资源文件

| 资源 | 路径 | 用途 |
| --- | --- | --- |
| `live.gif` | `assets/images/live/live.gif` | 直播相关动图 |
| `default_bg.webp` | `assets/images/live/default_bg.webp` | 直播默认背景 |
| 投币动画图片 | `assets/images/paycoins/`（`Assets.mario` / `gunSister` / `payBox` / `coinsOne` / `coinsTwo` / `thunder1~3`） | 投币页动画帧 |
| GLSL 着色器 | `assets/shaders/Anime4K_*.glsl` | 视频画质增强（不是 UI 动画） |

---

## 附录 A：全部「含动画代码」的文件清单

> 按目录分组，`(N)` 表示该文件里动画相关命中数，便于快速定位。

### lib/common/
- `lib/common/skeleton/skeleton.dart`
- `lib/common/widgets/animated_height.dart`
- `lib/common/widgets/animated_multi_height.dart`
- `lib/common/widgets/colored_box_transition.dart`
- `lib/common/widgets/custom_height_widget.dart`
- `lib/common/widgets/dialog/report.dart`
- `lib/common/widgets/draggable_sheet/dyn.dart`
- `lib/common/widgets/dynamic_sliver_app_bar/dynamic_sliver_app_bar.dart`
- `lib/common/widgets/expandable.dart`
- `lib/common/widgets/floating_navigation_bar.dart`
- `lib/common/widgets/gesture/mouse_interactive_viewer.dart`
- `lib/common/widgets/image/image_save.dart`
- `lib/common/widgets/image_grid/image_grid_view.dart`
- `lib/common/widgets/image_viewer/gallery_viewer.dart`
- `lib/common/widgets/image_viewer/hero.dart`
- `lib/common/widgets/image_viewer/hero_dialog_route.dart`
- `lib/common/widgets/image_viewer/viewer.dart`
- `lib/common/widgets/loading_widget/m3e_loading_indicator.dart`
- `lib/common/widgets/marquee.dart`
- `lib/common/widgets/refresh_indicator.dart`
- `lib/common/widgets/refresh_layout.dart`
- `lib/common/widgets/scaffold/bottom_sheet.dart`
- `lib/common/widgets/scaffold/mini_scaffold.dart`
- `lib/common/widgets/scroll_physics.dart`
- `lib/common/widgets/select_mask.dart`
- `lib/common/widgets/scale_app.dart`（整体 UI 缩放，非补间动画）
- `lib/common/widgets/reorder_mixin.dart`
- `lib/common/widgets/route_aware_mixin.dart`

### lib/pages/
- `lib/pages/common/common_page.dart`
- `lib/pages/common/fab_mixin.dart`
- `lib/pages/common/publish/publish_route.dart`
- `lib/pages/common/slide/common_slide_page.dart`
- `lib/pages/audio/controller.dart`、`lib/pages/audio/view.dart`
- `lib/pages/article/view.dart`、`widgets/html_render.dart`、`widgets/opus_content.dart`
- `lib/pages/danmaku/view.dart`
- `lib/pages/dynamics_detail/view.dart`、`dynamics_mention/view.dart`、`dynamics_repost/view.dart`、`dynamics_topic/view.dart`
- `lib/pages/dynamics/widgets/action_panel.dart`、`widgets/module_panel.dart`
- `lib/pages/fav_detail/view.dart`、`fav/note/child_view.dart`、`fav/pgc/child_view.dart`、`fav/video/widgets/item.dart`
- `lib/pages/follow/view.dart`、`lib/pages/home/view.dart`、`lib/pages/later/view.dart`
- `lib/pages/live_room/view.dart`、`widgets/chat_panel.dart`、`widgets/header_control.dart`、`contribution_rank/view.dart`
- `lib/pages/login/controller.dart`
- `lib/pages/main/controller.dart`、`lib/pages/main/view.dart`
- `lib/pages/main_reply/view.dart`、`match_info/view.dart`
- `lib/pages/member/widget/user_info_card.dart`、`member_opus/view.dart`、`member_video/view.dart`
- `lib/pages/mine/widgets/item.dart`、`lib/pages/music/view.dart`
- `lib/pages/pgc_index/view.dart`
- `lib/pages/save_panel/view.dart`
- `lib/pages/setting/pages/color_select.dart`、`pages/bar_set.dart`、`models/style_settings.dart`、`models/extra_settings.dart`
- `lib/pages/sponsor_block/block_mixin.dart`
- `lib/pages/subscription/widgets/item.dart`、`subscription_detail/view.dart`
- `lib/pages/video/controller.dart`、`view.dart`
- `lib/pages/video/introduction/ugc/view.dart`、`ugc/widgets/action_item.dart`、`ugc/widgets/menu_row.dart`、`ugc/widgets/triple_mixin.dart`
- `lib/pages/video/introduction/pgc/view.dart`、`pgc/widgets/intro_detail.dart`
- `lib/pages/video/pay_coins/view.dart`
- `lib/pages/video/reply_reply/controller.dart`、`reply_reply/view.dart`、`reply/view.dart`
- `lib/pages/whisper_detail/widget/chat_item.dart`

### lib/plugin/（播放器）
- `lib/plugin/pl_player/view/view.dart`
- `lib/plugin/pl_player/widgets/app_bar_ani.dart`
- `lib/plugin/pl_player/widgets/play_pause_btn.dart`
- `lib/plugin/pl_player/widgets/bottom_control.dart`、`common_btn.dart`、`forward_seek.dart`、`backward_seek.dart`

### lib/utils/
- `lib/utils/page_utils.dart`（`showVideoBottomSheet` 的 SlideTransition）
- `lib/utils/storage_pref.dart`（`pageTransition` 默认值）
- `lib/utils/theme_utils.dart`（`pageTransitionsTheme`，注意对 GetX 无效）

---

## 附录 B：一分钟「改动画」示例

### 例 1：把底栏气泡滑动从 500ms 改成 300ms

改 `lib/common/widgets/floating_navigation_bar.dart:41`：

```dart
    this.animationDuration = const Duration(milliseconds: 300),
```

（注意：调用处若显式传了 `animationDuration`，要改调用处。）

### 例 2：让 Android 默认转场回到 Flutter 原生风格

改 `lib/utils/storage_pref.dart:808`：

```dart
  static Transition get _defaultPageTransition => Platform.isAndroid
      ? Transition.native          // ← 原来是 sharedAxis
      : Transition.native;
```

### 例 3：改骨架屏微光速度

改 `lib/common/skeleton/skeleton.dart:23`：

```dart
  static const Duration period = Duration(milliseconds: 1500);   // 原来 1000
```

### 例 4：改播放器控件显隐速度

改 `lib/plugin/pl_player/view/view.dart:263`：

```dart
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),   // 原来 100
    );
```

### 例 5：改 Hero 图片飞行的形变规则

改 `lib/common/widgets/image_viewer/hero.dart` 的 `createEndRectTween`：

```dart
RectTween createEndRectTween(Rect? begin, Rect? end) {
  if (begin != null && end != null) {
    final endWidth = end.width;
    final endHeight = end.height;
    final beginRect = Rect.fromLTWH(
      begin.left + (begin.width - endWidth) / 2,
      begin.top + (begin.height - endHeight) / 2,
      endWidth,
      endHeight,
    );
    return RectTween(begin: beginRect, end: end);
  }
  return RectTween(begin: begin, end: end);
}
```

> 如果想让 Hero 保持原始比例（不裁剪），把 `beginRect` 直接换成 `begin` 即可。

---

*文档生成时间：2026-09-26　适用版本：PiliPlus 3.0.1+1（Flutter 3.47.5）*
