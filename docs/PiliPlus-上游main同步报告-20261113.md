# 上游 main 同步报告（2026-11-13）

## 一、本次同步概况

| 项目 | 内容 |
| --- | --- |
| 合并来源 | `upstream/main`（bggRGjQaUbCoE/PiliPlus）@ `915276c87` |
| 上游提交数 | 59 个（自上次同步点 `979b06418`） |
| 合并方式 | `git merge upstream/main`，冲突逐个手工解决（**不做整文件取舍**） |
| 冲突文件 | 15 个（详见第四节） |
| 实际改动 | 194 个文件，+8312 / −2943 |
| 应用版本号 | `2.2.0+1`（跟随主干，原分支为 `3.0.1+1`） |
| 备份分支 | `backup/feature-pre-sync-20261113`（同步前 HEAD） |

> 本报告只描述**功能行为**上的变化，以及合并时做出的功能取舍；内部重构、格式化、依赖升级细节见提交记录。

---

## 二、上游带来的新功能

### 1. 首页推荐：可选择推荐来源
- 设置页新增「首页推荐来源」，可在 **App 端 / Web 端 / 桌面端** 之间切换，切换后立即生效（无需重启）。
- 桌面端沿用公开网页推荐接口，但使用哔哩哔哩官方 Windows 客户端首页实际发送的参数组合（`plat=1`、`feed_version=V1`、`x_num`/`y_num`、`ps=30` 等），不涉及私有接口与设备指纹。
- 旧的二选一开关 `appRcmd` 保留并自动映射到新枚举，升级/降级都不丢配置。
- 桌面端新增悬浮「刷新」按钮（受设置项 `showRefreshFAB` 控制）。

### 2. 评论：楼中楼（threaded）回复
- 评论列表支持按层级缩进展示，可开关「回复树」。
- 回复分页逻辑重做，顶楼评论过滤修正。

### 3. 直播间
- 控制器按职责拆分为多个 mixin（弹幕、SC、点赞、勋章、数据、尺寸、时长、链路等），便于维护。
- 新增**直播链路信息**（live trace）上报。
- 新增**粉丝勋章管理**入口。
- 直播 PiP / 通知栏新增「刷新」「弹幕」按钮（对应 `ACTION_REFRESH` / `ACTION_DM` 自定义动作）。
- 横屏全屏时去掉底部安全区留白。

### 4. 视频播放
- 支持**视角（viewpoint）**：可在设置中选择是否遵循视角偏好、跳转到目标视角。
- 支持**离线字幕 / 离线视角**：下载时可一并保存，本地播放时读取。
- 修复本地字幕读取/更新、`seek`、`calcWindowOffset`、弹幕跳转链接提前量等问题。
- 音频焦点/音频会话处理改为经 `audio_service` 统一处理（后台播放、通知栏控制更一致）。
- 音量超过 100% 时不再削顶。

### 5. 其它
- 动态：支持 `foldAction` 折叠；专栏 opus 解析修复。
- 下载：画质更新后刷新下载入口、合集分集序号修正、离线 UGC 合集信息更新。
- 消息卡片：专栏卡片图片为空时不再崩溃。
- Linux：MPRIS 控制优化；macOS：隐藏标题栏后窗口仍可拖动。
- 修复 Android 上 ChromeOS(ARC) 忽略首选方向、`AppSign`、iOS 短信验证码不可用等若干问题。
- 依赖升级（`material_ui` 1.9.0 → 1.11.0、gRPC proto、若干 git 依赖 ref）。

---

## 三、合并后的功能行为（本地特性 + 上游）

### 1. 首页推荐：三种来源 + 本地刷新/缓存策略
- 刷新一次**凑够首屏内容**：
  - App 端：每页 10 条，**两页并行请求**后按 `bvid/aid` 去重合并；
  - Web 端：单次 20 条；
  - 桌面端：单次 30 条。
- 首屏本地缓存（`RcmdCache`）按来源分槽位（`app` / `web` / `desktop`），冷启动直接回放缓存，下拉刷新才发请求；缓存上限由 20 提到 **30 条**以容纳桌面端一页。
- 续页游标按「本次刷新实际消费了几页」推进；第二页失败时只前进一页，避免漏页。
- 刷新失败但已有内容时保留旧列表并提示；首次进入失败仍走错误页（可重试）。
- 「保留上次刷新内容 / 上次看到位置提示」两个开关继续生效，切换推荐来源时**不会**把旧来源内容拼进新列表。
- 首屏无任何数据时，滚动触发的「加载更多」改为按刷新处理（否则那一页会被丢弃）。

### 2. 直播间：后台省电策略保留
- 弹幕长连接增加：
  - **建流去重**（token 申请期间不重复建连）；
  - **失败退避重试**（最多 3 次、间隔 3s）；
  - **代次作废**（退出/切后台后在飞的 token 请求不会再建连）；
  - 应用回到后台即断开长连接，回到前台且仍在播放时清空 `dmInfo` 重连（应对 token 过期）。
- 这些逻辑已移植到上游新的 `controller_mixin/dm_stream.dart`，与上游拆分结构共存。

### 3. 音频打断：保留 Android 17 后台加固
- 打断结束时先判断「现在能不能出声」：应用可见或播放器仍在播放才立即续播；否则挂起，等回到前台再补一次续播。
- 仅在 **Android 17（API 37）及以上**生效，其余平台保持原来的「打断结束立即续播」。

