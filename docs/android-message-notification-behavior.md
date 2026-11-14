# Android 消息通知：当前行为说明

> 适用版本：本仓库当前实现（2026-11-14）。仅 Android 生效，其他平台相关逻辑直接跳过。
> 设计背景与取舍见 [android-message-notification-plan.md](./android-message-notification-plan.md)。

## 1. 开关

| 开关（设置 → 外观/样式 → 消息） | 配置键 | 默认 | 控制范围 |
| --- | --- | --- | --- |
| 桌面未读角标 | `msgBadgeNotify`（`Pref.enableMsgBadge`） | 开 | 会话通知上的未读数字（桌面上由启动器汇总成角标） |
| 通知栏消息详情 | `msgDetailNotify`（`Pref.enableMsgDetailNotify`） | 开 | 按会话的通知（头像/会话名/内容）+ 后台轮询前台服务 |

- **没有汇总通知**：通知栏里不会出现「有未读消息 / N 条未读消息」这一条，只有每个会话的通知。
- 桌面角标数字挂在会话通知上，所以关掉「通知栏消息详情」后也就没有角标；没有未读会话时同样不显示角标。
- 两个开关各有分工：关掉「通知栏消息详情」会连桌面角标一起停；关掉「桌面未读角标」只是改发到不带角标的渠道（通知照常展示，桌面图标不显示数字）。
- 通知权限是系统级开关，只在两个入口申请：进入消息页时（每个进程最多一次）、或在设置里手动打开任一开关时。拒绝后不再反复弹窗。

## 2. 何时刷新

| 场景 | 行为 |
| --- | --- |
| 前台（底栏页面，未被二级页面覆盖） | 定时器每 5 秒跑一次：会话列表（决定通知栏内容）每次都查，未读汇总（HTTP，给角标用）按 60 秒节流 |
| 前台但打开了视频页等二级页面 | 角标**不刷新**；通知栏内容按 **15 秒**刷新（`_coveredNoticeInterval`），用户看视频/逛设置时也能收到新会话通知 |
| 消息页可见 | 复用该页刷新拿到的会话列表，不额外请求；分类未读（回复/@/赞/系统）按 60 秒节流，不跟着 5 秒变勤 |
| 消息页不可见 | 单独拉一次会话列表（与定时器共用 5 秒节流；查完未读数后也顺带对齐一次，冷启动不必等满一轮轮询就有角标；翻过页导致列表自刷新被跳过时也走这里） |
| 从二级页面返回主页（`didPopNext`） | 覆盖期是 15 秒档，回到主页立刻对齐一次通知（仍受 5 秒节流约束，不会多打请求）；消息页可见时由该页刷新顺带更新 |
| 退到后台（`paused/hidden`） | 启动前台服务，**立刻查一次**，之后每 120 秒一次（定时器不停，只是降频；进程被冻结时自然不跑） |
| 进程即将销毁（`detached`） | 只停止轮询，不再尝试拉起前台服务 |
| 回到前台（`resumed`） | 立刻停止前台服务、摘掉常驻通知；真正从后台回来时会清掉通知节流，让 `resumed` 那次查询**立刻**对齐通知栏内容（只拉一下通知栏的 `inactive` 不算）；未读数与消息页的补刷仍由 `MainApp` 的 `resumed` 回调负责（底栏主页被二级页面覆盖时该回调已被摘掉，回到主页时 `didPopNext` 会补） |
| 私信汇总确认归零 | 若已发布过会话通知，强制对齐一次真实会话列表（不按另一套口径直接清），由列表决定还剩几条；没发过通知时不再多发一次请求 |
| 任一请求失败 | 保留上一次已发布的通知，绝不把失败当成"已无未读"清空 |

前台服务生命周期由 `MainController` 自己的 `AppLifecycleListener` 维护，不依赖 `MainApp` 的路由生命周期观察者，因此"从视频页直接退到后台"同样会启动后台轮询。

四个间隔都在 [lib/pages/main/controller.dart](../lib/pages/main/controller.dart) 顶部：`_noticePollInterval`（前台通知内容，5 秒）、`_coveredNoticeInterval`（被二级页面覆盖，15 秒）、`_msgPollInterval`（未读汇总/角标，60 秒）、`_bgPollInterval`（后台，120 秒）。会话列表请求仍受网络往返时间影响；轮询间隔是发现新内容前的额外等待上限，不是通知显示的端到端时延保证。

