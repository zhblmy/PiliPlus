import 'package:PiliPlus/services/audio_handler.dart';
import 'package:PiliPlus/services/audio_session.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

VideoPlayerServiceHandler? videoPlayerServiceHandler;
AudioSessionHandler? audioSessionHandler;

Future<void>? _audioServiceInit;

/// 发起音频服务（含前台服务）的初始化，**不阻塞调用方**（冷启动优化 S-01）。
///
/// Android 17 的后台音频加固（A17-01）要求「具备使用时(WIU)能力的前台服务要先于
/// 音频写入进入前台」。只要 [initAudioService] 是在应用**可见时**发起的，系统就会
/// 把该前台服务记为具备 WIU 能力，所以「发起但不等待」不会破坏 A17-01；
/// 而原实现 `await` 会在冷启动关键路径上多等一次 MethodChannel 往返 + 前台服务创建。
///
/// 初始化失败（例如设备/系统不支持前台服务）时**不会抛出**：[videoPlayerServiceHandler]
/// 保持为 null，消费方都是 `?.` 调用，播放本身不受影响。这一点很重要 —— 否则错误会被
/// 抛到 `PlPlayerController.play()` 里，表现成「点播放没反应」。
Future<void> setupServiceLocator() {
  audioSessionHandler ??= AudioSessionHandler();
  return _audioServiceInit ??= initAudioService().then(
    (handler) => videoPlayerServiceHandler = handler,
    // 必须用 onError 在 Future 内部消化错误：这个 Future 可能没有任何人 await
    // （main 里就是「发起即不管」），否则会变成未捕获的异步异常。
    onError: (Object e, StackTrace s) {
      if (kDebugMode) debugPrint('audio service init failed: $e');
    },
  );
}

/// 等待音频服务初始化完成；若尚未发起则先发起。
///
/// 失败已在 [setupServiceLocator] 内部消化，因此这里**不会抛异常**，
/// 调用方（如播放器 `play()`）不需要 try/catch。
Future<void> ensureServiceLocator() =>
    _audioServiceInit ?? setupServiceLocator();
