# PiliPlus 顶栏/底栏动画重构与视频转场优化报告（v3）

**日期**：2026-09-28　**范围**：首页与动态页顶栏、悬浮底栏与选中气泡、视频详情页转场、播放输出后端
**验证状态**：整个 `lib` 编译通过；release APK 构建成功（22.9 MB）
**对照基线**：「改造前」= 本次工作开始时的代码（git HEAD）

## 修订记录

| 版本 | 变更 |
| --- | --- |
| v1 | 首页/动态页顶栏改为 `SliverPersistentHeader`（pinned sliver） |
| v2 | 顶栏方案**回退**为「静态悬浮玻璃层 + 局部重建」；新增气泡 1.3 倍按压、底栏更透明、默认开启 Vulkan 输出 |
| v3 | 补充「改造前 vs 最终实现」逐项对照（第二、三章）与「效果汇总」（第四章） |

---

## 一、背景：问题与根因

| 现象 | 根因（改造前） |
| --- | --- |
| 首页滚动「有点卡」 | 1）首页顶栏的 `Obx` 包住**整块**玻璃（含 `LiquidGlass` + `BackdropFilter`），滚动时每帧重建；2）首页每帧写全局 `barOffset`，而动态页（`AutomaticKeepAlive` 存活）的 `Obx(page)` 也包着整页玻璃，于是**首页滚动会让动态页每帧重建整页玻璃** |
| 底栏「卡在半路」 | 底栏与顶栏共用同一个 `barOffset`（0~52）做连续位移，慢速/短距滑动松手后停在中途 |
| 选中气泡没有反馈 | 只有「切换 tab 时 500 ms 横向滑动」一种状态 |
| 视频详情页之间切换「转场最后卡一下 + 播放器闪一下」 | 取流回来后紧接着 `open` 媒体（重建解码器 + 纹理 + 首帧上屏）是重活，正好压在 300 ms 转场收尾那一帧上 |

---

## 二、改造前 vs 最终实现：顶栏

### 2.1 首页顶栏

| 项目 | 改造前 | 最终实现 | 变动内容 | 效果 |
| --- | --- | --- | --- | --- |
| 位置 | 页面 `Stack` 里 `Positioned(top: 0, left: 0, right: 0)` 的悬浮玻璃层，位于 `TabBarView` **之外** | **同**（期间 v1 曾改成插进各 Tab 页滚动视图的 pinned sliver，已回退） | 无 | 顶栏铺满整宽、切分类 Tab 时整体不动、盖住分区页左侧列 |
| 内部结构 | `LiquidGlass > Column[ Column[SizedBox(状态栏), ClipRect(搜索区)], 分类 Tab 栏 ]` | `LiquidGlass > Column[ SizedBox(状态栏), ClipRect(搜索行包装), 分类 Tab 栏 ]` | 去掉一层嵌套；搜索行的「高度 + 位移」包装单独成层 | 视觉不变 |
| **每帧重建范围** | 外层 `Obx(glassTopBar)` 包住**整块**：玻璃、`BackdropFilter`、整个 `Stack`（含 `Positioned.fill(body)` 的 inset 包装）每帧重建 | 玻璃实例在 `build` 里建一次；每帧只重建两个小叶子：`Obx(() => 搜索行包装(静态搜索行))` 与 `Obx(bodyWithInset)` | 重建范围从「整块玻璃 + body 的 inset 包装」收窄到「一个 `SizedBox` + `ClipRect` + `CustomHeightWidget`」+「一个 `TopBarInset`」 | 滚动时不再新建 `BackdropFilter`、不重建 body 侧包装，首页滚动更稳 |
| 收起驱动 | `barOffset`（`RxDouble`，0~52）：`CommonPageState` 按滚动增量写值 + `correctBy` 补偿滚动（`needsCorrection`）+ 抬手 220 ms `easeOutCubic` 补间 | **同** | 无 | 跟手 1:1；抬手/惯性结束后补到端点（0 或 52） |
| 让位 | `TopBarInset(value: 状态栏 + 搜索区当前高度 + 分类 Tab 栏)` + 各 Tab 页 `TopBarInsetSpacer` | **同** | 无 | 列表让出的空间随收起变小，内容贴着玻璃底边 |
| 「瞬时」模式 | 搜索区 `AnimatedContainer(height: 0/52)` + 让位 `TweenAnimationBuilder`（500 ms `easeInOutCubicEmphasized`） | **同** | 无 | 「跟随手指 / 瞬时」设置继续生效 |
| 收起时的裁切 | `ClipRect` 包住搜索区（`CustomHeightWidget` 不裁剪） | **同** | 无 | 收起的搜索行不会画到状态栏那片玻璃上 |