5 秒前台轮询会把普通前台会话列表请求频率从每分钟约 3 次提高到约 12 次（消息页可见时复用列表刷新，不另发会话请求）；覆盖页面从每分钟约 1 次提高到约 4 次。真机需继续观察网络用量与耗电；未接入推送前，仍无法做到实时送达。

## 3. 通知长什么样

### 3.1 没有汇总通知

- 通知栏里**不存在**「有未读消息 / N 条未读消息」这条汇总通知，只有下面 3.2 的会话通知。
- 旧版本留下的汇总通知与渠道（`message_badge`、`message_conversations_v1`）在 App 启动时就会被撤销并删除，不必等第一次通知更新。

### 3.2 会话通知（用户看到的"头像 + 会话名 + 内容"）

- 两个渠道，内容完全一样，只有角标设置不同（系统的渠道 `setShowBadge` 提交后不能再改）：
  - `message_conversations_v2`：「消息详情」，`IMPORTANCE_DEFAULT`、`setShowBadge(true)`。
  - `message_conversations_v2_nobadge`：「消息详情（不显示桌面角标）」，`setShowBadge(false)`。
- 两者都用 `VISIBILITY_PRIVATE`（安全锁屏上不展示正文）。
- 每个有未读的私聊/群会话一条，按会话列表顺序最多 5 条；**不做通知分组**（避免 summary 被折叠时子通知一起消失）。
- 标题 = 会话名（空则「新消息」）；正文 = 会话摘要（空则「有新消息」）；大图标 = 会话头像；`setWhen` = 会话时间；`category = MESSAGE`；点击打开 App；点开即消失。
- **桌面角标**：每条通知 `setNumber(该会话未读数)`，启动器把同一渠道里各条通知的数字相加，即"这些会话共有多少条未读"；关掉「桌面未读角标」时改发到不带角标的渠道，也不带数字。通知被划掉、或没有未读会话时，角标会跟着掉。
- 静音会话照常展示，但静默 + 低优先级。
- 发布是**两段**的：会话列表一到就先用已有缓存头像发出去（内容不必等图片），缺头像的那几条下载完再**静默**更新一次（`alert=false`，不会重复响）。头像下载失败也不会拖住通知栏里的文字内容。
- **提醒粒度到会话**：只有「该会话最新消息变化（时间/内容）」或「新会话出现」才响；只是未读数变化（例如在别处读掉一条）只更新内容不响。App 冷启动或重新登录后的第一次同步展示的是历史未读，全部静默。
- 原生按会话 key 记录内容指纹：内容没变的会话不会重复 `notify`。因此一批里只有真正变化的那条会响，也不会因为别的会话有新消息，把已划掉的通知又带回来。

### 3.3 前台服务通知（仅在后台）

- 渠道 `message_notify_service`，`IMPORTANCE_MIN`、无声、`setShowBadge(false)`、`setOngoing(true)`（默认常驻，个别系统版本允许用户强行划掉，划掉不影响服务运行）。
- 标题「正在接收消息通知」、正文「应用在后台时接收新的私信提醒」。
- **只在 App 退到后台时出现，回到前台立即消失**；从最近任务划掉 App 后服务停止。Android 12+ 默认会延后 10 秒显示前台服务通知，这里用 `FOREGROUND_SERVICE_IMMEDIATE` 改成立刻显示。

## 4. 什么时候会清掉通知

| 操作 | 结果 |
| --- | --- |
| 会话标为已读 / 全部已读 / 在会话详情里自动 ack / 删除会话 / 清空会话列表 / 切换免打扰 | 立刻用内存中的会话列表重发（不发请求），对应通知立即消失/更新 |
| 私信全部读完（汇总归零） | 对应会话通知随之消失，桌面角标跟着归零 |
| 切换「桌面未读角标」 | 立即重新拉取会话列表并按新渠道重发；内容没变的通知不会重新响 |
| 关闭「通知栏消息详情」 | 撤掉全部会话通知（桌面角标同时消失）+ 停止前台服务 |
| 退出登录 / 未登录 / 消息未读类型全关 | 全部会话通知清空 |
| 进程被系统回收后重启 | 首次更新按系统里仍在的通知做一次对齐，清掉上一进程的残留 |
| 从最近任务划掉 App | 前台服务停止，不再产生新通知 |

