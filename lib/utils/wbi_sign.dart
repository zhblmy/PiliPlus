// Wbi签名 用于生成 REST API 请求中的 w_rid 和 wts 字段
// https://github.com/SocialSisterYi/bilibili-API-collect/blob/master/docs/misc/sign/wbi.md
// import md5 from 'md5'
// import axios from 'axios'
import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';

abstract final class WbiSign {
  static Box get _localCache => GStorage.localCache;
  static final RegExp _chrFilter = RegExp(r"[!\'\(\)\*]");
  static const _mixinKeyEncTab = <int>[
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
  ];

  static Future<String>? _future;

  /// 上次取 key 失败的时间（本进程内）
  static DateTime? _failedAt;

  // 对 imgKey 和 subKey 进行字符顺序打乱编码
  static String getMixinKey(String orig) {
    return String.fromCharCodes(_mixinKeyEncTab.map(orig.codeUnitAt));
  }

  // 为请求参数进行 wbi 签名
  static void encWbi(Map<String, Object> params, String mixinKey) {
    params['wts'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 按照 key 重排参数
    final List<String> keys = params.keys.toList()..sort();
    final queryStr = keys
        .map(
          (i) =>
              '${Uri.encodeComponent(i)}=${Uri.encodeComponent(params[i].toString().replaceAll(_chrFilter, ''))}',
        )
        .join('&');
    params['w_rid'] = md5
        .convert(utf8.encode(queryStr + mixinKey))
        .toString(); // 计算 w_rid
  }

  static Future<String> _getWbiKeys() async {
    final resp = await Request().get(Api.userInfo);
    try {
      final wbiUrls = resp.data['data']['wbi_img'];

      final mixinKey = getMixinKey(
        Utils.getFileName(wbiUrls['img_url'], fileExt: false) +
            Utils.getFileName(wbiUrls['sub_url'], fileExt: false),
      );

      await _localCache.put(LocalCacheKey.mixinKey, mixinKey);

      return mixinKey;
    } catch (_) {
      // 取不到新 key 时清掉可能已过期的旧 key，否则后续请求会一直用签名错误的 key
      await _localCache.delete(LocalCacheKey.mixinKey);
      return '';
    }
  }

  static FutureOr<String> getWbiKeys() {
    final now = DateTime.now();
    final cached = DateTime.fromMillisecondsSinceEpoch(
      _localCache.get(LocalCacheKey.timeStamp, defaultValue: 0) as int,
    );
    // 只比较 day 会把「上个月的同一天」误判成今天，从而复用已经过期的 key
    final isToday =
        cached.year == now.year &&
        cached.month == now.month &&
        cached.day == now.day;
    if (isToday) {
      final String? mixinKey = _localCache.get(LocalCacheKey.mixinKey);
      if (mixinKey != null && mixinKey.isNotEmpty) return mixinKey;
    }
    // 取 key 失败后冷却一分钟再试，否则每个签名请求都会再打一次 nav 接口
    // （先查缓存再判冷却，避免手里有可用 key 时被冷却误伤）
    final failedAt = _failedAt;
    if (failedAt != null && now.difference(failedAt) < _retryDelay) return '';
    return _future ??= _localCache
        .put(LocalCacheKey.timeStamp, now.millisecondsSinceEpoch)
        .then((_) => _refreshKeys());
  }

  /// 取 key 失败后的冷却时间
  static const Duration _retryDelay = Duration(minutes: 1);

  static Future<String> _refreshKeys() async {
    _failedAt = null;
    final future = _getWbiKeys();
    _future = future;
    String key;
    try {
      key = await future;
    } catch (_) {
      key = '';
    }
    if (key.isEmpty) {
      _failedAt = DateTime.now();
      // 失败的 Future 不能一直挂着，否则本进程内每次签名都直接拿到空 key
      if (identical(_future, future)) _future = null;
    }
    return key;
  }

  static Future<Map<String, Object>> makSign(
    Map<String, Object> params,
  ) async {
    // params 为需要加密的请求参数
    final String mixinKey = await getWbiKeys();
    encWbi(params, mixinKey);
    return params;
  }
}