### 2.2 动态页顶栏

| 项目 | 改造前 | 最终实现 | 变动内容 | 效果 |
| --- | --- | --- | --- | --- |
| 顺序 | `Column[ 状态栏, 分类 Tab 栏, 可收起 UP 面板 ]`（Tab 栏在上、面板在下） | **同**（v1 曾把面板放到 Tab 栏之上，已修正） | 恢复原顺序 | 与首页一致：Tab 栏在上，可收起的面板在它下面 |
| 每帧重建范围 | 外层 `Obx(page)` 包住整页（含玻璃） | 玻璃实例建一次；每帧只重建 `Obx(() => topPanelArea(upPanelHeight()))` | 收窄到「UP 面板包装」 | 滚动时不再重建整页玻璃 |
| 面板收起 | 76↔52 比例映射（面板高 76、`barOffset` 量程 52）+ `CustomHeightWidget` 按当前高度裁切 + `ClipRect` | **同** | 无 | 收到底时面板高度正好为 0，不会剩一条空玻璃 |
| 切分类 Tab | 顶栏（Tab 栏 + UP 面板）不动，只有下方内容与下划线切换 | **同** | 无 | 符合预期 |
| 左/右固定位置的面板 | 在玻璃之外固定摆放，用 `barInset` 让位 | **同** | 无 | 不受影响 |

### 2.3 为什么最终不是 v1 的 sliver（中间方案废弃原因）

v1 把顶栏做成 pinned sliver 插进各 Tab 页的 `CustomScrollView`，实测三个无法接受的问题：

| 问题 | 根因 |
| --- | --- |
| 切分类 Tab 时顶栏整体横滑 | 每个 Tab 页各有一份玻璃 + 一个 `TabBar`，跟着 `TabBarView` 一起滑动 |
| 分区页左上方空白 | 玻璃只盖住右侧滚动视图，左侧竖 Tab 栏上方没有玻璃 |
| 直播/推荐顶栏两侧有缝、不模糊 | `lib/pages/live/view.dart` 整个页面被 `Container(margin: EdgeInsets.symmetric(horizontal: Style.safeSpace /*12*/))` 包着，玻璃跟着左右各缩进 12 px（推荐页同样有水平留白） |

结论：顶栏必须留在页面 `Stack` 里、位于 `TabBarView` **之外**。因此最终实现 = 改造前的结构 + 局部重建优化（外观与行为回到原版，性能优于原版）。

---

## 三、改造前 vs 最终实现：底栏 / 气泡 / 视频页 / 参数

### 3.1 悬浮底栏

