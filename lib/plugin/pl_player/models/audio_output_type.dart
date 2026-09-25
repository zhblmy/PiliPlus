import 'package:PiliPlus/models/common/enum_with_label.dart';

/// Android 上 mpv `--ao` 的候选后端（按优先级排列，逗号拼接传给 mpv）。
///
/// 顺序调整（性能报告 MI-08）：**AAudio → AudioTrack → OpenSL ES**。
/// - AAudio 是 Android 8.1+ 的现代低延迟音频后端（Oboe 的底层），起播延迟与
///   切轨/蓝牙切换表现优于 OpenSL ES，在 Android 17 + 骁龙 8 Elite 上更稳；
/// - OpenSL ES 自 Android 11 起已被官方标记为待弃用，放到最后兜底。
///
/// 三者都会传给 mpv，前一个不可用时自动回退，因此顺序变化不影响可用性；
/// 用户已保存的选择不受影响（只改默认值）。
enum AudioOutput implements EnumWithLabel {
  aaudio('AAudio'),
  audiotrack('AudioTrack'),
  opensles('OpenSL ES'),
  ;

  static final defaultValue = values.map((e) => e.name).join(',');

  @override
  final String label;
  const AudioOutput(this.label);
}
