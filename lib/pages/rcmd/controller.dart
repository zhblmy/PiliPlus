import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

class RcmdController extends CommonListController {
  late bool enableSaveLastData = Pref.enableSaveLastData;
  final bool appRcmd = Pref.appRcmd;

  int? lastRefreshAt;
  late bool savedRcmdTip = Pref.savedRcmdTip;

  @override
  bool get isEnd => false;

  @override
  void onInit() {
    super.onInit();
    page = 0;
    queryData();
  }

  @override
  Future<LoadingState> customGetData() {
    return appRcmd
        ? VideoHttp.rcmdVideoListApp(freshIdx: page)
        : VideoHttp.rcmdVideoList(freshIdx: page, ps: 20);
  }

  @override
  bool handleError(String? errMsg) {
    // 只有「刷新失败、但本地已有内容」时才保留旧数据；
    // 首屏（loadingState 还不是 Success）失败必须把 Error 交给页面，
    // 否则 loadingState 会一直停在 Loading()，永远停在骨架屏且没有重试入口。
    return enableSaveLastData &&
        loadingState.value.dataOrNull?.isNotEmpty == true;
  }

  @override
  void handleListResponse(List dataList) {
    if (enableSaveLastData && page == 0) {
      if (loadingState.value case Success(:final response)) {
        if (response != null && response.isNotEmpty) {
          if (savedRcmdTip) {
            lastRefreshAt = dataList.length;
          }
          if (response.length > 200) {
            dataList.addAll(response.take(50));
          } else {
            dataList.addAll(response);
          }
        }
      }
    }
  }

  @override
  Future<void> onRefresh() async {
    final prevPage = page;
    page = 0;
    isEnd = false;
    try {
      await queryData();
    } finally {
      // `page` 只在成功拿到一页时自增：刷新失败（保留上次内容）、被 isLoading
      // 挡掉、或请求异常时它仍然是 0。这时必须把分页游标退回刷新前，否则下一次
      // 「加载更多」会用 freshIdx=0 重新请求第一页（APP 端还带 pull=true），
      // 把另一批内容追加到旧列表后面。
      if (page == 0) page = prevPage;
    }
  }
}
