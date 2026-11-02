# PiliPlus Android 屏幕圆角转场实现说明

- 适用设备 / 系统：小米 15、Android 17（API 37）、澎湃 OS 4
- 适用转场：设置 → 样式 →「页面过渡动画」= **iOS 风格（横向滑动）**（`Transition.cupertino`）
- 相关文件：
  - `lib/scripts/getx_ios_transition.patch`（实现）
  - `lib/scripts/patch.ps1`（构建期打补丁）
  - `lib/utils/storage_pref.dart`、`lib/pages/setting/models/style_settings.dart`（转场选项）
  - `docs/PiliPlus-Android动画清单.md` 1.3.1 节（动画清单）

> **状态**：已实现（2026-11-02，`feature` 分支），静态验证与临时 widget 测试均通过。
> 小米 15 真机还需确认两点：HyperOS 是否上报非 0 的 `displayCornerRadii`；
> 转场收尾贴近屏幕角时是否需要把 `-1` 调到 `-2` / `-3`。

## 1. 目标

让 Android 端的页面在横向滑动转场时呈现圆角，且圆角**与屏幕硬件 R 角一致**：

1. 静止时不能露出下层页面（这是最容易翻车的点）；
2. 不引入新依赖、不加原生通道；
3. 不牺牲转场流畅度（尤其是收尾那一帧）；
4. 不破坏左缘返回手势、预测性返回与既有 `PopScope` 拦截逻辑。

## 2. 结论

| 项目 | 选择 |
| --- | --- |
| 数据源 | `MediaQuery.maybeDisplayCornerRadiiOf(context)`（Flutter 3.47.9 已内置，Android 12+ 填充） |
| 落点 | getx 的 `GetPageRouteTransitionMixin.buildPageTransitions` → `cupertino` 分支 |
| 裁剪时机 | **仅正在整屏滑动的上页**（`animation ∈ (0,1)` 且 `secondaryAnimation == 0`）；静止页与被压住的下页一律 `Clip.none` |
| 半径 | 屏幕半径 ÷ `uiScale` − 1 个逻辑像素 |
| 形状 | `ClipRRect`（圆形圆角，与系统给窗口做的裁切一致） |

## 3. 平台事实（为什么不需要插件）

1. **引擎已实现**：Android 侧的 `FlutterView.onApplyWindowInsets` 在
   `SDK_INT >= 31` 时读取
   `WindowInsets.getRoundedCorner(POSITION_*)`，四个角各自上报物理像素；
   `null` 会写成 `0`；`ViewportMetrics` 的默认值是 `unsetValue = -1`。
2. **Dart 侧**：`_decodeDisplayCornerRadii` 遇到 `-1` 返回 `null`，
   否则构造 `DisplayCornerRadii`（物理像素）；`MediaQueryData` 再除以真实
   `devicePixelRatio`，所以 `MediaQueryData.displayCornerRadii` 是**逻辑像素**。
3. **平台限制**：只有 Android 12+ 填充；更低的 Android、iOS、桌面一律 `null`。
4. **窗口语义**：AOSP 文档明确 —— 角落不在应用窗口内时 `getRoundedCorner`
   返回 `null`。因此分屏上半屏会得到 `(R, R, 0, 0)`（只圆贴屏的两角），
   自由窗口 / 小窗不贴角时全是 0，**不会误裁**。
5. **形状**：`RoundedCorner.getRadius()` 给的是**圆形**半径（面板本身可能是超椭圆），
   所以先用 `ClipRRect` 与系统裁切对齐；只有在实测发现转场收尾四角有差异时，
   才评估改用 `ClipRSuperellipse`（连续圆角，更接近超椭圆）。

结论：`corner_radius_plugin` / 自写 MethodChannel / 厂商 `dimen` 在这台设备上
都是重复实现。只有在需要覆盖 Android 12 以下机型时才值得补一条 JNI 兜底
（仓库已有 `AndroidHelper.java` + `jni` 通道）。

## 4. 实现

### 4.1 位置

`lib/scripts/getx_ios_transition.patch` 把 getx 的 `cupertino` 分支换成
`CupertinoRouteTransitionMixin.buildPageTransitions`，本次在该分支把页面内容
包进 `_DisplayCornerClip`：

