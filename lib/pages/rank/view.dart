import 'package:PiliPlus/common/widgets/flutter/vertical_tabs.dart';
import 'package:PiliPlus/common/widgets/liquid_glass.dart';
import 'package:PiliPlus/models/common/rank_type.dart';
import 'package:PiliPlus/pages/rank/controller.dart';
import 'package:PiliPlus/pages/rank/zone/view.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class RankPage extends StatefulWidget {
  const RankPage({super.key});

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage>
    with AutomaticKeepAliveClientMixin {
  final RankController _rankController = Get.put(RankController());

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return Row(
      children: [
        _buildTab(theme),
        Expanded(
          child: TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            controller: _rankController.tabController,
            children: RankType.values
                .map(
                  (item) => ZonePage(
                    rid: item.rid,
                    seasonType: item.seasonType,
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildTab(ThemeData theme) {
    final inset = TopBarInset.maybeOf(context);
    final double expanded = inset?.value ?? 0.0;
    // 收起量程（= 顶栏展开高度 - 收起后仍保留的高度）
    final double extent = expanded - (inset?.minValue ?? expanded);
    final ValueListenable<double>? collapse = inset?.collapse;
    final List<Widget> tabs = RankType.values
        .map((e) => VerticalTab(text: e.label))
        .toList();
    final double bottom = MediaQuery.paddingOf(context).bottom + 105;

    /// 左侧这一栏是固定不滚动的：顶栏完全展开时它正好在顶栏下面，
    /// 收起过程中跟着顶栏一起上移。
    /// （只给「收起后的高度」会一直贴在最上面、被搜索栏盖掉一项；
    /// 只给展开高度又会在收起后留一条空白。）
    Widget tabBar(double top) => VerticalTabBar(
      dividerWidth: 0,
      isScrollable: true,
      indicatorWeight: 3,
      indicatorSize: .tab,
      controller: _rankController.tabController,
      padding: .only(top: top, bottom: bottom),
      // tabs 在上面建好一份复用：收起过程中每帧只重建这一层包装
      tabs: tabs,
      onTap: (index) {
        if (!_rankController.tabController.indexIsChanging) {
          _rankController.animateToTop();
        } else {
          _rankController
            ..tabIndex.value = index
            ..tabController.animateTo(index);
        }
      },
    );

    if (extent <= 0 || collapse == null) {
      return tabBar(expanded);
    }
    // 跟首页玻璃顶栏用同一个收起进度，而不是自己去 Get.find 分区页控制器
    // （那个在分区页建好前会招异常，且切分区时会失效）
    return ValueListenableBuilder<double>(
      valueListenable: collapse,
      builder: (context, value, _) =>
          tabBar(expanded - value.clamp(0.0, extent)),
    );
  }
}
