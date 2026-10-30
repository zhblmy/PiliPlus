// ignore_for_file: constant_identifier_names

enum VideoDecodeFormatType {
  DVH1(['dvh1']),
  AV1(['av01']),
  HEVC(['hev1', 'hvc1']),
  AVC(['avc1']),
  ;

  String get description => name;
  final List<String> codes;

  const VideoDecodeFormatType(this.codes);

  /// 解析不认识的编码串时返回 null（B 站以后新增格式时不会直接抛 StateError）
  static VideoDecodeFormatType? tryParse(String? val) {
    if (val == null || val.isEmpty) return null;
    for (final i in values) {
      if (i.codes.any(val.startsWith)) return i;
    }
    return null;
  }

  /// 未知/空编码串回退到兼容性最好的 AVC，避免播放链路被一个陌生 codec 打断
  static VideoDecodeFormatType fromString(String val) => tryParse(val) ?? AVC;
}