### 4. 评论：渲染缓存保留
- 评论正文的 `TextSpan` 树按条目缓存（`Expando`，随条目回收），正则按 pattern 串做上限 256 的 LRU 复用。
- 缓存 key 覆盖内容、配色、词搜索开关、笔记/置顶标记与视频时长；投票弹窗改用 `Get.context`，避免缓存 span 持有失效的 `BuildContext`。

### 5. 首页/动态双击 Tab
- 双击底栏当前 Tab 时改为触发 `showRefresh()`（显示下拉转圈），与上游“刷新指示器”行为对齐；「消息」Tab 保持原有的列表刷新逻辑。

### 6. 颜色选择页
- 底部预览仍使用**真实首页**（可直观看到配色效果），未采用上游的骨架占位 `_Preview`。
- 代价：进入该页会实例化首页及其控制器；同时保留“动态取色重新取色（`force: true`）”的修复。

### 7. 版本号
- `pubspec.yaml` 版本改为 `2.2.0+1`（主干版本），即由 `3.0.1+1` **回退**。

---

## 四、冲突文件与解决方式

| 文件 | 解决方式 |
| --- | --- |
| `lib/pages/rcmd/controller.dart` | 保留上游三种推荐源，叠加本地“凑 20 条 + 缓存 + 续页游标 + 预取” |
| `lib/pages/rcmd/view.dart` | 两边合并（顶栏让位、滚动阻尼、cacheExtent、桌面刷新 FAB、refreshKey） |
| `lib/services/audio_session.dart` | 采用上游统一打断处理路径 + 本地 Android 17 门控 |
| `lib/services/audio_handler.dart` | 上游 `customAction` 与本地 `ensureForegroundPlaying` 并存 |
| `lib/plugin/pl_player/controller.dart` | 本地 lifecycle 观察者 + 上游 ChromeOS 判断；`play()` 两边改动并存 |
| `lib/pages/live_room/controller.dart` | 采用上游 controller + mixin 拆分，本地弹幕健壮性移植进 `dm_stream.dart` |
| `lib/pages/live_room/view.dart` | 上游服务生命周期 + 本地前后台/转场钩子，方法名改为 `start/stopLiveMsgStream` |
| `lib/pages/video/reply/widgets/reply_item_grpc.dart` | 采用上游布局重构，本地 span/正则缓存与 `Get.context` 修复迁移进去 |
| `lib/pages/video/controller.dart` | 保留上游空 `dash.video` 守卫 + 本地可空 `findTargetVideo` 处理；`onSkip` 用上游签名 |
| `lib/pages/common/common_list_controller.dart` | 本地 `try/finally`（异常也复位 `isLoading`）+ 上游 `endIfNullOrEmpty` |
| `lib/http/video.dart` | 本地 `onRawItems` 回调 + 上游 `desktop` 参数/参数组合 |
| `lib/pages/main/controller.dart` | 首页/动态用上游 `showRefresh()`，保留「消息」Tab 分支 |
| `lib/pages/setting/pages/color_select.dart` | 保留本地真实首页预览，删除上游 `_Preview` 及其无用 import |
| `lib/pages/whisper_detail/widget/chat_item.dart` | 采用上游空安全写法（文章卡片图片/标题/摘要） |
| `lib/services/download/download_service.dart` | 两边 import 与逻辑并存（前台服务 + 离线字幕/视角） |
| `lib/pages/dlna/view.dart` | 保留本地「本地网络」权限提示流程 + 上游 `normalizeLegacyDlnaControlUrls` |

---

## 五、合并后修正

| 文件 | 修正 |
| --- | --- |
| `lib/pages/rcmd/view.dart` | `cacheExtent` 迁移到 `scrollCacheExtent: ScrollCacheExtent.pixels(...)`（避免已弃用 API）；修正 import 顺序；补充桌面端 30 条说明 |
| `lib/pages/video/reply/widgets/reply_item_grpc.dart` | 缓存 key 中 `Get.arguments?['heroTag']` 空安全 |
| `lib/pages/live_room/controller_mixin/dm_stream.dart` | 弹幕重试定时器回调增加 `isClosed` 兜底 |
| `lib/pages/rcmd/controller.dart` | 首屏无数据时「加载更多」改走 `onRefresh()`，避免拉到的一页被丢弃 |

---

## 六、验证情况

- `flutter analyze`：**0 error / 0 warning**（剩余 40 条 info 均为 vendored widget 的弃用提示，与上游基线同源）。
- `flutter build bundle --debug`：通过（Dart 内核编译全量通过）。
- 未做真机冒烟。建议重点回归：首页推荐三种来源切换、评论区楼中楼、直播间后台/前台切换与弹幕重连、离线字幕/视角、音频打断续播（Android 17）。

### 环境提醒
- 上游把 `material_ui` 升到 1.11.0，本项目需要给该包打补丁后再编译。请按平台执行：
  `lib/scripts/patch.ps1 -platform android`（脚本会重置 Flutter SDK 并按平台应用补丁）。
  不要手动把 `lib/scripts/material/*.patch` 全量 apply（其中 `bottom_sheet_ios_flutter_material.patch` 仅 iOS 可用）。
