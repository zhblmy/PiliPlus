# PiliPlus 悬浮底栏改造说明

**日期**：2026-10-30
**范围**：悬浮底栏（`FloatingNavigationBar`）、新增「消息」分类、新增自绘「圈子」图标
**改动量**：`lib` 10 个文件 +850 / −475，另新增 `lib/common/widgets/nav_msg_icon.dart`（124 行）；不含本轮之前已有的震动反馈回退
**验证**：`flutter analyze lib` 0 error / 0 warning（38 条 info 均为改动前既有）；关键状态用 golden 逐帧渲染量测

> 本文只记录**改了什么**、**为什么这么改**，以及**每项的取舍与可调参数**。

---

## 一、新增「消息」分类

| # | 改动 | 优点 | 缺点 / 注意 |
|---|---|---|---|
| 1 | `NavigationBarType` 新增 `msg('消息', …)`，**枚举值追加在末尾**，另加 `static const defaultOrder = [home, dynamics, msg, mine]` | 「Navbar编辑 / 默认启动页」存的是**枚举下标**；插在中间会让老用户设置错位。展示顺序统一走 `defaultOrder` | 枚举声明顺序 ≠ 展示顺序，读代码时要留意 `defaultOrder` |
| 2 | `MainController._migrateNavBarSort()`：老配置里没有 msg 下标时自动插入（在「我的」之前），用 `navBarSortMigrated` 标记**只补一次** | 老用户升级后也能看到消息分类；用户之后主动删掉它，不会再被塞回来 | 多一个存储键 `navBarSortMigrated` |
| 3 | `setNavBarConfig()` 对缓存做**越界过滤 + 去重** + 空结果回退默认 | 老配置 / 手改配置里有非法下标时不再抛 `elementAt` 异常 | 行为上会静默丢弃非法项（比崩溃好） |
| 4 | 未读数：`hasHome` 条件放宽为 `hasHome \|\| hasMsg`；底栏消息图标带角标（跟随「消息角标」设置） | 没有首页分类时也能算未读 | `setIndex` 切到消息分类即清空未读（与首页那个入口行为一致） |
| 5 | `MainController.openMsgPage()` 收口「打开消息页」：有分类就切 Tab，没分类才压 `/whisper` 路由 | 首页 / 侧栏入口共用一份逻辑；避免 `home/view.dart` 反向 import `nav_bar_config.dart` 形成**循环 import** | — |
| 6 | 侧栏已有消息分类时，顶部不再重复放消息按钮；「我的」页同理（`if (!hasMsg)`） | 去掉重复入口 | — |
| 7 | `WhisperPage` 改 `AutomaticKeepAliveClientMixin` + `Get.putOrFind`，并包 `NotificationListener<UserScrollNotification>` **只包 body** | 作为 Tab 用不丢状态、不重复注册控制器；`idle` 不处理，避免抬手把收起的底栏弹回来；只动底栏、不动首页玻璃顶栏 | 消息页内滚动会收起底栏，和别的 Tab 一致 |
| 8 | `main/view.dart` 的 `pageOf()`：消息页统一用 `_MsgPageHost`（结构固定，只有 `MediaQueryData` 在两种模式间变） | 消息页自带 AppBar，避免状态栏留白被算两遍；结构固定是为了横竖屏 / 平板切换模式时 element 不被重建（状态不丢） | — |

---

## 二、气泡的视觉与几何

