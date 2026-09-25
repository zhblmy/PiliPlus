import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';

class AudioSessionHandler with WidgetsBindingObserver {
  late AudioSession session;
  bool _playInterrupted = false;

  /// 因音频打断暂停后，「现在不允许与音频 API 交互」时挂起的续播请求
  /// （见 [_resumeAfterInterruption]）。
  bool _pendingResume = false;

  Future<bool> setActive(bool active) {
    return session.setActive(active);
  }

  AudioSessionHandler() {
    initSession();
  }

  /// Android 17（API 37）起，应用在后台时若没有具备使用时（WIU）能力的前台服务，对
  /// 音频 API 的交互会被系统**静默**限制（播放无声、音频焦点请求直接失败）。因此打断
  /// 结束后需要先确认「现在能不能出声」，不能时就先挂起，等应用回到前台（或用户通过
  /// 媒体控件触发）再续播，避免出现「通知显示正在播放、实际完全没有声音」的状态。
  ///
  /// 只在 **Android 17 及以上**生效：更低版本没有这条限制，保持原有的「打断结束立即
  /// 续播」，不会让老设备上的后台续播变得不自动；其它平台同样恒为 true。
  bool get _canInteractWithAudio {
    if (!Platform.isAndroid || DeviceUtils.sdkInt < 37) return true;
    final controller = PlPlayerController.instance;
    // 应用可见（画中画 / 分屏都落在 inactive，同样按可见处理）→ 允许
    if (controller?.isForeground ?? false) return true;
    // 播放器仍在播放 → 前台服务已在前台运行，继续交互是安全的
    if (controller?.playerStatus.isPlaying ?? false) return true;
    return false;
  }

  void _resumeAfterInterruption() {
    if (_canInteractWithAudio) {
      _pendingResume = false;
      PlPlayerController.playIfExists();
    } else {
      _pendingResume = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_pendingResume || state != AppLifecycleState.resumed) return;
    _pendingResume = false;
    // 用户可能已经在应用内手动恢复了播放，这里只在仍处于暂停时补一次续播
    if (PlPlayerController.getPlayerStatusIfExists()?.isPlaying != true) {
      PlPlayerController.playIfExists();
    }
  }

  Future<void> initSession() async {
    WidgetsBinding.instance.addObserver(this);
    session = await AudioSession.instance;
    session.configure(const AudioSessionConfiguration.music());

    session.interruptionEventStream.listen((event) {
      final playerStatus = PlPlayerController.getPlayerStatusIfExists();
      // final player = PlPlayerController.getInstance();
      if (event.begin) {
        if (playerStatus != PlayerStatus.playing) return;
        // if (!player.playerStatus.playing) return;
        switch (event.type) {
          case AudioInterruptionType.duck:
            PlPlayerController.setVolumeIfExists(
              (PlPlayerController.getVolumeIfExists() ?? 0) * 0.5,
              showIndicator: false,
            );
            // player.setVolume(player.volume.value * 0.5);
            break;
          case AudioInterruptionType.pause:
            PlPlayerController.pauseIfExists(isInterrupt: true);
            // player.pause(isInterrupt: true);
            _playInterrupted = true;
            break;
          case AudioInterruptionType.unknown:
            PlPlayerController.pauseIfExists(isInterrupt: true);
            // player.pause(isInterrupt: true);
            _playInterrupted = true;
            break;
        }
      } else {
        switch (event.type) {
          case AudioInterruptionType.duck:
            PlPlayerController.setVolumeIfExists(
              (PlPlayerController.getVolumeIfExists() ?? 0) * 2,
              showIndicator: false,
            );
            // player.setVolume(player.volume.value * 2);
            break;
          case AudioInterruptionType.pause:
            if (_playInterrupted) _resumeAfterInterruption();
            //player.play();
            break;
          case AudioInterruptionType.unknown:
            break;
        }
        _playInterrupted = false;
      }
    });

    // 耳机拔出暂停
    session.becomingNoisyEventStream.listen((_) {
      PlPlayerController.pauseIfExists();
      // final player = PlPlayerController.getInstance();
      // if (player.playerStatus.playing) {
      //   player.pause();
      // }
    });
  }
}