| 项目 | 改造前 | 最终实现 | 变动内容 | 效果 |
| --- | --- | --- | --- | --- |
| 收起方式 | `sync`：`FractionalTranslation(barOffset/52)` 连续位移；`instant`：`showBottomBar` + `AnimatedSlide` 500 ms `easeInOutCubicEmphasized` | 两种模式统一为**两态**：`showBottomBar` + `AnimatedSlide` **220 ms `easeOutCubic`** + `RepaintBoundary` | 连续位移 → 两态；时长/曲线调整；加 `RepaintBoundary` | 上滑一次性收起、下滑一次性弹出，不再停在半路；`AnimatedSlide` 内部是 `Transform`，不触发布局，动画期间玻璃子树不重建 |
| 开关创建 | 只有 `barHideType == instant` 才创建 `showBottomBar` | 只要 `hideBottomBar` 为真就创建（`barOffset` 仍为 sync 保留，供顶栏/动态页使用） | 创建条件放宽 | 两种「收起方式」都能两态 |
| 方向判定 | `onNotificationType1`（`UserScrollNotification`）处理方向；sync 走的 `onNotificationType2` **不处理方向** | type1 不变，并在 `onNotificationType2` 里把 `UserScrollNotification` 转发给 type1 | 补一段转发 | 默认（sync）模式下两态才真正生效 |
| 竖排 Tab 80 px 补偿 | sync 读 `barOffset == 0`，instant 读 `showBottomBar` | 统一读 `showBottomBar` | 判断源统一 | 两种模式表现一致 |
| 玻璃透明度 | alpha 0.46（暗）/ 0.36（亮），blur 28 | alpha **0.32 / 0.22**（悬浮胶囊 + M3 底栏 + 旧版底栏共 3 处） | 下调透明着色 | 更「轻」的玻璃感，下层内容透出更明显 |

### 3.2 选中气泡（悬浮底栏内）

| 项目 | 改造前 | 最终实现 | 变动内容 | 效果 |
| --- | --- | --- | --- | --- |
| 切换 Tab | 单个气泡 500 ms `easeInOutCubicEmphasized` 横向滑动（用 `Transform`，不重排） | **同** | 无 | 保持 |
| 按住 | 无 | 按住放大 **1.3 倍**（150 ms `easeOutCubic`），抬手缩回 | 新增 `Listener` + `ScaleTransition` | 明确的按压反馈（1.3 倍会上下各凸出约 3 px，属预期） |
| 跟手拖动 | 无 | `onPointerMove` 相对手指位移换算成「第几格」，越过 4 px 才启动；位置写入 `ValueNotifier`，只有气泡自己重建 | 新增 | 可以按住把气泡拖到别的格 |
| 抬手 | — | 缩回并吸到最近一格；目标格与当前不同则顺带切换 | 新增 | 吸附后气泡与选中态一致 |
| 手势冲突 | — | 用 `Listener`（原始指针事件）而非 `GestureDetector` | — | 不与每个 destination 的点击识别器抢手势，点按照旧 |

### 3.3 视频详情页

| 项目 | 改造前 | 最终实现 | 变动内容 | 效果 |
| --- | --- | --- | --- | --- |
| 播放器初始化时机 | `initState` 里 `queryVideoUrl` → 取流回来后**立刻** `open` 媒体（重建解码器/纹理、首帧上屏），正好压在 300 ms 转场收尾那一帧 | 取流照旧立刻发起；真正的 `open` 等本页转场动画结束（`runAfterRouteAnimation`，另有 600 ms 兜底） | 新增 `_initGate` + `deferPlayerInit(Future)`，`_initPlayerIfNeeded` 开头 `await` 它（只生效一次） | 转场收尾不再抢帧；播放器首帧不再落在转场中途 |
| 返回恢复播放 | `runAfterRouteAnimation(_resumeOnPopNext)` | **同**（不经 gate） | 无 | 保持 |
| 播放输出后端 | `videoOutputBackend` 默认 `''`（完全跟随 mpv） | 默认 **`vo=gpu-next,gpu-api=vulkan`**（仅 Android） | 改默认值 | 由 mpv 用 Vulkan 后端输出；回退入口：设置 → 播放设置 → 视频输出后端 → 「默认」 |

---

## 四、效果汇总（用户可感知）

| 可感知效果 | 来自哪些变动 |
| --- | --- |
| 首页滚动更稳、掉帧减少 | 顶栏玻璃不再每帧重建（重建范围收窄到两个小叶子）；动态页不再被首页滚动牵连重建整页玻璃 |
| 顶栏外观与切换行为回到原版（铺满整宽、切 Tab 不动、分区页不空白、两侧不露缝） | 顶栏位置回退为页面级静态悬浮层（v1 的 sliver 方案废弃） |
| 底栏不再「卡在半路」 | 两态收起 + 220 ms `easeOutCubic`，且动画不触发布局、不重建玻璃 |
| 底栏玻璃更通透 | 透明着色 alpha 0.46/0.36 → 0.32/0.22 |
| 选中气泡有明确按压反馈、可拖拽切换 | 1.3 倍按压 + 跟手拖动 + 抬手吸附 |
| 视频详情页之间切换：转场收尾不卡、播放器不闪 | 播放器 `open` 推迟到转场之后 |
| 播放走 Vulkan 输出 | `videoOutputBackend` 默认开启 |

