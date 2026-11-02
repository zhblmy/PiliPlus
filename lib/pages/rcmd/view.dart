import 'package:PiliPlus/common/skeleton/video_card_v.dart';
import 'package:PiliPlus/common/sliver_single_child_delegate.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scroll_behavior.dart';
import 'package:PiliPlus/common/widgets/top_bar_inset.dart';
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
  /// 它同时是「什么时候把末条 build 出来、从而续拉下一页」的触发距离，所以取值
  /// 决定了两件事：首帧连锁拉几页、以及划动时提前多远开始请求下一页。
  ///
  /// 一行约 98（卡片 90 + 间距 8），APP 端推荐每页 10 条（约 5 行 490dp）。
  /// 取 700（约一屏）是按这两个数算过的折中：
  /// - 首帧连锁到第 3 页就停（30 条、约 2.3 屏内容，预建卡片约 28 张）；
  ///   原值 1200 会预建到第 4 页（约 38 张），冷启动时几十张缩略图一起抢带宽，
  ///   是首页首次加载慢的原因之一；
  /// - 同时留出约一屏的提前量，下一页在划到底之前就发出，不会出现
  ///   「划一下就到底、还得干等加载」。
  /// 低内存档位（或已出现过内存压力）再减半到 350（首帧仍是 3 页，提前量减半）。
  static double get _cacheExtent =>
      MemoryBudget.isLowMemory || MemoryBudget.isUnderPressure ? 350 : 700;

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
        child: ScrollConfiguration(
          behavior: const NoOverscrollIndicator(),
          child: CustomScrollView(
            controller: controller.scrollController,
            // iOS/小米那种带阻尼的回弹与惯性，比 Android 默认的“夹紧 + 拉伸”更顺滑跟手
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            cacheExtent: _cacheExtent,
            slivers: [
              // 为首页的顶栏让出空间
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
    );
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
                  // 末条被 build 出来（≈ 滚到离底部 [_cacheExtent] 以内）就续拉下一页，
                  // 请求在用户划到底之前发出。首帧内容不满预取范围时会连锁补到第 3 页
                  // 为止，之后追加的末条就落在范围外，只在继续划动时才再触发；
                  // 返回空页 / 整页被过滤时列表不变、末条不再重建，也不会反复请求。
                  if (index == response.length - 1) {
                    controller.onLoadMore();
                  }
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