```dart
return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
  rawRoute,
  context,
  animation,
  secondaryAnimation,
  _DisplayCornerClip(
    animation: animation,
    secondaryAnimation: secondaryAnimation,
    child: child,
  ),
);
```

选择这里而不是别处的原因：

- 本仓库所有页面跳转最终都是 `GetPageRoute`（70 个 `GetPage` +
  12 处 `Get.to(widget)` + 6 处直接 `GetPageRoute(...)`），
  `ThemeData.pageTransitionsTheme` 对 GetX 无效；
- 包在 `child` 上等于包在 `SlideTransition` 内侧，圆角跟着页面移动；
- 进/出两页都会经过这里：两边 `delegatedTransition` 是同一个静态方法
  tear-off（Dart 中相等），框架会把 `receivedTransition` 置空，
  上一页仍然走自己的 `buildTransitions`。

### 4.2 关键代码

```dart
class _DisplayCornerClip extends StatelessWidget {
  const _DisplayCornerClip({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 只裁「自己是上页、且正在整屏滑动」的那一页
    final isTopPageSliding = animation.value > 0.0 &&
        animation.value < 1.0 &&
        secondaryAnimation.value == 0.0;
    final radii =
        isTopPageSliding ? MediaQuery.maybeDisplayCornerRadiiOf(context) : null;
    // 界面缩放伪造了 devicePixelRatio，圆角值不会跟着缩放
    final scale = radii == null
        ? 1.0
        : MediaQuery.devicePixelRatioOf(context) /
            View.of(context).devicePixelRatio;

    Radius shrink(Radius r) {
      final value = r.x / scale - 1;           // 少 1dp，收尾时不露下层
      return Radius.circular(value > 0 ? value : 0);
    }

    final borderRadius = radii == null
        ? BorderRadius.zero
        : BorderRadius.only(
            topLeft: shrink(radii.topLeft),
            topRight: shrink(radii.topRight),
            bottomLeft: shrink(radii.bottomLeft),
            bottomRight: shrink(radii.bottomRight),
          );
    // 结构始终保持 ClipRRect：增删 widget 会让整页重新挂载、丢页面状态；
    // 不裁剪时用 Clip.none，不产生 clip layer。
    return ClipRRect(
      borderRadius: borderRadius,
      clipBehavior:
          borderRadius == BorderRadius.zero ? Clip.none : Clip.antiAlias,
      child: child,
    );
  }
}
```

要点：

- **只裁上页**：只有「自己是上页、且正在整屏滑动」（`animation ∈ (0,1)` 且
  `secondaryAnimation == 0`）的那一页才裁。被压住的下页不做裁剪：
  - 静止页裁不裁在视觉上没有区别，不裁还能避免「上报半径是圆形近似、面板实际
    是超椭圆」这类形状差异在四角露出底色，也不用长期挂一个 clip layer；
  - 下页只做 1/3 视差（`_kMiddleLeftTween`），右边缘基本都停在上页左边缘右侧
    （见 4.3 的数值表），两侧都不会露出直角，少裁一页就少一个 clip layer；
  - `secondaryAnimation == 0` 这一条还能排除「快速连推时仍在运动的下页」
    （它此时 `animation ∈ (0,1)` 且 `secondary > 0`），避免两页同时变圆。
- **用 `maybe...Of`**：它只订阅 `displayCornerRadii` 这一个 aspect，
  窗口尺寸/键盘/亮度变化不会带着整个页面重建。
- **不需要额外加监听器**：`_ModalScope` 用 `ListenableBuilder` 监听
  `animation` / `secondaryAnimation`，动画每一帧都会重建 transitions，
  直接读 `animation.value` 就是最新值（见 4.3）。
- **必须除以 `uiScale`**：`MyApp._builder` 在 `uiScale != 1` 时把
  `devicePixelRatio` 乘了 `uiScale`、`size` 除以 `uiScale`，
  但 `displayCornerRadii` 是按真实 dpr 算好的逻辑值，不修正会偏大 `uiScale` 倍。
- **减 1 个逻辑像素**：收尾阶段页面已经接近贴屏，应用边界比报告半径略内缩，
  可以避免圆形裁剪比面板切角更「狠」时在角上露出一线下层画面。