---

## 五、复查与修复

| # | 问题 | 修法 |
| --- | --- | --- |
| 1 | （v1）收尾补间在「下滑/展开」方向也会 `animateTo(0)`，把列表额外拽回顶部 | 只在「上滑/收起」方向补 |
| 2 | （v1）`ScrollController.position` 在挂两个 position 时会断言崩溃 | 改用 `controller.positions` 校验 |
| 3 | （v1）悬浮气泡可能被锁死：一次 pointer-down 后若没收到 up/cancel，后续按下全被忽略 | 新按下直接接管 |
| 4 | （v1）`stretchConfiguration` 每帧新建对象 | 改 `static final` |
| 5 | （v2）顶栏进 Tab 页导致切 Tab 横滑 / 两侧缝隙 / 分区页空白 | 顶栏回退为页面级静态悬浮层 |
| 6 | （v2）动态页 Tab 栏与 UP 面板顺序颠倒 | 恢复为 `状态栏 → Tab 栏 → UP 面板` |
| 7 | （v2）默认（sync）模式下两态底栏拿不到滚动方向 | `onNotificationType2` 转发 `UserScrollNotification` |

---

## 六、验证记录

| 项目 | 结果 |
| --- | --- |
| `dart format`（全部改动文件） | 干净 |
| 整个 `lib` 编译（临时 `import main.dart` 测试，跑完已删） | `All tests passed!` |
| release APK 构建 | 成功，22.9 MB：`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` |
| 一次性探针 widget test（v1 期间验证顶栏几何与收尾补间） | 已跑完并删除 |
| 工作区 | 10 个改动文件 + 本报告（md/docx） |

改造前 → 最终，以下参数**保持不变**：顶栏 blur 16、底栏 blur 28 / 高光边 1.2 / 形状 55 高圆角胶囊、底栏切 tab 气泡 500 ms、顶栏与底栏收尾补间 220 ms `easeOutCubic`。

---

## 七、遗留问题与建议

| # | 事项 | 建议 |
| --- | --- | --- |
| 1 | 气泡 1.3 倍会略微凸出 55 px 高的胶囊 | 观感不佳可改「只横向 1.3」或整体 1.15 |
| 2 | 分区页左侧竖 Tab 栏的让位随收起动态变化（收起过程中每帧重排分区页） | 这是原版行为；要消除需把竖 Tab 栏放进滚动视图，改动较大 |
| 3 | `CommonPageState` 的收尾补间仍用 `Timer.periodic` | 顶栏回退后它重新成为主力，暂不动；将来可换 `ScrollController.animateTo` |
| 4 | 视频页若「闪一下」仍在 | 可试 `VideoControllerConfiguration(androidAttachSurfaceAfterVideoParameters: true)`，需真机对比 |
| 5 | Vulkan 默认开启 | 若黑屏/花屏，先在设置里切回「默认」，并反馈机型 |

---

## 八、v4 追加：pinned sliver 让位 + 页面级静态玻璃（空间与外观解耦）

### 背景：v2 方案的不足

v2 为了修掉 v1 的三个毛病，把「让位」也交回给了页面：各 Tab 页自己算内边距 + `correctBy` 偷滚动，
首页用共享的 `barOffset` 驱动、动态页再按比例把 52 的量程换算成 76 的面板高度，收尾补间还是 `Timer.periodic`。
代价是：内容与手指不是原生 1:1；`TopBarInset` 的 `value` 每帧变，各 Tab 页每帧重排；比例换算容易对不齐。

### v4 的做法：把「空间」和「外观」拆开

