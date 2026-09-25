import 'package:media_kit/media_kit.dart';

bool _mediaKitInitialized = false;

/// 延迟初始化 `package:media_kit`（冷启动优化 S-02）。
///
/// 为什么需要这个工具：
/// - `MediaKit.ensureInitialized()` 内部会走
///   `AndroidHelper.ensureInitialized` + `NativeLibrary.ensureInitialized`，
///   最终执行 `DynamicLibrary.open('libmpv.so')`（媒体库体积大，dlopen 与符号
///   绑定是毫秒级到百毫秒级的同步开销）；
/// - 它同时是 media_kit 的**必需前置条件**：未初始化时
///   `NativeLibrary.path` 会抛
///   `MediaKit.ensureInitialized must be called before using any API...`。
///
/// 因此把它从 `main()` 顶部挪到「首帧之后」执行（见 `main.dart` 里的
/// `addPostFrameCallback`），并在这里保证**幂等**——所有创建播放器 / 调用
/// media_kit API 的地方都先调一次，即使首帧后的预热被推迟也不会漏初始化。
void ensureMediaKitInitialized() {
  if (_mediaKitInitialized) return;
  // 先调用再置位：`MediaKit.ensureInitialized()` 内部是幂等的，
  // 万一失败（缺少 libmpv）也不该让这里假装已初始化。
  MediaKit.ensureInitialized();
  _mediaKitInitialized = true;
}
