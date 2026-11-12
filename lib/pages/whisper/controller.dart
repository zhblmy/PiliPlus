import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart'
    show Offset, Session, SessionMainReply, SessionPageType, ThreeDotItem;
import 'package:PiliPlus/grpc/im.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/msg/msgfeed_unread.dart';
import 'package:PiliPlus/pages/common/common_whisper_controller.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
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

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (!isRefresh && !isLoading && !isEnd) {
      _loadedMore = true;
    }
    return super.queryData(isRefresh);
  }

  /// 自动刷新（前台轮询/回前台）：只有成功才替换列表，失败保留现有数据与分页状态，
  /// 也不弹 toast。用户主动下拉刷新仍走 [onRefresh]。
  Future<void> quietRefresh() async {
    if (isLoading || _loadedMore) return;
    isLoading = true;
    try {
      final res = await AccountManager.silent(ImGrpc.sessionMain);
      if (res case final Success<SessionMainReply> success) {
        customHandleResponse(true, success);
        loadingState.value = Success(getDataList(success.response));
        queryMsgFeedUnread();
      }
    } finally {
      isLoading = false;
    }
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
    }
    return false;
  }

  @override
  Future<LoadingState<SessionMainReply>> customGetData() =>
      ImGrpc.sessionMain(offset: offset);

  @override
  Future<void> onRefresh() {
    offset = null;
    // 手动刷新会重新拉第一页，自动刷新可以恢复
    _loadedMore = false;
    queryMsgFeedUnread();
    return super.onRefresh();
  }
}