| | v1（被否） | v2（回退） | **v4（本次）** |
| --- | --- | --- | --- |
| 让位（空间） | 各 Tab 页的 `SliverPersistentHeader` 里画玻璃 | 改内边距 + `correctBy` 偷滚动 | 各 Tab 页 `TopBarInsetSpacer`：**不可见 pinned sliver**（子节点 `SizedBox.expand()`，只占位不画东西） |
| 外观（玻璃） | 同上（在 Tab 内容里，会跟着切 Tab 横滑） | 页面 `Stack` 里的静态悬浮层 | **页面 `Stack` 里的静态悬浮层**（在 `TabBarView` 之外，铺满整宽） |
| 收起驱动 | sliver 自己 | 全局 `barOffset`（共享、滞后） | **滚动通知驱动的页面级 `ValueNotifier`**（每个滚动帧都发，1:1；用 `metrics` 实例做白名单） |
| 收尾补间 | sliver + `animateTo` | `Timer.periodic` 写 `barOffset` | `animateTo(extent, 220ms, easeOutCubic)`（原生、无定时器） |

关键点：

1. **让位就是一个普通占位 sliver**（`TopBarInsetSpacer` → `SliverToBoxAdapter`）：玻璃本体由页面 `Stack` 画，
   这里只占高度。同步模式高度固定为展开高度，即时模式高度 = 展开高度 − 收起进度。
   （v4 早期用过 `SliverPersistentHeader(pinned: true)`，实测与普通占位 sliver 的几何**完全等价**——
   内容顶部都是 `展开高度 − 滚动位置`，见下面「复核修复」第 1 条，所以已删掉。）
2. **玻璃在 `TabBarView` 之外**：切分类 Tab 时不再横滑；不会被各页自己的左右 12 px 留白切窄；
   也天然覆盖排行榜左侧竖排 Tab 栏那一整宽区域。
3. **同一个进度驱动**：页面把所有竖向列表的滚动通知汇总成一个 `ValueNotifier<double>`
   （只认当前可见 Tab 的列表，用 `metrics` 实例做白名单），玻璃、让位 sliver、排行榜左侧竖栏都读它，
   算出的高度与让位严格相等，不会出现「让位比玻璃少一点、漏出背景」。
4. **`TopBarInset` 的值都是常量**（`value` = 展开高度，`minValue` = 收起后仍保留的高度），
   不再每帧 `updateShouldNotify`（少了每帧一层 `InheritedWidget` 通知与各 Tab 页重排）；
   收起进度通过 `TopBarInset.collapse`（`ValueListenable`）下发，
   `followScroll` 告诉让位 sliver 是「滚动自己让位（空间固定）」还是「空间跟着收起进度收缩」。
5. **收尾补间回归原生**：`CommonPageState` 重新加回 `pinnedHeaderExtent` /
   `pinnedHeaderScrollController` / `onPinnedHeaderNotification`——手指抬起（`ScrollEndNotification`
   且本次是上滑）时 `animateTo(extent, 220ms, easeOutCubic)` 补到端点；页面 `useBarOffset => false`
   后，`Timer.periodic` 那套完全不参与（每个通知还先用 `identical(positions.first, metrics)` 过滤，
   避免被保活的邻页滚动误触发）。
6. 排行榜左侧竖排 Tab 栏用 `TopBarInset.collapse` 跟着顶栏一起上移（见下面「复核修复」第 5 条）。

### 四个问题的对应修复

| # | 问题 | 原因 | v4 修法 |
| --- | --- | --- | --- |
| 1 | 切分类 Tab 时整个顶栏跟着横滑 | v1 的玻璃长在 Tab 内容里 | 玻璃移到页面 `Stack`（`TabBarView` 之外） |
| 2 | 排行榜左侧一栏上方空白 | 用展开高度做 padding | 改用 `TopBarInset.collapse` 跟顶栏一起动（见复核修复第 5 条） |
| 3 | 直播/推荐顶栏模糊两侧有缝 | 玻璃在带 12 px 外边距的页面内容里 | 玻璃铺满整宽，在内容之外 |
| 4 | 动态页顺序 + 切 Tab 时顶栏/面板要静止 | 顺序颠倒 + 玻璃在 Tab 内 | `状态栏 → Tab 栏 → UP 面板`，整块在 `TabBarView` 之外 |