## 5. 权限与降级

- 未授予通知权限：不显示任何通知，前台服务也不会启动；开关仍保持"开"，不会反复弹窗。
- 用户也可以在系统设置里单独关掉「消息详情」渠道（带角标 / 不带角标是两个渠道，互不影响）：被关掉的那个渠道对应的通知不会出现，App 内开关状态不会跟着变。
- 若发布时发现目标渠道已被系统设置禁用，原生会清空该进程的已发布指纹；用户重新启用渠道后，下一次会话刷新即可重新发布当前未读通知。
- Android 12+ 可能在退到后台时拒绝启动前台服务：`startForegroundService` 抛出的 `ForegroundServiceStartNotAllowedException` 会原样变成 `start()` 的失败回执，Dart 侧随即不再做后台轮询；`MessageNotifyService` 内部 `startForeground` 的异常也会被吞掉并 `stopSelf()`，不会崩进程。前台功能不受影响。
- 前台服务常驻通知是系统硬性要求，无法隐藏；HyperOS 等还需允许自启动 / 无限制电量，否则服务可能被杀。

## 6. 已知限制

- 显示的是**会话摘要**，不保证是最新那条未读消息；群聊显示群头像，不是实际发送者的头像。
- 内容和头像都是**轮询**得来的：前台最坏情况要等下一轮（5 秒，二级页面覆盖时 15 秒）再加会话列表请求耗时，才会出现在通知栏，不是实时推送。
- 全部是本地轮询，**不是推送**：App 被划掉/被系统回收后不会收到新消息提醒（需要后续接入推送）。
- 桌面角标数字依赖启动器实现，`setNumber()` 不保证所有设备显示数字；它是各条会话通知 `setNumber` 的累加（最多 5 个会话），不等于服务端汇总的未读总数。
- 只有回复/@/赞/系统通知未读、没有任何未读私信会话时，通知栏与桌面角标都不会出现（没有可展示的头像/会话名/内容）。
- 后台轮询使用的前台服务类型 `remoteMessaging` 官方定义是设备间消息迁移，正式发布前应改为推送或确认合规替代方案（见方案文档第 8 节）。
- 用户手动划掉某条会话通知后，只要内容没变就不会再弹回来（避免打扰）；有新消息时才重新出现。
- 点击通知只打开 App，暂不直达对应会话（Intent 已带 `session_key`，留给后续深链）。

## 7. 实现位置

| 关注点 | 文件 |
| --- | --- |
| 会话 → 通知数据、头像下载与缓存、发布入口 | [lib/utils/msg_notice.dart](../lib/utils/msg_notice.dart) |
| MethodChannel 契约、内容指纹去重 | [lib/services/message_badge.dart](../lib/services/message_badge.dart) |
| 前台服务启停封装 | [lib/services/message_notify_foreground.dart](../lib/services/message_notify_foreground.dart) |
| 轮询、开关门控、前后台切换、覆盖降频、私信归零对齐 | [lib/pages/main/controller.dart](../lib/pages/main/controller.dart) |
| 回前台的刷新 | [lib/pages/main/view.dart](../lib/pages/main/view.dart) |
| 复用消息页响应、已读后立即同步；详情页 ack 后立即撤掉该会话通知 | [lib/pages/whisper/controller.dart](../lib/pages/whisper/controller.dart)、[lib/pages/common/common_whisper_controller.dart](../lib/pages/common/common_whisper_controller.dart)、[lib/pages/whisper_detail/controller.dart](../lib/pages/whisper_detail/controller.dart) |
| 设置项与权限申请 | [lib/pages/setting/models/style_settings.dart](../lib/pages/setting/models/style_settings.dart) |
| 通知构建与渠道 | [MessageBadge.kt](../android/app/src/main/kotlin/com/example/piliplus/MessageBadge.kt) |
| 前台服务 | [MessageNotifyService.kt](../android/app/src/main/kotlin/com/example/piliplus/MessageNotifyService.kt) |