| # | 改动 | 优点 | 缺点 / 注意 |
|---|---|---|---|
| 9 | 选中气泡改由底栏**统一绘制一个**（跟着选中项横向滑动），不再每格各画一个 | 才能实现「单颗气泡滑动」；拖动/按压只有一个真相来源 | `FloatingNavigationBar` 的 `indicatorShape` / `overlayColor` 参数因此失效，已删除 |
| 10 | 气泡 = `LiquidGlass`（blur 32，比底栏的 16 更朦胧）+ 渐变描边 + 上下内高光 + 「同色雾」软边 | 复刻 IT之家 那种有厚度的玻璃囊泡；软边用「纯色胶囊 + `ImageFiltered` 模糊」实现（`BackdropFilter` 本身没法羽化） | 气泡区域多一个 `saveLayer`；`ImageFiltered` 只能包纯色层，包住 `BackdropFilter` 会把模糊泄漏到胶囊外 |
| 11 | 静止尺寸 = 栏内四周各留 **3dp**（`_kIndicatorRestInset`），横向用 `_kIndicatorInnerInset = 3 − 4 = −1` 换算（气泡图层 `Clip.none`，会溢出图标行那 4dp 内边距） | 55/2 − 49/2 = 27.5 − 24.5 = **3**，气泡弧与底栏弧**同心**，所以两端弧度一致 | 改 `_kIndicatorRestInset` 时两条弧就不再同心了 |
| 12 | 底栏玻璃 alpha 提到 0.14（浅）/ 0.24（深），可一处调 | 更透，下层内容透出更明显（黑底实测覆盖率 36/255 = 0.14） | 过于透明会牺牲标签可读性；低于 ~0.10 就不建议了 |
| 13 | 底栏左右留白 = 底部距离（`_kSideMarginRatio = 1.0`），**底栏铺满可用宽度** | 左右留白严格等于「到屏幕底边的距离」（实测 360/400/412dp 屏都是 8 vs 8） | 只能靠 `_kMaxBarWidth = 480` 收住平板的超长胶囊；此时左右留白会大于底部（有意为之） |
| 14 | 格宽不再设下限，改由「条宽 ÷ 格数」得出；窄屏优先压缩左右留白（`_kMinCellWidth = 56` 只做阈值） | 气泡位置是用 `_cell` 反推的，一旦格宽大于实际布局宽度，气泡会越靠右越偏 | 极窄屏（< ~230dp）左右留白会塌到 0 |

> **几何公式**（`count` = 分类数）
> ```
> bottomInset = bottomPadding + safeArea.bottom
> sideInset   = min(max(bottomInset × 1.0, safeSide), max(safeSide, (屏宽 − count×56)/2))
> barWidth    = min(屏宽 − 2×sideInset, 480)
> cell        = barWidth / count
> cellW       = (count×cell − 8) / count        // 8 = 左右各 4 的内边距
> restWidth   = cellW − 2×(−1)                   // −1 = 3 − 4
> ```

---

## 三、交互

| # | 改动 | 优点 | 缺点 / 注意 |
|---|---|---|---|
| 15 | 按住底栏任意位置：整条底栏放大到 **1.05**（`_kBarPressScale`，150ms easeOutCubic），松手回落 | 和 IT之家 一致的「按下去整体鼓一下」 | 放大用 `Transform.scale`，不参与布局，所以不会引起内容跳动 |
| 16 | 按住某格：气泡**带动画滑到该格**（`_kPressSlideDuration = 320ms`），松手吸附；只点不拖时由 `onTap` 确认选中 | 按下立刻有反馈；拖动基准取「气泡此刻真实位置」，快速拖动不跳变 | 按下与选中的时长很接近，两者叠加时用「同目标早退」避免时间轴被重排 |
| 17 | 滑动曲线 `_kSlideCurve = Cubic(0.35, 0.0, 0.20, 1.0)`，切换选中 620 → **310ms**（按下滑动 640 → 320ms） | Material 的 emphasized 曲线 10% 时间就走完 62%，看着像瞬移；这条是「快起步 + 长尾巴」：10% 走 3.4%、40% 走 64%、60% 走 88%，最后 40% 时间慢慢收力——既明显非线性，又不会肉 | 想更慢/更快只改 `animationDuration`（与 `_kPressSlideDuration` 按同一比例） |
| 18 | 图标 / 文字颜色改由**气泡位置反推**（`_Emphasis`：`(1 − \|position − i\|)³`） | 颜色与气泡严格同步，拖动时实时跟手变色（旧实现是每格独立的 `AnimationController`，曲线不同步，会出现「气泡还没到、字先变色」） | `_Emphasis` 每帧新建实例，靠 `InheritedWidget` 重建；不能改成「复用+notifyListeners」，那会在 build 期触发 setState |
| 19 | 多指：`onPointerUp/Cancel` 传 `pointer` 并校验；只有按下的那根手指能结束交互 | 第二根手指抬起不再打断第一根的按压/拖动 | — |
| 20 | 手势被系统取消 / 长按菜单抢走时，下一帧把气泡滑回真正选中的那格 | 气泡不会卡在「按过但没选中」的位置 | 依赖 `addPostFrameCallback`，极端情况下多一次动画 |
| 21 | 拖动位移除以 `_barScale` | 底栏整体放大 1.05 时，手指位移和气泡位移才 1:1 | — |

