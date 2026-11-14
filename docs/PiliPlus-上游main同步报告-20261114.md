# 上游 main 同步报告（2026-11-14）

## 一、本次同步概况

| 项目 | 内容 |
| --- | --- |
| 合并来源 | `origin/main`（zhblmy/PiliPlus，本项目 fork 主干）@ `217fb54f5` Release 2.2.1 |
| 上游提交数 | 6 个（自上次同步点 `915276c87`） |
| 合并方式 | `git merge origin/main`，1 个文件冲突手工解决 |
| 冲突文件 | 1 个（详见第四节） |
| 实际改动 | 44 个文件，+202 / −445 |
| 应用版本号 | `2.2.1+1`（跟随主干，原为 `2.2.0+1`） |
| 备份分支 | `backup/feature-pre-sync-20261114`（同步前 HEAD + 本地未提交改动） |

> 本次为**小版本跟进**：主干只前进了 6 个提交，绝大部分是「减少重建」的横切重构与两个桌面端 Revert，移动端功能面变化很小。

本次待合入的提交：

| 提交 | 摘要 |
| --- | --- |
| `68fbb1ff5` | reduce rebuilds |
| `9999f21d4` | fix autoWearMedal |
| `94cd406a3` | upgrade deps |
| `96c1c519d` | Revert "fix calcWindowOffset (#3533)" |
| `de85b2d8d` | Revert "fix(desktop): calc min window size (#3478)" |
| `217fb54f5` | Release 2.2.1 |

---

## 二、上游带来的改动

### 1. 减少重建（`68fbb1ff5`，本次最大改动，32 个文件）

- 把 `Theme.of(context)`、`MediaQuery.viewPaddingOf`、`MediaQuery.sizeOf(context).isPortrait` 等取值从 `build()` 移到 `didChangeDependencies()` 缓存，改为字段复用（登录页、音频页、图集、发布页、动态相关页、直播间控制条、搜索相关页、设置页、视频页、评论项等 20+ 处）。
- 新增 Flutter SDK 补丁 **`lib/scripts/media_query.patch`**，给 `MediaQueryData` / `MediaQuery` 增加 `isPortrait`、`isTablet`、`shortestSide` 及对应的 `MediaQuery.isPortraitOf(context)` / `isTabletOf` / `shortestSideOf` 静态方法，并注册到 `InheritedModel` 的 `_MediaQueryAspect`。
  - 意义：读取这些属性时只依赖**单个 aspect**，尺寸以外的字段（如键盘内边距、亮度）变化不再触发页面重建。
- 删除 `lib/utils/extension/context_ext.dart`（`context.isTablet` 等扩展），调用点统一改为上面的 `MediaQuery.*Of`。
- `lib/utils/extension/size_ext.dart` 保留（`SizeExt.isPortrait` 供 `Size` 使用）。

> ⚠️ 该改动**依赖 SDK 补丁**。同步后必须重跑 `patch.ps1`，否则 `MediaQuery.isPortraitOf` 未定义，编译直接失败。

### 2. 直播间：自动佩戴粉丝勋章（`9999f21d4`）

- 自动佩戴逻辑原来只从接口取 `lookupV2.id`，佩戴完成后其它字段仍是旧值；改为取回完整的 `lookupV2` 对象并回写，且当接口返回 `null` 时走「恢复当前展示勋章」分支。
- 粉丝勋章列表弹窗约束由 `BoxConstraints.tightFor(width: 380)` 改为 `minWidth/maxWidth 380 + maxHeight 420`，列表过长时可在弹窗内滚动。

### 3. 依赖升级（`94cd406a3`）

- `image_cropper` 约束 `^12.0.0` → `^13.0.0`。
- `pubspec.lock` 中另有 6 处锁版本抬升（`2.1.5→2.1.6`、`4.6.0→4.7.1`、`2.3.4→2.4.0`、`4.12.0→4.13.0`、`7.0.0→8.0.1`、`8.0.0→9.0.0`）。

### 4. 桌面端两个 Revert（`96c1c519d`、`de85b2d8d`）

| 被撤销的提交 | 影响 |
| --- | --- |
| `fix calcWindowOffset (#3533)` | 删除 `lib/utils/desktop/window_bounds.dart` 中的偏移计算与 `test/utils/desktop/window_bounds_test.dart`，`calc_window_position.dart` 回到旧实现 |
| `fix(desktop): calc min window size (#3478)` | 撤销窗口最小尺寸计算（`lib/main.dart`、`pl_player/controller.dart`、`device_utils.dart` 相关改动一并回退） |

结论：**仅影响桌面端（Windows/macOS/Linux）窗口尺寸与位置计算**，Android/iOS 无行为变化。若之前桌面端窗口卡在最小尺寸、或拖动窗口位置异常的问题已修好，本次会退回旧行为。

### 5. 版本号（`217fb54f5`）

- `pubspec.yaml`：`2.2.0+1` → `2.2.1+1`。

---

## 三、合并后的功能行为（本地特性 + 上游）

### 1. 消息通知 / 角标（本地特性，与主干无功能交叉）

本次合并前刚提交的「消息通知前台服务 + 角标/会话通知刷新」与主干改动零交叉，全部保留：

