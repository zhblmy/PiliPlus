import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/rcmd_source.dart';
import 'package:PiliPlus/models/home/rcmd/result.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/pages/common/common_controller.dart'
    show RefreshImplMixin;
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/rcmd/rcmd_cache.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class RcmdController extends CommonListController with RefreshImplMixin {
  /// 一次刷新要凑够的条数：APP 接口每页固定 10 条，所以要连着拉两页；
  /// web / 桌面端接口能一次给够，单次请求即可。
  static const int _appRefreshPages = 2;

  late bool enableSaveLastData = Pref.enableSaveLastData;

  /// 可在设置页切换后立即生效，无需重启
  RcmdSource rcmdSource = Pref.rcmdSource;

  int? lastRefreshAt;
  late bool savedRcmdTip = Pref.savedRcmdTip;

  /// 当前首屏内容是否来自本地缓存（尚未被任何一次刷新替换）：
  /// 决定首次刷新时是"替换"还是"合并"。
  bool _fromCache = false;

  /// 避免每次刷新失败都弹一遍"显示的是上次内容"
  bool _cacheToastShown = false;

  /// 本次刷新实际消费掉了几页，供 [handleListResponse] 修正续页游标
  int _refreshPageSpan = 1;

  @override
  bool get isEnd => false;

  @override
  Future<void> onLoadMore() {
    // 首屏请求失败、但缓存/旧数据还在时 page 仍是 0。此时「加载更多」必须跳过
    // 第一页，否则 APP 端会用 freshIdx=0 + pull=true 把第一页再追加一遍。
    // isLoading 期间不能动 page —— 那是首次请求还在路上。
    if (page == 0 && !isLoading) page = 1;
    return super.onLoadMore();
  }

  @override
  void onInit() {
    super.onInit();
    page = 0;
    if (enableSaveLastData) {
      final cached = RcmdCache.read(
        src: rcmdSource.name,
        mid: Accounts.main.mid,
        parse: rcmdSource == RcmdSource.app
            ? VideoHttp.parseAppRcmdItems
            : VideoHttp.parseWebRcmdItems,
      );
      if (cached != null) {
        loadingState.value = Success(cached.items);
        _fromCache = true;
        // 缓存里已经包含 `pages` 页内容：续页从下一页开始，
        // 否则会重复请求第二页（APP 端每页 10 条）。
        // 启动期也不再自动发请求，数据新鲜度交给用户下拉。
        page = cached.pages;
        return;
      }
    }
    // 没有缓存（首次安装 / 缓存损坏 / 换账号）才在启动时请求
    queryData();
  }

  @override
  Future<LoadingState> customGetData() {
    if (page == 0) return _fetchRefresh();

    _refreshPageSpan = 1;
    return switch (rcmdSource) {
      RcmdSource.app => VideoHttp.rcmdVideoListApp(freshIdx: page),
      // 桌面端：与官方 Windows 客户端一致，每次请求 30 条
      RcmdSource.desktop => VideoHttp.rcmdVideoList(
        freshIdx: page,
        ps: 30,
        desktop: true,
      ),
      RcmdSource.web => VideoHttp.rcmdVideoList(freshIdx: page, ps: 20),
    };
  }

  /// 刷新（`freshIdx == 0`）：一次凑够首屏内容。
  ///
  /// - APP：10 条/页，两页并行发再合并去重（总延迟约等于一页）
  /// - web / 桌面端：单次请求就给足（20 / 30 条）
  Future<LoadingState> _fetchRefresh() async {
    if (rcmdSource != RcmdSource.app) {
      _refreshPageSpan = 1;
      final desktop = rcmdSource == RcmdSource.desktop;
      return VideoHttp.rcmdVideoList(
        freshIdx: 0,
        ps: desktop ? 30 : 20,
        desktop: desktop,
        onRawItems: (items) => _cacheRaw(items, 1),
      );
    }

    // 两页并行发（总延迟约等于一页），合并时按 bvid 去重，
    // 避免并发返回重叠内容
    List? raw0, raw1;
    final results = await Future.wait([
      _fetchAppPage(0, onRawItems: (items) => raw0 = items),
      _fetchAppPage(1, onRawItems: (items) => raw1 = items),
    ]);

    final first = results[0];
    // 第一页失败就是刷新失败；第二页失败只是少 10 条，不影响这次刷新
    if (first is! Success<List<RcmdVideoItemAppModel>>) return first;

    final second = results[1];
    // 以"第二页真的解析成功"为准：解析失败时 onRawItems 已经回调过，
    // 但这一页不能算进游标，否则会跳过它的内容
    final secondOk = second is Success<List<RcmdVideoItemAppModel>>;
    final merged = _mergeUnique(first.response, [
      if (secondOk) ...second.response,
    ]);

    // 第二页失败时这次刷新只消费了第 0 页：游标也只能前进一页，
    // 否则下次「加载更多」会跳过 freshIdx=1 的整页内容
    _refreshPageSpan = secondOk ? _appRefreshPages : 1;

    final raw = <dynamic>[...?raw0, if (secondOk) ...?raw1];
    if (raw.isNotEmpty) _cacheRaw(raw, _refreshPageSpan);

    return Success(merged);
  }

  /// app 端单页请求：把异常收敛成 [Error]。
  ///
  /// 并行请求时如果某一页抛异常，`Future.wait` 会整体抛出 —— 那样不仅会丢掉
  /// 另一页已经成功的结果，异常还会一路穿过 [queryData]，把 `loadingState`
  /// 留在 Loading()（永远停在骨架屏）。
  Future<LoadingState<List<RcmdVideoItemAppModel>>> _fetchAppPage(
    int idx, {
    void Function(List items)? onRawItems,
  }) {
    return VideoHttp.rcmdVideoListApp(
      freshIdx: idx,
      onRawItems: onRawItems,
    ).catchError((Object e) => Error(e.toString()));
  }

  /// 从 [dataList] 里就地剔除列表已有的条目（按 bvid / aid）
  void _removeExisting(List dataList) {
    final existing = loadingState.value.dataOrNull;
    if (existing == null || existing.isEmpty) return;
    final seen = <String>{};
    for (final item in existing) {
      final key = _itemKey(item);
      if (key != null) seen.add(key);
    }
    if (seen.isEmpty) return;
    dataList.removeWhere((item) {
      final key = _itemKey(item);
      return key != null && seen.contains(key);
    });
  }

  /// 按 `bvid`（退化到 `aid`）去重合并，保持 [base] 的顺序
  List<dynamic> _mergeUnique(List base, List extra) {
    final seen = <String>{};
    final out = <dynamic>[];
    for (final item in [...base, ...extra]) {
      final key = _itemKey(item);
      if (key != null && !seen.add(key)) continue;
      out.add(item);
    }
    return out;
  }

  String? _itemKey(dynamic item) {
    if (item is BaseRcmdVideoItemModel) {
      return item.bvid ?? item.aid?.toString();
    }
    return null;
  }

  void _cacheRaw(List items, int pages) {
    if (!enableSaveLastData) return;
    RcmdCache.write(
      src: rcmdSource.name,
      mid: Accounts.main.mid,
      items: items,
      pages: pages,
    );
  }

  @override
  bool handleError(String? errMsg) {
    // 只有「刷新失败、但本地已有内容」时才保留旧数据；
    // 首屏（loadingState 还不是 Success）失败必须把 Error 交给页面，
    // 否则 loadingState 会一直停在 Loading()，永远停在骨架屏且没有重试入口。
    if (!enableSaveLastData ||
        loadingState.value.dataOrNull?.isNotEmpty != true) {
      return false;
    }
    if (_fromCache && !_cacheToastShown) {
      _cacheToastShown = true;
      // 有缓存可看就别退回骨架屏，但要说清这是上次的内容（下拉即重试）
      SmartDialog.showToast('网络异常，显示的是上次内容');
    }
    return true;
  }

  @override
  void handleListResponse(List dataList) {
    // 加载更多：服务端偶尔会返回与已有内容重复的条目，就地剔除，
    // 否则会直接显示成重复卡片（刷新路径的去重管不到这里）
    if (page != 0) {
      _removeExisting(dataList);
      // 已经拿到网络数据了：首次刷新不必再"整列表替换"
      _fromCache = false;
      return;
    }

    final fromCache = _fromCache;
    _fromCache = false;
    _cacheToastShown = false;
    // 本次刷新消费了 [_refreshPageSpan] 页（APP 端两页），
    // 这里先把游标退一页，queryData 结尾的 page++ 正好落到续页上
    page = _refreshPageSpan - 1;

    // 缓存只是"先给点东西看"：首次刷新直接替换，不与缓存合并 ——
    // 否则会出现重复内容，以及语义错误的"上次看到这里"分隔卡
    if (fromCache || !enableSaveLastData) return;

    if (loadingState.value case Success(:final response)) {
      if (response != null && response.isNotEmpty) {
        // 先给新数据自己按 bvid 去重，再合并旧内容 —— 分隔卡的位置必须正好
        // 落在"新数据"与"旧内容"之间，否则 view 里 `index > lastRefreshAt`
        // 的换算会取到越界下标
        final base = _mergeUnique(dataList, const []);
        final merged = _mergeUnique(base, [
          if (response.length > 200) ...response.take(50) else ...response,
        ]);
        // 旧内容全是重复（没留下任何一条）时不插分隔卡
        lastRefreshAt = savedRcmdTip && merged.length > base.length
            ? base.length
            : null;
        dataList
          ..clear()
          ..addAll(merged);
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

  void toTopAndRefresh() {
    scrollController.jumpToTop();
    showRefresh();
  }
}
