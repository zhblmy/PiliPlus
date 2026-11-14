import 'dart:async';

import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart'
    show Offset, Session, SessionMainReply, SessionPageType, ThreeDotItem;
import 'package:PiliPlus/grpc/im.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/msg/msgfeed_unread.dart';
import 'package:PiliPlus/pages/common/common_whisper_controller.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/msg_notice.dart';
import 'package:PiliPlus/utils/msg_session_mute.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:protobuf/protobuf.dart' show PbMap;

typedef MsgFeedTopItem = ({
  bool enabled,
  IconData icon,
  String name,
  String route,
});

class WhisperController extends CommonWhisperController<SessionMainReply> {
  @override
  SessionPageType sessionPageType = SessionPageType.SESSION_PAGE_TYPE_HOME;

  late final List<MsgFeedTopItem> msgFeedTopItems;
  final disableLikeMsg = Pref.disableLikeMsg;
  late final RxList<int> unreadCounts;

  PbMap<int, Offset>? offset;

  Rx<List<ThreeDotItem>?> threeDotItems = Rx<List<ThreeDotItem>?>(null);
  Rx<List<ThreeDotItem>?> outsideItem = Rx<List<ThreeDotItem>?>(null);

  @override
  void onInit() {
    super.onInit();
    msgFeedTopItems = [
      const (
        name: "回复我的",
        icon: Icons.message_outlined,
        route: "/replyMe",
        enabled: true,
      ),
      const (
        name: "@我",
        icon: Icons.alternate_email_outlined,
        route: "/atMe",
        enabled: true,
      ),
      (
        name: "收到的赞",
        icon: Icons.favorite_border_outlined,
        route: "/likeMe",
        enabled: !disableLikeMsg,
      ),
      const (
        name: "系统通知",
        icon: Icons.notifications_none_outlined,
        route: "/sysMsg",
        enabled: true,
      ),
    ];
    unreadCounts = List.filled(msgFeedTopItems.length, 0).obs;
    queryMsgFeedUnread();
    queryData();
  }

  Future<void> queryMsgFeedUnread() async {
    _lastFeedUnreadAt = DateTime.now().millisecondsSinceEpoch;
    final res = await AccountManager.silent(
      () => ImGrpc.getTotalUnread(unreadType: 2),
    );
    if (res case Success(:final response)) {
      final data = MsgFeedUnread.fromJson(response.msgFeedUnread.unread);
      final unreadCounts = [
        data.reply,
        data.at,
        disableLikeMsg ? 0 : data.like,
        data.sysMsg,
      ];
      if (!listEquals(this.unreadCounts, unreadCounts)) {
        this.unreadCounts.value = unreadCounts;
      }
    }
    // 失败不弹提示：这里也会被前台轮询调用，网络抖动时不应该反复打扰；
    // 会话列表本身的刷新失败已经由列表层反馈
  }

  /// 用户是否已经往后翻过页。
  ///
  /// [quietRefresh] 只取第一页，直接替换列表会让已加载的后续页消失、列表变短，
  /// 正在翻看历史的用户会被顶回顶部，所以翻过页时不做自动替换。
  bool _loadedMore = false;

  int _lastFeedUnreadAt = 0;

