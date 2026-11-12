import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/msg.dart';
import 'package:PiliPlus/models_new/msg/msg_sys/data.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class SysMsgController
    extends CommonListController<List<MsgSysItem>?, MsgSysItem> {
  int? cursor;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  void handleListResponse(List<MsgSysItem> dataList) {
    if (dataList.isEmpty) return;
    if (cursor == null) {
      // 首次加载后上报已读游标；失败时不动本地未读，下次刷新 cursor 归零会重试
      _ackCursor(dataList.first.cursor);
    }
    cursor = dataList.last.cursor;
  }

  Future<void> _ackCursor(int? cursor) async {
    if (cursor == null) return;
    final res = await MsgHttp.msgSysUpdateCursor(cursor);
    if (res case Success()) {
      if (Get.isRegistered<MainController>()) {
        await Get.find<MainController>().queryUnreadMsg();
      }
    } else if (kDebugMode) {
      debugPrint('sys-msg update_cursor failed: $res');
    }
  }

  @override
  Future<void> onRefresh() {
    cursor = null;
    return super.onRefresh();
  }

  Future<void> onRemove(dynamic id, int index) async {
    try {
      final res = await MsgHttp.delSysMsg(id);
      if (res.isSuccess) {
        loadingState
          ..value.data!.removeAt(index)
          ..refresh();
        SmartDialog.showToast('删除成功');
      } else {
        res.toast();
      }
    } catch (_) {}
  }

  @override
  Future<LoadingState<List<MsgSysItem>?>> customGetData() =>
      MsgHttp.msgFeedNotify(cursor: cursor);
}