---

## 四、新增「圈子」图标（`nav_msg_icon.dart`）

| # | 改动 | 优点 | 缺点 / 注意 |
|---|---|---|---|
| 22 | 用 `CustomPaint` 画「圆气泡 + 右下小尾巴 + 笑弧」，比例照 IT之家 截图量取（尾尖 1.16R@37°、笑弧 0.77R、描边 0.08s） | 不依赖字体 / 图片资源，颜色尺寸全跟随 `IconTheme` | 手绘路径，改比例要动 `_bubble` / `_smile` |
| 23 | `radius = 0.335s`（外径带描边 = **0.75 槽位**） | 和 Material 图标视觉一致：同槽位实测 `home_outlined` 0.82×0.70、`person_outline` 0.67×0.66、`circle_outlined` 0.83×0.84 | 想让消息图标更接近 home 的宽度，可调到 0.36 |
| 24 | 选中（实心）时只把**外轮廓**补到 `r + stroke/2`（`_bubble(center, radius + stroke/2)` 填充），**不再缩放画布** | 描边版外沿是 `r + stroke/2`、实心版止于 `r`，不补偿会「选中瞬间缩小一圈」 | 尾巴按同一比例外扩，与描边版的外沿有 <1px 差异，肉眼不可见 |
| 25 | 笑弧在两种状态下用**同一条路径、同一个线宽**（未选中描出来，选中挖空） | 曾经用「整条路径绕中心缩小 `(r + stroke/2)/r`」来补偿外径，结果笑弧被一起推离圆心、撑大约 12%，黑线与白缝对不上 | 补偿只能动外轮廓，不能动内容 |
| 26 | 笑弧用 `saveLayer` + `BlendMode.clear` **真挖空** | 透出下面的玻璃，深色主题 / 彩色玻璃上都不会显脏 | 每次绘制多一层 `saveLayer`（图标很小，可忽略） |

---

## 五、本轮 review 顺手清理

