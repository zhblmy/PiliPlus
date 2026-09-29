# PiliPlus 顶栏收起：本轮改动与优缺点

**日期**：2026-09-29
**范围**：首页顶栏（搜索栏）与动态页顶栏（顶部 UP 面板）的收起/展开、以及支撑它们的公共件（`TopBarInset`、`CommonPageState`）
**改动量**：5 files changed, +168 −86
**验证**：`flutter analyze`（5 文件）`No issues found!`；全 `lib` 编译通过；release APK 构建 exit=0（23.99 MB）

> 本文只记录**改了什么**以及**每项的优缺点**。

---

## 一、可靠性：不再出现「该收没收 / 该出现没出现」

| # | 改动 | 优点 | 缺点 / 注意 |
|---|---|---|---|
| 1 | `CommonPageState._pinnedScrollUp` 从 `bool` 改成三态 `bool?`：手势开始（`ScrollStartNotification`）清空，只有本次手势真的产生过位移才判定方向；方向未知时**不做**收尾补间 | 不再拿**上一次**手势的方向去给这一次补间（原来会出现"往下拉、却往上补"）；点一下屏幕没动就抬手时也不再乱补 | 本次手势零位移时不做补间：若栏恰停半路（列表本身短于收起量程），它就停在半路。原来那种情况会硬补回展开，反而更错 |
| 2 | 首页 / 动态页的滚动处理里删掉 `notification is! ScrollMetricsNotification` 判断 | `ScrollMetricsNotification` 不是 `ScrollNotification` 的子类（它在 metrics 变化时单独发），这个条件永远为 false。删掉避免后来人误以为"Tab 变化有兜底" | 无（该分支从未生效过） |
| 3 | 删掉两个死覆盖：首页的 `needsCorrection`、动态页的 `onNotificationType2` | 两份"看起来在生效、实际挂不上"的逻辑消失（这两页 `useBarOffset = false`，对应的通知监听器根本不会挂载） | 若将来有人把 `useBarOffset` 改回 `true`（即重新走共享 `barOffset` 那套），需要把这两处补回来 |
| 4 | 首页 / 动态页 `_onTabChanged`：抽出 `_syncCollapseToCurrent()`，并在拿不到 `ScrollPosition` 时**下一帧再对齐一次** | `TabBarView` 的页面是懒建的（在 layout 阶段才建），刚切过去那一帧可能还没有 position；现在不会再把收起进度错误归零（表现为"顶栏自己弹回展开"）。对齐逻辑也只写一份 | 极少数情况下多一次「帧末写入」，会多触发一帧的子层重建 |
| 5 | 首页新增 `_showTopBarRequest()`：玻璃顶栏里挂一个 **0 尺寸 `Obx`**，读 `homeController.showTopBar`；处于收起状态又收到"要求显示"时播一次展开动画 | 找回既有行为：从别的 Tab 按返回键回首页时（`MainController.setSearchBar()` 会把 `showTopBar` 置 true），搜索栏会像以前一样展开——这个意图在上一轮重构里被漏掉了 | ① 玻璃里多一个 0 尺寸 widget（布局零影响，帧成本≈0）；② `showTopBar` 从此有了真正的读者，以后改它要连带看这里；③ 用 `Obx` 而不是自己订阅，好处是不用管释放，代价是刷新时机交给 GetX |
| 6 | 首页 / 动态页 `_onBarAnimTick` 加 `_instant` 守卫 | 同步模式的"收起进度 = 滚动位置"不会被动画串改，两条驱动链路互不越界 | 无（正常路径下该动画不会被调用，属纯防御） |

## 二、一致性：同一个条件只留一个来源

| # | 改动 | 优点 | 缺点 / 注意 |
|---|---|---|---|
| 7 | 首页新增 `_barCollapsible`（`hideTopBar && !useSideBar && _isPortrait`），`pinnedHeaderExtent` / `_onScrollNotification` / `_onTabChanged` 全部改用它；`_isPortrait` 在 `didChangeDependencies` 缓存 | ① 收起条件只有一个定义，不会再出现"某处判得不一样"；② **滚动回调不再临时读 `MediaQuery`**（这是"在回调里顺手注册继承依赖"的真实场景）；③ 横屏 / 侧栏模式下不再白跑 220ms 收起动画、白写 `ValueNotifier` | 旋转屏幕时靠 `didChangeDependencies` 更新缓存值（框架保证它在 build 之前调用，行为与原先一致） |
| 8 | 动态页 `pinnedHeaderExtent` 改为复用 `_panelCollapsible`，`_onTabChanged` 也用它做前置判断 | 与 build 里的 `collapsiblePanel` **永远一致**，从根上消掉"两处判据不同步"这类隐患（横屏误判可收起，就是这种问题） | 无（横屏本就不建 inset，属一致性 + 省算力） |
| 9 | 动态页收起量程收成 `_collapseExtent`，`minValue` 改为 `barInset - (collapsiblePanel ? _collapseExtent : 0)` | 量程只有一个来源，以后改面板高度不会漏改；数值与原来的 `statusBarHeight + _kAppBarHeight` **恒等** | 无（纯等价改写，可读性换来的） |
| 10 | `TopBarInset` 增加 `assert(minValue <= value)`，并给 `collapse` 补文档："必须是稳定实例" | 接线错误在 debug 期立刻炸出来，而不是变成"内容缩进搜索栏里"这种难查的怪现象；契约写进文档，避免有人每次 build 新建一个 notifier | debug 下多一次断言（release 无）；`const` 实例化时该断言在编译期检查 |

## 三、性能：少重建、少白算

| # | 改动 | 优点 | 缺点 / 注意 |
|---|---|---|---|
| 11 | 首页 `msgBadge` 拆成两层 `Obx`：外层只订阅登录态，内层订阅未读数 | 未读数变化只重建 `IconButton` 那一小棵子树，不再把外层判断连整个按钮一起重跑 | 多一层 widget（≈0）；两个 rx 的订阅点分开，读代码要跳一层 |
| 12 | 排行榜左侧竖排 Tab 列表提为 `late final _tabs` 字段 | 不再每次 build 重新造 N 个 `VerticalTab`（与主题/context 无关，本来就该复用） | widget 实例被长期持有（内存极小）；**注意别顺手把 `VerticalTabBar` 本身也提上去**——它的 `padding` 参与收起计算，必须每帧重算 |

---

## 验证记录

| 项 | 结果 |
|---|---|
| `dart format`（5 文件） | 通过（reflow 1 处） |
| `flutter analyze`（5 文件） | `No issues found!`，exit=0 |
| 全 `lib` 编译（临时探针 `flutter test`） | `All tests passed!`，exit=0 |
| `flutter build apk --release`（先删旧包） | exit=0，`app-arm64-v8a-release.apk` 23.99 MB |

---

## 一句话总结

本轮改动的**主线是"消歧"**：把"谁说了算"的条件（可收起？收起进度？手势方向？）各自收敛到一个来源，并补上被漏掉的既有行为（返回键回首页要展开搜索栏）。收益是行为更可预测、横屏/侧栏不再白算；代价基本只是"多一层间接"和"某些极端场景不再做多余补间"。
