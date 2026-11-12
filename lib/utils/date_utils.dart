import 'package:intl/intl.dart' show DateFormat;

abstract final class DateFormatUtils {
  static final shortFormat = DateFormat('MM-dd');
  static final longFormat = DateFormat('yyyy-MM-dd');
  static final _shortFormatD = DateFormat('MM-dd HH:mm');
  static final longFormatD = DateFormat('yyyy-MM-dd HH:mm');
  static final longFormatDs = DateFormat('yyyy-MM-dd HH:mm:ss');
  static final only0_9 = DateFormat('yyyyMMddHHmmss');

  /// 相邻消息间隔超过该秒数时重新显示时间标签
  static const chatTimeGap = 180;

  /// 消息列表按时间倒序渲染时，判断当前消息是否显示时间标签。
  ///
  /// 每段连续消息只在最早一条显示；[olderTimestamp] 为时间上更早的相邻消息，
  /// 为 null 表示当前就是最早一条。跨天时额外确保新的一天有日期分隔。
  static bool showChatTime({
    required int timestamp,
    required int? olderTimestamp,
  }) {
    if (olderTimestamp == null) return true;
    if ((timestamp - olderTimestamp).abs() > chatTimeGap) return true;
    final newer = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final older = DateTime.fromMillisecondsSinceEpoch(olderTimestamp * 1000);
    return newer.year != older.year ||
        newer.month != older.month ||
        newer.day != older.day;
  }

  // U-08：相对时间在列表里会被「每一项、每一次 build」重算。这里按当前分钟整体失效地
  // 做一层结果缓存，省掉重复的 DateTime 运算与字符串拼接（跨分钟才重算，不会显示过期文案）。
  static final Map<String, String> _relativeCache = {};
  static int _relativeCacheMinute = -1;

  static String dateFormat(
    int? time, {
    DateFormat? short,
    DateFormat? long,
  }) {
    if (time == null || time == 0) {
      return '';
    }

    final minute = DateTime.now().millisecondsSinceEpoch ~/ 60000;
    if (minute != _relativeCacheMinute) {
      _relativeCacheMinute = minute;
      _relativeCache.clear();
    }
    final key = '$time|${short?.pattern}|${long?.pattern}';
    final cached = _relativeCache[key];
    if (cached != null) {
      return cached;
    }
    final result = _dateFormat(time, short: short, long: long);
    // 防御性上限：极端情况下（同一分钟内出现大量不同时间戳）不让缓存无限增长
    if (_relativeCache.length >= 512) {
      _relativeCache.clear();
    }
    _relativeCache[key] = result;
    return result;
  }

  static String _dateFormat(
    int? time, {
    DateFormat? short,
    DateFormat? long,
  }) {
    if (time == null || time == 0) {
      return '';
    }

    final now = DateTime.now();
    final date = DateTime.fromMillisecondsSinceEpoch(time * 1000);
    final diff = now.difference(date);

    final diffInMins = diff.inMinutes;
    if (diffInMins < 1) return '刚刚';
    if (diffInMins < 60) return '$diffInMins分钟前';

    final diffInHours = diff.inHours;
    if (diffInHours < 24) return '$diffInHours小时前';

    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(date.year, date.month, date.day);
    final dayDiff = today.difference(dateDay).inDays;
    if (dayDiff == 1) {
      return '昨天 ${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
    }
    if (dayDiff < 4) {
      return '$dayDiff天前';
    }
    final DateFormat sdf = now.year == date.year
        ? short ?? shortFormat
        : long ?? longFormat;
    return sdf.format(date);
  }

  static String _twoDigits(int n) => n.toString().padLeft(2, '0');

  static String chatFormat(int? time, {bool isHistory = false}) {
    if (time == null || time == 0) {
      return '';
    }

    final now = DateTime.now();
    final date = DateTime.fromMillisecondsSinceEpoch(time * 1000);

    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(date.year, date.month, date.day);
    if (today == dateDay) {
      return '${isHistory ? '今天 ' : ''}${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
    }
    final isYesterday = today.subtract(const Duration(days: 1)) == dateDay;
    if (isYesterday) {
      return '昨天 ${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
    }
    if (isHistory) {
      final DateFormat sdf = now.year == date.year
          ? _shortFormatD
          : longFormatD;
      return sdf.format(date);
    }
    return longFormatD.format(date);
  }

  static String format(int? time, {DateFormat? format}) {
    if (time == null || time == 0) {
      return '';
    }
    final date = DateTime.fromMillisecondsSinceEpoch(time * 1000);
    return (format ?? longFormatD).format(date);
  }
}