### v4 改动文件

| 文件 | 变动 |
| --- | --- |
| `lib/common/widgets/liquid_glass.dart` | `TopBarInset` 增加 `minValue` / `collapse` / `followScroll`；`TopBarInsetSpacer` 简化成普通占位 sliver（同步固定高度 / 即时随收起收缩） |
| `lib/pages/common/common_page.dart` | 恢复 `pinnedHeaderExtent` / `pinnedHeaderScrollController` / `onPinnedHeaderNotification`（仅同步模式生效）；新增 `useBarOffset` 开关 |
| `lib/pages/home/view.dart` | 让位交给 sliver；滚动通知 + `ValueNotifier`/`AnimationController` 驱动收起；`TopBarInset(collapse:, followScroll:)` |
| `lib/pages/dynamics/view.dart` | 同上（面板 76）；`TopBarInset(value: barInset, minValue: 状态栏 + Tab 栏)` |
| `lib/pages/rank/view.dart` | 左侧竖排 Tab 栏用 `TopBarInset.collapse` 跟着顶栏一起动 |
| `lib/utils/storage_pref.dart` | `barHideType` 默认值 `sync` → `instant`（上滑收起/下滑出现成为默认） |

### 复核修复（本次自查发现并修掉的问题）

1. （历史）**pinned 头部的子节点不能是 0 高度。** 当时用 `SliverPersistentHeader(pinned: true)` 时，
   `layoutExtent = clamp(maxExtent - scrollOffset, 0, paintExtent)` 而 `paintExtent` 受子节点实际高度影响：
   `SizedBox.shrink()` 会让 `paintExtent = 0`、`layoutExtent = 94`，debug 下直接抛
   `SliverGeometry is not valid: layoutExtent exceeds paintExtent`（`SizedBox.expand()` 可以绕过）。
   后来实测这个 pinned 头部与普通占位 sliver 的几何完全等价（都是 `展开高度 − 滚动位置`），
   于是直接删掉了 pinned 头部——问题连同组件一起消失。
2. **收尾补间会空转。** 列表本身就短于量程时（`maxScrollExtent < 量程`），`animateTo(量程)` 只能停在 `maxScrollExtent`，
   抬手结束又触发一次补间 → 每 220ms 起一次动画、永不停。已加 `pixels >= maxScrollExtent` 判断。
3. **首帧 / 切到未访问的 Tab 时拿不到 `ScrollPosition`。** `HomeTabType.ctr` 内部是 `Get.find`，而 `TabBarView`
   的页面是懒建的（而且在 layout 阶段才建）：首帧调用会抛异常；就算兜成 null，玻璃也只能渲染成「完全展开」，
   之后**没有任何东西会让它重新订阅** → 第一次滚动时让位（sliver）在收、玻璃却纹丝不动，
   表现为内容被搜索栏多盖 52px。→ 驱动源改成**滚动通知 + 页面级 `ValueNotifier`**（每个滚动帧都发，天然 1:1，
   也不存在订阅生命周期），并用 `metrics` 实例做白名单（保活的其他 Tab、卡片里内嵌的竖直列表、UP 面板都不会把顶栏带偏）。
4. **切分区后订阅失效。** 排行榜/番剧里还有一层 Tab，外层（首页）的 `TabController` 不会动，
   基于 `ScrollPosition` 的订阅会一直盯着旧分区的列表 → 顶栏停在旧状态（与让位对不上，出现一条空白）。
   改成通知驱动后，新分区的列表一落位就会重新认一次并对齐；切 Tab 时再按新 Tab 的真实位置额外对齐一次。
5. **排行榜左侧竖栏给常量两个方向都不对。** 只给「收起后的高度」会一直贴在最上面、被搜索栏盖掉一项（而且点不到）；
   只给展开高度又会在收起后留一条空白。原实现本来就是跟着顶栏动态变的，v4 用 `TopBarInset.offset` 恢复了这个行为，
   而且比原来省：原来每帧重排整个分区页，现在只重建那一层包装。
