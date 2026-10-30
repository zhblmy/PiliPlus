import 'package:PiliPlus/common/skeleton/video_card_v.dart';
import 'package:PiliPlus/common/sliver_single_child_delegate.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/liquid_glass.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scroll_behavior.dart';
import 'package:PiliPlus/common/widgets/video_card/video_card_v.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/memory_budget.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class RcmdPage extends StatefulWidget {
  const RcmdPage({super.key});

  @override
  State<RcmdPage> createState() => _RcmdPageState();
}

class _RcmdPageState extends State<RcmdPage>
    with AutomaticKeepAliveClientMixin {
  final controller = Get.put(RcmdController());

  @override
  bool get wantKeepAlive => true;

  /// 列表预取量（逻辑像素）。
  ///
  /// 一行约 98（卡片 90 + 间距 8），1200 等于视口上下各预建近 12 行、
  /// 两列约 48 张缩略图；这部分解码与图片缓存开销在低端机上会直接顶到
  /// 64 MiB 的图片缓存预算，所以低内存档位（或已出现过内存压力）减半到 600，
  /// 仍保留上下各约 6 行的提前量。
  static double get _cacheExtent =>
      MemoryBudget.isLowMemory || MemoryBudget.isUnderPressure ? 600 : 1200;

  /// 触底加载阈值（逻辑像素）：滚动结束时离末尾这么近就请求下一页。
  static const double _loadMoreExtent = 400;

  /// 监听列表内容变化：骨架 → 首屏、追加一页之后补一次「是否填满视口」的检查。
  ///
  /// 放在监听里而不是 build 里：build 会被主题 / 键盘 / 旋转等无关重建带着跑，
  /// 在里面挂 post-frame 会把分页触发绑定到「渲染时机」上（首页顶栏那个
  /// 「在 build 里检查并触发」的旧写法就是这么出的问题，见 home/view.dart）。
  Worker? _loadingStateWorker;

  @override
  void initState() {
    super.initState();
    _loadingStateWorker = ever(
      controller.loadingState,
      (_) => WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureFilled(),
      ),
    );
  }

  @override
  void dispose() {
    _loadingStateWorker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = ColorScheme.of(context);
    return Container(
      clipBehavior: .hardEdge,
      margin: const .symmetric(horizontal: Style.safeSpace),
      decoration: const BoxDecoration(borderRadius: Style.mdRadius),
      child: refreshIndicator(
        onRefresh: controller.onRefresh,
        // BouncingScrollPhysics 自己就会“弹”，别再叠加 Android 的拉伸指示器
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: ScrollConfiguration(
            behavior: const NoOverscrollIndicator(),
            child: CustomScrollView(
              controller: controller.scrollController,
              // iOS/小米那种带阻尼的回弹与惯性，比 Android 默认的“夹紧 + 拉伸”更顺滑跟手
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              // 预渲染约一屏：避免新的一行刚进视口才开始构建/取图造成的掉帧。
              // 但它是「上下各」预建，低内存设备上要按预算减半（见 [_cacheExtent]）。
              cacheExtent: _cacheExtent,
              slivers: [
                // 为首页的液体玻璃顶栏让出空间
                const TopBarInsetSpacer(),
                SliverPadding(
                  padding: const .only(top: Style.cardSpace, bottom: 100),
                  sliver: Obx(
                    () => _buildBody(
                      colorScheme,
                      controller.loadingState.value,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 分页触发：只在一次滚动结束时判定。
  ///
  /// 不再用「列表项 build 到末条就 loadMore」——`cacheExtent` 会把视口外一屏多的
  /// 列表项也 build 出来，而 APP 端推荐每页只有 10 条（约 5 行 490dp），
  /// 首帧就会沿着「末条 build → 追加一页 → 新末条仍在 cacheExtent 内」链式连发
  /// 5~7 个分页请求，冷启动时和首屏图片抢带宽/连接。
  ///
  /// 也不按每帧的滚动更新判定：那样一次请求返回空页（或整页都被过滤器拦掉）时，
  /// 只要手指还压在屏幕底部，就会「一返回就再发一次」，变成连续刷接口。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollEndNotification) return false;
    final metrics = notification.metrics;
    // 必须在顶部之外：本监听器是 RefreshIndicator 的后代，同一条 ScrollEndNotification
    // 我们先收到。列表不足一屏时 `extentAfter` 恒 < 阈值，若在顶部下拉刷新也判定，
    // 就会抢在 RefreshIndicator 调 onRefresh 之前先发一个 loadMore（isLoading 被占住），
    // 把下拉刷新吞掉。BouncingScrollPhysics 下顶部下拉时 pixels 恒 <= 0。
    if (metrics.pixels > 0 &&
        metrics.axis == .vertical &&
        metrics.extentAfter < _loadMoreExtent &&
        _canLoadMore) {
      controller.onLoadMore();
    }
    return false;
  }

  /// 内容还不满一屏（没得滚）时主动补一页
  void _ensureFilled() {
    if (!mounted || !_canLoadMore) return;
    final positions = controller.scrollController.positions;
    // 同一控制器可能短暂挂到多个视图上（Tab 切换期），拿不准就跳过
    if (positions.length != 1) return;
    final position = positions.first;
    // 还没布局过就没有内容尺寸，`maxScrollExtent` 会直接抛空断言
    if (!position.hasContentDimensions || position.maxScrollExtent > 0) return;
    controller.onLoadMore();
  }

  /// 只有已经拿到内容、且没有请求在飞时才允许续拉：
  /// Loading / Error / 空列表都在这里挡掉，失败不会被放大成重试风暴
  bool get _canLoadMore {
    final data = controller.loadingState.value.dataOrNull;
    return data != null && data.isNotEmpty && !controller.isLoading;
  }

  late final gridDelegate = SliverGridDelegateWithExtentAndRatio(
    mainAxisSpacing: Style.cardSpace,
    crossAxisSpacing: Style.cardSpace,
    maxCrossAxisExtent: Pref.recommendCardWidth,
    childAspectRatio: Style.aspectRatio,
    mainAxisExtent: MediaQuery.textScalerOf(context).scale(90),
  );

  Widget _buildBody(
    ColorScheme colorScheme,
    LoadingState<List<dynamic>?> loadingState,
  ) {
    return switch (loadingState) {
      Loading() => _buildSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  if (controller.lastRefreshAt != null) {
                    if (controller.lastRefreshAt == index) {
                      return GestureDetector(
                        onTap: () => controller
                          ..animateToTop()
                          ..onRefresh(),
                        child: Card(
                          child: Container(
                            alignment: Alignment.center,
                            padding: const .symmetric(horizontal: 10),
                            child: Text(
                              '上次看到这里\n点击刷新',
                              textAlign: .center,
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                    final actualIndex = index > controller.lastRefreshAt!
                        ? index - 1
                        : index;
                    return VideoCardV(
                      videoItem: response[actualIndex],
                      onRemove: () {
                        if (controller.lastRefreshAt != null &&
                            actualIndex < controller.lastRefreshAt!) {
                          controller.lastRefreshAt =
                              controller.lastRefreshAt! - 1;
                        }
                        controller.loadingState
                          ..value.data!.removeAt(actualIndex)
                          ..refresh();
                      },
                    );
                  } else {
                    return VideoCardV(
                      videoItem: response[index],
                      onRemove: () => controller.loadingState
                        ..value.data!.removeAt(index)
                        ..refresh(),
                    );
                  }
                },
                itemCount: controller.lastRefreshAt != null
                    ? response.length + 1
                    : response.length,
              )
            : HttpError(onReload: controller.onReload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: controller.onReload,
      ),
    };
  }

  Widget get _buildSkeleton => SliverGrid(
    gridDelegate: gridDelegate,
    delegate: const SliverSingleChildDelegate(
      count: 10,
      child: VideoCardVSkeleton(),
    ),
  );
}
