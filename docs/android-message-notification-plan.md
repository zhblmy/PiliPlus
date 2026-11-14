# Android 未读消息通知改造方案

> 状态：通知代码已实现并完成静态审查修订（2026-11-14）；真机验收仍待完成。**当前实际行为见 [android-message-notification-behavior.md](./android-message-notification-behavior.md)。** 后台轮询所用 `remoteMessaging` 类型不符合 Android 官方定义的设备间消息迁移用途，正式发布前需接入推送或确认合规替代方案，详见[第 8 节](#8-关键限制)。
>
> 注意：下文第 4、5 节里的示例代码是**首版设计**（桌面角标靠一条「有未读消息」汇总通知）。2026-11-14 起该汇总通知已移除，角标改由会话通知的 `setNumber` 带出，差异见第 9 节的变更记录 60–63。

## 1. 目标与现状

**用户诉求**：Android 下拉通知栏里，未读消息只显示「有未读消息 / N 条未读消息」，看不到发送者头像、会话名和消息内容。
**期望结果**：通知栏按会话展示头像 + 会话名 + 消息摘要。

现状（改造前，已逐条比对代码）：

1. [`lib/services/message_badge.dart`](../lib/services/message_badge.dart) 通过 MethodChannel 只传 `count`。
2. [`MainActivity.kt`](../android/app/src/main/kotlin/com/example/piliplus/MainActivity.kt) 把 `count` 交给原生 `MessageBadge.update(this, count)`。
3. [`MessageBadge.kt`](../android/app/src/main/kotlin/com/example/piliplus/MessageBadge.kt) 固定显示「有未读消息」+「N 条未读消息」，没有会话数据可供展示；渠道 `message_badge` 是 `IMPORTANCE_LOW` + `VISIBILITY_SECRET`（安全锁屏上整条隐藏）。
4. [`MainController.queryUnreadMsg()`](../lib/pages/main/controller.dart) 只用 HTTP 汇总接口算总数，汇总结果没有联系人、头像、摘要。
5. 前台轮询 `_pollMsg()`（60 秒）在 App 进入后台时被 `stopMsgPolling()` 与 lifecycle 早退掐断，所以后台期间不会产生任何新通知。

## 2. 改造前的代码事实（决定方案边界）

| 事实 | 位置 |
| --- | --- |
| Dart 侧只传 `count`；原生文案写死 | `message_badge.dart` 的 `_update`；`MessageBadge.kt` 的 `update` |
| `_msgPollInterval = Duration(seconds: 60)`；`_pollMsg()` 有 `lifecycleState != resumed` 早退 | [controller.dart](../lib/pages/main/controller.dart) |
| 后台 `paused/hidden/detached` 时 `stopMsgPolling()` | [main/view.dart](../lib/pages/main/view.dart) |
| `_period = 5 * 60 * 1000`（`checkUnread` 节流），与 60 秒轮询不是一回事 | same |
| `queryUnreadMsg()` 在 `msgBadgeMode == hidden && !Pref.enableMsgBadge` 时直接 `clearUnreadMsg()` | controller.dart |
| `_msgUnread()` 私信数 = `followUnread + unfollowUnread + bizMsgFollowUnread + bizMsgUnfollowUnread + unfollowPushMsg + customUnread` | controller.dart |
| `counts.any((e) => e == null)` 时整体提前 return（两个汇总请求都成功才继续） | controller.dart |
| 现有开关 `msgBadgeNotify` 就是 `Pref.enableMsgBadge`（默认 `true`），设置页已有 UI 与权限申请 | [storage_pref.dart](../lib/utils/storage_pref.dart)、[style_settings.dart](../lib/pages/setting/models/style_settings.dart) |
| 关闭该开关会调用 `MessageBadge.update(0)` | style_settings.dart `_onMsgBadgeNotifyChanged` |
| `MessageBadge.ensurePermission()` 以 `Pref.enableMsgBadge` 为门控 | message_badge.dart |
| `contentIntent()` 固定 `requestCode = 1` + `FLAG_UPDATE_CURRENT` | MessageBadge.kt |
| `WhisperController.quietRefresh()` 开头 `if (isLoading || _loadedMore) return` | [whisper/controller.dart](../lib/pages/whisper/controller.dart) |
| 免打扰本地覆盖 `MsgSessionMute.apply()` 只在 `WhisperController.getDataList` 里执行 | whisper/controller.dart、[msg_session_mute.dart](../lib/utils/msg_session_mute.dart) |
| `Session` 有 `id`(private/group/fold/system/customer)、`sessionInfo.sessionName`、`avatar.fallbackLayers`、`msgSummary.rawMsg`、`unread`、`isMuted`、`timestamp` | `grpc/bilibili/app/im/v1.pb.dart` |
| **`Unread.number` 是 `fixnum.Int64`**，`StandardMessageCodec` 不支持，必须 `.toInt()` | 同上 |
| `MsgSummary` 只有 `rawMsg/prefixType/prefixText/isGroupOwner`，**没有发送者 UID** | 同上 |
| `ImGrpc.syncFetchSessionMsgs` 固定 `sessionType: 1`、参数只有 `talkerId`，只能用于私聊 | [grpc/im.dart](../lib/grpc/im.dart) |
| `hasResNativeDraw()` 在 dagw avatar proto（`resource` 的三个分支都存在） | `grpc/bilibili/dagw/component/avatar/v1.pb.dart` |
| 已有 `DownloadForegroundService`（`dataSync`）可作前台服务模板；**未声明 `remoteMessaging` 类型及权限** | AndroidManifest、DownloadForegroundService.kt |
| `compileSdk/targetSdk = 37`、`POST_NOTIFICATIONS`/`INTERNET` 已声明；`ACCESS_LOCAL_NETWORK` 重复声明两次（第 273、300 行，与本方案无关） | build.gradle.kts、AndroidManifest.xml |
| 项目已有 `ImageUtils.thumbnailUrl(src, q, w, h)`（B 站图床返回 `@96w_96h_1c_1q.webp` 并自动 http→https）与 Dio | [image_utils.dart](../lib/utils/image_utils.dart)、[http/init.dart](../lib/http/init.dart) |

## 3. 方案总览

四件事，缺一不可：

1. **数据**：从会话列表生成每会话通知数据 —— 抽成纯函数，可单测。
2. **呈现**：原生按会话发通知（头像大图标 + 会话名 + 摘要），独立渠道、不分组。
3. **开关**：拆成两项独立开关（桌面角标 / 通知栏详情），权限与门控同步放宽。
4. **后台**：`remoteMessaging` 前台服务保证 App 退到后台后仍能低频轮询。

### 3.1 开关设计（双开关，互相独立）

| 开关 | 配置项 | 默认 | 控制范围 |
| --- | --- | --- | --- |
| 桌面未读角标（**既有**） | `msgBadgeNotify` / `Pref.enableMsgBadge` | 开 | 会话通知上的 `setNumber`（桌面角标） |
| 通知栏消息详情（**新增**） | `msgDetailNotify` / `Pref.enableMsgDetailNotify` | 开 | 每会话通知（头像/名称/摘要）+ 后台轮询前台服务 |

两个开关**默认都是开**，老用户升级后直接生效，不需要先去设置页打开——这也是「通知栏看不到头像/内容」这个诉求的默认解法：装上就应该看到，而不是藏在一个默认关闭的开关后面。关掉任意一个只影响它自己的那部分，互不牵连。

必须同步修改的门控（漏一处就会出现「开关没用」或「关不掉」）：

1. `MainController.onInit` 里的 `checkMsgBadge` 条件。
2. `queryUnreadMsg()` 的前置判断：改成 `msgBadgeMode == hidden && !enableMsgBadge && !enableMsgDetailNotify` 才 `clearUnreadMsg()`。
3. `checkUnread()` 的同类条件。
4. `MessageBadge.ensurePermission()`：改成 `enableMsgBadge || enableMsgDetailNotify`。
5. 设置页：`_onMsgBadgeNotifyChanged` 只让会话通知按新状态重发（带/不带数字），**不能把通知清掉**；`_onMsgDetailNotifyChanged(false)` 才清空会话通知。

### 3.2 数据来源与刷新节流

- **消息页可见时**：复用 `WhisperController` 的会话列表响应（`customHandleResponse` 是唯一出口），不额外发请求。
- **消息页不可见 / 后台**：走独立刷新 `_refreshMsgNotice()`，前台 60 秒节流（后台由 120 秒的轮询间隔控制）。`quietRefresh()` 因 `_loadedMore` 跳过时也能通过该路径更新。
- **会话状态本地变化时立即刷新**：标为已读 / 全部已读 / 删除会话 / 切换免打扰后，`CommonWhisperController.refreshNotices()` 用**内存里的当前列表**重新发布（不发请求），通知栏不必等下一轮轮询才消失。
- **请求失败**：保留上次已发布的通知，绝不把失败当成空列表清除。
- **`inactive` 不算后台**：下拉通知栏、系统弹窗只会让 App 失焦，前台轮询照常跑；只有 `paused/hidden/detached` 才降频。
- **`pmCount > 0` 但首页筛不出未读会话是常态**（汇总口径包含未关注人私信、业务通知等），不得据此清空会话通知；只有私信汇总确实为 0 时才清。
- 会话通知的更新**不依赖** `_msgFeedUnread()` 成功：`counts.any((e) => e == null)` 的早退只影响角标数字，不应阻断会话通知刷新。

### 3.3 后台轮询（前台服务，仅后台运行）

当前实现新增 `MessageNotifyService`，但此实现仅供功能验证，不应据此宣称符合 Android 前台服务类型政策：

- **只在退到后台时启动，回前台立刻停止**。前台服务必然带一条常驻通知；App 在使用中却挂一条「正在接收消息通知」正是本次报障的直接原因。把生命周期收窄到后台，前台就完全看不到它。
- 当前代码使用 `foregroundServiceType="remoteMessaging"`。Android 官方将其定义为在设备间迁移文本消息、支持用户切换设备时的任务连续性，不是轮询应用服务器的通用常驻类型。**不能仅为绕过 `dataSync` 时限而选用它**；正式后台消息接收优先使用服务端推送（如 FCM/厂商通道）。
- Android 15+ 的 `dataSync` 前台服务有 6 小时/24 小时累计上限，也不适合无限常驻。若没有推送后端，需重新评估产品需求与 Android 前台服务政策，不能把另一种 FGS 类型当作等价替代。
- 常驻通知：独立渠道 `message_notify_service`、`IMPORTANCE_MIN`、`setShowBadge(false)`、无声、`setOngoing(true)`，标题「正在接收消息通知」。
- 触发点：`AppLifecycleState.paused/hidden` → `MainController.onEnterBackground()` 启动服务并**立刻轮询一次**；`resumed` → `onEnterForeground()` 停止服务；`detached`（进程将销毁）只收尾，不再启动服务。Android 12+ 可能拒绝后台启动 FGS，失败就停止后台轮询，不影响前台；关闭开关 / 退出登录也会 `stopService`。
- `android:stopWithTask="true"`：用户从最近任务划掉 App 后停止轮询（与下载服务行为一致、可预期，不复活进程）。
- 间隔：前台 60 秒（沿用 `_msgPollInterval`）；后台 120 秒。后台只更新角标与会话通知，不调用 `refreshMsgPage()`（页面不可见，controller 可能未注册）。
- 常驻通知是 FGS 的硬性要求，无法隐藏；HyperOS 等仍需用户允许自启动 / 无限制电量，系统设置不能替代 FGS。

### 3.4 头像：Dart 下载，原生只解码

- 复用 `ImageUtils.thumbnailUrl(url, 1, 96, 96)`：B 站图床由服务端缩放到 96×96 webp，流量与解码成本都最低，并自动 `http→https`。
- Dio 8 秒超时、`ResponseType.bytes`、上限 256 KB；失败只降级为无头像，不影响文字通知。
- 内存缓存 `Map<String, ({Uint8List? bytes, int at})>`（URL → bytes）：成功长期缓存，失败只缓存 10 分钟，避免一次网络抖动把某张头像永久锁死；超过 50 条整体清空重建。
- 通过 MethodChannel 传 `Uint8List`（StandardMessageCodec 原生支持）；原生用 `BitmapFactory.decodeByteArray` 解码并缩放到 96dp。**禁止在主线程下载/解码**。

### 3.5 通知呈现（第一阶段用 BigTextStyle）

- 标题 `sessionName`，正文 `msgSummary.rawMsg`（空则「有新消息」），大图标为会话头像。
- 群聊只能拿到**会话头像**，不是发送者头像；发送者级别的信息属于第二阶段。
- `setCategory(CATEGORY_MESSAGE)`、`setWhen(会话时间，微秒→毫秒)`、`tag = 会话 key` + 固定 id。
- **不做通知分组**：分组的 summary 一旦被系统折叠/被渠道限制，子通知会跟着看不见，直接违背「显示头像/会话名/内容」的目标。
- `setOnlyAlertOnce(false)`：同一会话内容变化时允许再次提醒（Dart 侧已按内容指纹去重，不会因重复轮询反复响）。
- `setAutoCancel(true)`；每个会话用**独立 `requestCode`**。
- 发布**一次性**完成（头像下载好后一起发），不做"先文字后头像"的两段式：两段式的指纹会来回跳，导致每轮轮询都重新 notify。
- 是否提醒按**会话级**判断：新会话、或该会话最新消息（时间/内容）变化才 `alert=true`；只是未读数变化（在别处读掉一条）不响。冷启动第一次同步全部静默（历史未读）。
- 原生按会话 key 记录内容指纹，未变化就不再 `notify`：这样一批里只有真正变化的那条会提醒，用户手动划掉的通知也不会被别的会话变化带着又弹回来。
- 最多 5 条，超出的靠差集 `cancel` 清掉。

## 4. 修改位置

| 文件 | 计划修改 |
| --- | --- |
| [`lib/utils/storage_key.dart`](../lib/utils/storage_key.dart) | 紧跟 `msgBadgeNotify` 新增 `msgDetailNotify = 'msgDetailNotify'` |
| [`lib/utils/storage_pref.dart`](../lib/utils/storage_pref.dart) | 新增 `enableMsgDetailNotify` getter（默认 `true`） |
| **新增** `lib/utils/msg_notice.dart` | 纯函数 `buildMsgNotices(List<Session>)` + 头像下载/缓存 + 发布入口 |
| [`lib/services/message_badge.dart`](../lib/services/message_badge.dart) | 新契约：`conversations` 可空、内容指纹去重、`updateConversations()`、`clearAll()` |
| **新增** `lib/services/message_notify_foreground.dart` | 前台服务 MethodChannel 封装（幂等 start / stop / `isRunning`） |
| [`lib/pages/main/controller.dart`](../lib/pages/main/controller.dart) | 放宽 3 处开关门控；`_pollMsg` 前后台两种间隔；`_refreshMsgNotice()`；`startMsgPolling` 登录门控；`clearUnreadMsg` 走 `clearAll` |
| [`lib/pages/main/view.dart`](../lib/pages/main/view.dart) | 回前台只做刷新；前台服务启停移到 `MainController` 的 `AppLifecycleListener`（不受 `didPushNext` 摘除观察者影响） |
| [`lib/pages/whisper/controller.dart`](../lib/pages/whisper/controller.dart) | `customHandleResponse` 复用响应发布；`quietRefresh` 返回 `bool?`；`refreshNotices()` 覆盖 |
| [`lib/pages/common/common_whisper_controller.dart`](../lib/pages/common/common_whisper_controller.dart) | 已读/删除/免打扰成功分支调用 `refreshNotices()`（默认空实现） |
| [`lib/pages/whisper/widgets/item.dart`](../lib/pages/whisper/widgets/item.dart) | 新增 `onUnreadChanged`，标已读成功后立即同步通知 |
| [`lib/pages/whisper/view.dart`](../lib/pages/whisper/view.dart) | 传入 `onUnreadChanged: _controller.refreshNotices` |
| [`lib/pages/setting/models/style_settings.dart`](../lib/pages/setting/models/style_settings.dart) | 新增「通知栏消息详情」开关 + 权限申请 + 启停前台服务 |
| [`MainActivity.kt`](../android/app/src/main/kotlin/com/example/piliplus/MainActivity.kt) | 安全解析 `conversations`（区分「未传」与「空」）；新增前台服务 channel |
| [`MessageBadge.kt`](../android/app/src/main/kotlin/com/example/piliplus/MessageBadge.kt) | 拆分汇总/会话两条路径、双渠道、头像解码、差集清理、`requestCode` |
| **新增** `android/.../MessageNotifyService.kt` | `remoteMessaging` 前台服务 |
| [`AndroidManifest.xml`](../android/app/src/main/AndroidManifest.xml) | 新增 `FOREGROUND_SERVICE_REMOTE_MESSAGING` 权限与服务声明 |
| **新增** `test/utils/msg_notice_test.dart` | 映射/去重/降级的单元测试 |

**前置条件**：先落 `storage_key.dart` + `storage_pref.dart`，否则后续全部编译不过。

## 5. 具体代码

### 5.1 `lib/utils/msg_notice.dart`（新增）

```dart
import 'dart:typed_data';

import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart' show Session, UnreadStyle;
import 'package:PiliPlus/http/init.dart' show Request;
import 'package:PiliPlus/services/message_badge.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/msg_session_mute.dart';
import 'package:dio/dio.dart';

class MsgNoticeItem {
  MsgNoticeItem({
    required this.key,
    required this.name,
    required this.avatarUrl,
    required this.content,
    required this.unread,
    required this.muted,
    required this.timestamp,
  });

  final String key;
  final String name;
  final String avatarUrl;
  final String content;
  final int unread;
  final bool muted;
  final int timestamp;

  Map<String, Object?> toChannelMap(Uint8List? avatar, {bool alert = true}) => {
        'key': key,
        'name': name,
        'avatarUrl': avatarUrl,
        'avatar': ?avatar,
        'content': content,
        // 注意：必须转 int，Unread.number 是 Int64，通道不支持
        'unread': unread,
        'muted': muted,
        'timestamp': timestamp,
        // 只决定这一条要不要响，不参与内容去重（同一条只发布一次）
        'alert': alert,
      };
}

/// 纯函数：会话列表 → 通知数据。可单测，不要内联进 controller。
List<MsgNoticeItem> buildMsgNotices(List<Session> sessions, {int limit = 5}) {
  final items = <MsgNoticeItem>[];
  for (final session in sessions) {
    if (!session.hasUnread()) continue;
    final unread = session.unread;
    final hasUnread = unread.style != UnreadStyle.UNREAD_STYLE_NONE ||
        unread.number > 0 ||
        unread.numberShow.isNotEmpty;
    if (!hasUnread) continue;

    final String key;
    if (session.id.hasPrivateId()) {
      key = 'p:${session.id.privateId.talkerUid.toInt()}';
    } else if (session.id.hasGroupId()) {
      key = 'g:${session.id.groupId.groupId.toInt()}';
    } else {
      // fold / system / customer 不是联系人会话，不进会话通知
      continue;
    }

    final preview = session.hasMsgSummary() ? session.msgSummary.rawMsg.trim() : '';
    final name = session.sessionInfo.sessionName.trim();
    final number = unread.number.toInt();
    items.add(
      MsgNoticeItem(
        key: key,
        name: name.isEmpty ? '新消息' : name,
        avatarUrl: _avatarUrl(session),
        content: preview.isEmpty ? '有新消息' : preview,
        // number 为 0 但服务端给了 numberShow（如「99+」）时按 1 处理
        unread: number > 0 ? number : 1,
        muted: session.isMuted,
        // Session.timestamp 是微秒，通知的 setWhen 要毫秒
        timestamp: session.timestamp.toInt() ~/ 1000,
      ),
    );
    if (items.length >= limit) break;
  }
  return items;
}

String _avatarUrl(Session session) {
  final layers = session.sessionInfo.avatar.fallbackLayers.layers;
  if (layers.isEmpty) return '';
  final resource = layers.first.resource;
  if (resource.hasResImage()) return resource.resImage.imageSrc.remote.url;
  if (resource.hasResAnimation()) return resource.resAnimation.webpSrc.remote.url;
  if (resource.hasResNativeDraw()) return resource.resNativeDraw.drawSrc.remote.url;
  return '';
}

typedef _CachedAvatar = ({Uint8List? bytes, int at});

final _avatarCache = <String, _CachedAvatar>{};
const _avatarMaxBytes = 256 * 1024;
const _avatarFailureTtlMs = 10 * 60 * 1000;

Future<Uint8List?> loadNoticeAvatar(String url) async {
  if (url.isEmpty) return null;
  final now = DateTime.now().millisecondsSinceEpoch;
  final cached = _avatarCache[url];
  // 成功长期缓存；失败只留 10 分钟，避免一次抖动把头像永久锁死
  if (cached != null &&
      (cached.bytes != null || now - cached.at < _avatarFailureTtlMs)) {
    return cached.bytes;
  }
  Uint8List? bytes;
  try {
    final res = await Request().get<List<int>>(
      ImageUtils.thumbnailUrl(url, 1, 96, 96),
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    final data = res.data;
    // 失败时 Request 会把 data 换成 Map，不能只判空
    if (res.statusCode == 200 &&
        data is List<int> &&
        data.length <= _avatarMaxBytes) {
      bytes = Uint8List.fromList(data);
    }
  } catch (_) {
    bytes = null;
  }
  if (_avatarCache.length > 50) _avatarCache.clear();
  _avatarCache[url] = (bytes: bytes, at: now);
  return bytes;
}

/// 唯一发布入口：先应用本地免打扰覆盖，再映射，最后交给原生
Future<void> publishMsgNotices(List<Session> sessions) async {
  // 头像请求可能乱序返回；只允许最后一次会话列表发布其异步结果。
  final version = ++_publishVersion;
  MsgSessionMute.apply(sessions);
  final items = buildMsgNotices(sessions);
  if (items.isEmpty) {
    _hasPublished = true;
    _lastItemSignatures.clear();
    MessageBadge.updateConversations(const []);
    return;
  }

  // 冷启动的第一次同步展示的是历史未读，全部静默；之后只有真正的新消息才提醒
  final alertKeys = _hasPublished
      ? changedNoticeKeys(items, _lastItemSignatures)
      : const <String>{};
  _hasPublished = true;
  _lastItemSignatures
    ..clear()
    ..addEntries(
      items.map(
        (item) => MapEntry(item.key, '${item.timestamp}\u0001${item.content}'),
      ),
    );

  // 头像到位后一次性发布：分两次发会让内容指纹来回跳，每轮都重新 notify
  final avatars = await Future.wait([
    for (final item in items) loadNoticeAvatar(item.avatarUrl),
  ]);
  if (version != _publishVersion) return;
  MessageBadge.updateConversations([
    for (var i = 0; i < items.length; i++)
      items[i].toChannelMap(avatars[i], alert: alertKeys.contains(items[i].key)),
  ]);
}
```

### 5.2 `lib/services/message_badge.dart` 新契约

```dart
abstract final class MessageBadge {
  static const _channel = MethodChannel('piliplus/message_badge');

  static int? _lastCount;
  static String? _lastConvSig;
  static int _updateVersion = 0;

  /// [conversations] 为 `null` 表示「本次不改动会话通知」，空列表表示「全部清除」。
  /// 设置页关闭桌面角标会调 `update(0)` 并保留会话通知；
  /// `clearUnreadMsg()` 则用 `clearAll()` 显式清空两类通知。
  static void update(int count, {List<Map<String, Object?>>? conversations}) {
    if (!Platform.isAndroid) return;
    _send(
      Pref.enableMsgBadge && count > 0 ? count : 0,
      _effective(conversations),
    );
  }

  /// 只更新会话通知；角标不动（原生 `count` 缺省即保持现状）
  static void updateConversations(List<Map<String, Object?>> conversations) {
    if (!Platform.isAndroid) return;
    _send(null, _effective(conversations));
  }

  /// 关闭「通知栏消息详情」后，只传角标的调用也要把已发布的会话通知撤掉
  static List<Map<String, Object?>>? _effective(
    List<Map<String, Object?>>? conversations,
  ) => Pref.enableMsgDetailNotify ? conversations : const [];

  static void _send(
    int? badgeCount,
    List<Map<String, Object?>>? conversations,
  ) {
    // 两个维度各自去重，只带真正变化的那部分过通道（原生契约：缺省 = 不改动）
    final countChanged = badgeCount != null && badgeCount != _lastCount;
    final signature = conversations == null
        ? null
        : _signatureOf(conversations);
    final conversationsChanged =
        signature != null && signature != _lastConvSig;
    if (!countChanged && !conversationsChanged) return;

    if (countChanged) _lastCount = badgeCount;
    if (conversationsChanged) _lastConvSig = signature;

    final version = ++_updateVersion;
    _update(
      countChanged ? badgeCount : null,
      conversationsChanged ? conversations : null,
    ).then((success) {
      if (!success && version == _updateVersion) {
        if (countChanged) _lastCount = null;
        if (conversationsChanged) _lastConvSig = null;
      }
    });
  }

  /// 内容指纹刻意不含 `alert`：它只决定"这次要不要响"，不是内容变化
  static String _signatureOf(List<Map<String, Object?>> items) => items
      .map(
        (e) => '${e['key']}\u0001${e['name']}\u0001${e['avatarUrl']}'
          '\u0001${e['content']}\u0001${e['unread']}\u0001${e['muted']}'
          '\u0001${e['timestamp']}\u0001${e['avatar'] != null}',
      )
      .join('\u0002');

  @visibleForTesting
  static String signatureForTesting(List<Map<String, Object?>> items) =>
      _signatureOf(items);

  /// 回前台：只重置角标（划掉的要重建）；会话通知保持去重，避免又弹回来
  static void reset() {
    _lastCount = null;
    _updateVersion++;
  }

  /// 退出登录 / 未登录：角标与会话通知都清
  static void clearAll() {
    if (!Platform.isAndroid) return;
    _send(0, const []);
  }

  static Future<bool> _update(
    int? count,
    List<Map<String, Object?>>? conversations,
  ) async {
    try {
      return await _channel.invokeMethod<bool>('setCount', {
            'count': ?count,
            'conversations': ?conversations,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
```

`ensurePermission()` 的门控同时要放宽，并在**刚拿到权限**时补一次前台服务启动（冷启动那次通常因为没权限而失败）：

```dart
static Future<void> ensurePermission() async {
  if (!Platform.isAndroid ||
      _askedPermission ||
      !(Pref.enableMsgBadge || Pref.enableMsgDetailNotify)) {
    return;
  }
  _askedPermission = true;
  var granted = await Permission.notification.isGranted;
  if (!granted) {
    granted = (await Permission.notification.request()).isGranted;
  }
  if (granted && Pref.enableMsgDetailNotify) {
    unawaited(MessageNotifyForeground.start());
  }
}
```

### 5.3 `lib/services/message_notify_foreground.dart`（新增）

```dart
abstract final class MessageNotifyForeground {
  static const _channel = MethodChannel('piliplus/message_notify_foreground');
  static int _lastStartMs = 0;
  static bool _running = false;

  static bool get isRunning => _running;

  /// 幂等；失败后 5 秒内不重试
  static Future<bool> start() async {
    if (!Platform.isAndroid) return false;
    if (_running) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastStartMs < 5000) return false;
    if (!await Permission.notification.isGranted) {
      return false; // 权限申请交给设置页，避免后台弹窗
    }
    _lastStartMs = now;
    try {
      _running = await _channel.invokeMethod<bool>('start') ?? false;
    } catch (_) {
      _running = false;
    }
    return _running;
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    _running = false;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
```

### 5.4 `lib/pages/main/controller.dart`

```dart
static const _msgPollInterval = Duration(seconds: 60);
static const _bgPollInterval = Duration(minutes: 2);
int _lastBgPollAt = 0;
int _lastNoticeRefreshAt = 0;
bool _isBackground = false;

Future<void> _pollMsg() async {
  if (!accountService.isLogin.value) return;

  // 只有真正退到后台才算「后台」：inactive 只是失焦（下拉通知栏、系统弹窗）
  final state = WidgetsBinding.instance.lifecycleState;
  final background =
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.detached;
  if (background) {
    // 后台只有「通知栏消息详情」开启且前台服务存活时才继续，且降频
    if (!Pref.enableMsgDetailNotify || !MessageNotifyForeground.isRunning) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastBgPollAt < _bgPollInterval.inMilliseconds) return;
    _lastBgPollAt = now;
  }

  final badgeVisible =
      msgBadgeMode != DynamicBadgeMode.hidden ||
      Pref.enableMsgBadge ||
      Pref.enableMsgDetailNotify;
  if (badgeVisible) await queryUnreadMsg();

  // 消息页可见时由 WhisperController 顺带更新会话摘要；翻过页时它会跳过，需要兜底
  bool? refreshed;
  if (!background && isMsgPageVisible) {
    refreshed = await refreshMsgPage(quiet: true);
  }
  if (refreshed == null) await _refreshMsgNotice();
}

/// 消息页不可见（含 quietRefresh 因 _loadedMore 跳过）时的独立刷新
Future<void> _refreshMsgNotice({bool force = false}) async {
  if (!Pref.enableMsgDetailNotify) return;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (!force && now - _lastNoticeRefreshAt < _msgPollInterval.inMilliseconds) {
    return;
  }
  _lastNoticeRefreshAt = now;
  final res = await AccountManager.silent(ImGrpc.sessionMain);
  if (res case Success(:final response)) {
    await publishMsgNotices(response.sessions);
  }
  // 失败：保留上次已发布的通知，不要当作空列表清除
}
```

同时修改三处门控：

```dart
// onInit
final checkMsgBadge = (msgBadgeMode != DynamicBadgeMode.hidden ||
        Pref.enableMsgBadge ||
        Pref.enableMsgDetailNotify) &&
    (hasHome || hasMsg);

// queryUnreadMsg
if (!accountService.isLogin.value ||
    !(hasHome || hasMsg) ||
    msgUnReadTypes.isEmpty ||
    (msgBadgeMode == DynamicBadgeMode.hidden &&
        !Pref.enableMsgBadge &&
        !Pref.enableMsgDetailNotify)) {
  clearUnreadMsg();
  return;
}

// checkUnread 同上
```

另外三处必须同步的状态语义：

```dart
// onInit 里注册，不依赖 MainApp 的生命周期观察者：
// MainApp 在 didPushNext 时会 removeObserverMobile，从视频页退到后台就收不到了
_appLifecycle = AppLifecycleListener(
  onHide: onEnterBackground,
  onPause: onEnterBackground,
  // 进程即将销毁：不在这里拉起服务，直接收尾
  onDetach: onDetach,
  onResume: onEnterForeground,
);

void startMsgPolling() {
  _ensureMsgPollTimer();
}

/// 退到后台：前台服务只在后台需要，此时才拉起常驻通知并继续轮询
Future<void> onEnterBackground() async {
  if (_isBackground) return;
  _isBackground = true;
  if (!(Pref.enableMsgDetailNotify && accountService.isLogin.value)) {
    stopMsgPolling();
    return;
  }
  _lastBgPollAt = 0; // 进后台先立刻查一次
  _ensureMsgPollTimer();
  if (!await MessageNotifyForeground.start()) {
    stopMsgPolling();
    return;
  }
  // 启动回执期间可能已经回到前台，别把常驻通知留到前台
  if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
    unawaited(MessageNotifyForeground.stop());
    return;
  }
  unawaited(_pollMsg());
}

/// 回前台：摘掉常驻的「正在接收消息通知」
void onEnterForeground() {
  _isBackground = false;
  if (MessageNotifyForeground.isRunning) {
    unawaited(MessageNotifyForeground.stop());
  }
}

void clearUnreadMsg() {
  msgUnReadCount.value = null;
  // 角标与会话通知一起清：未登录/关闭开关/无消息类型时都不该残留通知
  MessageBadge.clearAll();
}

// onChangeAccount(false)
MsgSessionMute.clear();
clearUnreadMsg();
resetMsgNoticeState(); // 新账号首次同步按"历史未读"处理，不响
unawaited(MessageNotifyForeground.stop());
```

> 私信汇总归零时**不要**直接 `update(count, conversations: [])`：群会话的未读不一定计入这个汇总，
> 直接清会把群消息通知误删。应改为 `_refreshMsgNotice(force: true)` 用真实会话列表对齐一次，
> 由列表自己决定剩几条；这次请求会顶替同一轮 `_pollMsg` 的常规刷新，不多打一次。

> 注意：**不要**把 `clearUnreadMsg()` 改回 `MessageBadge.update(0)`。`update(0)` 只撤汇总，
> 未登录、切账号、清空消息类型这些路径会留下上一次的会话通知。

### 5.5 `lib/pages/main/view.dart`

```dart
if (state == AppLifecycleState.resumed) {
  // 回前台立刻补一次未读（前台服务的停靠在 MainController 的生命周期监听里做）
  MessageBadge.reset();
  _mainController
    ..queryUnreadMsg()
    ..checkUnreadDynamic()
    ..checkDefaultSearch(true);
  if (ModalRoute.of(context)?.isCurrent == true) {
    _mainController.startMsgPolling();
  }
  if (_mainController.isMsgPageVisible) {
    _mainController.refreshMsgPage(quiet: true);
  }
}
```

> `AppLifecycleState.paused/hidden/detached` 不再在这里处理：`MainApp` 在 `didPushNext`
> 时会 `removeObserverMobile(this)`，从二级页面退到后台就收不到回调。服务的启停统一由
> `MainController` 自己的 `AppLifecycleListener` 负责，与路由栈无关。

### 5.6 `lib/pages/whisper/controller.dart`

```dart
@override
bool customHandleResponse(bool isRefresh, Success<SessionMainReply> response) {
  if (isRefresh) {
    threeDotItems.value = response.response.threeDotItems;
    outsideItem.value = response.response.outsideItem;
    // 复用同一次响应，避免消息页可见时再打一次 sessionMain。
    // 翻页拿到的是更旧的会话，不能拿去覆盖通知
    unawaited(publishMsgNotices(response.response.sessions));
  }
  return false;
}
```

`publishMsgNotices` 内部会自己 `MsgSessionMute.apply`，不依赖 `getDataList` 的调用顺序。
为了区分「跳过」和「失败」，`quietRefresh()` / `refreshMsgPage()` 改为返回 `bool?`
（`null` 跳过、`false` 失败、`true` 成功），`_pollMsg` 只在跳过时才走独立刷新。

会话状态在本地发生变化时（标已读 / 全部已读 / 删除 / 免打扰）立即同步，不发请求：

```dart
// CommonWhisperController
void refreshNotices() {}   // 子类按需实现

// 在 onClearUnread / onRemove / onSetMute 成功分支里调用 refreshNotices();

// WhisperController
@override
void refreshNotices() {
  final data = loadingState.value.data;
  if (data != null) unawaited(publishMsgNotices(data));
}
```

### 5.7 `lib/pages/setting/models/style_settings.dart`

```dart
if (Platform.isAndroid) ...[
  const SwitchModel(
    title: '桌面未读角标',
    subtitle: '通过一条消息通知在桌面图标上显示未读数；需要通知权限',
    leading: Icon(Icons.notifications_active_outlined),
    setKey: SettingBoxKey.msgBadgeNotify,
    defaultVal: true,
    beforeChange: _requestMsgBadgePermission,
    onChanged: _onMsgBadgeNotifyChanged,
  ),
  SwitchModel(
    title: '通知栏消息详情',
    subtitle: '按会话显示头像、会话名和消息摘要；退到后台时会保留一个常驻通知用于接收消息',
    leading: Icon(Icons.forum_outlined),
    setKey: SettingBoxKey.msgDetailNotify,
    defaultVal: true,
    beforeChange: (value) =>
      _requestMsgBadgePermission(value, tip: '通知栏消息详情'),
    onChanged: _onMsgDetailNotifyChanged,
  ),
],
```

```dart
void _onMsgDetailNotifyChanged(bool value) {
  if (!value) {
    MessageNotifyForeground.stop();
    MessageBadge.updateConversations(const []);
    return;
  }
  // 常驻服务只在退到后台时启动，这里只需按当前未读数重建通知
  MessageBadge.reset();
  if (Get.isRegistered<MainController>()) {
    Get.find<MainController>().queryUnreadMsg();
  }
}
```

`_onMsgBadgeNotifyChanged(false)` 保持 `MessageBadge.update(0)`（`conversations` 为 `null`，只撤汇总）。退出登录处改成 `MessageBadge.clearAll()`。

### 5.8 `MainActivity.kt`

```kotlin
"setCount" -> {
    val args = call.arguments as? Map<*, *>
    // 未传 conversations = 不改动会话通知；传空列表 = 清空
    val conversations = if (args != null && args.containsKey("conversations")) {
        (args["conversations"] as? List<*>).orEmpty()
            .mapNotNull { entry -> (entry as? Map<*, *>)?.toConversationNotice() }
    } else {
        null
    }
    // decodeAvatar 处理会话头像，不要在 MethodChannel 主线程同步执行。
    MESSAGE_BADGE_EXECUTOR.execute {
      val success = runCatching {
        MessageBadge.update(
          this,
          (args?.get("count") as? Number)?.toInt(),
          conversations,
        )
      }.getOrDefault(false)
      runOnUiThread { runCatching { result.success(success) } }
    }
}

// 新增第二个 channel
MethodChannel(
    flutterEngine.dartExecutor.binaryMessenger,
    MESSAGE_NOTIFY_CHANNEL,
).setMethodCallHandler { call, result ->
    when (call.method) {
        "start" -> result.success(runCatching { MessageNotifyService.start(this) }.isSuccess)
        "stop" -> result.success(runCatching { MessageNotifyService.stop(this) }.isSuccess)
        else -> result.notImplemented()
    }
}
```

```kotlin
private fun Map<*, *>.toConversationNotice(): ConversationNotice? {
    val key = this["key"] as? String ?: return null
    return ConversationNotice(
        key = key,
        name = (this["name"] as? String).orEmpty().ifEmpty { "新消息" },
        avatarUrl = (this["avatarUrl"] as? String).orEmpty(),
        avatar = this["avatar"] as? ByteArray,
        content = (this["content"] as? String).orEmpty().ifEmpty { "有新消息" },
        unread = (this["unread"] as? Number)?.toInt()?.coerceAtLeast(1) ?: 1,
        muted = this["muted"] as? Boolean ?: false,
        timestamp = (this["timestamp"] as? Number)?.toLong() ?: 0L,
    )
}
```

> 用 `call.arguments as? Map<*, *>` 而不是 `call.argument<List<Map<String, Any?>>>`：后者是编译期擦除的强转，元素实际是 `HashMap<Any?, Any?>`，一旦 Dart 侧混入 `Int64`/非字符串键就会在运行期炸在意外的地方，逐字段 `as?` 更好排查。

### 5.9 `MessageBadge.kt`（改造要点）

```kotlin
class ConversationNotice(
    val key: String,
    val name: String,
    val avatarUrl: String,
    val avatar: ByteArray?,
    val content: String,
    val unread: Int,
    val muted: Boolean,
    val timestamp: Long,
    val alert: Boolean,
)

object MessageBadge {
    private const val BADGE_CHANNEL_ID = "message_badge"
    private const val NOTICE_CHANNEL_ID = "message_conversations_v1"
    private const val SUMMARY_ID = 0x2001
    private const val SESSION_ID = 0x2100
    private const val MAX_SESSIONS = 5

    private val published = mutableSetOf<String>()

    /** 每条通知最近一次的内容指纹：内容没变就不再 notify（否则整批会被重复提醒） */
    private val lastPosted = mutableMapOf<String, String>()

    private fun fingerprint(item: ConversationNotice): String = buildString {
        append(item.name).append('\u0001')
        append(item.content).append('\u0001')
        append(item.unread).append('\u0001')
        append(item.muted).append('\u0001')
        append(item.timestamp).append('\u0001')
        // 不含 alert：它只决定这次要不要响，不是内容变化
        append(item.avatar?.contentHashCode() ?: 0)
    }

    fun update(
        context: Context,
        count: Int?,
        conversations: List<ConversationNotice>?,
    ): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
            ?: return false
        val compat = NotificationManagerCompat.from(context)

        // 1) 汇总/角标：count 为 null 表示本次不改汇总；<= 0 只撤汇总
        if (count != null) {
            if (count <= 0) {
                compat.cancel(SUMMARY_ID)
            } else if (compat.areNotificationsEnabled()) {
                ensureChannels(manager)
                runCatching { compat.notify(SUMMARY_ID, buildSummary(context, count)) }
            }
        }

        // 2) 会话通知：null = 本次不改动
        if (conversations == null) return true
        if (!compat.areNotificationsEnabled()) return false
        ensureChannels(manager)

        val next = conversations.take(MAX_SESSIONS).associateBy { it.key }
        // 进程重启后 published 为空：先用系统里仍在的通知补齐，避免旧会话通知残留
        restorePublished(context)
        (published - next.keys).forEach { compat.cancel(it, SESSION_ID) }
        published.retainAll(next.keys)

        next.values.forEach { item ->
            val fp = fingerprint(item)
            // 内容没变（含用户手动划掉的情况）就不再 notify，避免整批重复提醒
            if (lastPosted[item.key] == fp) return@forEach
            published += item.key
            lastPosted[item.key] = fp
            val icon = decodeAvatar(item.avatar)
            runCatching { compat.notify(item.key, SESSION_ID, buildSession(context, item, icon)) }
        }
        lastPosted.keys.retainAll(next.keys)
        return true
    }
}
```

`buildSession` / `buildSummary` 关键属性：

```kotlin
NotificationCompat.Builder(context, NOTICE_CHANNEL_ID)
    .setSmallIcon(R.drawable.ic_notification_icon)
    .setContentTitle(item.name)
    .setContentText(item.content)
    .setStyle(NotificationCompat.BigTextStyle().bigText(item.content))
    .setLargeIcon(icon)
    .setWhen(item.timestamp)
    .setCategory(NotificationCompat.CATEGORY_MESSAGE)
    // alert=false 是静默的文字预览阶段；正式提醒时允许内容变化再次提醒
    .setOnlyAlertOnce(silent)
    .setAutoCancel(true)
    .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
    .setContentIntent(contentIntent(context, item))
    .build()

// 汇总：沿用原样式，不加 group —— 分组 summary 被折叠时子通知会一起看不见
```

`contentIntent` 必须按会话分配 `requestCode`：

```kotlin
private fun contentIntent(context: Context, item: ConversationNotice?): PendingIntent? {
    val launch = Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        // 预留给第二阶段深链；现在只透传，Flutter 侧暂不消费
        if (item != null) putExtra(EXTRA_SESSION_KEY, item.key)
    }
    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
    // 固定 requestCode 会让后发布的会话覆盖前一个的 extras
    return PendingIntent.getActivity(context, item?.key?.hashCode() ?: 1, launch, flags)
}
```

`restorePublished`（API 23+）：

```kotlin
private fun restorePublished(context: Context) {
    if (published.isNotEmpty()) return
    val manager = context.getSystemService(NotificationManager::class.java) ?: return
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
    manager.activeNotifications
        .filter { it.id == SESSION_ID && it.tag != null }
        .forEach { published += it.tag }
}
```

`decodeAvatar` 在 `MESSAGE_BADGE_EXECUTOR` 单线程队列内执行 `BitmapFactory.decodeByteArray` 并按最长边缩放到 ≤192px，失败返回 `null`；**不要**用 `cancelAll()` 清理。

### 5.10 `MessageNotifyService.kt` + Manifest

```kotlin
class MessageNotifyService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION") stopForeground(true)
        }
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "message_notify_service"
        private const val NOTIFICATION_ID = 0x2200

        fun start(context: Context) {
            val intent = Intent(context, MessageNotifyService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MessageNotifyService::class.java))
        }
    }
}
```

渠道：`IMPORTANCE_MIN`、`setShowBadge(false)`、`enableVibration(false)`、`setSound(null, null)`；通知 `setOngoing(true)`、`setOnlyAlertOnce(true)`、`setShowWhen(false)`、`setCategory(CATEGORY_SERVICE)`、`setForegroundServiceBehavior(FOREGROUND_SERVICE_IMMEDIATE)`（Android 12+ 默认会延后 10 秒才显示前台服务通知）。

Manifest：

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING" />

<service
    android:name=".MessageNotifyService"
    android:exported="false"
    android:foregroundServiceType="remoteMessaging"
    android:stopWithTask="true" />
```

## 6. 通知渠道与隐私

| 渠道 | 重要性 | 角标 | 用途 |
| --- | --- | --- | --- |
| `message_conversations_v2` | `IMPORTANCE_DEFAULT` | `setShowBadge(true)` | 每会话通知，允许提醒；`VISIBILITY_PRIVATE`，安全锁屏上隐藏正文；角标数字由各条 `setNumber` 累加 |
| `message_conversations_v2_nobadge` | `IMPORTANCE_DEFAULT` | `setShowBadge(false)` | 同一套会话通知，用于关闭「桌面未读角标」时（渠道提交后 `setShowBadge` 不能再改） |
| `message_notify_service` | `IMPORTANCE_MIN` | `setShowBadge(false)` | 前台服务常驻通知，静默 |
| ~~`message_badge`~~ / ~~`message_conversations_v1`~~ | — | — | 已废弃：App 启动时撤销汇总通知并删除渠道 |

要点：

- Android O 起渠道创建后重要性/声音由系统保存，代码无法覆盖用户选择；改动渠道语义时用新 ID。
- **不再有汇总通知**（「有未读消息 / N 条未读消息」），桌面角标改由会话通知的 `setNumber` 带出。
- `VISIBILITY_PRIVATE` 只保证安全锁屏上不展示正文（可配 `setPublicVersion()` 定制公开版本）；如需彻底隐藏，用户应在系统里关闭该渠道的锁屏通知。
- 发布前检查应用通知总开关：`compat.areNotificationsEnabled()`；关闭期间还要清空原生内容指纹，否则重新授权后内容没变就不会再发。
- 发布前同时检查应用通知总开关与目标渠道：`compat.areNotificationsEnabled()`，必要时 `getNotificationChannel(id).importance != IMPORTANCE_NONE`。

## 7. 验收

功能：

1. 私信未读 → 通知栏出现：头像、会话名、摘要、未读数；点击打开 App。
2. 群聊 → 显示群名 + 群头像 + 摘要（**不是**成员头像，属于第二阶段）。
3. 无头像 / 无摘要 / `sessionName` 为空 → 降级为默认图标 +「有新消息」。
4. 同一会话新消息（总数不变、内容变化）→ 通知内容与时间更新并再次提醒。
5. 会话已读 → 该条通知**立即**消失（本地 `refreshNotices()`，不等下一轮轮询），其他会话保留；私信汇总归零 → 汇总与会话通知都消失。
6. 关闭「桌面未读角标」→ 桌面角标/汇总消失，**会话通知仍在**。
7. 关闭「通知栏消息详情」→ 会话通知消失 + 前台服务停止，角标仍按开关工作。
8. 拒绝通知权限 → 不崩溃、不反复弹窗；开关回退并给出跳转系统设置的提示。
9. **前台不出现常驻通知**：App 在前台时通知栏只有会话/汇总通知，没有「正在接收消息通知」。
10. 后台：退到后台才会出现常驻通知；进入后台立刻查一次，之后 120 秒一次，新会话通知正常出现；从最近任务划掉后服务停止、不再通知。
11. 安全锁屏不展示消息正文。
12. 进程被杀重开 → 无旧会话通知残留。
13. 小米 15 / HyperOS 3、4 真机：分别记录 Android API 级别、HyperOS 版本、通知渠道、自启动/电量设置状态。
14. 首次安装（两个开关默认开）：进消息页授权通知后，前台按会话看到头像/名称/摘要；退到后台才出现常驻服务通知。
15. 从二级页面（如视频页）直接退到后台，也能正常拉起后台轮询（生命周期监听不依赖路由栈）。

自动化：

- `test/utils/msg_notice_test.dart`：未读过滤、私聊/群 key、`limit = 5`、空值降级、Int64→int、`muted` 透传、`fold/system` 排除。
- 去重：内容相同 → 指纹相同（`MessageBadge` 不再下发）；内容变化 → 指纹不同。

## 8. 关键限制

- 会话通知展示的是**会话摘要**，不保证是最新那条未读消息；群聊无法标注实际发送人（`MsgSummary` 无发送者 UID）。
- 精确到消息：私聊可评估 `syncFetchSessionMsgs`（当前写死 `sessionType: 1`），群聊需另找协议；不要拿会话头像冒充群成员头像。
- 仍是**轮询**，不是推送：App 被划掉/被系统回收后不会通知；要做到「完全退出也实时通知」必须接推送（含厂商通道）。
- **后台前台服务类型待整改**：Android 官方 `remoteMessaging` 指设备间消息迁移/连续性，并非轮询应用服务器的通用用途；当前实现不可视为符合 Android/Play 政策的发布方案。正式发布应接入推送；不能改用 `dataSync` 无限常驻（Android 15+ 有时限）。
- 私信汇总请求成功且 `pm` 未读类型启用、结果为 0 时，**不要**直接清空会话通知（群会话未读可能不在这个汇总里），而是强制对齐一次真实会话列表（`_refreshMsgNotice(force: true)`）。
- 常驻通知无法隐藏，但**只在退到后台时出现**；App 在前台时服务会停掉，通知栏不会一直挂着「正在接收消息通知」。
- Android 12+ 可能拒绝在 `onStop` 阶段启动前台服务（`ForegroundServiceStartNotAllowedException`）：此时后台轮询会直接停掉，前台功能不受影响，这是有意的降级。
- `pmCount`（HTTP 汇总）与会话列表（gRPC 首页）口径不同，两者不可互相反推。
- `setNumber()` 不保证所有启动器显示数字，桌面角标不能作为通用承诺；需与「通知栏展示」分开验收。
- 本项目额外约束：**不要**在 `queryUnreadMsg()` 里直接调 `sessionMain()`（它在 ack、标已读、回前台、切账号等路径上高频调用）。
- 两个开关默认开启：升级后无需任何操作就能按会话看到头像/名称/摘要；只有**退到后台**时才会出现常驻服务通知（`IMPORTANCE_MIN`，多数系统折叠）。
- 前台服务只在**已登录**且开关打开时启动；未登录不常驻，退出登录会 `stopService`。
- 通知权限仍只在你主动到达的界面申请（消息页 / 设置页开关），不会冷启动弹窗；未授权时前台服务起不来，后台也就没有新通知。
- 前台只在**底栏页面**轮询：`MainApp.didPushNext` 会停表（视频页等二级页面覆盖时不再轮询），这是既有行为；因此前台看视频时不会产生新的会话通知，退到后台后由前台服务接管。

## 9. 本次修订记录（勘误）

| # | 原文档问题 | 本次修订 |
| --- | --- | --- |
| 1 | 示例 `'unread': unread.number` 直接放 `Int64` | 改为 `.toInt()`，并在文档中写明通道类型限制 |
| 2 | `items.hashCode` 做内容去重（Dart 是身份哈希，永不相等） | 改为显式内容指纹 `_signatureOf` |
| 3 | `if (_lastConversationsHash == payloadHash && items.isEmpty) return;` 逻辑反了 | 改为 `if (_lastSignature == key) return;` |
| 4 | 示例重复声明已存在的 `_updateVersion` | 直接给最终版成员声明 |
| 5 | 示例把发布逻辑内联进 `queryUnreadMsg`，与自己「禁止内联」的结论矛盾 | 抽成 `publishMsgNotices` 纯操作，由 `customHandleResponse` / 独立刷新调用 |
| 6 | 会话通知示例用 `CHANNEL_ID`（`message_badge`），与新建渠道矛盾 | 双渠道：`message_badge` 汇总、`message_conversations_v1` 会话 |
| 7 | `conversations = const []` 默认值会让既有 `update(0)` 调用点清空会话通知 | 改为可空参数：`null` 不改动、`[]` 清空 |
| 8 | 声称「缓存/分组/差集」已完备，但未处理进程重启后的残留通知 | 增加 `restorePublished()`（`activeNotifications` 对齐） |
| 9 | 新增开关却没列设置页改动 → 默认关闭导致功能不可达 | 明确新增「通知栏消息详情」开关与权限、前台服务启停 |
| 10 | 未提 `ensurePermission()` 的 `enableMsgBadge` 门控与 `_onMsgBadgeNotifyChanged` 的连带清除 | 单独列为必改项 |
| 11 | 头像下载放原生（重复一套网络/缓存） | 改为 Dart 侧下载 96px 缩略图、传字节，原生只解码 |
| 12 | 未正视「后台不轮询」这一根因 | 增加 `remoteMessaging` 前台服务方案与 300 秒后台节流 |
| 13 | 链接指向 `c:\lmyzhb\PiliPlus-feature\...` | 改为仓库相对路径 |
| 14 | 未覆盖 `MsgSessionMute` 与 `counts.any(null)` 早退 | 映射前统一 `apply`，会话通知不依赖 feed 汇总成功 |
| 15 | 头像下载失败被永久负缓存，一次抖动后该头像再也不加载 | 成功长期缓存、失败只缓存 10 分钟 |
| 16 | `clearUnreadMsg()` 用 `update(0)`（只撤汇总），未登录/清零后会残留会话通知 | 改为 `clearAll()`，汇总与会话一起清 |
| 17 | 未登录也会拉起常驻前台服务 | `startMsgPolling()` 增加登录判断，退出登录时停止服务 |
| 18 | 授权成功后前台服务不会重启，要等下次回前台 | `ensurePermission()` 在拿到权限后补一次 `MessageNotifyForeground.start()` |
| 19 | 标已读/删除/免打扰后通知要等下一轮轮询才更新 | 新增 `refreshNotices()`，用内存列表即时重发 |
| 20 | 新开关默认关闭，用户根本看不到这个功能 | 两个开关都默认开启（`defaultValue/defaultVal: true`），升级后直接生效 |
| 21 | 通知指纹遗漏头像就绪状态与消息时间 | 纳入头像存在状态和 `timestamp`，头像下载回填与同文新消息都能更新通知 |
| 22 | 多次发布并发下载头像，旧请求可能覆盖新会话列表 | 为发布操作加版本号，过期异步结果不再下发 |
| 23 | 无通知权限时启动尝试也触发 5 秒退避，刚授权后的补启动可能被跳过 | 只在权限通过后记录启动退避时间 |
| 24 | 把 `remoteMessaging` 描述成一般消息通知 FGS | 更正为设备间消息迁移用途，并把后台轮询发布合规列为待整改项 |
| 25 | 服务启动回执与退后台回调竞态可能停掉轮询定时器 | 服务确认启动后若应用已在后台，再确保周期定时器存在 |
| 26 | 私信汇总确认归零时仅撤汇总通知 | 仅在私信未读类型启用且汇总请求成功返回 0 时，同时清除会话通知 |
| 27 | 原生头像解码在 MethodChannel 主线程执行 | 改为单线程后台队列处理通知，完成后在主线程回传结果 |
| 28 | 文档将 `clearUnreadMsg()` 描述为 `update(0)` | 改为准确说明 `clearAll()` 清双通知，`update(0)` 用于只关汇总 |
| 29 | 去重说明没有对应自动化覆盖 | 新增指纹测试，覆盖相同数据、头像到位和时间戳变化 |
| 30 | 常驻通知文案暗示划掉应用后仍会提醒，与 `stopWithTask=true` 矛盾 | 改为准确说明应用在后台时接收提醒 |
| 31 | 前台服务在 App 启动时就常驻，通知栏永远挂着「正在接收消息通知」 | 改为**只在退到后台时启动、回前台立刻停止**，前台完全隐藏 |
| 32 | 会话通知与汇总通知共用 `GROUP_KEY`，summary 被折叠/渠道受限时子通知一起看不见 | 取消分组，每条会话通知独立展示头像/名称/摘要 |
| 33 | 后台轮询 300 秒，测试时体感「收到消息也不变化」 | 降到 120 秒，并在进入后台时立刻轮询一次 |
| 34 | 用私信汇总（另一套口径）直接清空会话通知，可能误删群消息通知 | 改为 `_refreshMsgNotice(force: true)` 用真实会话列表对齐 |
| 35 | 授权成功后补启前台服务，会在前台弹出常驻通知 | 去掉该补启；服务只在后台起点启动 |
| 36 | 服务启停挂在 `MainApp` 的生命周期观察者上，而 `didPushNext` 已把观察者移除：从二级页面退到后台不会启动服务 | 改由 `MainController` 自己注册 `AppLifecycleListener`，与路由栈无关 |
| 37 | `onEnterForeground` 无条件 `stop()`，每次回前台都多跨一次平台通道 | 仅在 `isRunning` 时停止 |
| 38 | 验收清单出现两个 `10.` | 重新编号，并补充「二级页面直接退后台」用例 |
| 39 | 两阶段发布（先文字、后头像）会让同一条消息连响两次 | 增加 `alert` 标记：文字预览静默，带图更新才提醒；头像全失败时补一次文字提醒（两段式本身已由 #44 取消，`alert` 现在只表示「这一批要不要响」） |
| 40 | 当前实际行为只散落在方案与代码里 | 新增 [android-message-notification-behavior.md](./android-message-notification-behavior.md) 作为行为说明 |
| 41 | `startForeground` 在 Android 12+ 后台被拒时异常会直接崩进程 | `MessageNotifyService` 吞掉异常并 `stopSelf()`，Dart 侧随之停止后台轮询 |
| 42 | `detached` 也走 `onEnterBackground`，会在进程销毁前尝试启动前台服务 | `detached` 改为只停轮询、不再启动服务 |
| 43 | 文档把常驻通知写成「不可滑掉」 | 改为「默认常驻，个别系统版本允许强行划掉」 |
| 44 | 两段式发布（文字 → 头像）让内容指纹每轮在两种状态间来回跳，实际每轮轮询都会重新 notify、重复提醒 | 改为头像到位后一次性发布 |
| 45 | 整批发布时未变化的会话也会被重新 notify，被带上再次提醒 | 原生按会话 key 记录内容指纹，未变化直接跳过 |
| 46 | 冷启动首次同步会把历史未读全部响一遍；未读数变化也会误报为新消息 | 首次同步静默；`changedNoticeKeys` 只按「新会话 / 时间 / 内容」判定是否需要提醒 |
| 47 | `updateConversations` 每次都带 `count`，汇总通知被重复下发 | 角标/会话两个维度各自去重，只把变化的那部分过通道 |
| 48 | 内容指纹里含 `alert`，每次提醒后又多一次静默重发 | Dart 与原生指纹都只描述内容，`alert` 不参与去重 |
| 49 | `reset()` 清空会话指纹，回前台会把用户划掉的通知重新弹回 | 只重置角标，保留会话指纹 |
| 50 | 退出登录/切换账号后提醒判定状态未清，新账号首次同步可能把历史未读当新消息 | 新增 `resetMsgNoticeState()`，切账号时连同 `clearAll()` 一起清 |
| 51 | Android 12+ 默认把前台服务通知延后 10 秒显示，退到后台要等一会才看到 | `setForegroundServiceBehavior(FOREGROUND_SERVICE_IMMEDIATE)` |
| 52 | `Session.timestamp` 直接塞进 `setWhen`，但它是**微秒**（会话列表 UI 也是 `~/ 1000000` 取秒），通知时间会显示成几万年以后 | `buildMsgNotices` 转成毫秒（`~/ 1000`），单测改用真实微秒输入 |
| 53 | 退出登录时若有一次「下载头像中」的发布还没回来，头像到位后仍会把旧账号的会话通知发回去 | `resetMsgNoticeState()` 同时递增发布版本号，作废在飞的那次发布 |
| 54 | 私信汇总归零时无条件强制对齐会话列表：零未读是常态，每次回前台都会白打一次 `sessionMain` | 只在已发布过会话通知（`hasPublishedMsgNotices`）时才对齐 |
| 55 | 退到后台/服务启动失败时停掉轮询定时器，从二级页面退后台再回前台后定时器再也起不来 | 后台不再停表；`_pollMsg` 已按前后台状态与 `isRunning` 早退，停表是多余的 |
| 56 | 发送回执失败的回滚绑在全局 `_updateVersion` 上：期间若又有别的发送，该维度会一直停在「已发送」，直到值再次变化才重发 | 改为逐维度比较当前值再回滚，删掉 `_updateVersion` |
| 57 | 关闭再打开「通知栏消息详情」后会话通知要等下一轮轮询（最多 60 秒）才回来；「清空会话列表」也不会立刻撤销通知 | 新增 `MainController.refreshMsgNotices()`、`clearMsgNotices()`，设置页与 `CommonWhisperController.onDeleteList` 立即触发 |
| 58 | 后台轮询用的定时器在回前台后仍会在二级页面（视频页）上按 60 秒跑，违背「前台被覆盖不轮询」 | 用 `_routeCovered` 记录覆盖状态：回前台时若仍被覆盖就停表，`didPopNext` 再恢复 |
| 59 | 会话通知整条链路（会话列表请求 + 头像下载）在桌面/iOS 上也照跑，只是原生侧空实现 | 新增 `enableMsgNotice`（Android 且开关打开），`_refreshMsgNotice` / `publishMsgNotices` 在非 Android 直接跳过 |
| 60 | 通知栏里同时有「有未读消息 / N 条未读消息」汇总通知和会话通知，用户要求只留下「头像 + 会话名 + 内容」 | 删掉汇总通知与该路径：角标数字改由会话通知 `setNumber` 带出（启动器累加），Dart 侧 `count` 维度、`reset()` 与 `_lastCount` 一并移除 |
| 61 | 汇总渠道 `message_badge`、旧会话渠道 `message_conversations_v1` 在旧版本里已创建，改代码不会改变已有渠道的 `showBadge` | 换成 `message_conversations_v2`（`setShowBadge(true)`）+ `message_conversations_v2_nobadge`（`setShowBadge(false)`）；App 启动时撤销旧汇总通知并删除两个旧渠道 |
| 62 | 通知权限被拒期间原生按内容指纹跳过发送，重新授权后内容没变就一直不出现 | 权限关闭时清空 `lastPosted`；Dart 侧仍按发送失败回滚指纹，下一轮轮询会重发 |
| 63 | 角标改由会话通知带出后，冷启动要等满一轮轮询（60 秒）才出现，而旧实现的汇总通知是立刻出现的 | `queryUnreadMsg()` 成功后（消息页不可见时）顺带 `_refreshMsgNotice()`，与轮询共用 60 秒节流，不多打请求 |
| 64 | 头像下载期间就提交了最新消息指纹；若该发布后来过期，新消息会被静默吞掉 | 等头像完成且发布版本仍有效后再计算提醒并提交指纹 |
| 65 | 系统单独禁用目标通知渠道时仍可能保留原生内容指纹；发布失败也可能记成已发布 | 校验目标渠道状态；仅在 `notify` 成功后保存指纹，失败时清除对应记录 |
| 66 | 行为说明误称桌面角标开关切换复用快照且不发请求 | 改为强制刷新会话列表后按新渠道重发 |

## 10. 实施检查清单

- [x] `storage_key.dart` 新增 `msgDetailNotify`
- [x] `storage_pref.dart` 新增 `enableMsgDetailNotify`（默认 `true`）
- [x] 设置页两个开关都 `defaultVal: true`（升级后直接生效）
- [x] 新增 `lib/utils/msg_notice.dart`（纯函数 + 头像下载/10 分钟失败缓存 + 发布入口）
- [x] `message_badge.dart` 改为可空 `conversations` + 内容指纹 + `updateConversations` / `clearAll`
- [x] `ensurePermission()` 门控并入 `enableMsgDetailNotify`（不再补启前台服务）
- [x] 新增 `lib/services/message_notify_foreground.dart`
- [x] `main/controller.dart`：3 处门控、`_pollMsg` 前后台间隔、`_refreshMsgNotice`、`startMsgPolling` 登录门控、`clearUnreadMsg` 走 `clearAll`
- [x] `main/view.dart`：退到后台才启动前台服务、回前台停止；`main/controller.dart` 的 `onEnterBackground/onEnterForeground`
- [x] `MainController` 注册独立 `AppLifecycleListener`（不受 `didPushNext` 摘除观察者影响）
- [x] `whisper/controller.dart`：`customHandleResponse` 内发布 + `refreshNotices()` 覆盖
- [x] `common_whisper_controller.dart`：已读/删除/免打扰后 `refreshNotices()`
- [x] `whisper/widgets/item.dart`：标已读后回调 `onUnreadChanged`
- [x] `style_settings.dart`：新开关 + 权限 + 服务启停 + 退出登录走 `clearAll`
- [x] `MainActivity.kt`：安全解析 `conversations`、新增服务 channel
- [x] `MessageBadge.kt`：拆汇总/会话两条路径、双渠道、头像解码、差集清理、`requestCode`
- [x] 新增 `MessageNotifyService.kt` + Manifest 权限与服务声明
- [x] `test/utils/msg_notice_test.dart`
- [x] 通知指纹单测（同数据稳定；头像字节或时间戳变化可区分）
- [x] 会话时间戳单位（微秒 → 毫秒）、退出登录作废在飞发布、清空会话列表立即撤通知
- [ ] 真机验收第 7 节 13 条；本次 `flutter test test/utils/msg_notice_test.dart` 因缺少 MSVC C++ 工具链，在 native assets 构建阶段中止，测试未执行
- [ ] 正式后台接收方案：以推送替代当前不适用的 `remoteMessaging` 轮询前台服务

## 11. 参考

- [Android 通知运行时权限](https://developer.android.com/develop/ui/views/notifications/notification-permission)
- [Android 通知渠道](https://developer.android.com/develop/ui/views/notifications/channels)
- [前台服务类型](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [Android 15 前台服务超时](https://developer.android.com/about/versions/15/behavior-changes-15#datasync-timeout)
- [Android 17 行为变更](https://developer.android.com/about/versions/17/behavior-changes-all)
