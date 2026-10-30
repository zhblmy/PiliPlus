import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/keep_alive_wrapper.dart';
import 'package:PiliPlus/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:PiliPlus/pages/fan/view.dart';
import 'package:PiliPlus/pages/follow/child/child_view.dart';
import 'package:PiliPlus/pages/follow_search/view.dart';
import 'package:PiliPlus/pages/share/view.dart' show UserModel;
import 'package:PiliPlus/utils/accounts.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class ContactPage extends StatefulWidget {
  const ContactPage({super.key, this.isFromSelect = true, this.title});

  final bool isFromSelect;

  /// 页面标题，默认「通讯录」；从消息页「我的好友」入口进来时传「我的好友」
  final String? title;

  @override
  State<ContactPage> createState() => _ContactPageState();
}

class _ContactPageState extends State<ContactPage>
    with SingleTickerProviderStateMixin {
  late final mid = Accounts.main.mid;
  late final TabController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void onSelect(UserModel userModel) {
    Get.back(result: userModel);
  }

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(
        title: Text(widget.title ?? '通讯录'),
        actions: [
          IconButton(
            onPressed: () async {
              final UserModel? userModel = await Navigator.of(context).push(
                GetPageRoute(
                  page: () => FollowSearchPage(
                    mid: mid,
                    isFromSelect: widget.isFromSelect,
                  ),
                ),
              );
              if (userModel != null) {
                Get.back(result: userModel);
              }
            },
            icon: const Icon(Icons.search),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: Style.tabBarHeight,
            child: TabBar(
              indicator: Style.tabIndicator(ColorScheme.of(context).primary),
              controller: _controller,
              tabs: const [
                Tab(text: '我的关注'),
                Tab(text: '我的粉丝'),
              ],
            ),
          ),
          Expanded(
            child: tabBarView(
              controller: _controller,
              // 两个 Tab 都保活：否则切一次就销毁重建，控制器重新请求、列表闪回骨架
              children: [
                KeepAliveWrapper(
                  child: FollowChildPage(
                    mid: mid,
                    onSelect: widget.isFromSelect ? onSelect : null,
                  ),
                ),
                KeepAliveWrapper(
                  child: FansPage(
                    showName: false,
                    onSelect: widget.isFromSelect ? onSelect : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