| # | 改动 | 原因 |
|---|---|---|
| 27 | 删除死代码 `NavigationIndicator`、`_StatusTransitionWidgetBuilder`、`_SelectableAnimatedBuilder`(+State) | 气泡改由底栏统一绘制后无人引用（`NavigationIndicator` 在扫描时就已无引用） |
| 28 | 删除 `_NavigationDestinationInfo` 的 `indicatorColor` / `indicatorShape` / `overlayColor` 字段 | 只传不读，纯噪音 |
| 29 | `openMsgPage()` 收口 + 去掉 `home/view.dart` 对 `nav_bar_config.dart` 的反向 import | 消除循环 import，逻辑单点 |
| 30 | `setNavBarConfig()` 越界过滤 / 去重 / 空回退 | 防 `elementAt` 抛异常 |
| 31 | 去掉格宽下限、改为压缩左右留白 | 修「窄屏溢出 + 气泡与格子错位」 |
| 32 | `_endDrag()` 把「点按」和「拖动」两条路合并成一套收尾：算出一个 `target`，再统一在下一帧校验选中是否真的切过去，没切就滑回去 | 原来只有「点按」那条路有回位逻辑，**拖动松手被拒绝时气泡会停在没被选中的格子上**（登录拦截、回调被忽略等） |
| 33 | `_onPointerMove()` 不再在起拖瞬间把 `_dragStartDx` 重置到当前点，改成「扣掉 `_kDragSlop` 那一段再算位移」 | 原来的写法会**吞掉触发拖动那一次移动的全部位移**：一次性大跨度移动（事件合并 / 触控笔）气泡纹丝不动；小步移动也会永久落后手指约 4dp |
| 34 | 删除 `_CurvedAnimationBuilder`（连同它的 status 状态机），换成一行的 `CurveTween(...).animate()` | `_Emphasis` 的值由气泡位置算出来、永远不会「反向」，那个「前进用 curve、后退用 reverseCurve」的状态机已经全无作用，`addStatusListener` 也打在一个空实现上 |
| 35 | `_barScale` 改用 `_pressProgress`（带 easeOutCubic）计算，不再用线性的 `_pressController.value` | 文档写的是「150ms easeOutCubic 放大」，但实际取的是线性值，底栏放大和气泡撑开（用 `_pressProgress`）曲线不一致。两处都用同一个值，且拖动位移的补偿依旧和视觉缩放严格一致 |
| 36 | 未读角标抽成 `msgUnreadBadge()`（`home/view.dart`），首页顶栏入口和底栏 / 侧栏的消息分类共用 | 同一颗角标两个入口各写一份语义（number / dot / hidden + 对齐位置），迟早走偏；顺手把底栏那颗的对齐也统一成和顶栏一致 |
| 37 | 切进「消息」分类时补一次 `WhisperController.onRefresh()` | 消息页现在是 keep-alive 常驻 Tab，只在第一次 `onInit` 拉数据；而切进来会**立刻清掉未读角标**，「角标清了、列表还是旧的」自相矛盾。以前每次 push 全新的 `/whisper`，天然是新数据 |
| 38 | `pageOf()` 里消息页两种模式都用同一个 `_MsgPageHost`，只改 `MediaQueryData` | 原来按 `useBottomNav` 返回完全不同的 widget 树，横竖屏 / 平板切换模式时消息页的 element 会被重建，滚动位置和 keep-alive 状态全丢（其它页面一直有「始终包一层 Padding」的保护，消息页不能例外） |
| 39 | 把 `MediaQuery.of(context)` 从 `_MainAppState.build` 挪进 `_MsgPageHost.build` | 在 `build` 里直接调 `MediaQuery.of` 会让**整个主页**订阅整份 MediaQuery（键盘弹起/收起都重建 `PageView`）；放进独立 widget 后依赖只落在消息页那一层 |

---

## 六、怎么验证的

仓库自带的 `flutter test` 在本机跑不了（`cnativeapi` 的 build hook 需要 MSVC），所以把相关的真实组件（`floating_navigation_bar` / `liquid_glass` / `nav_msg_icon`）拷进临时工程做 golden 渲染量测，验证完删除：

| 用例 | 量测结果 |
|---|---|
| 图标大小 | 未选中 / 选中都是 90×90（槽位 120），与 `person_outline`(0.67) / `home_outlined`(0.82) 同一量级 |
| 图标笑弧对齐 | 槽位 240 渲染：未选中黑线与选中挖空缝的包围盒都是 128×52、质心差 (0.11, 0.05)px、IoU 0.97（差值全是抗锯齿阈值），外轮廓都是 180×180（0.750 槽位）且位置完全一致 |
| 气泡四周留白 | 首页格 左/右 4.3dp、上 4.3dp、下 4.7dp（目标 5，误差来自软边+抗锯齿） |
| 左右留白 == 底部距离 | 360 / 400 / 412dp 屏：side 8.3 / 8.0，bottom 8 → 一致；800dp：160（受 480 上限约束，有意）；200dp：0（兜底） |
| 按压滑动 | 与切换选中**同一条曲线**，只把时长换成 320ms（同一段代码，`_animateTo(duration:)` 传入） |
| 点击切换 | 310ms；实测 31ms 走 5.6%、62ms 走 31%、93ms 走 61%、124ms 走 83%、186ms 走 97%、248ms 到位（后 40% 时间只挪最后 17%，长尾收力） |
| 笑弧两态重合 | 真实底栏、22dp、4× 超采样：两态图标盒子都是 `Rect(236,746,258,768)`，墨迹 66×66 @ y[11,76]，笑弧 bbox 都是 x[21,66] y[46,64]，质心都是 (43.55, 55.93) —— 逐像素完全一致 |
| 极窄屏 200dp × 4 格 | 无 overflow 异常；图标中心 28 / 76 / 124 / 172dp（格宽 50、内距 4 → 理论值一致） |
| 深色主题 | 玻璃通透、文字图标对比足够 |
| 交互回位（点按被拒绝） | 点第 3 格但回调不改 `selectedIndex`：900ms 后整条底栏与初始静息帧**逐像素 maxDiff = 0**（气泡精确滑回原位） |
| 交互回位（拖动被拒绝） | 拖到第 3 格松手、回调拒绝：`onDestinationSelected` 收到 1 次调用，900ms 后与初始帧 **maxDiff = 0** |
| 拖动生效 | 按住第 1 格拖动 2.1 格松手 → `selectedIndex` 变成 2，气泡吸附到第 3 格 |
| 按压曲线 | 按住 75ms 时 `Transform.scale` = **1.04376**（easeOutCubic(0.5)=0.875 → 1+0.05×0.875），线性的话只有 1.025 |