  /// 自动刷新时的分类未读：按 60 秒节流。
  ///
  /// 通知栏内容需要 20 秒一次，但这几个分类角标（回复/@/赞/系统）没必要跟着变勤，
  /// 否则消息页可见时每 20 秒就要多打一个汇总请求。手动刷新/进页面走
  /// [queryMsgFeedUnread]，它会自己刷新时间戳，不受这里的节流影响。
  void _queryMsgFeedUnreadThrottled() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastFeedUnreadAt < 60 * 1000) return;
    queryMsgFeedUnread();
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (!isRefresh && !isLoading && !isEnd) {
      _loadedMore = true;
    }
    return super.queryData(isRefresh);
  }

  /// 自动刷新（前台轮询/回前台）：只有成功才替换列表，失败保留现有数据与分页状态，
  /// 也不弹 toast。用户主动下拉刷新仍走 [onRefresh]。
  ///
  /// 返回是否真的刷新到了新数据：`null` 表示本次跳过（正在加载或翻过页），
  /// `false` 表示请求过但失败，调用方据此判断要不要另走会话通知刷新。
  Future<bool?> quietRefresh() async {
    if (isLoading || _loadedMore) return null;
    isLoading = true;
    _isAutoRefreshing = true;
    try {
      final res = await AccountManager.silent(ImGrpc.sessionMain);
      if (res case final Success<SessionMainReply> success) {
        customHandleResponse(true, success);
        loadingState.value = Success(getDataList(success.response));
        _queryMsgFeedUnreadThrottled();
        return true;
      }
      return false;
    } finally {
      isLoading = false;
      _isAutoRefreshing = false;
      // 自动刷新期间用户下拉过：这次请求已经把列表刷到最新，直接补一次用户手势
      if (_pendingManualRefresh) {
        _pendingManualRefresh = false;
        unawaited(onRefresh());
      }
    }
  }

  /// 本次加载是否是 [quietRefresh]（自动刷新）发起的
  bool _isAutoRefreshing = false;
  bool _pendingManualRefresh = false;

  /// 自动刷新在飞时轮到用户下拉，排队等它结束，不要把手势静默丢掉
  @override
  Future<void> onRefresh() async {
    if (isLoading) {
      // 手动刷新在飞时再下拉没有意义，不必排队；只有自动刷新才需要补
      if (_isAutoRefreshing) _pendingManualRefresh = true;
      return;
    }
    offset = null;
    // 手动刷新会重新拉第一页，自动刷新可以恢复
    _loadedMore = false;
    queryMsgFeedUnread();
    return super.onRefresh();
  }

  /// 会话状态变化后立即刷新通知，不必等下一轮轮询
  @override
  void refreshNotices() {
    final state = loadingState.value;
    final data = state.data;
    if (data != null) {
      unawaited(publishMsgNotices(data));
    } else if (state is Success) {
      // 会话列表被整体删除：没有会话可展示，通知也一起撤掉
      clearMsgNotices();
    }
  }

  /// 详情页 ack 成功：把列表里这个会话的未读清掉并立即重建通知。
  ///
  /// 否则在会话里读消息时，它自己的那条通知要等下一轮列表刷新（最长 60 秒，
  /// 详情页属于被覆盖状态）才会消失。
  void markSessionRead(int talkerId) {
    final list = loadingState.value.data;
    if (list == null || list.isEmpty) return;
    var changed = false;
    for (final session in list) {
      if (session.hasUnread() &&
          session.id.hasPrivateId() &&
          session.id.privateId.hasTalkerUid() &&
          session.id.privateId.talkerUid.toInt() == talkerId) {
        session.clearUnread();
        changed = true;
      }
    }
    if (!changed) return;
    loadingState.refresh();
    refreshNotices();
  }

  @override
  List<Session>? getDataList(SessionMainReply response) {
    offset = response.paginationParams.offsets;
    isEnd = !response.paginationParams.hasMore;
    // 免打扰刚写入、SessionMain 尚未读回一致时，按已确认的本地状态展示
    MsgSessionMute.apply(response.sessions);
    return response.sessions;
  }

  @override
  bool customHandleResponse(
    bool isRefresh,
    Success<SessionMainReply> response,
  ) {
    if (isRefresh) {
      threeDotItems.value = response.response.threeDotItems;
      outsideItem.value = response.response.outsideItem;
      // 复用同一次响应，避免消息页可见时再打一次 sessionMain。
      // 翻页拿到的是更旧的会话，不能拿去覆盖通知
      unawaited(publishMsgNotices(response.response.sessions));
    }
    return false;
  }

  @override
  Future<LoadingState<SessionMainReply>> customGetData() =>
      ImGrpc.sessionMain(offset: offset);
}