- **必须保留 `ClipRRect` 结构**：裁剪 / 不裁剪之间只能切
  `clipBehavior` 与 `borderRadius`，**不要**改成 `return child` 或增删
  widget —— 那会让整页重新挂载、丢失页面状态（滚动位置、控制器等）。
  小窗 / 自由窗口会把四个角的半径变成 0，同样走 `Clip.none`。
- **保留部分角为 0**：分屏只圆贴屏的两角，这是系统语义。
- **不加阴影 / 不加 `BackdropFilter`**：圆角缺口里的背景已经由
  `GetPageRoute.barrierColor = 0x18000000` 的压暗提供；
  `CupertinoPageTransition` 的左缘阴影只有 `0x04000000`（1.5% 黑），
  没有被 clip 也看不见。

### 4.3 为什么「只在滑动时裁」不会造成收尾卡顿

早期判断是「切换 clip 会触发整页重绘」，实际看 Flutter 的
`_ModalScope` 结构并不成立：

- 每个路由的页面内容被包在 `RepaintBoundary(key: _subtreeKey)` 里
  （`routes.dart` 的 `_ModalScopeState.build`），而 `buildTransitions`
  （以及这里的 `ClipRRect`）在这层 `RepaintBoundary` **外面**；
- 所以切换 `clipBehavior` 只会 `markNeedsPaint` 到路由外层的那一圈转场壳，
  页面 layer 直接复用，不会重绘页面内容；
- 同一处还有 `ListenableBuilder(listenable: 路由的 animation +
  secondaryAnimation)`，动画每一帧都会重建 transitions，因此读
  `animation.value` 不需要自己加监听；
- 反过来说，如果做成「静止也裁」，就多了一层永久 clip，且一旦上报半径与面板
  形状不一致（圆形 vs 超椭圆），四角会长期露出底色——风险更大。

### 4.3.1 下页不裁为什么不会露出直角（数值验证）

上页左边缘 = `(1 − c_p)·W`，下页右边缘 = `(1 − c_s/3)·W`，两条曲线不同
（`route.dart:548-553`）：

- `c_p = Curves.fastEaseInToSlowEaseOut(t)`，
  `ThreePointCubic(0.056,0.024 / 0.108,0.3085 / 0.198,0.541 / 0.3655,1.0 / 0.5465,0.989)`
- `c_s = Curves.linearToEaseOut(t)` = `Cubic(0.35, 0.91, 0.33, 0.97)`

逐点求解（`gap = c_p − c_s/3`，正数表示下页右边缘在上页左边缘右侧）：

| t | c_p | c_s | 上页左边缘 | 下页右边缘 | gap |
| --- | --- | --- | --- | --- | --- |
| 0.008 | 0.0052 | 0.0208 | 0.9948W | 0.9931W | **−0.0018W** |
| 0.02 | 0.0193 | 0.0521 | 0.9807W | 0.9826W | +0.0019W |
| 0.1 | 0.2383 | 0.2615 | 0.7617W | 0.9128W | +0.1511W |
| 0.3 | 0.7604 | 0.7195 | 0.2396W | 0.7602W | +0.5206W |
| 0.5 | 0.9422 | 0.9201 | 0.0578W | 0.6933W | +0.6355W |
| 1.0 | 1.0000 | 1.0000 | 0 | 0.6667W | +0.6667W |

唯一的例外是起步瞬间 `t≈0.008` 的 −0.18%W 亚像素交叉：小米 15 逻辑宽约
393dp 时只有 ≈0.7dp（≈2 物理像素），且此时两页都在 `x > 0.99W`、被屏幕切角
挡住，不可见。所以下页不裁是安全的。

命中测试不受影响：`RenderClipRRect.hitTest` 只在 `clipper != null` 时裁剪命中区，
这里传的是 `borderRadius`，左缘返回手势与页面内滚动都不变。

## 5. 补丁工程

- 生效方式：`lib/scripts/patch.ps1 android`（CI 的 `build.yml` 已包含）；
- 该脚本对补丁做了幂等处理：`git apply --reverse --check` 成功就跳过，
  否则正向 apply；文件在应用前会被规范成 LF + UTF-8 无 BOM；