---

## 七、可调参数速查（都在 `floating_navigation_bar.dart` 顶部）

| 常量 | 现值 | 作用 |
|---|---|---|
| `_kNavigationHeight` | 55 | 底栏高度 |
| `_kIndicatorRestInset` | 3 | 气泡四周留白（= 两条弧的同心距离） |
| `_kPressGrow` | 20 | 按压时气泡额外撑开的尺寸 |
| `_kPressSlideDuration` | 320ms | 按下滑到该格的时长 |
| `animationDuration`（widget 参数） | 310ms | 切换选中的滑动时长 |
| `_kSlideCurve` | `Cubic(0.35, 0.0, 0.20, 1.0)` | 滑动缓动（快起步 + 长尾巴） |
| `_kBarPressScale` | 1.05 | 按压时整条底栏放大倍数 |
| `_kBarFillAlphaLight/Dark` | 0.14 / 0.24 | 底栏玻璃浓度（越小越透） |
| `_kIndicatorBlurSigma` | 32 | 气泡磨砂强度（底栏是 16） |
| `_kSideMarginRatio` | 1.0 | 左右留白 = 底部距离 × 该值 |
| `_kMaxBarWidth` | 480 | 底栏最大宽度（平板收口） |

---

## 八、已知取舍

1. **气泡的强调度用「每帧新建 `Animation` 实例」实现**。这会让 `InheritedWidget` 每帧 `updateShouldNotify = true`（本来也要重建），换来的是不必在 build 期触发 `notifyListeners`（那会报 setState during build）。
2. **按压时整条底栏 `Transform.scale`**：玻璃、图标、文字一起放大，属于「非布局变换」；如果你希望图标不跟着放大，需要改成只缩放玻璃层。
3. **底栏宽度上限 480dp**：这是「左右留白 = 底部距离」和「平板上别被拉成超长胶囊」之间的折衷。要让大屏也严格等距，删掉 `_kMaxBarWidth` 判断即可。
4. **消息分类的迁移只做一次**：用户之后在「Navbar编辑」里删掉它，不会被重新塞回。
5. **未读清零时机**：打开消息分类即清零（沿用首页消息入口原有行为）。若希望只在真正读完才清，删掉 `setIndex` 里的 `clearUnreadMsg()` 分支即可。
6. **消息分类每次切进去都会刷新一次**（`_refreshMsgPage()`，两个请求：会话列表 + 未读汇总）。这是为了和「以前每次 push 一个全新的 `/whisper`」行为对齐；嫌费流量就删掉 `setIndex` 里那一行，改成纯下拉刷新。
7. **描边版和实心版的笑弧是同一个坐标**（实测逐像素相同），但两种画法天生有观感差：描边版的笑弧两端离圆环内沿只有约 1.2 个物理像素（3x 屏），看着像粘在圆环上；实心版两端离边缘约 6.5 个物理像素，明显悬空。这是 outline / filled 图标的固有差异（Material 自己的 `sentiment_satisfied` 系列也一样），不是位移。真要抹平只能把笑弧收窄（124° → ~90°），会牺牲和参考图的相似度。
