import 'package:PiliPlus/common/skeleton/whisper_item.dart';
import 'package:PiliPlus/common/sliver_single_child_delegate.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/pages/whisper/controller.dart';
import 'package:PiliPlus/pages/whisper/widgets/item.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/extension/three_dot_ext.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class WhisperPage extends StatefulWidget {
  const WhisperPage({super.key});

  @override
  State<WhisperPage> createState() => _WhisperPageState();
}

class _WhisperPageState extends State<WhisperPage>
    with AutomaticKeepAliveClientMixin {
  // 底栏的「消息」分类和 /whisper 路由共用同一个控制器，避免重复注册
  final _controller = Get.putOrFind(WhisperController.new);

  MainController? _mainController;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // /whisper 也可能在没有任何底栏的场景下被直接打开，取不到就算了
    _mainController = Get.isRegistered<MainController>()
        ? Get.find<MainController>()
        : null;
  }

  /// 作为底栏分类使用时和别的 Tab 一样：内容上滑收起底栏、下滑弹出。
  /// 只动底栏，不动首页那条玻璃顶栏的状态。
  bool _onScroll(UserScrollNotification notification) {
    final mainController = _mainController;
    if (mainController == null || !mainController.useBottomNav) return false;
    if (notification.metrics.axis != .vertical) return false;
    // idle（滚动结束）不处理，否则一抬手就把收起的底栏又弹回来
    switch (notification.direction) {
      case .forward:
        mainController.showBottomBar?.value = true;
      case .reverse:
        mainController.showBottomBar?.value = false;
      case _:
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('消息'),
        actions: [
          IconButton(
            tooltip: '新增粉丝',
            onPressed: () => Get.toNamed(
              '/webview',
              parameters: {
                'url':
                    'https://www.bilibili.com/h5/follow/newFans?navhide=1&${ThemeUtils.themeUrl(theme.isDark)}',
              },
            ),
            icon: const Icon(Icons.account_circle_outlined),
          ),
          Obx(() {
            final outsideItem = _controller.outsideItem.value;
            if (outsideItem != null && outsideItem.isNotEmpty) {
              return Row(
                mainAxisSize: .min,
                children: outsideItem.map((e) {
                  return IconButton(
                    tooltip: e.hasTitle() ? e.title : null,
                    onPressed: () => e.type.action(
                      context: context,
                      controller: _controller,
                      item: e,
                    ),
                    icon: e.type.icon,
                  );
                }).toList(),
              );
            }
            return const SizedBox.shrink();
          }),
          Obx(() {
            final threeDotItems = _controller.threeDotItems.value;
            if (threeDotItems != null && threeDotItems.isNotEmpty) {
              return PopupMenuButton(
                itemBuilder: (context) {
                  return threeDotItems
                      .map(
                        (e) => PopupMenuItem(
                          onTap: () => e.type.action(
                            context: context,
                            controller: _controller,
                            item: e,
                          ),
                          child: Row(
                            children: [
                              e.type.icon,
                              Text('  ${e.title}'),
                            ],
                          ),
                        ),
                      )
                      .toList();
                },
              );
            }
            return const SizedBox.shrink();
          }),
          const SizedBox(width: 5),
        ],
      ),
      body: NotificationListener<UserScrollNotification>(
        onNotification: _onScroll,
        child: refreshIndicator(
          onRefresh: _controller.onRefresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              _buildTopItems(theme, padding),
              SliverPadding(
                padding: EdgeInsets.only(bottom: padding.bottom + 100),
                sliver: Obx(() => _buildBody(_controller.loadingState.value)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(LoadingState<List<Session>?> loadingState) {
    switch (loadingState) {
      case Loading():
        return const SliverPrototypeExtentList(
          prototypeItem: WhisperItemSkeleton(),
          delegate: SliverSingleChildDelegate(
            count: 12,
            child: WhisperItemSkeleton(),
          ),
        );
      case Success(:final response):
        if (response != null && response.isNotEmpty) {
          final divider = Divider(
            indent: 72,
            endIndent: 20,
            height: 0,
            color: Colors.grey.withValues(alpha: 0.1),
          );
          return SliverList.separated(
            itemCount: response.length,
            itemBuilder: (context, index) {
              if (index == response.length - 1) {
                _controller.onLoadMore();
              }
              final item = response[index];
              return WhisperSessionItem(
                item: item,
                onSetTop: (isTop, id) =>
                    _controller.onSetTop(item, index, isTop, id),
                onSetMute: (isMuted, talkerUid) =>
                    _controller.onSetMute(item, isMuted, talkerUid),
                onRemove: (talkerId) => _controller.onRemove(index, talkerId),
              );
            },
            separatorBuilder: (context, index) => divider,
          );
        }
        return HttpError(onReload: _controller.onReload);
      case Error(:final errMsg):
        return HttpError(
          errMsg: errMsg,
          onReload: _controller.onReload,
        );
    }
  }

  Widget _buildTopItems(ThemeData theme, EdgeInsets padding) {
    return SliverPadding(
      padding: EdgeInsets.only(left: padding.left, right: padding.right),
      sliver: SliverToBoxAdapter(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(_controller.msgFeedTopItems.length, (index) {
            final item = _controller.msgFeedTopItems[index];
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Obx(
                      () {
                        final count = _controller.unreadCounts[index];
                        return Badge(
                          isLabelVisible: count > 0,
                          label: Text(" $count "),
                          alignment: Alignment.topRight,
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: .circle,
                              color: theme.colorScheme.onInverseSurface,
                            ),
                            child: Icon(
                              item.icon,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.name,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              onTap: () {
                if (!item.enabled) {
                  SmartDialog.showToast('已禁用');
                  return;
                }
                _controller.unreadCounts[index] = 0;
                Get.toNamed(item.route);
              },
            );
          }),
        ),
      ),
    );
  }
}
