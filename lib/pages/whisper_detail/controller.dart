import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/grpc/bilibili/im/interfaces/v1.pb.dart'
    show EmotionInfo, RspSessionMsg;
import 'package:PiliPlus/grpc/bilibili/im/type.pb.dart' show Msg, MsgType;
import 'package:PiliPlus/grpc/im.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/msg.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/extension/rsp_session_msg_ext.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class WhisperDetailController extends CommonListController<RspSessionMsg, Msg> {
  late final account = Accounts.main;

  late final int talkerId;
  late final String name;
  late final String face;
  late final int? mid;
  late final bool isLive;

  /// 向上翻页的游标：本页最旧一条消息的序号，不是已读位置
  Int64? oldestSeqno;

  //表情转换图片规则
  List<EmotionInfo>? eInfos;

  @override
  void onInit() {
    super.onInit();
    final args = Get.arguments;
    talkerId = args['talkerId'];
    name = args['name'];
    face = args['face'];
    mid = args['mid'];
    isLive = args['isLive'] ?? false;
    queryData();
  }

  static const _syncInterval = Duration(seconds: 20);

  /// 距离最新消息多少像素以内算「停在最新位置」
  static const _latestThreshold = 64.0;

  Timer? _syncTimer;
  bool _syncEnabled = false;
  bool _isSyncingLatest = false;
  bool _syncWhenReachLatest = false;

  /// 由页面生命周期控制：页面可见时才增量同步当前会话
  void startSync() {
    if (_syncTimer != null) return;
    _syncEnabled = true;
    _syncTimer = Timer.periodic(_syncInterval, (_) => _syncLatest());
    scrollController.addListener(_onSyncScroll);
  }

  void stopSync() {
    _syncEnabled = false;
    _syncTimer?.cancel();
    _syncTimer = null;
    scrollController.removeListener(_onSyncScroll);
  }

  /// reverse 列表：偏移 0 就是最新消息
  bool get _isAtLatest =>
      !scrollController.hasClients ||
      scrollController.position.pixels <= _latestThreshold;

  void _onSyncScroll() {
    if (_syncWhenReachLatest && _isAtLatest) {
      _syncWhenReachLatest = false;
      _syncLatest();
    }
  }

  @override
  void onClose() {
    stopSync();
    super.onClose();
  }

  /// 增量同步新消息。
  ///
  /// begin_seqno / end_seqno 的确切语义没有可核验的文档，这里固定取「最新一页」
  /// （不带序号范围），再按序号只保留本地还没有的新消息，避免依赖未确认的参数。
  Future<void> _syncLatest() async {
    if (!_syncEnabled ||
        _isSyncingLatest ||
        isLoading ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    // 用户正在上翻看历史：插入新消息会把当前内容顶走，这些消息也还没被看到，
    // 不应该在这里 ack。等回到最新位置再由滚动回调补一次。
    if (!_isAtLatest) {
      _syncWhenReachLatest = true;
      return;
    }
    if (loadingState.value case Success(:final response)) {
      // 列表还没加载出来时没有基准序号，等整页刷新
      if (response == null || response.isEmpty) return;
    } else {
      return;
    }
    _isSyncingLatest = true;
    try {
      // 定时同步失败时不打扰用户，等下一次 tick
      final res = await AccountManager.silent(
        () => ImGrpc.syncFetchSessionMsgs(talkerId: talkerId),
      );
      if (res is! Success<RspSessionMsg>) return;
      if (!_syncEnabled) return;
      // 请求期间可能开始/完成了整页刷新：交给它的结果，避免合并进一张已被替换的列表
      if (isLoading) return;
      // 请求期间用户可能上翻；不要插入未读消息或将其 ack，等回到最新位置再同步
      if (!_isAtLatest) {
        _syncWhenReachLatest = true;
        return;
      }
      if (loadingState.value case Success(:final response)) {
        final List<Msg>? list = response;
        if (list == null || list.isEmpty) return;
        final newest = list.first.msgSeqno;
        final fresh = res.response.messages
            .where((e) => e.msgSeqno > newest)
            .where((e) => e.msgType != MsgType.EN_MSG_TYPE_DRAW_BACK.value)
            .toList();
        if (fresh.isEmpty) return;
        // 列表按时间倒序维护，index 0 是最新
        fresh.sort((a, b) => b.msgSeqno.compareTo(a.msgSeqno));
        // 新消息可能带新的表情资源，和首次加载一样合并进来
        _mergeInfos(res.response.eInfos);
        list.insertAll(0, fresh);
        loadingState.refresh();
        // 会话已读到最新，用服务端返回的最新序号 ack（与首次加载同一口径）
        final ackSeqno = res.response.newestSeqno;
        if (ackSeqno > 0) ackSessionMsg(ackSeqno);
      }
    } catch (error) {
      if (kDebugMode) debugPrint('sync latest session messages failed: $error');
    } finally {
      _isSyncingLatest = false;
    }
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<RspSessionMsg> response) {
    List<Msg> msgs = response.response.messages;
    if (msgs.isNotEmpty) {
      // 消息按时间倒序返回，最后一条是本页最旧的一条
      oldestSeqno = msgs.last.msgSeqno;
      if (msgs.length == 1 &&
          msgs.last.msgType == 18 &&
          msgs.last.msgSource == 18) {
        //{content: [{"text":"对方主动回复或关注你前，最多发送1条消息","color_day":"#9499A0","color_nig":"#9499A0"}]}
      } else if (isRefresh) {
        // 翻页不重复标记已读；拿不到有效序号就别发，避免把已读位置写坏
        final ackSeqno = response.response.newestSeqno;
        if (ackSeqno > 0) ackSessionMsg(ackSeqno);
      }
      msgs.removeWhere((e) => e.msgType == MsgType.EN_MSG_TYPE_DRAW_BACK.value);
      _mergeInfos(response.response.eInfos);
    }
    return false;
  }

  /// 合并表情资源。
  ///
  /// 每次拉取都会带回同一批表情，直接 `addAll` 会让列表随刷新和 20 秒增量同步
  /// 无限增长，而每条消息渲染都要线性扫一遍，所以按 `text` 去重。
  void _mergeInfos(Iterable<EmotionInfo> infos) {
    if (infos.isEmpty) return;
    final list = eInfos ??= <EmotionInfo>[];
    for (final info in infos) {
      if (!list.any((e) => e.text == info.text)) {
        list.add(info);
      }
    }
  }

  // 消息标记已读，ackSeqno 必须是会话最新一条消息的序号
  Future<void> ackSessionMsg(int ackSeqno) async {
    final res = await MsgHttp.ackSessionMsg(
      talkerId: talkerId,
      ackSeqno: ackSeqno,
    );
    if (res.isSuccess) {
      // 服务端已确认已读，未读角标以服务端汇总为准
      if (Get.isRegistered<MainController>()) {
        Get.find<MainController>().queryUnreadMsg();
      }
    } else if (kDebugMode) {
      // 自动 ack 由增量同步触发，失败时不打断用户，角标会保持未读
      debugPrint('ack session msg failed: $res');
    }
  }

  late bool _isSending = false;
  Future<void> sendMsg({
    String? message,
    Map? picMsg,
    required VoidCallback onClearText,
    MsgType? msgType,
  }) async {
    // debug
    // if (loadingState.value case Success(:final response)) {
    //   final list = List.of(response ?? <Msg>[])
    //     ..insert(
    //       0,
    //       Msg.create()..mergeFromProto3Json({
    //         "senderUid": "${account.mid}",
    //         "receiverType": 1,
    //         "receiverId": "$mid",
    //         "msgType": msgType,
    //         "content": jsonEncode({"content": message}),
    //         "msgSeqno": "1",
    //         "timestamp": "${DateTime.now().millisecondsSinceEpoch ~/ 1000}",
    //         "atUids": ["0"],
    //         "msgKey": "2",
    //         "msgSource": msgType,
    //       }),
    //     );
    //   loadingState.value = Success(list);
    // }
    // onClearText();
    // scrollController.jumpToTop();
    // SmartDialog.showToast('发送成功');
    // return;
    assert((message != null) ^ (picMsg != null));
    // 登录检查放在加锁之前：早退时不能把发送锁留在持有状态
    if (!account.isLogin) {
      SmartDialog.showToast('请先登录');
      return;
    }
    if (_isSending) return;
    _isSending = true;
    feedBack();
    SmartDialog.dismiss();
    try {
      final res = await ImGrpc.sendMsg(
        senderUid: account.mid,
        receiverId: mid!,
        content: msgType == .EN_MSG_TYPE_DRAW_BACK
            ? message!
            : jsonEncode(picMsg ?? {"content": message!}),
        msgType:
            msgType ?? (picMsg != null ? .EN_MSG_TYPE_PIC : .EN_MSG_TYPE_TEXT),
      );
      SmartDialog.dismiss();
      if (res.isSuccess) {
        if (msgType == .EN_MSG_TYPE_DRAW_BACK) {
          // 用 msgKey 定位撤回的那条：菜单打开期间增量同步可能插入新消息，
          // 调用时捕获的 index 已经不可靠
          final key = message;
          final list = loadingState.value.data;
          if (key != null && key.isNotEmpty && key != '0' && list != null) {
            final i = list.indexWhere((e) => '${e.msgKey}' == key);
            if (i != -1) {
              list[i].msgStatus = 1;
              loadingState.refresh();
            }
          }
          SmartDialog.showToast('撤回成功');
        } else {
          onRefresh();
          onClearText();
          SmartDialog.showToast('发送成功');
        }
      } else {
        res.toast();
      }
    } finally {
      // 请求异常时也要收掉「正在发送」的加载态并复位发送锁
      SmartDialog.dismiss();
      _isSending = false;
    }
  }

  @override
  List<Msg>? getDataList(RspSessionMsg response) {
    if (response.hasMore == 0) {
      isEnd = true;
    }
    return response.messages;
  }

  @override
  Future<void> onRefresh() {
    oldestSeqno = null;
    eInfos = null;
    scrollController.jumpToTop();
    return super.onRefresh();
  }

  @override
  Future<LoadingState<RspSessionMsg>> customGetData() =>
      ImGrpc.syncFetchSessionMsgs(
        talkerId: talkerId,
        beginSeqno: oldestSeqno != null ? Int64.ZERO : null,
        endSeqno: oldestSeqno,
      );

  Future<LoadingState> onReport(Msg item, int reasonType, String reasonDesc) {
    return MsgHttp.imMsgReport(
      accusedUid: item.senderUid.toInt(),
      reasonType: reasonType,
      reasonDesc: reasonDesc,
      comment: {'group_id': 0, 'msg_key': item.msgKey.toString()},
      extra: {"msg_keys": []},
    );
  }
}