- **修改过 patch 文件后**，如果 pub cache 里还是旧补丁，反向检查会失败、
  正向 apply 会冲突。此时先重置再跑：

  ```powershell
  $dir = Get-ChildItem "$env:LOCALAPPDATA\Pub\Cache\git" -Directory -Filter 'getx-*'
  git -C $dir.FullName checkout -- .
  lib/scripts/patch.ps1 android
  ```

- 回滚：同样 `git -C <getx 目录> checkout -- .` 即可恢复未打补丁的 getx。

## 6. 验证

已完成的静态验证：

- 新补丁可干净应用到 getx `3e65da8`（`git apply --check` 通过）；
- 在临时 clone 中 `flutter pub get` + `dart analyze`：
  修改后的 `get_transition_mixin.dart` **No issues found**；
  整个 getx `lib` 仅剩 1 条既有的 `onPopPage` deprecated info；
- 临时 widget 测试（`GetMaterialApp` + `Transition.cupertino`，用
  `MediaQueryData.applyDisplayCornerRadii` 注入四角半径）覆盖六件事：
  1. 转场进行到一半时 `ClipRRect.borderRadius == 24 - 1 = 23`；
  2. **同一时刻生效裁剪的 `ClipRRect` 只有 1 个**（下页被压住，不裁）；
  3. 静止时所有 `ClipRRect` 都是 `Clip.none`（不裁、无 layer）；
  4. 快速连推（B 的 `animation≈0.4` 时推 C）仍然只有 1 个生效裁剪；
  5. 伪 dpr ×1.5（模拟 `uiScale`）时半径为 `24 / 1.5 - 1 = 15`；
  6. 半径在 24 → 0 → 24 之间切换时页面 State 保持（计数器不重置），
     验证「只切 clip 属性、不增删 widget」不会丢状态。

实测「生效裁剪的页面集合」（finder 同时统计 offstage 子树）：

| 采样点 | 结果 |
| --- | --- |
| 静止 | `{}` |
| push @250ms | `{上页}`（改前是 `{上页, 下页}`） |
| push 结束 | `{}` |
| pop @250ms | `{上页}`（改前是 `{上页, 下页}`） |
| 左缘拖动 150px / 250px | `{上页}` |
| 快速连推 C @100ms | `{C}`（B 被排除） |

待小米 15 真机确认（脚本/步骤）：

1. 打印实际值（确认非 0）：

   ```dart
   debugPrint('corner=${MediaQuery.maybeDisplayCornerRadiiOf(context)} '
       'dpr=${MediaQuery.devicePixelRatioOf(context)} '
       'viewDpr=${View.of(context).devicePixelRatio}');
   ```

2. 转场收尾（页面快贴屏时）盯四角：若露出下层画面就把 `-1` 调到 `-2` / `-3`；
   静止状态本身不裁剪，所以**静止时四角应当与系统完全一致**；
3. 首页 → 视频详情 → 左缘拖动返回 / 中途松手取消，看四个角是否与屏幕弧度连续；
4. `flutter run --profile` + DevTools Performance：开/关圆角各录 3 次
   「首页 → 视频」，对比 raster 帧时间，重点看收尾帧有无尖峰；
5. 边界场景：分屏（只应圆贴屏的两角）、横屏、PiP、悬浮玻璃底栏
   （唯一 `BackdropFilter`）、图片查看器（`tmpPadding` 全屏）、
   **WebView 页**（平台视图，见 7. 已知风险）；
6. 小窗 / 自由窗口进出各一次：确认页面**状态没有丢失**（滚动位置、输入内容），
   这是 `Clip.none` 而非 `return child` 的原因。

## 7. 已知风险

