import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart' show Session;
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

/// 免打扰写入（HTTP `set_msg_dnd`）与会话列表（gRPC `SessionMain` 的 `is_muted`）
/// 读回不一致时的本地覆盖。
///
/// 实际现象：`set_msg_dnd` 关闭免打扰后 `get_msg_dnd` 已返回 0，但 `SessionMain`
/// 仍返回 `is_muted = true`，列表里的免打扰图标一直存在。因此把用户确认过的状态
/// 持久化下来，等 `SessionMain` 读回一致后自动移除；超过 [ttl] 后放弃覆盖，
/// 避免永久盖住服务端值。
///
/// 覆盖按账号隔离：换账号后旧覆盖不再生效，也不影响新账号的会话。
abstract final class MsgSessionMute {
  static const ttl = Duration(days: 7);

  static Map<int, ({bool muted, DateTime at})>? _cache;
  static int _cacheMid = -1;

  static Map<int, ({bool muted, DateTime at})> get _overrides {
    final mid = Accounts.main.mid;
    if (_cache == null || _cacheMid != mid) {
      _cacheMid = mid;
      _cache = _load(mid);
    }
    return _cache!;
  }

  static Map<int, ({bool muted, DateTime at})> _load(int mid) {
    final result = <int, ({bool muted, DateTime at})>{};
    final raw = GStorage.setting.get(SettingBoxKey.msgDndOverride);
    // 上一个账号留下的覆盖直接丢弃
    if (raw is! Map || raw['mid'] != mid) return result;
    final items = raw['items'];
    if (items is! Map) return result;
    final now = DateTime.now();
    for (final entry in items.entries) {
      final uid = int.tryParse('${entry.key}');
      final value = entry.value;
      if (uid == null || value is! List || value.length < 2) continue;
      final at = DateTime.fromMillisecondsSinceEpoch(
        value[1] is int ? value[1] as int : 0,
      );
      if (now.difference(at) > ttl) continue;
      result[uid] = (muted: value[0] == 1, at: at);
    }
    return result;
  }

  static void _persist() {
    GStorage.setting.put(SettingBoxKey.msgDndOverride, {
      'mid': _cacheMid,
      'items': {
        for (final entry in _overrides.entries)
          '${entry.key}': [
            entry.value.muted ? 1 : 0,
            entry.value.at.millisecondsSinceEpoch,
          ],
      },
    });
  }

  static void remember(int talkerUid, bool muted) {
    // 先取一次，确保 _cacheMid 与当前账号对齐
    final overrides = _overrides;
    overrides[talkerUid] = (muted: muted, at: DateTime.now());
    _persist();
  }

  static void forget(int talkerUid) {
    if (_overrides.remove(talkerUid) != null) _persist();
  }

  /// 退出登录时调用：旧账号的覆盖已经没有意义
  static void clear() {
    _cache = {};
    _cacheMid = Accounts.main.mid;
    GStorage.setting.delete(SettingBoxKey.msgDndOverride);
  }

  static void apply(List<Session>? sessions) {
    if (_overrides.isEmpty) return;
    final now = DateTime.now();
    var changed = false;
    _overrides.removeWhere((_, override) {
      final expired = now.difference(override.at) > ttl;
      if (expired) changed = true;
      return expired;
    });
    if (sessions != null && sessions.isNotEmpty) {
      for (final session in sessions) {
        if (!session.id.privateId.hasTalkerUid()) continue;
        final uid = session.id.privateId.talkerUid.toInt();
        final override = _overrides[uid];
        if (override == null) continue;
        if (session.isMuted == override.muted) {
          // 列表已经读回一致，覆盖不再需要
          _overrides.remove(uid);
          changed = true;
        } else {
          session.isMuted = override.muted;
        }
      }
    }
    if (changed) _persist();
  }
}