- Android `MessageNotifyService` 前台服务、`MessageBadge` 多会话详情通知；
- `MainController` 轮询拆分：未读汇总（HTTP）60s / 通知内容（gRPC）5s，后台降频到 2 分钟、页面被二级页覆盖时降到 15s；
- 生命周期改为自持 `AppLifecycleListener`，不再依赖 `MainApp` 被覆盖时摘掉的观察者；
- 设置项 `enableMsgDetailNotify` 及文案。

主干对该文件的唯一改动是 `useBottomNav` 初值 `false` → `true`（首帧直接按底栏布局，避免先渲染一次侧栏），不影响本地轮询与通知逻辑。

### 2. 首页顶栏：继续使用本地折叠方案

- 本地重写的 `ClipBelowTopBar` + `TopBarInset` 折叠顶栏完整保留，不采用主干原来的 `customAppBar() + tabBar + Expanded(tabBarView)` 结构。
- 主干在 `home/view.dart` 的改动只有两处 API 改名，已一并采纳（见第五节）。

### 3. 布局尺寸判定统一走 `MediaQuery.*Of`

- 首页、登录页等原先的 `MediaQuery.sizeOf(context).isPortrait` 与 `context.isTablet` 全部改为 `MediaQuery.isPortraitOf(context)` / `isTabletOf(context)`，与主干保持同一套语义（`isPortrait` 的定义仍是 `width < 600 || height >= width`，`isTablet` 为 `shortestSide >= 600`，与本地原 `SizeExt` / `ContextExt` 判定一致，**无视觉差异**）。

---

## 四、冲突文件与解决方式

| 文件 | 冲突原因 | 解决方式 |
| --- | --- | --- |
| `lib/pages/home/view.dart` | 主干把 `MediaQuery.sizeOf(context).isPortrait` 改为 `MediaQuery.isPortraitOf(context)` 并删掉 `size_ext.dart` import；本地已把该文件整体重写为折叠顶栏，冲突块里两侧结构完全不同 | **保留本地顶栏重写**（`Positioned.fill` + `ClipBelowTopBar` + `TopBarInset`），同时采纳主干的 API 改名与 import 删除。经确认：主干在该文件**没有任何功能改动**，只是 API 重构，因此不构成功能取舍 |

---

## 五、合并后修正

| 文件 | 修正 |
| --- | --- |
| `lib/pages/home/view.dart` | 删除已不再使用的 `import 'package:PiliPlus/utils/extension/size_ext.dart';` |
| `lib/pages/home/view.dart` | `didChangeDependencies()` 与 `build()` 中的 `MediaQuery.sizeOf(context).isPortrait` → `MediaQuery.isPortraitOf(context)`（保留本地「在 `didChangeDependencies` 里缓存 `_isPortrait`」的写法） |

---

## 六、验证情况

- `flutter analyze`：**0 error / 0 warning**，39 条 info（均为 vendored widget 的弃用提示与既有风格提示，与主干基线同源）。
- 合并审计（两套方法）：
  - 集合法：`git diff origin/main HEAD --name-only` 共 203 个文件，**与本地相对同步点改动的文件集合完全一致**（`B\A` 为空）→ 没有文件被静默改回，也没有主干改动被整体吞掉。
  - 行级法：13 个双方共同修改的文件中，主干新增行全部保留；唯一未命中的一行是 `if (!_mainController.useSideBar && MediaQuery.isPortraitOf(context))`，属本地新布局取代 `customAppBar()` 的预期差异。
- 未做真机冒烟。建议重点回归：
  1. 首页顶栏折叠/展开、下拉刷新与顶栏让位动画（冲突文件）；
  2. 登录页横竖屏切换、评论/分享等 `showModalBottomSheet` 的最大高度（`shortestSideOf` / `isPortraitOf` 迁移点）；
  3. 直播间自动佩戴粉丝勋章、勋章列表弹窗滚动；
  4. 桌面端窗口最小尺寸与拖动位置（两个 Revert 的影响）；
  5. 消息通知与角标（本地特性回归）。

### 环境提醒

1. **必须重跑框架补丁**（新增 `media_query.patch`）：
   ```
   $env:FLUTTER_ROOT='C:\Users\zhang\flutter'
   $env:GITHUB_WORKSPACE='<repo>'
   powershell -ExecutionPolicy Bypass -File lib/scripts/patch.ps1 android
   ```
   默认执行策略会拒绝运行脚本，必须带 `-ExecutionPolicy Bypass`。
2. **`material_ui` 版本选择坑**：`patch.ps1` 用 `Get-ChildItem material_ui-* | Select-Object -Last 1` 按**字符串排序**取目录，pub 缓存里存在多个版本时会选错（`1.11.0` 排在 `1.3.0` 之前 → 选中 `1.8.0`，导致 `scaffold.patch` 打不上）。本次已把旧版本移到
   `%LOCALAPPDATA%\Pub\Cache\material_ui_old_versions_bak\`。
3. `media_kit_video` 补丁**不幂等**：重复运行会报 `patch does not apply`，用
   `git -C <media-kit-*dir> apply --reverse --check <patch>` 确认退出码为 0 即已在位，可忽略该报错。
