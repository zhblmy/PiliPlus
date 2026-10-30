import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:get/get.dart';

abstract class CommonDataController<R, T> extends CommonController<R, T> {
  @override
  Rx<LoadingState<T>> loadingState = LoadingState<T>.loading().obs;

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    if (isLoading) return;
    isLoading = true;
    // 请求或响应处理抛异常时也必须复位，否则之后所有刷新/加载都会被挡住
    try {
      final LoadingState<R> res = await customGetData();
      if (res is Success<R>) {
        if (!customHandleResponse(isRefresh, res)) {
          loadingState.value = res as LoadingState<T>;
        }
      } else {
        if (isRefresh && !handleError(res is Error ? res.errMsg : null)) {
          loadingState.value = res as Error;
        }
      }
    } finally {
      isLoading = false;
    }
  }

  @override
  Future<void> onReload() {
    loadingState.value = LoadingState<T>.loading();
    return super.onReload();
  }
}
