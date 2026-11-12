import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:convert' show ascii, utf8;
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/android/display_mode_utils.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/native_geometry_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:PiliPlus/utils/media_kit_util.dart';
import 'package:PiliPlus/utils/mobile_observer.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart'
    show DeviceOrientation, HapticFeedback, KeyDownEvent;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi show Size, Rectangle;
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

typedef PlayCallback = Future<void>? Function();
typedef PlayOwner = ({String tag, Type? type});

class PlPlayerController
    with BlockConfigMixin, AudioNormalizationMixin, WidgetsBindingObserver {
  Player? _videoPlayerController;
  VideoController? _videoController;

  static PlPlayerController? _instance;

  PlayerStatus playerStatus = .paused;

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);
  final RxInt seekPosition = RxInt(0);
  int get progress =>
      isSeeking.value && hoverDx == null ? seekPosition.value : position.value;

  int get positionInMilliseconds =>
      videoPlayerController?.state.position.inMilliseconds ?? 0;

  final RxInt buffered = RxInt(0);

  final RxInt duration = RxInt(0);

  int durationInMilliseconds = 0;

  void updateDuration(Duration value) {
    duration.value = value.inSeconds;
    durationInMilliseconds = value.inMilliseconds;
  }

  int _playerCount = 0;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;
  bool isLive = false;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  bool _autoPlay = false;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;

  /// 播放心跳最小间隔（秒）：原来 5s 一次（720 次/小时）会把射频一直钉在
  /// CONNECTED 态并持续唤醒 CPU，改为 15s 并在暂停时补发一次（性能报告 P-02）。
  static const int _heartBeatInterval = 15;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;

  /// 听视频
  late final RxBool onlyPlayAudio = false.obs;

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode =>
      (Platform.isAndroid && AndroidHelper.isPipMode) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  late nativeapi.Size _lastMinSize;
  late nativeapi.Rectangle _lastWindowBounds;
  static nativeapi.Rectangle? _lastPipBounds;

  nativeapi.Rectangle _adjustPipBounds(
    nativeapi.Rectangle lastRect,
    nativeapi.Size size,
    double aspectRatio,
  ) {
    final lastSize = lastRect.size;
    final lastOrientation = lastSize.orientation;
    final orientation = size.orientation;

    if (lastOrientation != orientation) {
      final double width, height;
      switch (orientation) {
        case .portrait:
          if (lastSize.width > size.height) {
            height = min(lastSize.width, _lastWindowBounds.size.height);
            width = height * aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
        case .landscape:
          if (lastSize.height > size.width) {
            width = lastSize.height;
            height = width / aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
      }

      return _lastPipBounds = nativeapi.Rectangle(
        x: lastRect.x,
        y: lastRect.y,
        width: width,
        height: height,
      );
    }
    return _lastPipBounds = nativeapi.Rectangle(
      x: lastRect.x,
      y: lastRect.y,
      width: lastSize.width,
      height: lastSize.width / aspectRatio,
    );
  }

  bool updatePipBounds(Window window) {
    if (isDesktopPip) {
      _lastPipBounds = window.bounds;
      return true;
    }
    return false;
  }

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  void setAlwaysOnTop(bool value, {Window? window}) {
    window ??= WindowController.instance.window;
    if (window == null) return;

    isAlwaysOnTop.value = value;
    window.isAlwaysOnTop = value;
  }

  void exitDesktopPip() {
    final window = WindowController.instance.window;
    if (window == null) return;

    isDesktopPip = false;
    if (showWindowTitleBar) window.titleBarStyle = .normal;
    window
      ..minimumSize = _lastMinSize
      ..bounds = _lastWindowBounds
      ..aspectRatio = 0;
    setAlwaysOnTop(false, window: window);
  }

  void enterDesktopPip() {
    final window = WindowController.instance.window;
    if (window == null) return;

    if (isFullScreen.value) return;

    isDesktopPip = true;

    _lastMinSize = window.minimumSize;
    _lastWindowBounds = window.bounds;

    if (showWindowTitleBar) window.titleBarStyle = .hidden;

    const shortSide = 280.0;
    const minShortSide = 160.0;
    final nativeapi.Size size;
    final nativeapi.Size minimumSize;
    final state = videoPlayerController!.state;
    int width = state.width;
    int height = state.height;
    if (width == 0) width = this.width ?? 16;
    if (height == 0) height = this.height ?? 9;
    final aspectRatio = width / height;
    if (height > width) {
      size = nativeapi.Size(width: shortSide, height: shortSide / aspectRatio);
      minimumSize = nativeapi.Size(
        width: minShortSide,
        height: minShortSide / aspectRatio,
      );
    } else {
      size = nativeapi.Size(width: shortSide * aspectRatio, height: shortSide);
      minimumSize = nativeapi.Size(
        width: minShortSide * aspectRatio,
        height: minShortSide,
      );
    }

    window.minimumSize = minimumSize;
    setAlwaysOnTop(true, window: window);
    if (_lastPipBounds != null) {
      window.bounds = _adjustPipBounds(_lastPipBounds!, size, aspectRatio);
    } else {
      window.contentSize = size;
    }
    window.aspectRatio = aspectRatio;
  }

  void toggleDesktopPip() {
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      enterDesktopPip();
    }
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  void enterPip({bool autoEnter = false}) {
    if (videoPlayerController case NativePlayer(:final state)) {
      if (Platform.isIOS) {
        if (videoController?.id.value case final textureId?) {
          IOSPipHelper.enter(
            textureId,
            width: state.width == 0 ? width : state.width,
            height: state.height == 0 ? height : state.height,
            autoEnter: autoEnter,
            state: _iosPipState(state),
          );
        }
        return;
      }
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
    }
  }

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      if (Platform.isIOS) {
        IOSPipHelper.disableAutoEnter();
      } else {
        PiliAndroidHelper.disableAutoEnterPip();
      }
    }
  }

  Map<String, Object> _iosPipState(PlayerState state, [Duration? position]) {
    return {
      'isPlaying': playerStatus.isPlaying,
      'isBuffering': isBuffering.value,
      'isLive': isLive,
      'position': (position ?? state.position).inMilliseconds,
      'duration': durationInMilliseconds,
      'speed': state.rate,
    };
  }

  void _updateIOSPip([Duration? position]) {
    if (Platform.isIOS && IOSPipHelper.needsUpdate) {
      if (_videoPlayerController case final player?) {
        IOSPipHelper.update(_iosPipState(player.state, position));
      }
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  int? tmpSubtitlePaddingB;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  final bool showVipDanmaku = Pref.showVipDanmaku; // loop unswitching
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableScrollVolume = Pref.enableScrollVolume;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardInSeconds = Pref.fastForBackwardDuration;
  late final fastForBackwardDuration = Duration(
    seconds: fastForBackwardInSeconds,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile || Platform.isLinux
      ? null
      : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  late String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;

  /// 视频输出后端里解析出来的 `vo`（仅 Android，见 [_initPlayer]）；
  /// 空/null 表示没设置，media_kit 会用 `vo=gpu`。
  String? _videoOutputVo;

  /// 是否在用 `vo=mediacodec_embed`（MediaCodec 直接输出到 Surface）。
  /// 该后端对 mpv 侧的硬解档位/滤镜都有硬性要求，见各处判断。
  bool get isMediacodecEmbed => _videoOutputVo == 'mediacodec_embed';

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    tmpSubtitlePaddingB = null;
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    updateSubtitleStyle();
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(
    PlayCallback? playCallBack, {
    PlayOwner? playOwner,
  }) {
    _playCallBack = playCallBack;
    _playOwner = playOwner;
  }

  static PlayOwner? _playOwner;
  static PlayOwner? get playOwner => _playOwner;
  static PlayCallback? _playCallBack;

  static Future<void>? playIfExists() {
    return _playCallBack?.call();
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus;
  }

  static Future<void>? pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) {
    if (_instance?.playerStatus.isPlaying ?? false) {
      return _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
    return null;
  }

  static Future<void>? seekToIfExists(Duration position) {
    return _instance?.seekTo(position);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  bool _isForeground = true;

  /// App 是否处于前台。
  ///
  /// 只有 resumed / inactive 算前台：画中画、分屏、应用切换器都落在 inactive，
  /// 此时用户仍在看视频；熄屏或切到后台会走到 hidden / paused。
  bool get isForeground => _isForeground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == .resumed || state == .inactive;
    if (foreground == _isForeground) return;
    _isForeground = foreground;
    _updateWakeLock();
  }

  DeviceOrientation? _orientation;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    _orientation = param.orientation;
    if (Platform.isIOS && !visible) return;
    if (controlsLock.value) return;
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        portraitDownMode();
      case .landscapeLeft:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode();
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    // 唤醒锁需要跟随前后台（见 _updateWakeLock），这里由控制器自己监听 lifecycle，
    // 不依赖播放页控件——它是条件构建的，可能被卸载而漏掉 resumed 事件。
    addObserverMobile(this);
    if (PlatformUtils.isMobile && !DeviceUtils.isChromeOS) {
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid && autoPiP) {
      if (DeviceUtils.sdkInt < 31) {
        final func = Runnable.implement($Runnable(run: _onUserLeaveHint));
        AndroidHelper$ToDart.onUserLeaveHint = func;
        func.release();
      } else {
        _isAutoEnterPip = true;
      }
    } else if (Platform.isIOS && autoPiP && IOSPipHelper.isAvailable) {
      _isAutoEnterPip = true;
    }
  }

  void _onUserLeaveHint() {
    if (playerStatus.isPlaying && _isCurrVideoPage) {
      enterPip();
    }
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    // 如果实例尚未创建，则创建一个新实例
    return (_instance ??= PlPlayerController._())
      ..isLive = isLive
      .._playerCount += 1;
  }

  bool _processing = false;
  bool get processing => _processing;

  // offline
  bool get isFileSource => dataSource is FileSource;

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    // 初始化播放位置
    Duration? seekTo,
    // 初始化播放速度
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    // 方向
    bool? isVertical,
    // 记录历史记录
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? onInit,
    Volume? volume,
    bool autoFullScreenFlag = false,
    int? rotate,
  }) async {
    try {
      _processing = true;
      this.isLive = isLive;
      _videoType = videoType ?? VideoType.ugc;
      // PL-05：换片后重新给硬解降级链机会（不同的编码可能支持硬解）
      _hwdecFallbackCount = 0;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      // 初始化数据加载状态
      dataStatus.value = DataStatus.loading;
      // 初始化全屏方向
      _isVertical = isVertical ?? false;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      cancelLongPressTimer();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount == 0) {
        return;
      }
      // 配置Player 音轨、字幕等等
      await _createVideoController(dataSource, seekTo, volume, rotate);

      if (_playerCount == 0) {
        _removeListeners();
        _videoPlayerController?.dispose();
        _videoPlayerController = null;
        _videoController = null;
        return;
      }

      updateDuration(duration ?? _videoPlayerController!.state.duration);
      position.value = buffered.value = seekTo?.inSeconds ?? 0;

      dataStatus.value = .loaded;

      if (autoFullScreenFlag && autoEnterFullScreen) {
        triggerFullScreen(status: true);
      }

      await _initializePlayer();
      onInit?.call();
    } catch (err, stackTrace) {
      dataStatus.value = DataStatus.error;
      if (kDebugMode) {
        debugPrint(stackTrace.toString());
        debugPrint('plPlayer err:  $err');
      }
    } finally {
      _processing = false;
    }
  }

  String? shadersDirPath;
  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;

  /// 低功耗 / 画中画降载：临时清空 glsl-shaders（Anime4K 超分是移动 GPU 上最重的
  /// 一项），**不落盘**、也不改用户的超分设置，退出场景后再 [restoreSuperResolution]。
  Future<void> trimShadersForLowPower() async {
    // vo=mediacodec_embed 直出 Surface，mpv 侧不存在画面滤镜/着色器链
    if (isMediacodecEmbed) return;
    await _videoPlayerController?.command(
      const ['change-list', 'glsl-shaders', 'clr', ''],
    );
  }

  /// 恢复用户设置里的超分档位（只在用户确实开启了超分、且当前是番剧/影视时生效）
  Future<void> restoreSuperResolution() {
    if (_videoPlayerController == null ||
        superResolutionType.value == SuperResolutionType.disable) {
      return Future.value();
    }
    return setShader();
  }

  Future<void> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    if (type == null) {
      type = superResolutionType.value;
    } else {
      superResolutionType.value = type;
      if (isAnim && !tempPlayerConf) {
        setting.put(SettingBoxKey.superResolutionType, type.index);
      }
    }
    // vo=mediacodec_embed 直出 Surface，mpv 侧没有任何画面滤镜/着色器链，
    // 下发 glsl-shaders 只会报错；档位照旧记录，但不设着色器。
    if (isMediacodecEmbed) return;
    pp ??= _videoPlayerController!;
    switch (type) {
      case SuperResolutionType.disable:
        return pp.command(const ['change-list', 'glsl-shaders', 'clr', '']);
      case SuperResolutionType.efficiency:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShadersLite,
          ),
        ]);
      case SuperResolutionType.quality:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShaders,
          ),
        ]);
    }
  }

  Future<Player> _initPlayer() async {
    assert(_videoPlayerController == null);
    // 冷启动优化 S-02：libmpv 改在首帧后预热，创建播放器前必须确保已加载
    ensureMediaKitInitialized();
    final opt = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }
    // PL-02：Android 可选 mpv 视频输出后端（vo / gpu-api，逗号分隔，
    // 默认 vo=gpu,gpu-api=vulkan）。空字符串 = 不设置，此时 media_kit 会用 vo=gpu
    //（并不是 mpv 自己的默认值，原因见下）。
    //
    // 注意 vo 必须单独交给 VideoControllerConfiguration，不能只塞进 Player options：
    // media_kit 的 AndroidVideoController 创建后会把 vo 置成 'null'，随后 onLoadHooks /
    // videoParams 又按 configuration.vo ?? 'gpu' 覆盖回去（见 media_kit_video 的
    // android_video_controller/real.dart），从 Player options 传的 vo 一定会被吃掉。
    // 其余项（gpu-api 等）不是 media_kit 管的属性，照旧走 Player options。
    String? vo;
    if (Platform.isAndroid) {
      final backend = Pref.videoOutputBackend;
      if (backend.isNotEmpty) {
        for (final item in backend.split(',')) {
          final index = item.indexOf('=');
          if (index > 0) {
            final key = item.substring(0, index).trim();
            final value = item.substring(index + 1).trim();
            if (key == 'vo') {
              vo = value;
            } else {
              opt[key] = value;
            }
          }
        }
      }
    }
    _videoOutputVo = vo;

    // vo=mediacodec_embed 是「MediaCodec 直接输出到 Surface」的后端（mpv 文档：
    // Requires --hwdec=mediacodec），只有 mediacodec 这一档硬解能给它供帧，
    // 否则 vo 拿不到解码器的 Surface、画面会全黑。所以这里覆盖用户设置里的硬解档位
    // （VideoControllerConfiguration.hwdec 会在 Player 创建之后写入 mpv，优先级更高）。
    final String? videoHwdec = isMediacodecEmbed ? 'mediacodec' : hwdec;

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: opt,
      ),
    );

    // >100% 的音量走 af 增益+限幅，避免直接放大 mpv volume 导致削波
    await setVolumeCapped(
      player,
      PlatformUtils.isMobile ? Pref.playerVolume / 100 : volume.value,
    );

    assert(_videoController == null);

    _videoController = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: videoHwdec != null,
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: videoHwdec,
        vo: vo,
      ),
    );

    if (Platform.isAndroid) {
      // Avoid sizing the surface using mpv's idle window between media loads.
      player.setProperty('force-window', 'no');
    }

    player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);

    _startListeners(player);

    return player;
  }

  late final buffer = Pref.initBuffer(_playbackSpeed.value);
  late final liveBuffer = Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
    int? rotate,
  ) async {
    isBuffering.value = false;
    _heartDuration = 0;
    danmakuController?.clear();

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer();
      if (_playerCount == 0) {
        _removeListeners();
        player.dispose();
        player = null;
        _videoController = null;
        return;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    final Map<String, String> extras = {
      if (dataSource is FileSource)
        'cache': 'no'
      else if (isLive)
        ...liveBuffer
      else
        ...buffer,
      'video-rotate': ?rotate?.toString(),
    };

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      audioFilterExtras(volume, map: extras);
    }

    assert(!isLive || seekTo == null);
    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
  }

  Future<void>? refreshPlayer() {
    if (dataSource is FileSource) {
      return null;
    }
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      var media = ctr.current.last;
      if (!isLive) media = media.copyWith(start: ctr.state.position);
      return ctr.open(media, play: true);
    }
    return null;
  }

  /// 硬解失败时的降级链（性能报告 PL-05）。mpv 无法热切换解码器，所以做法是：
  /// 运行时改 `hwdec`，再重新 open 同一媒体（重新 open 会重建解码器）。
  static const List<String> _hwdecFallbackChain = [
    'mediacodec-copy',
    'auto-copy',
    'no',
  ];

  int _hwdecFallbackCount = 0;
  bool _hwdecFallbackRunning = false;

  Future<void> _tryHwdecFallback() async {
    if (!Platform.isAndroid || !Pref.hwdecFallback) return;
    // vo=mediacodec_embed 只吃 mediacodec，降级链里的 mediacodec-copy/auto-copy/软解
    // 都会让画面直接变黑，所以这个后端下不降级。
    if (isMediacodecEmbed) return;
    if (_hwdecFallbackRunning || isLive) return;
    if (_hwdecFallbackCount >= _hwdecFallbackChain.length) return;
    final player = _videoPlayerController;
    if (player == null) return;
    final next = _hwdecFallbackChain[_hwdecFallbackCount++];
    if (next == hwdec) return;
    hwdec = next;
    _hwdecFallbackRunning = true;
    try {
      player.setProperty('hwdec', next);
      SmartDialog.showToast(
        next == 'no' ? '解码器不受支持，已切换为软解' : '解码器不受支持，已切换为 $next',
      );
      await refreshPlayer();
    } catch (_) {
    } finally {
      _hwdecFallbackRunning = false;
    }
  }

  /// 当前内容帧率（mpv `container-fps`），供场景化刷新率使用（PL-02）；未知返回 null
  double? get _containerFps {
    if (_videoPlayerController case NativePlayer player) {
      try {
        final fps = double.tryParse(player.getProperty('container-fps'));
        if (fps != null && fps > 0) return fps;
      } catch (_) {}
    }
    return null;
  }

  Timer? _liveReconnectTimer;
  int _liveReconnectCount = 0;

  /// 直播错误重连：同一时刻只保留一个定时器，并按 3s/6s/12s/24s 指数退避。
  /// 原来每条 error 都排一个 3s 定时器，流抖动时会叠加出多次建连（性能报告 P-07）。
  void _scheduleLiveReconnect() {
    if (!isLive || _liveReconnectTimer != null) return;
    final delay = Duration(
      milliseconds: 3000 << _liveReconnectCount.clamp(0, 3),
    );
    _liveReconnectCount++;
    _liveReconnectTimer = Timer(delay, () {
      _liveReconnectTimer = null;
      refreshPlayer();
    });
  }

  /// 播放恢复正常后重置直播重连退避
  void _resetLiveReconnect() {
    _liveReconnectTimer?.cancel();
    _liveReconnectTimer = null;
    _liveReconnectCount = 0;
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (_videoPlayerController != null) {
      final speed = isLive ? 1.0 : playbackSpeed;
      if (_videoPlayerController!.state.rate != speed) {
        await setPlaybackSpeed(speed);
      }
    }
    _initVideoFit();

    // 自动播放
    if (_autoPlay) {
      playIfExists();
    }
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  Timer? _wakeLockTimer;

  void _startWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = Timer(
      const Duration(milliseconds: 500),
      _stopWakeLock,
    );
  }

  void _stopWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
  }

  void _stopWakeLock() {
    WakelockPlus.disable();
    _updatePlaybackState(debugLabel: 'onVideoPaused');
  }

  /// 唤醒锁门控：只有「App 在前台 && 正在播放」时才持有 PARTIAL_WAKE_LOCK
  /// （性能报告 P-01）。
  ///
  /// 熄屏/切后台时 lifecycle 会走到 hidden/paused，此时立即释放，避免屏幕熄灭
  /// 后 CPU 仍被钉住、mpv 全速解码；后台播放交给音频链路与 audio_service 前台
  /// 服务，不再依赖该唤醒锁。
  ///
  /// 这里刻意不使用 [visible]（也不使用 [isPipMode]）：
  /// - 画中画/分屏只走到 inactive，`visible` 已是 false，但用户仍在看视频；
  /// - `isPipMode` 由原生 onPictureInPictureModeChanged 写入，与 lifecycle 回调
  ///   存在先后顺序问题，用它兜底会偶发「画中画时屏幕熄灭」。
  /// 因此只按「前台 + 播放中」判断，前台含义见 [isForeground]。
  void _updateWakeLock() {
    if (_isForeground && playerStatus.isPlaying) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    videoPlayerServiceHandler?.onUpdateState(
      playerStatus,
      isBuffering.value,
      isLive,
      position: position ?? _videoPlayerController!.state.position,
      speed: playbackSpeed,
      debugLabel: debugLabel,
    );
    _updateIOSPip(position);
  }

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      /// playing
      stream.playing.listen((bool playing) {
        if (playing) {
          playerStatus = .playing;
          _stopWakeLockTimer();
          _updatePlaybackState();
          _updateWakeLock();
          _resetLiveReconnect();
          // MI-02：视频场景按内容帧率定档（≤ 45fps 时降到 60Hz 档，退出后恢复）
          DisplayModeUtils.setVideoScene(true, contentFps: _containerFps);
          // MI-15：播放期间申报持续性能模式（长时播放/弹幕帧时间更平缓）
          if (Platform.isAndroid) {
            PiliAndroidHelper.setSustainedPerformanceMode(true);
          }

          if (_isAutoEnterPip) {
            if (_isCurrVideoPage) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
        } else {
          // 暂停时补发一次心跳，避免心跳间隔拉长后丢掉最后的播放进度
          final seconds = videoPlayerController!.state.position.inSeconds;
          // MI-15：暂停后不再需要持续性能
          if (Platform.isAndroid) {
            PiliAndroidHelper.setSustainedPerformanceMode(false);
          }
          if (seconds != 0) {
            makeHeartBeat(seconds, type: .status, isManual: true);
          }
          playerStatus = .paused;
          _startWakeLockTimer();
          _disableAutoEnterPip();
          _updateIOSPip();
        }

        for (final element in _statusListeners) {
          element(playing ? .playing : .paused);
        }

        if (playing) {
          final seconds = videoPlayerController!.state.position.inSeconds;
          if (seconds != 0) {
            makeHeartBeat(seconds, type: .status);
          }
        }
      }),

      ///completed
      stream.completed.listen((bool completed) {
        if (completed) {
          playerStatus = .completed;
          _startWakeLockTimer();

          for (final element in _statusListeners) {
            element(.completed);
          }

          makeHeartBeat(-1, type: .completed);
        }
      }),

      /// position
      stream.position.listen((Duration position) {
        final posInSeconds = position.inSeconds;

        if (posInSeconds != this.position.value) {
          if (posInSeconds == 0 && playerStatus.isPlaying) {
            _updatePlaybackState(position: position);
          }

          this.position.value = posInSeconds;

          makeHeartBeat(posInSeconds);
        }

        for (final element in _positionListeners) {
          element(position);
        }
      }),
      stream.duration.listen((Duration duration) {
        updateDuration(duration);
        _updateIOSPip();
      }),
      stream.buffer.listen((Duration buffer) {
        buffered.value = buffer.inSeconds;
      }),
      stream.buffering.listen((bool buffering) {
        isBuffering.value = buffering;
        if (!playerStatus.isCompleted) {
          _stopWakeLockTimer();
          _updatePlaybackState();
        }
      }),
      if (kDebugMode)
        stream.log.listen(((PlayerLog log) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError(
              '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
              null,
            );
          } else {
            debugPrint(log.toString());
          }
        })),
      stream.error.listen((String event) {
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            _scheduleLiveReconnect();
          }
          return;
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            //tcp: ffurl_read returned 0xdfb9b0bb
            //tcp: ffurl_read returned 0xffffff99
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'controllerStream.error.listen',
            const Duration(milliseconds: 10000),
            () => Timer(const Duration(milliseconds: 3000), () {
              // if (kDebugMode) {
              //   debugPrint("isBuffering.value: ${isBuffering.value}");
              // }
              // if (kDebugMode) {
              //   debugPrint("_buffered.value: ${_buffered.value}");
              // }
              if (isBuffering.value && buffered.value == 0) {
                SmartDialog.showToast(
                  '视频链接打开失败，重试中',
                  displayTime: const Duration(milliseconds: 500),
                );
                refreshPlayer();
              }
            }),
          );
        } else if (event.startsWith('Could not open codec') ||
            event.startsWith('Failed to initialize a decoder')) {
          if (isMediacodecEmbed) {
            // 该模式只接受 mediacodec 硬解（见 _initPlayer），降级链在这里没有意义，
            // 提示要说清楚怎么办，而不是给它一个「可能会切软解」的假希望。
            SmartDialog.showToast('此视频无法用 mediacodec 硬解，请把视频输出后端改回默认');
          } else {
            SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
            // PL-05：自动逐级降级（mediacodec-copy → auto-copy → 软解）
            unawaited(_tryHwdecFallback());
          }
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
    ];
  }

  /// 移除事件监听
  void _removeListeners() {
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position) async {
    if (_playerCount == 0) return;

    _heartDuration = position.inSeconds;

    danmakuController?.clear();
    try {
      await _videoPlayerController?.seek(position);
      _updateIOSPip(position);
    } catch (e) {
      if (kDebugMode) debugPrint('seek failed: $e');
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _videoPlayerController?.state.rate) return;

    await _videoPlayerController?.setRate(speed);
    if (!isLive) _playbackSpeed.value = speed;
    _updatePlaybackState();
    if (danmakuController != null) {
      try {
        danmakuController?.updateOption(
          danmakuController!.option.copyWith(
            duration: DanmakuOptions.danmakuDuration / speed,
            staticDuration: DanmakuOptions.danmakuStaticDuration / speed,
          ),
        );
      } catch (_) {}
    }
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    if (hideControls) controls = false;
    // repeat为true，将从头播放
    if (repeat) {
      await seekTo(Duration.zero);
    }

    // Android 17 后台音频加固：先让前台服务进入「播放中」再开始写音频，
    // 否则后台恢复播放时音频可能被系统静默限制（见 ensureForegroundPlaying）。
    // 冷启动优化 S-01 之后音频服务是「发起但不等待」的，所以这里必须先等它就绪。
    await ensureServiceLocator();
    videoPlayerServiceHandler?.ensureForegroundPlaying();

    await _videoPlayerController?.play();

    audioSessionHandler?.setActive(true);

    playerStatus = .playing;
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
    playerStatus = .paused;

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSeeking.value && !tripling && hoverDx == null) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekStart(int seekFrom) {
    seekPosition.value = seekFrom;
    isSeeking.value = true;
  }

  void onSeekEnd() {
    hidePreviewIfNeeded();
    hasToasted = false;
    isSeeking.value = false;
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await setVolumeCapped(_videoPlayerController, volume);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.isPlaying) {
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      // if (kDebugMode) debugPrint('$playbackSpeed');
      longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get isCompleted =>
      videoPlayerController!.state.completed ||
      durationInMilliseconds - positionInMilliseconds <= 50;

  // 双击播放、暂停
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      await videoPlayerController!.play();
    } else if (videoPlayerController!.state.playing) {
      await pause();
    } else {
      await play(hideControls: false);
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position - duration);
  }

  void multiBackwardStart([_]) {
    isSeeking.value = true;
    seekPosition.value = max(0, seekPosition.value - fastForBackwardInSeconds);
  }

  void multiBackwardEnd() {
    if (isSeeking.value) {
      isSeeking.value = false;
      onForwardBackward(Duration(seconds: seekPosition.value));
    } else {
      onBackward(fastForBackwardDuration);
    }
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
    ).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
  }) {
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode();
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode();
        } else {
          return landscapeLeftMode();
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode();
        } else {
          return landscapeRightMode();
        }
      }
    }
  }

  // 全屏
  bool _fsProcessing = false;
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip) return;
    if (isFullScreen.value == status) return;

    if (_fsProcessing) return;
    _fsProcessing = true;
    this.isManualFS = isManualFS;
    try {
      if (status) {
        if (PlatformUtils.isMobile) {
          hideSystemBar();
          await changeOrientation(
            isVertical: isVertical,
            orientation: orientation,
          );
        } else {
          enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            showSystemBar();
          }
          if (orientation == null && mode == .none) {
            return;
          }
          await resetScreenRotation();
        } else {
          exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status);
      _fsProcessing = false;
    }
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_playerCount == 0) return;
    _positionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) =>
      _positionListeners.remove(listener);

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_playerCount == 0) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= _heartBeatInterval) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation() {
    if (horizontalScreen) {
      return fullMode();
    } else {
      return portraitUpMode();
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    if (PlatformUtils.isDesktop) exitDesktopFullScreen();
    dispose();
    Get.until((route) => route.isFirst);
  }

  void dispose() {
    // 每次减1，最后销毁
    resetScreenRotation();
    cancelLongPressTimer();
    if (!_isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      return;
    }

    _playerCount = 0;
    if (removeSafeArea) {
      showSystemBar();
    }
    danmakuController = null;
    _stopOrientationListener();
    removeObserverMobile(this);
    _disableAutoEnterPip();
    setPlayCallBack(null);
    // MI-02：离开播放页后恢复用户档位
    DisplayModeUtils.setVideoScene(false);
    // MI-15：退出播放页后取消持续性能申报
    if (Platform.isAndroid) {
      PiliAndroidHelper.setSustainedPerformanceMode(false);
    }
    dmState.clear();
    if (showSeekPreview) {
      _clearPreview();
    }
    if (Platform.isAndroid) {
      AndroidHelper$ToDart.onUserLeaveHint = null;
    } else if (Platform.isIOS) {
      IOSPipHelper.dispose();
    }
    _timer?.cancel();
    // _position.close();
    // _playerEventSubs?.cancel();
    // _sliderPosition.close();
    // _sliderTempPosition.close();
    // _isSliderMoving.close();
    // _duration.close();
    // _buffered.close();
    // _showControls.close();
    // _controlsLock.close();

    // playerStatus.close();
    // dataStatus.close();

    if (PlatformUtils.isDesktop && isAlwaysOnTop.value) {
      WindowController.instance.window?.isAlwaysOnTop = false;
    }

    _removeListeners();
    _positionListeners.clear();
    _statusListeners.clear();
    _stopWakeLockTimer();
    _resetLiveReconnect();
    WakelockPlus.disable();
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _videoController = null;
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  double? hoverDx;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      showPreview.value = true;
      final index = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
      if (previewIndex.value != index) {
        previewIndex.value = index;
      } else if (hoverDx != null) {
        previewIndex.refresh();
      }
    }
  }

  void hidePreviewIfNeeded() {
    if (showSeekPreview) {
      hidePreview();
    }
  }

  void hidePreview() {
    hoverDx = null;
    showPreview.value = false;
  }

  void _clearPreview() {
    hidePreview();
    previewIndex.value = null;
    videoShot = null;
    for (final i in previewCache.values) {
      i?.dispose();
    }
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    videoShot = await VideoHttp.videoshot(bvid: bvid, cid: cid!);
  }

  int _screenshotState = 0;
  Future<void> takeScreenshot() async {
    if (_screenshotState > 0) return;
    _screenshotState = 1;
    SmartDialog.showToast('截图中');
    final image = await videoPlayerController?.screenshot();
    if (image != null) {
      SmartDialog.showToast('点击弹窗或按 Enter 保存截图');
      await showDialog(
        context: Get.context!,
        requestFocus: true,
        builder: (context) {
          Future<void> save() async {
            if (_screenshotState > 1) return;
            _screenshotState = 2;
            final bytes = await image.toByteData(format: .png);
            if (bytes != null) {
              final time = DurationUtils.formatDuration(
                positionInMilliseconds / 1000,
              ).replaceAll(':', '-');
              ImageUtils.saveByteImg(
                bytes: bytes.buffer.asUint8List(),
                fileName: 'screenshot_${cid}_$time',
              );
            } else {
              SmartDialog.showToast('保存失败');
            }
            Get.back();
          }

          return Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) {
                final key = event.logicalKey;
                if (key == .keyS || key == .enter || key == .numpadEnter) {
                  save();
                  return .handled;
                }
              }
              return .ignored;
            },
            child: GestureDetector(
              onTap: save,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          width: 5,
                          color: ColorScheme.of(context).surface,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: RawImage(image: image),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
      image.dispose();
    } else {
      SmartDialog.showToast('截图失败');
    }
    _screenshotState = 0;
  }

  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      if (playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        _disableAutoEnterPip();
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isDesktopPip) {
      exitDesktopPip();
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    Get.back();
  }
}