| 风险 | 影响 | 处理 |
| --- | --- | --- |
| HyperOS 上报 0 | 功能静默不生效（无副作用） | 真机打印确认；必要时走 JNI 读 `rounded_corner_radius` 兜底 |
| 上报半径偏大 / 面板是超椭圆 | 转场收尾贴近屏幕角时露出一线下方画面 | 先把 `-1` 调到 `-2` / `-3`；仍明显则说明圆形裁剪与面板超椭圆不匹配，可试 `ClipRSuperellipse`。静止不裁剪，不会长期露底 |
| 嵌套 Navigator（当前仓库没有） | 页面小于窗口时圆角变成可见装饰 | 加「页面尺寸 == 窗口尺寸」判断 |
| PiP / 自由窗口恰在屏幕角 | 可能只圆一个角 | 属系统语义，可接受 |
| 平台视图（WebView）不受 Flutter 图层裁剪 | `/webview` 页在转场中露出直角 | Android 混合合成（hybrid composition）把 WebView 放进独立的 Android View，`PlatformViewWrapper` 不支持非矩形裁剪，`ClipRRect` 对它无效。只在转场那一瞬间可见；要彻底修需要把 WebView 改成 texture 模式（性能代价更大），当前接受 |
| 被压住的下页不裁（含快速连推打断的过渡） | 打断过渡时下页左缘会露出视差条带（宽度 = 下页 `secondaryAnimation/3`，最多约 1/3 屏宽；示例 `secondary=0.2` 时约 6.7%W），那里是直角 | iOS 原生在被**打断**的转场里同样是直角，属于一致的观感；若要求圆角需改成「所有运动中的页面都裁」，代价是多一个 clip layer、且失去「半径偏大时露出压暗下页而非空背景」的抗性 |

## 8. 未采用的备选方案

| 方案 | 不采用的原因 |
| --- | --- |
| `corner_radius_plugin` / 自写 MethodChannel | 重复引擎在 Android 12+ 已提供的能力，只为 API < 31 与 iOS 才有价值 |
| 改 `ThemeData.pageTransitionsTheme` | GetX 路由不读，仓库注释已注明 |
| `MyApp._builder` 里全局 `ClipRRect` | 裁剪固定在屏幕层，不随页面滑动；会误裁 dialog / bottom sheet |
| 用 `GetPage.copy()` 批量包页面 | 漏掉 12 处 `Get.to(widget)` 与 6 处直接 `GetPageRoute(...)`，覆盖率不如补丁 |
| 静止时也裁剪（常驻 clip） | 上报半径是圆形近似、面板实际是超椭圆时，四角会长期露出底色；还多一层永久 clip layer |
| 上下两页都裁 | 下页被压住时裁剪没有视觉收益（见 4.3.1），还会让「半径偏大」时露出的是空背景而不是被压暗的下页 |
| 把 clip 移到 `CupertinoPageTransition` 外层（连左缘阴影一起裁） | 不透明全屏路由下 clip 盒 = 整屏，mask 固定在屏幕角上，效果直接消失 |

## 9. 后续可选

- 想让 `sharedAxis` / `fade` / `zoom` 也带圆角：**不能**简单挪到
  `GetPageRoute._getChild()`——那里拿不到转场动画，无法判断「是否正在滑动」。
  需要在那里自己接动画，例如
  `ModalRoute.of(context)?.animation`（配合 `AnimatedBuilder`）或
  `Get.routing.route is PageRoute` 后再读其 `animation`/`secondaryAnimation`；
- 想做成用户开关：`Transition` 枚举来自 getx、项目侧不能新增值
  （`style_settings.dart` 已注明），需要给补丁加一个应用注入的 hook
  （包内读不到 `Pref`），再新增 `SettingBoxKey` + `SwitchModel`。

## 10. 改动清单

| 文件 | 改动 |
| --- | --- |
| `lib/scripts/getx_ios_transition.patch` | 在 `cupertino` 分支把页面内容包进 `_DisplayCornerClip`（**仅正在整屏滑动的上页**按屏幕硬件圆角裁剪） |
| `lib/scripts/patch.ps1` | 补丁说明补充「按屏幕硬件圆角裁切（仅正在滑动的上页）」一句 |
| `docs/PiliPlus-Android动画清单.md` | 1.3.1 节新增圆角条目，并补充旧补丁残留时的重置步骤 |
| `docs/PiliPlus-Android屏幕圆角转场实现说明.md` | 本文（设计依据、实现、验证与风险） |

不改动：`pubspec.yaml`（不新增依赖）、`lib/utils/theme_utils.dart`
（`pageTransitionsTheme` 对 GetX 无效）、`lib/main.dart`（无需全局裁剪）。