6. 玻璃/面板里的静态内容改为作为 `ValueListenableBuilder` 的 `child` 传下去，重建范围更明确。

### 即时模式：「上滑收起隐藏，下滑出现」

设置里的「顶/底栏收起类型」有两个值：**同步**（跟手 1:1）与**即时**（上滑收起/下滑出现）。
**默认已改成「即时」**（`storage_pref.dart` 里 `barHideType` 的默认值 `sync` → `instant`）：
这样新装、或没动过该设置的机器直接就是「上滑收起隐藏、下滑出现」（与底栏两态一致）；
想跟手 1:1 的到设置里切「同步」即可（改完需重启）。

| 模式 | 玻璃 / 让位怎么动 |
| --- | --- |
| 同步 `sync` | 收起进度 = 可见列表的滚动位置，跟手 1:1；让位空间固定，滚动本身就完成让位；抬手停在中途时补到端点（`animateTo` 220ms `easeOutCubic`） |
| 即时 `instant` | 滚动**方向**决定两态：上滑（内容上移 = `ScrollDirection.reverse`）→ 收起隐藏；下滑（`forward`）→ 出现。用 220ms `easeOutCubic` 的 `AnimationController` 驱动同一个收起进度，让位空间一起收缩，所以不会留空白 |

两个模式共用同一条链路（同一个 `ValueNotifier` → 玻璃 / 让位 sliver / 排行榜左栏），
所以两态动画期间顶栏与让位仍然严格对齐。要点：

- `UserScrollNotification` 在滚动结束时还会再发一个 `idle` 方向，**不能**把它当成「出现」，
  否则一上滑收起就立刻弹回来（只在 `forward` / `reverse` 上动作）。
- 即时模式关闭收尾补间（`pinnedHeaderExtent` 返回 0）——动画自己会到端点，再去 `animateTo` 反而会打架。
- 方向语义沿用旧的 instant 模式（`forward` = 出现、`reverse` = 收起）；真机上手感若相反，
  把 `case .forward` / `case .reverse` 里那两行对调即可。
- 即时模式下顶栏状态不跟着切 Tab 重置（与旧实现一致），切 Tab 也不会把已收起的顶栏弹回来。
- **前提**：动态页 UP 栏要能「上滑收起」，需要把「UP 面板位置」设为**顶部**——
  只有「顶部」位置的面板才会放进玻璃顶栏（默认是「左侧固定」，那种是独立侧栏，不参与顶栏收起）。

### 8.4 二次复核：上一版「上滑收起」完全没反应的真 root cause

- **`ScrollNotification.metrics` 不是 `ScrollPosition`，而是 `copyWith()` 出来的快照。**
  `scroll_position.dart` 里所有派发都是 `dispatchScrollXxxNotification(copyWith(), ...)`，
  所以 `identical(notification.metrics, position)` **永远为 false**。上一版拿它当白名单 →
  每一条通知都被过滤掉 → 顶栏/面板对滚动毫无反应（同步、即时两个模式都不动）。
  同一个错误还出现在 `CommonPageState.onPinnedHeaderNotification` 里，所以收尾补间也一直是死的。
- **正确姿势**：`notification.context` 是派发者内部 GestureDetector 的 context
  （SDK 注释里明确写了它在 `_ScrollableScope` 里面），所以
  `Scrollable.maybeOf(notification.context)?.position` 能准确拿回派发它的那个 Scrollable 的 `position`，
  再用它和当前 Tab 的 `ScrollController.position` 做 `identical` 才是对的。
- 新增两条一次性探针（跑完已删）钉住这两个事实：
  1. `identical(metrics, position) == false`，而 `identical(Scrollable.maybeOf(context)?.position, position) == true`；
  2. 手指上滑 → `ScrollDirection.reverse`、下滑 → `forward`（即「上滑收起、下滑出现」的映射是对的）。

### 8.5 本轮复核又修的两点

