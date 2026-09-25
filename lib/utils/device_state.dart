import 'package:get/get_rx/get_rx.dart';

/// 设备低功耗状态（省电模式 / 低电量 / 温控降档）的共享状态。
///
/// 拆成"纯状态"文件是为了避免底层工具（`storage_pref`、`danmaku_options`）反向依赖
/// 服务层（`PowerSaveWatcher`）而出现循环 import；写入方只有 `PowerSaveWatcher`。
abstract final class DeviceState {
  /// 是否处于低功耗降档状态（性能报告 MI-04）
  static final RxBool isLowPower = false.obs;

  /// 低功耗时的点播/直播缓冲系数（只影响之后新建的播放器）
  static double get bufferScale => isLowPower.value ? 0.75 : 1.0;

  /// 低功耗时的弹幕显示区域系数（降低每帧文本绘制量）
  static double get danmakuAreaScale => isLowPower.value ? 0.6 : 1.0;

  /// 低功耗时是否去掉弹幕描边（每个字形少一次描边绘制）
  static bool get trimDanmakuStroke => isLowPower.value;
}
