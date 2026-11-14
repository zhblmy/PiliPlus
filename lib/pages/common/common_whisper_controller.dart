import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart'
    show SessionPageType, SessionId, Session;
import 'package:PiliPlus/grpc/im.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/msg.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/msg_session_mute.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

abstract class CommonWhisperController<R>
    extends CommonListController<R, Session> {
  SessionPageType get sessionPageType;

  /// 会话未读/免打扰状态变化后同步通知；主会话列表会覆写
  void refreshNotices() {}

  Future<void> onRemove(int talkerId) async {
    final res = await MsgHttp.removeMsg(talkerId);
    if (res.isSuccess) {
      // 请求期间列表可能已刷新或增删，按 UID 重新定位，避免删掉错误的会话
      final list = loadingState.value.data;
      final index = list?.indexWhere(
        (e) =>
            e.id.privateId.hasTalkerUid() &&
            e.id.privateId.talkerUid.toInt() == talkerId,
      );
      if (list != null && index != null && index != -1) {
        loadingState
          ..value.data!.removeAt(index)
          ..refresh();
      } else {
        await onRefresh();
      }
      MsgSessionMute.forget(talkerId);
      refreshNotices();
      SmartDialog.showToast('删除成功');
    } else {
      res.toast();
    }
  }

  Future<void> onSetTop(bool isTop, SessionId sessionId) async {
    final res = isTop
        ? await ImGrpc.unpinSession(sessionId: sessionId)
        : await ImGrpc.pinSession(sessionId: sessionId);

    if (res.isSuccess) {
      // 异步期间列表可能变化，用稳定的 sessionId 重新定位
      final list = loadingState.value.data;
      final index = list?.indexWhere((e) => e.id == sessionId);
      if (list != null && index != null && index != -1) {
        if (isTop) {
          list[index].isPinned = false;
        } else {
          final item = list.removeAt(index)..isPinned = true;
          list.insert(0, item);
        }
        loadingState.refresh();
      } else {
        await onRefresh();
      }
      SmartDialog.showToast('${isTop ? '移除' : ''}置顶成功');
    } else {
      res.toast();
    }
  }

  Future<void> onSetMute(Session item, bool isMuted, Int64 talkerUid) async {
    final targetMuted = !isMuted;
    final setting = targetMuted ? 1 : 0;
    final res = await MsgHttp.setMsgDnd(
      uid: Accounts.main.mid,
      setting: setting,
      dndUid: talkerUid,
    );
    if (!res.isSuccess) {
      res.toast();
      return;
    }
    // HTTP 写入和 gRPC 会话列表可能读回不一致：读回核对通过后才改本地状态，
    // 未确认时不要把本地乐观值当成服务端状态
    final verifyRes = await MsgHttp.getMsgDnd(uidsStr: talkerUid);
    final persisted = switch (verifyRes) {
      Success(:final response) =>
        response == null || response.isEmpty ? null : response.first.setting,
      _ => null,
    };
    if (persisted != setting) {
      MsgSessionMute.forget(talkerUid.toInt());
      await onRefresh();
      SmartDialog.showToast(
        persisted == null ? '设置已提交，但未能确认服务端状态' : '免打扰状态尚未同步，请稍后重试',
      );
      return;
    }
    MsgSessionMute.remember(talkerUid.toInt(), targetMuted);
    item.isMuted = targetMuted;
    // 两次请求期间列表可能被整页刷新替换过，同步更新当前列表里的同一会话，
    // 否则「设置成功」的提示会和界面状态对不上
    final uid = talkerUid.toInt();
    for (final session in loadingState.value.data ?? const <Session>[]) {
      if (session.id.privateId.hasTalkerUid() &&
          session.id.privateId.talkerUid.toInt() == uid) {
        session.isMuted = targetMuted;
      }
    }
    loadingState.refresh();
    refreshNotices();
    SmartDialog.showToast('设置成功');
  }

  Future<void> onClearUnread() async {
    final res = await ImGrpc.clearUnread(pageType: sessionPageType);
    if (res.isSuccess) {
      if (loadingState.value case Success(:final response)) {
        if (response != null && response.isNotEmpty) {
          for (final item in response) {
            if (item.hasUnread()) {
              item.clearUnread();
            }
          }
          loadingState.refresh();
        }
      }
      SmartDialog.showToast('已标记为已读');
      refreshNotices();
      if (Get.isRegistered<MainController>()) {
        await Get.find<MainController>().queryUnreadMsg();
      }
    } else {
      res.toast();
    }
  }

  Future<void> onDeleteList() async {
    final res = await ImGrpc.deleteSessionList(pageType: sessionPageType);
    if (res.isSuccess) {
      loadingState.value = const Success(null);
      // 列表已整体删除，通知栏里的会话通知也要立刻消失
      refreshNotices();
    } else {
      res.toast();
    }
  }
}
