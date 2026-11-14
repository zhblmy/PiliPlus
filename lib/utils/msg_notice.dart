import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart' show Session, UnreadStyle;
import 'package:PiliPlus/http/init.dart' show Request;
import 'package:PiliPlus/services/message_badge.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/msg_session_mute.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';

/// 一条会话通知的数据，纯数据便于单测。
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

  /// 已转成 int：`Unread.number` 是 Int64，MethodChannel 不支持
  final int unread;
  final bool muted;
  final int timestamp;

  Map<String, Object?> toChannelMap(Uint8List? avatar, {bool alert = true}) => {
    'key': key,
    'name': name,
    'avatarUrl': avatarUrl,
    'avatar': ?avatar,
    'content': content,
    'unread': unread,
    'muted': muted,
    'timestamp': timestamp,
    // 只决定这一条要不要响，不参与内容去重（同一条只发布一次）
    'alert': alert,
  };
}

/// 会话列表 → 通知数据。
///
/// 只保留有未读标记的私聊/群会话；fold/system/customer 这些不是联系人会话，
/// 不进通知。按会话列表原有顺序（最近活跃在前）取前 [limit] 条。
List<MsgNoticeItem> buildMsgNotices(List<Session> sessions, {int limit = 5}) {
  final items = <MsgNoticeItem>[];
  for (final session in sessions) {
    if (!session.hasUnread()) continue;
    final unread = session.unread;
    // 与服务内列表同口径：style 非 none、或 number > 0、或给了 numberShow
    final hasUnread =
        unread.style != UnreadStyle.UNREAD_STYLE_NONE ||
        unread.number > 0 ||
        unread.numberShow.isNotEmpty;
    if (!hasUnread) continue;

    final String key;
    if (session.id.hasPrivateId()) {
      key = 'p:${session.id.privateId.talkerUid.toInt()}';
    } else if (session.id.hasGroupId()) {
      key = 'g:${session.id.groupId.groupId.toInt()}';
    } else {
      continue;
    }

    final preview = session.hasMsgSummary()
        ? session.msgSummary.rawMsg.trim()
        : '';
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
        // Session.timestamp 是微秒（会话列表 UI 也是 ~/ 1000000 取秒），
        // 这里要的是毫秒，否则通知时间会显示成几万年以后
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
  if (resource.hasResAnimation()) {
    return resource.resAnimation.webpSrc.remote.url;
  }
  if (resource.hasResNativeDraw()) {
    return resource.resNativeDraw.drawSrc.remote.url;
  }
  return '';
}

typedef _CachedAvatar = ({Uint8List? bytes, int at});

final _avatarCache = <String, _CachedAvatar>{};
const _avatarMaxBytes = 256 * 1024;
const _avatarFailureTtlMs = 10 * 60 * 1000;
int _publishVersion = 0;

/// 上一次发布时每个会话的「最新消息指纹」（时间 + 内容）
final Map<String, String> _lastItemSignatures = {};
bool _hasPublished = false;

/// 需要提醒的会话：新出现的会话，或最新消息（时间/内容）变了。
/// 只是未读数变化（例如在别处读掉一条）不算新消息，不打扰。
Set<String> changedNoticeKeys(
  List<MsgNoticeItem> items,
  Map<String, String> previous,
) => {
  for (final item in items)
    if (previous[item.key] != '${item.timestamp}\u0001${item.content}')
      item.key,
};

/// 头像缩略图：让服务端缩到 96×96 webp，原生只负责解码
Future<Uint8List?> loadNoticeAvatar(String url) async {
  if (url.isEmpty) return null;
  final now = DateTime.now().millisecondsSinceEpoch;
  final cached = _avatarCache[url];
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
    // 请求失败时 Request 会把 data 换成 Map，不能只判空
    if (res.statusCode == 200 &&
        data is List<int> &&
        data.length <= _avatarMaxBytes) {
      bytes = Uint8List.fromList(data);
    }
  } catch (_) {
    bytes = null;
  }
  // 成功结果长期缓存；失败只留 10 分钟，避免一次网络抖动把头像永久锁死
  if (_avatarCache.length > 50) _avatarCache.clear();
  _avatarCache[url] = (bytes: bytes, at: now);
  return bytes;
}

/// 退出登录 / 切换账号：清掉提醒判定的历史，
/// 避免新账号的第一次同步被当成"新消息"响一遍
void resetMsgNoticeState() {
  // 正在下载头像的那次发布也要作废，否则退出登录后它还会把旧会话通知发上去
  _publishVersion++;
  _hasPublished = false;
  _lastItemSignatures.clear();
}

/// 是否还有已发布的会话通知（只有这时才值得为「汇总归零」再查一次会话列表）
bool get hasPublishedMsgNotices => _lastItemSignatures.isNotEmpty;

/// 会话列表整体作废（例如删除全部会话）：立刻撤掉通知，并把现有会话当作全新会话
void clearMsgNotices() {
  _publishVersion++;
  _hasPublished = true;
  _lastItemSignatures.clear();
  MessageBadge.updateConversations(const []);
}

/// 会话通知只在 Android 且「通知栏消息详情」打开时才有意义。
/// 调用方用它跳过整个流程，避免在桌面/iOS 上白发一次会话列表请求、白下载头像。
bool get enableMsgNotice =>
    Platform.isAndroid && Pref.enableMsgDetailNotify;

/// 唯一发布入口：先应用本地免打扰覆盖，再映射，最后交给原生
Future<void> publishMsgNotices(List<Session> sessions) async {
  // 非 Android 不做映射与头像下载：原生侧本来也是空实现
  if (!Platform.isAndroid) return;
  final version = ++_publishVersion;
  MsgSessionMute.apply(sessions);
  final items = buildMsgNotices(sessions);
  if (items.isEmpty) {
    _hasPublished = true;
    _lastItemSignatures.clear();
    MessageBadge.updateConversations(const []);
    return;
  }

  // 头像到位后一次性发布：分两次发（先文字后头像）会让内容指纹在两次之间来回跳，
  // 每轮轮询都重新 notify 一遍，通知会被反复提醒。
  final avatars = await Future.wait([
    for (final item in items) loadNoticeAvatar(item.avatarUrl),
  ]);
  if (version != _publishVersion) return;

  // 只在最新一批真正准备发布时推进历史指纹，避免过期头像请求吞掉新消息提醒。
  // 冷启动第一次同步展示的是历史未读，全部静默；之后只有真正的新消息才提醒。
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

  MessageBadge.updateConversations([
    for (var i = 0; i < items.length; i++)
      items[i].toChannelMap(avatars[i], alert: alertKeys.contains(items[i].key)),
  ]);
}
