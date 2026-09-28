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

### 附：v1 的 sliver 方案已删除的文件

`lib/common/widgets/top_bar_header.dart`（`TopBarHeaderDelegate`）、`TopBarInset.headerSliver` / `TopBarInsetSpacer` 返回 sliver 的写法、`CommonPageState` 的 `pinnedHeaderExtent` / `pinnedHeaderScrollController` / `onPinnedHeaderNotification`。相关实测数据（pinned+floating+snap 的几何与收尾行为）已记入工程笔记，供将来重新评估。