1. **即时模式不再依赖白名单**：方向是全局 UI 状态，先按方向处理并直接返回；之前它排在
   「认出是哪个列表」后面，一旦控制器解析失败（首帧/切 Tab 竞态）就会连方向通知一起丢掉。
   同步模式才需要那个白名单 —— 收起进度必须取「拥有让位空间的那个列表」的滚动位置。
2. **动画控制器改在 `initState` 里创建**：原来写成 `late final ... = AnimationController(...)`，
   惰性初始化意味着「一直没触发过即时模式」的页面会在 `dispose()` 里才第一次创建它。

### 已知取舍

- 收尾补间两个方向都补（上滑补到收起端点、下滑补回展开）：仅在 `pixels < 量程` 时补，
  也就是刚离开顶部那 50～80 px，观感是「松手后归位」；补回 0 会把列表带回顶部，
  但幅度不超过量程，可以接受。
- 动态页切到「本来就在顶部」的分类时，UP 面板会随 `animateToTop` 一起展开，而不是瞬跳。

---

## 附录：改动文件清单（改造前 → 最终）

| 文件 | 改造前 | 最终 | 关键变动 |
| --- | --- | --- | --- |
| `lib/pages/home/view.dart` | 顶栏玻璃整块被 `Obx` 包住，每帧重建 | 静态玻璃 + 两个 `Obx` 小叶子（搜索行包装、`TopBarInset`） | 重建范围收窄；其余（位置/结构/驱动/让位）与改造前一致 |
| `lib/pages/dynamics/view.dart` | `Obx(page)` 包住整页 | 静态玻璃 + `Obx(() => topPanelArea(...))` | 同上；面板顺序回到 Tab 栏之下 |
| `lib/pages/common/common_page.dart` | `onNotificationType2` 不处理滚动方向 | 转发 `UserScrollNotification` 给 type1 | 让默认模式下两态底栏拿到方向 |
| `lib/common/widgets/floating_navigation_bar.dart` | 气泡只滑不按压 | 1.3 倍按压 + 跟手拖动 + 抬手吸附；alpha 0.46/0.36 → 0.32/0.22 | 新增交互与更透明玻璃 |
| `lib/pages/main/controller.dart` | `showBottomBar` 仅 instant 创建 | 只要 `hideBottomBar` 就创建 | 支持两态 |
| `lib/pages/main/view.dart` | sync 连续位移 / instant `AnimatedSlide` 500 ms | 统一 `AnimatedSlide` 220 ms + `RepaintBoundary`；两处旧底栏 alpha 同步 | 两态、更透 |
| `lib/common/widgets/flutter/vertical_tabs.dart` | 按模式分别读 `barOffset` / `showBottomBar` | 统一读 `showBottomBar` | 判断源统一 |
| `lib/pages/video/controller.dart` | 无 | `_initGate` + `deferPlayerInit` | 播放器初始化可延后 |
| `lib/pages/video/view.dart` | `initState` 直接初始化播放器 | 转场结束后再初始化（600 ms 兜底） | 转场收尾不抢帧 |
| `lib/utils/storage_pref.dart` | `videoOutputBackend` 默认 `''` | 默认 `vo=gpu-next,gpu-api=vulkan`（Android） | 开启 Vulkan 输出 |

### 附：v1 的 sliver 方案已删除、又在 v4 以解耦方式恢复

- v1 删除的文件 `lib/common/widgets/top_bar_header.dart`（`TopBarHeaderDelegate`）没有恢复：
  v4 不需要在 sliver 里画任何东西，只用一个不可见的 `SliverPersistentHeader` 占位。
- v1 删除的 `CommonPageState.pinnedHeaderExtent` / `pinnedHeaderScrollController` /
  `onPinnedHeaderNotification` 已在 v4 恢复（见第八节），但收尾补间从 `Timer.periodic`
  换成了 `ScrollController.animateTo`。
- 相关实测数据（pinned 头部的占位公式、`pinned + floating` 会覆盖内容、snap 只会补到展开态）
  记入工程笔记。
