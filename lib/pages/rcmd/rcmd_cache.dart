import 'dart:convert';

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

/// 首页推荐流首屏缓存。
///
/// 存的是**过滤前**的原始 item，读的时候重跑一遍网络层那套解析 + 过滤，
/// 这样用户新拉黑的 UP、新加的屏蔽词立刻生效，不会因为用了缓存而"复活"。
abstract final class RcmdCache {
  /// 2：指纹改为全量 id、新增 `pages`（旧缓存读不出来，正好丢掉）
  static const int _ver = 2;

  /// 20 条 ≈ 2 屏：一次刷新就是这么多，再多也用不到
  static const int _maxItems = 20;

  /// 每个来源一个槽位：app / web 的缓存互不覆盖，
  /// 来回切换模式不用各拉一次
  static String _key(String src) => '${LocalCacheKey.rcmdCache}_$src';

  /// 写入原始 item（只在刷新时调用，即 `freshIdx == 0`）。
  ///
  /// [pages] 是这批 item 实际覆盖了几页（APP 端每页 10 条、正常两页，
  /// 第二页失败时只有一页），冷启动时据此决定续页游标。
  ///
  /// 缓存只是加速手段，任何异常都不能影响主流程，因此整体吞掉异常。
  static Future<void> write({
    required String src,
    required int mid,
    required List items,
    required int pages,
  }) async {
    if (items.isEmpty) return;
    try {
      final box = GStorage.localCache;
      final cached = _dedupe(items).take(_maxItems).toList();
      if (cached.isEmpty) return;
      final sig = _signature(cached);

      // 来源 / 账号 / 版本 / 内容都没变才跳过写入。
      // 不能只比 sig：取不到 id 时 sig 为 null，切模式或换账号后也可能
      // 算出同一个 sig —— 那样新内容永远写不进去，缓存就冻在旧数据上。
      if (sig != null) {
        final old = box.get(_key(src));
        if (old is Map &&
            old['ver'] == _ver &&
            old['src'] == src &&
            old['mid'] == mid &&
            old['pages'] == pages &&
            old['sig'] == sig) {
          return;
        }
      }

      await box.put(_key(src), <String, dynamic>{
        'ver': _ver,
        'src': src,
        'mid': mid,
        'sig': sig,
        'pages': pages,
        // 存 JSON 字符串而不是嵌套 Map：Hive 读回来的 Map 是
        // Map<dynamic, dynamic>，直接喂给 Model.fromJson(Map<String, dynamic>)
        // 会在运行时抛类型错误；jsonDecode 之后的类型才是对的
        'items': jsonEncode(cached),
      });
    } catch (_) {
      // 缓存写失败无所谓，下次刷新会再写
    }
  }

  /// 读取缓存并就地解析。
  ///
  /// 返回 `null` 表示没有可用缓存（没有 / 版本或来源或账号不符 / 数据损坏 /
  /// 全部被过滤掉）。`pages` 是缓存覆盖的页数，用于冷启动时定续页游标。
  static ({List<dynamic> items, int pages})? read({
    required String src,
    required int mid,
    required List<dynamic> Function(List items) parse,
  }) {
    try {
      final raw = GStorage.localCache.get(_key(src));
      if (raw is! Map) return null;
      if (raw['ver'] != _ver || raw['src'] != src || raw['mid'] != mid) {
        return null;
      }
      final encoded = raw['items'];
      if (encoded is! String || encoded.isEmpty) return null;
      final decoded = jsonDecode(encoded);
      if (decoded is! List || decoded.isEmpty) return null;

      final list = parse(decoded);
      if (list.isEmpty) return null;

      final rawPages = raw['pages'];
      // 脏数据不能让续页游标跑到很远的地方
      final int pages = rawPages is int && rawPages >= 1 && rawPages <= 9
          ? rawPages
          : 1;
      return (items: list, pages: pages);
    } catch (_) {
      // 结构不符 / 上游字段变动 / 老版本数据 → 回落到骨架屏
      return null;
    }
  }

  /// 内容指纹：**全部条目**的 id 串。
  ///
  /// 只比首尾不够——首尾没变、中间换了一批时会被误判成"没变化"，缓存从此
  /// 停在旧内容上。任一条目取不到 id 时返回 null，调用方据此放弃判等、
  /// 照常写入（宁可多写一次盘，也不能让缓存卡住）。
  static String? _signature(List items) {
    final ids = <Object?>[];
    for (final item in items) {
      final id = _itemId(item);
      if (id == null) return null;
      ids.add(id);
    }
    return ids.join(',');
  }

  /// 原始 item 的稳定 id。
  ///
  /// * web（`/x/web-interface/.../rcmd`）：有 `id`
  /// * app（`/x/v2/feed/index`）：只有 `param` 必然存在（模型里是不可空的
  ///   `int.parse(json['param'])`），`player_args.aid` 通常也有，`bvid` 时有时无
  static Object? _itemId(Object? item) {
    if (item is! Map) return null;
    final id = item['id'] ?? item['param'] ?? item['aid'];
    if (id != null) return id;
    final args = item['player_args'];
    if (args is Map) return args['aid'] ?? item['bvid'];
    return item['bvid'];
  }

  /// 按 [_itemId] 去重，保持顺序。
  ///
  /// id 统一转成字符串再比：同一个 aid 有时是 `int`、有时是 `'123'`，
  /// 不归一化会漏掉重复
  static List _dedupe(List items) {
    final seen = <String>{};
    final out = <dynamic>[];
    for (final item in items) {
      final id = _itemId(item)?.toString();
      if (id != null && !seen.add(id)) continue;
      out.add(item);
    }
    return out;
  }
}
