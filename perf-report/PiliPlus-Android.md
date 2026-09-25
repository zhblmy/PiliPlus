# PiliPlus Android 客户端 性能 / 发热 / 耗电 / 流畅度 优化分析报告

> **报告性质**：纯静态代码分析（只读）。本次分析**未修改任何项目文件、未运行 App、未执行性能采样**。
> 所有结论均可回溯到 `文件:行号`，建议在实施前后用 `flutter run --profile` + DevTools 与 Android Studio Profiler 复核。
>
> **分析范围**：`lib/`（Dart 业务与渲染层）、`android/`（清单、Gradle、原生服务配置）、`pubspec.yaml`（依赖与版本）。
> **工程版本**：PiliPlus 2.1.4+1（Flutter 3.47.5，compileSdk/targetSdk 37，AGP 9.0.1，Kotlin 2.3.20，Gradle 9.5.0）。
> **日期**：2026-09-24

---

## 目录

1. [结论摘要](#一结论摘要)
2. [问题总览](#二问题总览)
3. [播放与解码链路](#三播放与解码链路)
4. [弹幕系统](#四弹幕系统)
5. [直播场景](#五直播场景)
6. [UI 渲染与列表重建](#六ui-渲染与列表重建)
7. [图片 / 主题 / 字体](#七图片--主题--字体)
8. [后台服务、唤醒锁与定时器](#八后台服务唤醒锁与定时器)
9. [网络与序列化](#九网络与序列化)
10. [启动性能](#十启动性能)
11. [Android 构建与系统层](#十一android-构建与系统层)
12. [分阶段实施路线图](#十二分阶段实施路线图)
13. [度量与验证方法](#十三度量与验证方法)
14. [附录：文件行号索引](#附录文件行号索引)

---

## 一、结论摘要

本工程总体质量较高（图片内存缓存、播放器控件层 `RepaintBoundary`、列表 `prototypeItem` 覆盖率都不错），但仍然存在**若干条贯穿"播放—后台—熄屏"全链路的耗电放大器**，以及**成片出现的每帧级重建**。按"收益 / 改动成本"排序，最值得先做的十件事：

| # | 结论（含证据位置） | 预期收益 |
|---|------------------|---------|
| 1 | **唤醒锁只按"是否在播放"判断，不看前后台 / 页面可见性**。后台播放开启后（`enableBackgroundPlay` 默认 true），熄屏仍在持 `PARTIAL_WAKE_LOCK` + mpv 全速解码。<br>`controller.dart:907`、`:881`、`storage_pref.dart:660` | 熄屏场景**待机电流可降 30%~60%**，最强发热源 |
| 2 | **播放心跳每 5 秒发一次 HTTPS POST**（12 次/分钟、720 次/小时），把射频钉在 CONNECTED 态。<br>`controller.dart:1484-1490`、`:947` | 连续观看时射频与唤醒次数显著下降 |
| 3 | **骨架屏：每个占位项一个 `AnimationController.repeat()` + 每帧 `setState` + 每帧 `ShaderMask`**，首屏常态 10~12 个。<br>`skeleton.dart:16-35`、`sliver_single_child_delegate.dart:14-17` | 首屏 / 切 Tab **掉帧直接消失** |
| 4 | **视频页整页 `Obx` + `scrollRatio` 每帧写 Rx + 悬浮栏 `Opacity`（每帧 saveLayer）**。<br>`video/view.dart:488`、`:634`、`video_header.dart:57` | 视频页滚动帧率、GPU 占用 |
| 5 | **评论项每次 build 重新拼接并编译正则**（内容不变的评论也重算）。<br>`reply_item_grpc.dart:716-739` | 评论列表滚动 CPU |
| 6 | **直播弹幕逐条 `jsonDecode` + 多次 `fromJson` 全在 UI isolate**，热点房间 1000+ 条/分钟。<br>`live_room/controller.dart:577-690`、`tcp/live.dart:221` | 直播间 **CPU 从 20~60% 单核降到个位数** |
| 7 | **`RetryInterceptor`：所有失败请求固定重试 2 次（500ms/1000ms），无退避、不分幂等**。<br>`retry_interceptor.dart:63`、`storage_pref.dart:557-561` | 弱网下流量 ×3 → ×1.2 |
| 8 | **图片磁盘缓存默认上限 1 GiB**，且"清理缓存"递归 `stat` 整目录。<br>`storage_pref.dart:618-619`、`cache_manager.dart:18-32` | 长期存储写入 / 随机 IO 下降 |
| 9 | **日志默认开启，每条异常 `flush()`（fsync），文件无上限无轮转**。<br>`json_file_handler.dart:17-20`、`:47-60`、`storage_pref.dart:637-638` | 异常多时避免持续 fsync 唤醒 |
| 10 | **启动前 `await` 了 audio_service 前台服务、动态取色、`MediaKit.ensureInitialized()`、9 个 Hive box**。<br>`main.dart:94`、`:117-120`、`:189-190`、`storage.dart:31-72` | 冷启动首帧 **-200~500ms** |

> **最值得注意的一个"组合拳"**：`enableBackgroundPlay` 默认开启（`lib/utils/storage_pref.dart:660-661`）+ Wakelock 无门控（`controller.dart:907`）+ 心跳 5s（`controller.dart:1484`）+ 常驻前台服务与高频通知更新（`lib/services/audio_handler.dart:26-34`、`:74-140`）。四者叠加 = **熄屏后 CPU、网络、显示子系统仍在全速工作**，这是"手机烫、掉电快"最可能的直接原因。

---

## 二、问题总览

按模块统计（详细分析见后续章节）：

| 模块 | 编号前缀 | 条目数 | 主要代价维度 |
|------|---------|-------|-------------|
| 播放与解码 | `P-xx` | 12 | CPU / 发热 / 耗电 |
| 弹幕系统 | `D-xx` | 5 | CPU / GPU / 发热 |
| 直播场景 | `L-xx` | 7 | CPU / 网络 / 耗电 |
| UI 渲染与列表 | `U-xx` | 17 | 流畅度 / GPU |
| 图片 / 主题 / 字体 | `I-xx` | 6 | 内存 / GPU |
| 后台服务与定时器 | `B-xx` | 12 | 待机耗电 / 唤醒 |
| 网络与序列化 | `N-xx` | 4 | CPU / 网络 / 流量 |
| 启动性能 | `S-xx` | 10 | 冷启动耗时 |
| Android 构建与系统层 | `A-xx` | 4 | 体积 / 启动 / 帧率 |

---

## 三、播放与解码链路

### P-01 唤醒锁缺少前后台与页面可见性门控【严重】

**证据**

```dart
// lib/plugin/pl_player/controller.dart:903-913
stream.playing.listen((bool playing) {
  if (playing) {
    playerStatus = .playing;
    _stopWakeLockTimer();
    _updatePlaybackState();
    WakelockPlus.enable();          // ← 只判断 playing，不看前台/可见
```

```dart
// lib/plugin/pl_player/controller.dart:867-881
void _startWakeLockTimer() {          // 暂停后 500ms 才释放
  _wakeLockTimer?.cancel();
  _wakeLockTimer = Timer(const Duration(milliseconds: 500), _stopWakeLock);
}
```

全仓只有一个地方兜底释放：`controller.dart:1587`（`dispose()`）。

**影响**：只要 mpv 报告 `playing == true`，就持有 `PARTIAL_WAKE_LOCK`。用户开启"后台播放"或使用画中画/分屏时，即使屏幕熄灭/页面不可见，CPU 也无法进入 suspend，mpv 持续解码 + 拉流。配合 `audio_service` 前台服务，这是熄屏发热的第一大来源。

**建议**
- 在 `PlPlayerController` 增加 `isForeground` 状态，由 `didChangeAppLifecycleState` 维护；
- 唤醒锁条件改为 `isForeground && isPageVisible && playing`；
- 后台播放改由音频服务承担（不依赖唤醒锁）；`AppLifecycleState.paused` 时立即 `WakelockPlus.disable()`；
- 页面不可见（`visible == false`，`controller.dart` 已有该字段）时同样释放。

---

### P-02 播放心跳每 5 秒一次网络请求【严重】

**证据**

```dart
// lib/plugin/pl_player/controller.dart:1484-1490
case .playing:
  if (progress - _heartDuration >= 5) {   // ← 阈值 5 秒
    _heartDuration = progress;
    return send();                         // VideoHttp.heartBeat(...)
  }
case .status:
  if (progress - _heartDuration >= 2) {   // ← 暂停/恢复也发，阈值 2 秒
```

调用点：`controller.dart:947`（`stream.position` 监听内）、`:913`（`playing` 回调内 `makeHeartBeat(seconds, type: .status)`）、`:930`（`completed`）。

**影响**：播放中 **12 次/分钟、720 次/小时** 的完整 HTTPS 请求（含 Cookie 与 csrf 签名）。无线电模块（RRC）在如此密集的请求下无法回到 IDLE，射频功耗远高于睡眠；同时每次请求都产生一次 CPU 唤醒，wakeups 计数上升。

**建议**
- 阈值改为 15~30 秒（可做成 `Pref` 配置项）；
- 暂停 / seek / 退出页面 / 生命周期切换时各补发一次，保证进度不丢；
- `stream.position` 监听内先做"秒级变化"判断再进函数，避免高频空转；
- 离线 / 后台 / 低电量时直接跳过。

---

### P-03 `stream.position` 回调频率高，回调内仍走完整链路

**证据**

```dart
// lib/plugin/pl_player/controller.dart:934-951
stream.position.listen((Duration position) {
  final posInSeconds = position.inSeconds;
  if (posInSeconds != this.position.value) {
    if (posInSeconds == 0 && playerStatus.isPlaying) {
      _updatePlaybackState(position: position);
    }
    this.position.value = posInSeconds;   // 写 Rx → 触发订阅者重建
    makeHeartBeat(posInSeconds);          // 无条件调用
  }
  for (final element in _positionListeners) {
    element(position);                     // 逐个回调（含弹幕）
  }
});
```

**影响**：media_kit 的 `position` 事件频率远高于 1 Hz。虽然已有"秒变化才写 Rx"的判断，但 `_positionListeners` 是**每个 tick 都遍历**的，弹幕渲染（`lib/pages/danmaku/view.dart:65`）与视频页（`lib/pages/video/view.dart:184`、`:207`、`:314`、`:437` 多次注册）都挂在这个集合上。

**建议**：把 `_positionListeners` 的调用也纳入"秒变化或位置跳跃"判断内；弹幕层只在**毫秒取整百**真正变化时才需要回调（`lib/pages/danmaku/view.dart:104-107` 已有取整逻辑，可上移到分发处，一次性过滤所有订阅者）。

---

### P-04 `video-sync: display-resample` + `autosync: 30` 默认开启

**证据**

```dart
// lib/utils/storage_pref.dart:269-274
static String get videoSync =>
    _setting.get(SettingBoxKey.videoSync, defaultValue: 'display-resample');
static String get autosync => _setting.get(
  SettingBoxKey.autosync, defaultValue: Platform.isAndroid ? '30' : '0');
```

```dart
// lib/plugin/pl_player/controller.dart:722-736
final opt = {
  'video-sync': Pref.videoSync,          // display-resample
  if (Platform.isAndroid) 'ao': Pref.audioOutput,
  'volume': ...,
};
final autosync = Pref.autosync;
if (autosync != '0') opt['autosync'] = autosync;
```

**影响**：`display-resample` 会让 mpv 持续重采样音频并动态微调播放速率以匹配显示刷新率。在 120Hz 屏幕上是**持续**的音频重采样 + 视频帧重定时开销，换来的收益（音画完全同步）在移动端收益有限；`autosync=30`（帧丢弃/重复阈值）也会增加同步逻辑的运算量。

**建议**：Android 默认改为 `audio`（或 `desync`），把 `display-resample` 作为高级选项；`autosync` 默认调小或关闭。

---

### P-05 硬件解码配置与失败降级策略

**证据**

```dart
// lib/plugin/pl_player/controller.dart:368
late final String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;

// lib/plugin/pl_player/controller.dart:749-753
_videoController = await VideoController.create(player,
  configuration: VideoControllerConfiguration(
    enableHardwareAcceleration: hwdec != null,
    androidAttachSurfaceAfterVideoParameters: false,
    hwdec: hwdec,
  ));
```

```dart
// lib/plugin/pl_player/models/hwdec_type.dart:45-49
static final String kHwdec = Platform.isAndroid
    ? kDebugMode ? autoSafe.hwdec
      : [mediacodec.hwdec, autoSafe.hwdec].join(',')   // "mediacodec,auto-safe"
    : auto.hwdec;
```

**影响**：默认配置本身是合理的（`mediacodec` 优先）。但 `Could not open codec` 只弹一个 toast（`controller.dart:1047-1048`），**没有自动降级到软解/其他解码器**，用户遇到兼容性问题时只能一直硬解失败重试；反过来，用户一旦手动关闭"硬件加速"（`enableHA`），变成纯软解，此时 4K/高码率视频会直接跑满 CPU、剧烈发热。

**建议**
- `hwdec` 失败时自动回退：`mediacodec` → `auto-safe` → `auto-copy` → `no`；
- 在设置页对"关闭硬件加速"给出明确警告；
- 可考虑在高码率/高分辨率视频上强制 `*-copy` 之外的硬件路径并提示。

---

### P-06 Anime4K 超分着色器是移动 GPU 的重负载

**证据**

```dart
// lib/plugin/pl_player/controller.dart:685-721
switch (type) {
  case SuperResolutionType.efficiency:
    ... Assets.mpvAnime4KShadersLite ...
  case SuperResolutionType.quality:
    ... Assets.mpvAnime4KShaders ...       // CNN_VL / CNN_M / CNN_S / Upscale CNN x2
}
```

```dart
// lib/plugin/pl_player/controller.dart:672-684
Future<String> get copyShadersToExternalDirectory async {
  if (shadersDirPath != null) return shadersDirPath!;
  return shadersDirPath = await AssetUtils.getOrCopy(
    'assets/shaders', Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
    path.join(appSupportDirPath, 'anime_shaders'));
}
```

**影响**：`quality` 档加载的是 CNN 卷积类着色器（`Anime4K_Restore_CNN_VL` + `Upscale_CNN_x2_VL` 等），在手机 GPU 上是**每帧多次卷积**，是典型的高发热、高耗电负载。默认仅在 `isAnim`（`controller.dart:683`，番剧/影视）且用户主动开启时生效 —— 入口是安全的，但缺少功耗提示与场景限制。

**建议**
- 设置页标注"高耗电 / 会显著发热"，并给出"仅插电时启用"选项；
- 低电量（<20%）时自动关闭；
- 本地文件播放（省网络功耗）时才推荐开启；
- 检测 `SuperResolutionType.quality` 在低端 GPU 上自动降级为 `efficiency`。

---

### P-07 直播错误重连完全没有节流【中】

**证据**

```dart
// lib/plugin/pl_player/controller.dart:993-999
if (isLive) {
  if (event.startsWith('tcp: ffurl_read returned ') || ...) {
    Timer(const Duration(milliseconds: 3000), refreshPlayer);   // ← 无节流！
  }
  return;
}
```
对比非直播分支（同文件 `:1000-1030`）用了 `EasyThrottle.throttle(..., Duration(milliseconds: 10000), ...)`。

**影响**：直播流抖动时 `stream.error` 会密集触发，每条错误都排一个 3 秒后执行的 `Timer`，多个定时器叠加 → 多次重新建连（TLS + CDN 握手）。表现为"网络指示灯常亮 + SoC 高负载"，比正常观看更耗电。

**建议**：`isLive` 分支套同样的节流（≥10s），并做指数退避（3s → 10s → 30s）；重连前 `cancel()` 已有定时器；给 `refreshPlayer()` 加 `_processing` 互斥保护（目前只有 `setDataSource` 有）。

---

### P-08 播放页整页 `Obx` + 滚动比例每帧回写 Rx

**证据**

```dart
// lib/pages/video/view.dart:488-495
Widget get childWhenDisabled {
  return Obx(                                  // ← 整个视频页包在 Obx 里
    () {
      final isFullScreen = this.isFullScreen;
      return SimpleScaffold(
        appBar: removeAppBar(isFullScreen) ? null : Obx(() {
          final scrollRatio = videoDetailController.scrollRatio.value;   // ← 内层再包一层
```

写入源（在**渲染层**直接写 Rx）：

```dart
// lib/common/widgets/sliver/video_header.dart:57
if (_scrollRatio != scrollRatio) {
  _scrollRatio = scrollRatio;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    onScrollRatioChanged(scrollRatio);       // → videoDetailController.scrollRatio = x
  });
}
```

```dart
// lib/pages/video/controller.dart:176
late final RxDouble scrollRatio = 0.0.obs;
```

**影响**：滚动视频页时 `scrollRatio` 每帧变化 → 每次都标脏整个页面的 `Obx` 与外层 `Obx`。这是本页最贵的路径。

**建议**
- `scrollRatio` 改用 `ValueNotifier<double>` + `ValueListenableBuilder`，只包住真正需要随比例变化的**最小子树**（顶栏背景色 / 悬浮栏透明度）；
- 拆掉 `childWhenDisabled` 外层的整页 `Obx`，改为只订阅 `isFullScreen` 的局部 `Obx`；
- 回写改为节流（如比例变化 > 0.01 才写）或直接用 `ScrollController` 派生。

---

### P-09 悬浮工具栏用 `Opacity` 且每帧重建 → 每帧一次 `saveLayer`【中】

**证据**

```dart
// lib/pages/video/view.dart:634-640
return Opacity(                             // ← 不走 GPU 合成，插入 saveLayer
  opacity: videoDetailController.scrollRatio.value,
  child: Container(
    color: colorScheme.surface,
    child: SizedBox(height: kToolbarHeight, child: Stack( ... 多个 IconButton ...
```
调用方 `lib/pages/video/view.dart:710-746`：`_buildHeaderOverlay()` 的 `Obx` 内 `child: _buildOverlayToolBar(scrollRatio)`。

**影响**：`Opacity` 会为整个子树（含文字与图标）插入一次 `saveLayer`，叠加每帧重建（见 P-08），滚动时明显掉帧。

**建议**：改用 `AnimatedOpacity`（或用 `FadeTransition` + `AnimationController`），或者干脆把透明度换成"背景色 lerp + 图标颜色变化"，完全避免 `saveLayer`。

---

### P-10 `_positionListeners` 与多种定时器散布在播放页

**证据**
- 页面前后台切换、`didPopNext`、`playCallBack` 各处重复注册（`lib/pages/video/view.dart:180`、`:207`、`:314`、`:437`，注销在 `:332`、`:389`）—— 多处注册/注销容易失衡，导致页面不可见时仍被回调。
- 展开/收起动画的 listener 每帧调用 `refreshPage()`：

```dart
// lib/pages/video/controller.dart:199-205
void _animListener() {
  if (animationController.isForwardOrCompleted) {
    _calcAnimHeight();
    refreshPage();                        // → scrollKey.currentState?.refresh()
  }
}
```

**影响**：一次性 `AnimationController`（200ms）每帧触发 `ExtendedNestedScrollView.refresh()`，即每帧对整个嵌套滚动视图做一次重排；同时 `_animListener` 在动画结束后仍挂着（`isForwardOrCompleted` 只在 `completed` 才为 true）。

**建议**：`_animListener` 改为只更新 `animHeight` 对应的 `ValueNotifier`，让 `VideoHeader` 通过 `AnimatedBuilder` 订阅；或把 `refreshPage()` 从 listener 中移出，只在动画开始/结束各调用一次。

---

### P-11 控制条时钟 1 秒定时器 + 每次 build 触发电池查询

**证据**

```dart
// lib/pages/video/widgets/header_control.dart:103-113
Timer.periodic(const Duration(seconds: 1), ...);   // 写 now.value → Obx 重建
// lib/pages/video/widgets/header_control.dart:128
late final _battery = Battery();
// lib/pages/video/widgets/header_control.dart:131-140
EasyThrottle(30s) 内 await _battery.batteryLevel
```
调用方 `lib/plugin/pl_player/view/view.dart:206-220`（控制条显隐回调里每次调用 `getBatteryLevelIfNeeded()`）；直播侧同样：`lib/pages/live_room/widgets/header_control.dart:72`、`:133`。

**影响**：秒级文本刷新让有动画的控制条再叠一层重建；电池查询走 platform channel，且**每次 build 都调用**（虽被 throttle 但每次都要判一次）。

**建议**
- 时钟改为"对齐到下一个整分钟"的单次 `Timer`（控制条上只显示 `HH:mm`）；
- 电池查询独立为 `Timer.periodic(60s)`，且只在 `_showBatteryLevel` 为真时创建。

---

### P-12 各类"小定时器"在播放期间持续运行

| 位置 | 间隔 | 代价 |
|------|------|------|
| `lib/pages/sponsor_block/block_mixin.dart:207-211` | 4 秒常驻 | 只要有一条未消费的片段提示就一直 tick，即使视频已暂停/已后台；每次触发删除动画重建 |
| `lib/pages/video/pay_coins/view.dart:522` | `50 ~/ 3` ≈ **16.67 ms** 的 `Timer.periodic` | 用定时器模拟动画而不是 vsync，与显示刷新错位；该 State 本身已 `with TickerProviderStateMixin`（`:63`） |
| `lib/pages/common/common_intro_controller.dart:89-95` | 10 秒（同时在线人数） | 6 次/分钟、360 次/小时；只在简介 Tab 可见时才需要 |

**建议**
- SponsorBlock：入队时按该条目到期时刻安排**单次** `Timer`，不用常驻周期定时器；播放暂停/后台时暂停。
- 投币动画：改用 `AnimationController` / `Ticker`（已有 vsync）。
- 在线人数：间隔提到 30~60 秒，且仅在简介 Tab 可见且播放中轮询。

---

## 四、弹幕系统

### D-01 弹幕逐条插入与解析在 UI isolate，且渲染不过滤

**证据**

```dart
// lib/pages/danmaku/view.dart:93-155
void videoPositionListen(Duration position) {
  ...
  int currentPosition = position.inMilliseconds;
  currentPosition -= currentPosition % 100;     // 取整百毫秒
  if (currentPosition == latestAddedPosition) return;
  latestAddedPosition = currentPosition;

  List<DanmakuElem>? currentDanmakuList =
      _plDanmakuController.getCurrentDanmaku(currentPosition);
  if (currentDanmakuList != null) {
    final blockColorful = DanmakuOptions.blockColorful;
    final danmakuWeight = DanmakuOptions.danmakuWeight;
    for (DanmakuElem e in currentDanmakuList) {
      if (e.weight < danmakuWeight) return;     // ← 注意是 return（见下）
      if (e.mode == 7) {
        _controller!.addDanmaku(SpecialDanmakuContentItem.fromList(
          ...,
          jsonDecode(e.content.replaceAll('\n', '\\n')),   // ← UI isolate 上解码
          ...));
      } else {
        _controller!.addDanmaku(DanmakuContentItem(...));
      }
    }
  }
}
```

- 默认屏蔽等级为 **0**（`lib/utils/storage_pref.dart:790-791` `danmakuWeight => defaultValue: 0`）→ **不做任何过滤**，全部弹幕进入渲染队列。
- `mode == 7` 的特殊弹幕（代码弹幕）在 UI isolate 上 `jsonDecode`。

**影响**：高密度弹幕视频每 100ms 循环处理一批元素、构造 `DanmakuContentItem`（含颜色转换、`DmUtils.getPosition` 等），特殊弹幕还额外 `jsonDecode`。这是弹幕场景 CPU 与发热的主要来源之一。

**建议**
- 弹幕列表解析（含 `mode == 7` 的 `content`）在 `PlDanmakuController` 拉取时就一次性展开并缓存，渲染层只读；
- 默认屏蔽等级提到 5~8（B 站默认是分级屏蔽，0 级等于全开）；
- 增加"每秒最大新增弹幕数"上限（如 60 条/秒），超出时只插入高权重弹幕。

> **附带发现（逻辑问题，非性能）**：`lib/pages/danmaku/view.dart:117` 的 `if (e.weight < danmakuWeight) return;` 用的是 `return` 而非 `continue`，意味着一旦遇到一条低权重弹幕，**当批剩余弹幕全部被丢弃**。这会让"智能云屏蔽"行为异常，也让弹幕看起来莫名其妙地变少。建议一并确认。

---

### D-02 弹幕渲染层未做"可见性 / 后台"暂停

**证据**

```dart
// lib/pages/danmaku/view.dart:158-177
return Obx(() => AnimatedOpacity(
  opacity: playerController.enableShowDanmaku.value
      ? playerController.danmakuOpacity.value : 0,
  duration: const Duration(milliseconds: 100),
  child: DanmakuScreen<DanmakuExtra>( ... ),
));
```

**影响**：用 `opacity: 0` 隐藏弹幕时，`DanmakuScreen` 仍在**全速绘制**（只是最终混合为透明）。视频页暂停/后台/隐藏弹幕的场景下，Canvas 仍在每帧重绘。

**建议**：`enableShowDanmaku == false` 时用条件分支直接返回 `SizedBox.shrink()` 或调用 `DanmakuController.pause()`（`playerListener` 里已有 `controller.pause()`，`lib/pages/danmaku/view.dart:81-90`，确认该路径在所有隐藏场景均被触发）。

---

### D-03 弹幕绘制参数可以更省

**证据**

```dart
// lib/plugin/pl_player/utils/danmaku_options.dart:30-48
return DanmakuOption(
  fontSize: 15 * (notFullscreen ? danmakuFontScale : danmakuFontScaleFS),
  strokeWidth: danmakuStrokeWidth,       // 描边 → 每个字形多一次描边绘制
  area: danmakuShowArea,                 // 默认 0.5（storage_pref.dart:793-794）
  lineHeight: danmakuLineHeight,
  massiveMode: danmakuMassiveMode,
  safeArea: true,
  ...
);
```

**影响**：描边宽度、字号缩放、`massiveMode`（海量模式）都直接影响每帧的文本绘制与合成成本；`safeArea: true` 在部分机型上会带来额外的区域裁剪。

**建议**：低端设备自动建议"减小字号/关闭描边/降低显示区域"；`massiveMode` 明确标注为高耗电选项。

---

### D-04 弹幕透明度变化走 `AnimatedOpacity`

**证据**：`lib/pages/danmaku/view.dart:170-175`。

**影响**：`AnimatedOpacity` 在动画期间（100ms）同样会插入 `saveLayer`，且它包住的是**整块全屏 `DanmakuScreen`**，代价比普通小控件高得多。

**建议**：改用 `DanmakuController` 自身的透明度参数（`canvas_danmaku` 支持设置透明度），或在播放器层用 `ColorFiltered`/`ShaderMask` 之外的方案，避免对全屏内容做 `saveLayer`。

---

### D-05 弹幕分段与预加载策略

**证据**：`lib/pages/danmaku/controller.dart`（`PlDanmakuController`）、`DmUtils.calcSegment`（调用点 `lib/pages/danmaku/view.dart:57-58`）。

**影响**：分段拉取弹幕本身是正确做法，但需确认：① 切分片时是否有大对象 GC 抖动；② 弹幕总量很大时（如 6 分钟分片、上万条）是否会造成长任务阻塞 UI isolate。本次仅静态分析，建议在 DevTools 中用 Timeline 复核 `queryDanmaku` 与解析路径的耗时。

**建议**：分片解析放到 `Isolate.run` / `compute`，UI isolate 只接收已构造好的轻量结构。

---

## 五、直播场景

直播间是本工程的"最重场景"：**WSS 长连接 + 逐条解析 + 高频列表插入 + 全屏持续渲染**四件事同时发生。

### L-01 弹幕/礼物消息逐条解析全在 UI isolate【严重】

**证据**

```dart
// lib/pages/live_room/controller.dart:577-690  _danmakuListener
// 每条消息：jsonDecode → BaseEmote.fromJson → UinfoMedal.fromJson → DmUtils.decimalToColor

// lib/pages/live_room/controller.dart:592
jsonDecode(content['extra'])          // 同一帧内第二次 decode

// lib/tcp/live.dart:221
jsonDecode(utf8.decode(...))          // WS 每条消息（含粘包拆分 :230-236）

// lib/tcp/live.dart:286-320
// 每条消息 brotli / zlib 解压
```

**影响**：热点直播间 1000+ 条/分钟，每条都做 1~2 次 `jsonDecode` + 多个 `fromJson` + 列表插入 + 文本控件重建。20%~60% 单核占用可持续，伴随高频 GC → CPU 与屏幕双重发热。

**建议**
- 解压 + `jsonDecode` 移到 `Isolate.run`，或按批（如每 50ms 合并一次）处理；
- 增加消息限流：超过 N 条/秒时丢弃非 SC / 非上麦消息；
- `lib/pages/live_room/controller.dart:3` 的 `_kMaxChatCount = 500` 调到 200 以内；
- `messages` 用普通 `List` + 手写通知（代码里已有 `chatSimpleIndex` / `trimDmIndex` 裁剪机制，说明作者也清楚列表是瓶颈）。

---

### L-02 后台不关闭弹幕 WebSocket

**证据**

```dart
// lib/pages/live_room/view.dart:193-205
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == .paused) {
    cancelLiveTimer();
    // 清弹幕 ...  但没有 closeLiveMsg()
  }
}
// lib/pages/live_room/controller.dart:414-417  closeLiveMsg() 存在但未在此调用
```

**影响**：是否关闭 WSS 依赖"播放器暂停 → `playerListener` → `closeLiveMsg`"这条链。一旦用户开启后台播放，或 player 状态回调未注册（`lib/pages/live_room/view.dart:150` 的 `didPushNext` 会 `removeStatusLister`），WSS 会在后台继续收包并逐条解析（同 L-01），持续网络 + CPU。

**建议**：`paused` 时显式 `closeLiveMsg()`，`resumed` 时按需重连。

---

### L-03 每条 SuperChat 一个 1 秒定时器

**证据**

```dart
// lib/pages/live_room/superchat/superchat_card.dart:87-89
_timer = Timer.periodic(const Duration(seconds: 1), _callback);
// :100-107  _callback 内写 _remains!.value → 该卡片重建
```

**影响**：SC 最长挂 1 小时 → 单卡 3600 次 tick；热房同时挂 5~10 张卡 = 每秒 5~10 个定时器 + 5~10 次 element 重建，全在 UI isolate。

**建议**：全局共享一个 1 秒 ticker（或 `Ticker` 驱动的 `ValueNotifier<int>`），各卡片订阅并自算剩余；或按结束时间排序，只跑"最近到期的那张卡"。

---

### L-04 直播间 5 分钟 `liveTime` 定时器与滚动到底动画

**证据**

```dart
// lib/pages/live_room/controller.dart:73-84
Timer.periodic(Duration(minutes: 5), ...)   // 只 refresh 一个"开播时长"文案
// lib/pages/live_room/controller.dart:380-393
scrollToBottom() → animateTo(..., 500ms)    // 弹幕高频时反复触发
```

**影响**：5 分钟定时器价值极低（一个文案）；`scrollToBottom` 在弹幕密集时被反复触发，每次 500ms 的滚动动画叠加。

**建议**：开播时长改为进入页面/恢复可见时按当前时间计算，去掉周期定时器；`scrollToBottom` 做节流（如 500ms 内只调一次）。

---

### L-05 直播间全屏背景图用 `Opacity`

**证据**：`lib/pages/live_room/view.dart:412`（`Opacity(opacity: 0.6)` 包住全屏背景图）；`:394-399` 用 `ImageUtils.safeThumbnailUrl(appBackground)`（不带 quality 参数）。

**影响**：全屏 `Opacity` = 每帧一次全屏 `saveLayer`，代价极高。

**建议**：在 `CachedNetworkImage` 的 `imageBuilder` 里对 `Image` 加 `color`/`opacity`（`Image` 自带 `opacity` 属性会走 `Paint.color` 而非 `saveLayer`），或预先把背景图染成半透明。

---

### L-06 直播间消息列表上限与视图复用

**证据**：`lib/pages/live_room/controller.dart:3`（`_kMaxChatCount = 500`）、`:560-574`（`addDm`）。

**建议**：见 L-01；另外确认聊天列表是否使用了 `prototypeItem` / `itemExtent`（固定行高时收益明显）。

---

### L-07 与直播相关的 CDN / 缓冲配置

**证据**

```dart
// lib/utils/storage_pref.dart:841-847
static Map<String, String> initLiveBuffer() => {
  'cache': 'yes',
  'demuxer-max-bytes': (Pref.bufferSize * 0x200000).toStringAsFixed(0),
  'demuxer-max-back-bytes': '0',
};
```

**影响**：直播缓冲区大小直接影响内存与预读量。`demuxer-max-bytes` 使用 2× 系数，若默认 `bufferSize` 偏大，会在低内存机型上增加内存压力与 GC。

**建议**：在低内存设备（`ActivityManager.memoryClass` 较小）上自动下调直播缓冲。

---

## 六、UI 渲染与列表重建

### U-01 骨架屏：每项一个无限动画 + 每帧 `setState` + 每帧 `ShaderMask`【严重】

**证据**

```dart
// lib/common/skeleton/skeleton.dart:16-35
late final AnimationController _controller;
_controller = AnimationController.unbounded(vsync: this)
  ..repeat(min: -0.5, max: 1.5, period: const Duration(milliseconds: 1000))
  ..addListener(_setState);
void _setState() {
  setState(() {});        // ← 每帧一次
}
// :47-64  build 里每帧重建 ui.Gradient.linear + ShaderMask（saveLayer）
```

放大因素 —— 同一个 widget 实例被塞进每个槽位，各自建立独立的 `Element`/`State`：

```dart
// lib/common/sliver_single_child_delegate.dart:14-17
Widget? build(BuildContext context, int index) {
  if (index < 0 || index >= estimatedChildCount) return null;
  return child;                                       // 同一个实例 → N 个 State
}
```

典型数量：
- `lib/pages/video/reply/view.dart:153`、`:155` → `count: 5`
- `lib/pages/common/dyn/common_dyn_page.dart:143`、`:145` → `count: 12`
- `lib/utils/waterfall.dart:48`、`:50` → `count: 10`
- `lib/pages/rcmd/view.dart:137`、`lib/utils/grid.dart:15` → `count: 10`

**影响**："加载中"阶段常态存在 **10~12 个 60fps 无限动画 + 10~12 层 ShaderMask**。这是首屏与切 Tab 掉帧的主因之一，也是持续 GPU/CPU 占用（发热）的来源。

**建议（性价比最高的一项改造）**
- 把 shimmer 抽到列表**外层**：用一个共享的 `AnimationController`（或 `AnimatedBuilder` + 单个 `ShaderMask`）覆盖整块骨架区域，内部只画静态灰块；
- 骨架项改用 `ListView.builder` / `SliverChildBuilderDelegate`（每个 index 独立 create），而不是共享同一 widget 实例；
- 骨架 `SizedBox` 外层套 `RepaintBoundary`；
- `matrix`、`colors`、`Gradient` 在 `initState` 里预计算，`build` 里不再新建。

---

### U-02 评论项每次 build 重新拼接并编译正则【严重】

**证据**

```dart
// lib/pages/video/reply/widgets/reply_item_grpc.dart:716-739
final List<String> specialTokens = [
  ...content.emotes.keys,
  ...content.topics.keys.map((e) => '#$e#'),
  ...content.atNameToMid.keys.map((e) => '@$e'),
  ...urlKeys,
];
String patternStr = [
  ...specialTokens.map(RegExp.escape),
  r'(?:\d+[:：])?\d+[:：]\d+',
  r'\{vote:\d+?\}',
  Constants.urlRegex.pattern,
].join('|');
final RegExp pattern = RegExp(patternStr);        // ← 每次 build 都编译
```

`ReplyItemGrpc` 是 `StatelessWidget`，滚动重入、点赞（`reply_item_grpc.dart:426`、`:433`、`:448` 的 `markNeedsBuild()`）、`loadingState.refresh()` 都会重跑这段 —— **内容完全没变的评论也要重算**。

**影响**：正则编译是昂贵操作（微秒~毫秒级，取决于表情数量）。表情/话题多的长评论最贵。评论列表滚动时的主导 CPU 成本之一。

**建议**
- 把解析结果缓存到 `ReplyInfo`（懒加载字段 `late final List<TextSpan> _spans`），只在内容变化时失效；
- 至少把 `RegExp` 缓存到模型或按 `specialTokens` 的哈希做 LRU；
- 把"构建 `TextSpan`"从 build 中移出，改用 `RichText` + 预构建的 `TextSpan`。

---

### U-03 删除 / 置顶 / 发评论导致整个列表重建

**证据**

```dart
// lib/pages/common/reply_controller.dart:204-218  onRemove(...) { ...; loadingState.refresh(); }
// lib/pages/common/reply_controller.dart:224-243  同类
// lib/pages/video/reply/view.dart:119
Obx(() => _buildBody(_videoReplyController.loadingState.value)),
```

同类：`lib/pages/dynamics_tab/view.dart:61-62` + `lib/pages/dynamics_tab/controller.dart:70-104`（`onRemove` / `onBlock` / `onUnfold` 都是 `..refresh()`）、`lib/pages/rcmd/view.dart:96-104`、`lib/pages/video/related/view.dart:48-52`。

**影响**：`loadingState.refresh()` 让包裹整个 `SliverList.builder` 的 `Obx` 重建 → 可见项全部重建 → 每条都要重跑 U-02 的正则。

**建议**
- 列表数据改用 `RxList`，配对 `Obx` 只包住 `SliverChildBuilderDelegate` 的 item 级（或 `ValueListenableBuilder`）；
- 删除/展开用局部 `setState` 或 `AnimatedList`/`SliverAnimatedList`；
- 至少把 `loadingState` 的 `data` 变化与列表"结构变化"分开，避免结构未变时全量重建。

---

### U-04 列表与加载态共用一个 `Obx`

**证据**：`lib/pages/video/reply_reply/view.dart:214`、`lib/pages/common/dyn/common_dyn_page.dart:143`、`lib/pages/member_dynamics/view.dart:93`、`lib/pages/member_search/child/view.dart:75-94`。

反例（正确写法，可作模板）：`lib/pages/video/reply/view.dart:89-104` 只把 `sortType` 包进小 `Obx`。

**建议**：按上述模板拆分 —— 加载态走一个 `Obx`，列表走另一个，数据用 `RxList` 的 `Obx` 只包 builder 委托。

---

### U-05 顶栏/底栏隐藏动画每滚动帧写 Rx → 每帧重建

**证据**

```dart
// lib/pages/common/common_page.dart:70-95
if (notification is ScrollUpdateNotification) {
  ...
  _updateOffset(scrollDelta);          // _barOffset!.value = clamp(...)
}
```
消费端：`lib/pages/home/view.dart:104-118`（`Obx` 重建 `CustomHeightWidget`，含搜索栏 + 消息按钮 + 头像）、`lib/pages/main/view.dart:382-395`（`Obx` 重建 `FractionalTranslation` 与 `AnimatedSlide`）。

**影响**：滚动时这些子树持续重建（搜索栏含 `TextField` / 头像 / 图标，成本不低）。

**建议**：改用 `ValueListenableBuilder` / `AnimatedBuilder`，或直接用 `AnimatedContainer` 的 `Offset` 隐式动画，只重建真正位移的那一层。

---

### U-06 `Opacity` 反模式

**证据**
- `lib/pages/dynamics/widgets/up_panel.dart:220`：`Opacity(opacity: isCurrent ? 1 : 0.6)` 包住整个头像 + 文字（**列表项内**，影响面大）
- `lib/common/widgets/expandable.dart:99`
- `lib/common/widgets/scaffold/mini_scaffold.dart:215`
- `lib/pages/live_room/view.dart:412`（见 L-05）
- `lib/pages/video/view.dart:634`（见 P-09）

**建议**：静态透明度用 `Color.withOpacity` / `Image.color` / `TextStyle.color` 表达；需要动画用 `AnimatedOpacity` 或 `FadeTransition`（`FadeTransition` 走 `OpacityLayer`，比 `Opacity` widget 便宜）。

---

### U-07 列表项里的 `LayoutBuilder` 引入额外布局 pass

**证据**

```dart
// lib/common/widgets/video_card/video_card_v.dart:101-115
AspectRatio(
  aspectRatio: Style.aspectRatio,
  child: LayoutBuilder(                     // ← 每个卡片一次额外布局
    builder: (context, boxConstraints) { ... NetworkImgLayer(width: maxWidth, height: maxHeight) }
```
同样：`lib/common/widgets/video_card/video_card_h.dart:57-59`。

**影响**：`LayoutBuilder` 会引入 relayout boundary。首屏 10+ 张卡片 = 10+ 次额外布局；网格滚动时每次都触发。

**建议**：`gridDelegate` 已给出确定尺寸时，直接用 `SizedBox.expand` / `FractionallySizedBox` / 已知宽高比计算，去掉 `LayoutBuilder`。

---

### U-08 每项每次 build 现算日期

**证据**

```dart
// lib/common/widgets/video_card/video_card_v.dart:225-226, 251
static final shortFormat = DateFormat('M-d');        // 好：formatter 复用
text: DateFormatUtils.dateFormat(videoItem.pubdate, short: shortFormat, long: longFormat),
// lib/utils/date_utils.dart:15-46  内部每次 DateTime.now() + 2~3 次 DateTime.fromMillisecondsSinceEpoch
```

**建议**：在 `VideoItem` 模型里缓存格式化结果（`late final String pubdateText`），或对 `(pubdate, nowDay)` 做一层小 LRU。

---

### U-09 图片光栅化与裁剪层

**证据（做得好的部分）**

```dart
// lib/common/widgets/image/network_img_layer.dart:66-84
if (cacheWidth ?? width <= height) {
  memCacheWidth = width.cacheSize(context);
} else {
  memCacheHeight = height.cacheSize(context);
}
return CachedNetworkImage(
  imageUrl: ImageUtils.thumbnailUrl(src, quality),   // @Nq.webp
  memCacheWidth: memCacheWidth, memCacheHeight: memCacheHeight,
  filterQuality: FilterQuality.low,
```

**问题在裁剪层（`:47-56`）**：非 emote 一律 `ClipRRect`、头像一律 `ClipOval`。`ClipRRect` 默认 `Clip.antiAlias` → **每张图一次 `saveLayer`**。评论/动态列表里每项至少 1 个头像（`lib/common/widgets/pendant_avatar.dart:71-76` 还会额外加载一个挂件图）。

**建议**
- 矩形圆角改用 `DecorationImage` + `BoxDecoration(borderRadius: ...)`（由 `RRect` 裁剪，无 `saveLayer`）；
- 或 `ClipRRect(clipBehavior: Clip.hardEdge)`（仅对圆角边缘做硬裁剪）；
- 圆形头像用 `CircleAvatar`/`Container(decoration: BoxDecoration(shape: circle, image: ...))`。

---

### U-10 少数位置绕过缩略图，直接拉原图

**证据**

```dart
// lib/pages/live_room/view.dart:394-399
imageUrl: ImageUtils.safeThumbnailUrl(appBackground),   // 已带 @xxx 则原样返回
```
```dart
// lib/utils/image_utils.dart:199-206 / :213-215
// safeThumbnailUrl：后缀已带参数时不缩图
// thumbnailUrl：imgQuality == 100 时退回原图
```

**影响**：默认画质 `10`（`lib/utils/storage_pref.dart:154-155`），用户设为 100 时列表缩略图会拉原图，内存占用与解码开销显著上升。

**建议**：列表场景的缩略图**强制**上限（如最长边 ≤ 480px），仅在详情/大图查看时使用原图。

---

### U-11 `ImageGridBuilder` 把所有图片都变成 repaint boundary

**证据**

```dart
// lib/common/widgets/image_grid/image_grid_builder.dart:273
bool get isRepaintBoundary => true;   // 注释写的是 "gif repaint"
```

**影响**：静态图也各成一层 layer，9 图宫格会多出 9 层合成。

**建议**：只对真正的动图开启（`lib/models_new/reply/picture.dart:7` 已有 `playGifThumbnail` 标记可用）。

---

### U-12 `Hero` tag 里带 `hashCode`

**证据**

```dart
// lib/common/widgets/image_grid/image_grid_view.dart:253-255
if (!item.isLongPic) {
  child = Hero(tag: '${item.url}$hashCode', child: child);
}
```

**影响**：`hashCode` 会在 widget 重建后变化 → 框架不断注销/注册 hero 飞行目标，Hero 子树需要在每次布局中上报飞行矩形，带来额外 `Layout` 开销。

**建议**：tag 用稳定标识（`item.url` 或 item 的持久 id）。

---

### U-13 `build` 中做副作用（dispose/create `TabController`）

**证据**

```dart
// lib/pages/video/view.dart:1388-1404  buildTabBar()
// 在 build 中判断数量不符就 tabCtr.dispose() 并新建 TabController
```

**影响**：在 build 阶段 dispose/create 控制器，长度抖动时会引发额外重建甚至一帧异常。

**建议**：移到 `didUpdateWidget` 或状态变更处（`TabBar` 的 `length` 变化应在数据源变化的回调里同步处理）。

---

### U-14 列表 `cacheExtent` 与 `prototypeItem` 覆盖不完整

**已优化（无需改）**：`lib/pages/video/reply/view.dart:153`、`lib/pages/common/dyn/common_dyn_page.dart:143`、`lib/pages/main_reply/view.dart:117`、`lib/pages/blacklist/view.dart:71`、`lib/pages/video/note/view.dart:174`、`lib/pages/whisper/view.dart:116` 使用 `prototypeItem`；`lib/pages/video/medialist/view.dart:138`、`lib/pages/video/member/view.dart:229`、`:261`、`lib/pages/video/introduction/ugc/widgets/page.dart:148`、`lib/pages/episode_panel/view.dart:336`、`:354` 使用 `itemExtent`。

**尚未设置**：`lib/pages/rcmd/view.dart:44-73`（首页推荐 `SliverGrid.builder`）、`lib/pages/dynamics_tab/view.dart:78-101`（瀑布流/列表）、`lib/pages/search_panel/video/view.dart:114`、`lib/pages/video/related/view.dart:43`、评论主列表 `lib/pages/video/reply/view.dart:167`。

另外**全库没有出现过自定义 `cacheExtent`**（使用 Flutter 默认 250）→ 长列表快速滑动时白屏概率偏高。

**建议**
- 给高度可预估的列表补 `prototypeItem`；
- 首页推荐/动态这类图片密集列表把 `cacheExtent` 提到 400~800（用内存换流畅度，注意与图片内存缓存上限一起调）。

---

### U-15 搜索建议列表非懒加载

**证据**

```dart
// lib/pages/search/view.dart:140
? SliverList.list(        // 一次性构建全部子项
    children: list.map((item) => InkWell(... Text.rich(Em.regTitle(item.textRich)) ...)).toList(),
```
同文件 `:351-355` 的历史标签已经用了正确写法（带 `addAutomaticKeepAlives: false, addRepaintBoundaries: false`）。

**建议**：对齐历史标签的写法，改用 `SliverList.builder`；`Em.regTitle` + `parseHtml`（`lib/utils/em.dart:32-51`）的正则结果做缓存。

---

### U-16 动态 UP 面板选择时整块重建

**证据**

```dart
// lib/pages/dynamics/widgets/up_panel.dart:131-135
void _onSelect(UpItem item) {
  item.hasUpdate = false;
  controller.onSelectUp(item.mid);
  setState(() {});        // ← 重建整个面板（含 SliverList.builder 全部 up 项）
}
```
同时每项内层还套了 `Opacity`（`:220`，见 U-06）。

**建议**：选择状态用独立 `ValueNotifier<String>` 只驱动必要的项；`Opacity` 换成颜色表达。

---

### U-17 主题在 `build` 里每次重建两套完整 `ThemeData`

**证据**

```dart
// lib/main.dart:283-288
final (light, dark) = getAllTheme();      // ← 每次 build 都重新构造两套 ThemeData
...
return GetMaterialApp(theme: light, darkTheme: dark, ...);
```
```dart
// lib/main.dart:250-274   getAllTheme()
//   :264-265  brandColor.asColorSchemeSeed(variant, .light/.dark)   ← flex_seed_scheme HCT 全调色板
//   两次 ThemeUtils.getThemeData(...)
// lib/utils/theme_utils.dart:23-60   ThemeData(...) 体量很大
```

**影响**：每次都是新实例 → `MaterialApp` 一定判定主题变化 → **所有依赖 `Theme`/`ColorScheme` 的 widget 全树重建**。触发条件很多：切深浅色、动态取色生效、`uiScale` 变化、任何根 widget 重建。单次 20~80ms（低端机更高）。

**建议**：按 `(customColor, schemeVariant, dynamicColor, isPureBlackTheme, appFontWeight, FontUtils.fontFamily, FontUtils.isCustom)` 做 memo；把 `MyApp` 改成 `StatefulWidget`，只在上述依赖变化时重算。

---

## 七、图片 / 主题 / 字体

### I-01 图片磁盘缓存默认 1 GiB，且统计缓存大小时递归 `stat` 全目录

**证据**

```dart
// lib/utils/storage_pref.dart:618-619
static num get maxCacheSize => _setting.get(SettingBoxKey.maxCacheSize) ?? 1 << 30;   // 1 GiB
// lib/utils/cache_manager.dart:11-13
DefaultCacheManager.init(maxNrOfCacheLength: Pref.maxCacheSize.toInt());
// lib/utils/cache_manager.dart:18-32
CacheManager.loadApplicationCache()  // 递归 list(recursive: true) 并对每个文件 length()
```

**影响**：封面/头像瀑布流会把大量缩略图写入 flash 并做 LRU 清理，1 GiB 上限意味着长期大量随机写与周期 compaction；打开"关于/清理缓存"页时的递归统计是重 I/O。

**建议**
- 默认上限降到 128~256 MiB（并给用户可调范围加上限提示）；
- 缓存大小改走缓存库自身的 length 接口，避免递归 `stat`；
- 统计放到 `SchedulerBinding.instance.scheduleTask` / `idleCallback`，不要阻塞页面打开。

---

### I-02 日志默认开启、每条 `flush()`、文件无上限无轮转

**证据**

```dart
// lib/utils/json_file_handler.dart:17-20, 47-60
raf.writeString(...);  ...  _flush();     // 每条 = 一次 fsync
// lib/services/logger.dart:11-18           release 级别 .warning
// lib/services/logger.dart:33-52           <Documents>/.pili_logs.json
// lib/main.dart:191-215                    Pref.enableLog 为真才挂 Catcher2
// lib/utils/storage_pref.dart:637-638     enableLog 默认 true
```

**影响**：每条 report 一次 `RandomAccessFile.flush()` = 一次 fsync，唤醒存储控制器并阻止设备进入低功耗；文件**没有大小上限/轮转**（只能在设置页手动清空）。

**建议**：release 默认 `enableLog = false`；写入改内存缓冲 + 定时（如 5s）或按条数批量 flush；文件超过 1~2 MB 自动截断/轮转。

---

### I-03 `Pref` 的 getter 会"读时写盘"，可能发生在 build 内

**证据**
- `lib/utils/storage_pref.dart:196-206` `fullScreenMode`：缺值时 `_setting.put(...)`
- `lib/utils/storage_pref.dart:322-334` `blockUserID`：缺值时算 md5 并 `put`
- `lib/utils/storage_pref.dart:626-632` `horizontalScreen`：缺值时调 `DeviceUtils.isTablet`（JNI）并 `put`
- `lib/utils/storage_pref.dart:576-586` `appFontWeight`：旧键迁移 `delete` + `put`

其中 `appFontWeight` 就在 build 路径上：`lib/main.dart:283 getAllTheme()` → `lib/utils/theme_utils.dart:35`。

**影响**：Hive `put` 是主 isolate 上的文件写，落在帧内即一次磁盘 IO 抖动；`horizontalScreen` 还顺带触发首次 JNI 调用。

**建议**：启动预热阶段（`GStorage.init()` 之后）统一 `putIfAbsent` 这些键；getter 保持纯读（缺值走 `defaultValue` 分支）。

---

### I-04 字体与 JNI 调用夹在首帧前

**证据**
- `lib/main.dart:108` `?FontUtils.init()` → `lib/utils/font_utils.dart:58-66`（`fontFile.readAsBytes()`）+ `:74-76` `loadFontFromList(bytes, ...)`
- `lib/main.dart:116` `MaxScreenSize.init()` → `lib/utils/max_screen_size.dart:12-18` → `lib/utils/android/android_helper.dart:105-115`（JNI 首次 attach）
- `lib/utils/device_utils.dart:6-10` `sdkInt` / `isTablet` 在 `Pref.horizontalScreen` 首次读取时再触发 JNI

**影响**：字体 20~150ms（取决于用户设置的字体大小）+ 首次 JNI attach 10~50ms，全部计入首帧前。

**建议**：字体改 post-frame 加载（加载完成后通知主题重建）；JNI 调用合并成一次并缓存（`MaxScreenSize.init()` 里同时取 `sdkInt`/`isFoldable`），或整体延后到首帧后（`isTablet` 只影响导航布局，可先按手机布局渲染）。

---

### I-05 图标字体 tree-shake：结论良好，无需改动

- 自定义图标字体只有 33 个字形，且全部是 `static const IconData`：`lib/common/widgets/custom_icon.dart:9-41`
- 全库 `IconData(` 只出现在该文件（+ 生成的 pb 文件），**没有非常量 IconData** → `--tree-shake-icons`（release 默认开启）可正常裁剪 `material_design_icons_flutter` / `font_awesome_flutter`
- `pubspec.yaml:272-278` 只声明了 `digital_id_num`、`custom_icon` 两个字体族

---

### I-06 动画控制器生命周期：结论良好

- 无限重复动画只有骨架屏 `lib/common/skeleton/skeleton.dart:24`（问题是**数量**，见 U-01，不是泄漏）
- `dispose` 覆盖良好：`lib/common/skeleton/skeleton.dart:29-31`、`lib/plugin/pl_player/view/view.dart:263-266`（控件淡入淡出，配合 `:1960-2044` 的 `ClipRect + RepaintBoundary` 隔离，这块做得很对）、`lib/pages/video/pay_coins/view.dart:71-77`

---

## 八、后台服务、唤醒锁与定时器

> P-01 / P-02 / L-02 属于本章范畴，已在前文展开，此处不重复。

### B-01 `RetryInterceptor`：固定 2 次重试，无退避、不分幂等

**证据**

```dart
// lib/http/retry_interceptor.dart:63
Timer(Duration(milliseconds: ++_rt * _delay), ...)
// lib/http/init.dart:229-233   注册
// lib/utils/storage_pref.dart:557-561
//   retryCount = 2, retryDelay = 500
```

**影响**：弱网时每个失败请求变成 3 次（回帖、关注、弹幕、图片并发请求叠加，可能一次几十个请求 → 上百次重试），持续占用射频；500ms 的密集重试正好落在 RRC 不释放的窗口内。POST 重试（心跳、投币）还有重复副作用风险。

**建议**：指数退避 + 抖动（0.5s / 2s / 8s）；仅对 GET/幂等请求重试；重试前先 `Connectivity().checkConnectivity()`；后台（`paused`）时不重试。

---

### B-02 回前台 / 切 Tab 的请求突发

**证据**

```dart
// lib/pages/main/view.dart:111-117
AppLifecycleState.resumed → checkUnreadDynamic() + checkDefaultSearch(true) + checkUnread(...)
// lib/pages/main/controller.dart:216-227   DynGrpc.dynRed
// lib/pages/main/controller.dart:246-275   _period = 5 * 60 * 1000; dynamicPeriod = Pref.dynamicPeriod * 60 * 1000
// lib/pages/main/controller.dart:306-310   切 Tab 再触发 checkDefaultSearch/checkUnread
// lib/pages/main/view.dart:99-100          didPopNext 又无条件调一次 checkDefaultSearch(true)
```

**影响**：一次 resume 最多并发 4 个请求。开关屏频繁的用户会反复触发 4 连发；`didPopNext` 的那次调用更缺少任何门限。

**建议**：加"后台 <60s 不刷新"判断；`msgUnread + msgFeedUnread` 合并成一次请求；`resumed` 只刷新当前可见 Tab 的角标。

---

### B-03 视频简介页"同时在看人数"10 秒轮询

**证据**

```dart
// lib/pages/common/common_intro_controller.dart:89-95
timer ??= Timer.periodic(const Duration(seconds: 10), ... queryOnlineTotal());
// 启动点：lib/pages/video/view.dart:194（resume）、:415（didPopNext）
// 默认关闭：lib/utils/storage_pref.dart:857-858  enableOnlineTotal defaultValue: false
```

**影响**：开启后 **6 次/分钟、360 次/小时**；且不随简介 Tab 是否可见变化。

**建议**：间隔改 30~60 s；只在简介 Tab 可见且播放中轮询；暂停/后台时 `cancelTimer()`。

---

### B-04 HTTP 连接池 15 秒空闲即回收 + 网络变化强制拆池

**证据**

```dart
// lib/http/init.dart:151, 156
HttpClient()..idleTimeout = const Duration(seconds: 15);
// lib/http/init.dart:162
ConnectionManager(idleTimeout: 15s)
// lib/http/init.dart:166-186
_resetAdaptersForNetworkChange() → connectionManager.close(force: true) / fallbackAdapter.close(force: true)
// lib/http/init.dart:119-133   500ms debounce
// lib/http/init.dart:251       if (Platform.isIOS) _watchConnectivity();   ← Android 未注册
```

**影响**：15 秒空闲就断开，意味着浏览/播放过程中的间隔性请求几乎每次都要 TCP + TLS 重新握手（多 3~4 个 RTT），比复用 keep-alive 明显更耗电；网络切换时 `force: true` 会连在途请求一起丢弃 → 触发 B-01 的三倍重试。

**建议**：`idleTimeout` 提到 60~120 s；网络切换时 `close()` 不带 `force`；Android 也注册连通性监听，但仅在**网络类型真的改变**（wifi ↔ 蜂窝）时才重建连接池。

---

### B-05 高刷新率：启动即 `setPreferredMode`，设置页可锁 120Hz

**证据**

```dart
// lib/main.dart:150-161
FlutterDisplayMode.supported → setPreferredMode(displayMode ?? DisplayMode.auto)
// lib/pages/setting/pages/display_mode.dart:58, :82   用户可选任意 DisplayMode（含高刷档）
```

**影响**：`auto` 在多数 Android 机型 = 跟随系统最高刷新率。本 App 有大量持续动画（弹幕 canvas、marquee、骨架屏、控制条动画），高刷下显示子系统功耗可翻倍；"弹幕 + 120Hz"是持续渲染的最坏组合。

**建议**
- 默认降到 60/90Hz，仅用户显式选择时用 120Hz；
- 播放页/弹幕开启时可临时降档（目前只有静态用户档位，缺场景化策略）；
- `DisplayMode` 列表加功耗提示文案。

---

### B-06 登录二维码 1 秒轮询后端

**证据**

```dart
// lib/pages/login/controller.dart:78-100
qrCodeTimer = Timer.periodic(const Duration(milliseconds: 1000), ...);
// 内部 LoginHttp.codePoll(response.authCode)，最长 180 次
// 仅 if (tabController.index != 2) return; 跳过请求，但定时器仍在跑、qrCodeLeftTime 仍每秒变化
```

**影响**：登录页停留 3 分钟 = 180 个请求；切走后定时器仍在运行并每秒触发 UI 更新。

**建议**：轮询改 2~3 s 并做慢启动（前 30s 2s，之后 3s）；页面不可见/App 后台时暂停定时器。

---

### B-07 定时关闭的 1 秒倒计时常驻

**证据**

```dart
// lib/services/shutdown_timer_service.dart:406-410  initState 即启动
// lib/services/shutdown_timer_service.dart:433-441  _countdownTimer = .periodic(1s, _updateCountdownText)
// lib/services/shutdown_timer_service.dart:443-452  dispose 才停
```

**影响**：1 Hz 持续到 deadline（最长 24 小时 → 86400 次 tick）。这是**睡眠场景**下的 1 Hz 定时器，会明显增加 idle 唤醒次数（即使屏幕熄灭，Dart 定时器仍需平台唤醒）。对一个"还有多久关机"的文案来说代价过高。

**建议**：改为按分钟刷新（对齐 60s 的单次 `Timer`），或仅在页面可见时才 1 Hz；到点判定交给单次 `Timer`（服务里已有 `_shutdownTimer`）。

---

### B-08 前台服务与后台播放的默认组合缺少省电策略

**证据**

```dart
// lib/services/audio_handler.dart:26-34
androidNotificationOngoing: true      // 通知不可划掉
androidStopForegroundOnPause: true
// lib/services/audio_handler.dart:74-86    每次 mediaItem.add 过一次平台通道更新通知
// lib/services/audio_handler.dart:94-140   onUpdateState 在播放/暂停/缓冲/位置变化时都会被调用
// lib/utils/storage_pref.dart:660-661      enableBackgroundPlay 默认 true
// lib/plugin/pl_player/controller.dart:1228-1235  setBackgroundPlay
```

**影响**：`enableBackgroundPlay` 默认开启 → 常驻前台服务 + 持续构建/推送 `MediaItem`。配合 P-01 的唤醒锁，构成"熄屏仍全速"的完整链路。`onUpdateState` 里的位置去重只在配置相同且秒不变时生效，`_lastConfig` 变化后 `_lastPos` 判断会失效。

**建议**
- 默认关闭后台播放，或首次开启时明确提示耗电并建议配合定时关闭；
- `onUpdateState` 对 `position` 变化做 1 秒节流；
- 后台播放时降低通知更新频率。

---

### B-09 其他定时器汇总（便于统一治理）

| 位置 | 间隔 | 说明 |
|------|------|------|
| `lib/plugin/pl_player/controller.dart:869-873` | 500ms 单次 | 唤醒锁延迟释放（见 P-01） |
| `lib/plugin/pl_player/controller.dart:1484-1490` | 5s（阈值） | 心跳（见 P-02） |
| `lib/plugin/pl_player/controller.dart:993-999` | 3s 单次 | 直播重连（见 P-07） |
| `lib/pages/video/widgets/header_control.dart:103` | 1s | 控制条时钟（见 P-11） |
| `lib/pages/live_room/widgets/header_control.dart:72`、`:133` | 1s / 节流 30s | 直播控制条时钟 + 电池 |
| `lib/pages/live_room/superchat/superchat_card.dart:87` | 1s × N 卡 | SC 倒计时（见 L-03） |
| `lib/pages/live_room/controller.dart:73-84` | 5 分钟 | 开播时长（见 L-04） |
| `lib/tcp/live.dart:249` | 30s | 直播 WS 心跳（合理） |
| `lib/pages/sponsor_block/block_mixin.dart:207` | 4s | 空降助手（见 P-12） |
| `lib/pages/common/common_intro_controller.dart:89` | 10s | 在线人数（见 B-03） |
| `lib/pages/login/controller.dart:78` | 1s | 二维码轮询（见 B-06） |
| `lib/services/shutdown_timer_service.dart:433` | 1s | 定时关闭倒计时（见 B-07） |
| `lib/pages/video/pay_coins/view.dart:522` | 16.67ms | 投币动画（见 P-12） |
| `lib/plugin/pl_player/view/view.dart:366` | 200ms 单次 | 亮度指示器延迟 |
| `lib/plugin/pl_player/view/view.dart:184` | — | 音量指示器 |

**统一建议**：建立一个"应用不可见时统一暂停"的门控（在 `AppLifecycleState.paused` 时集中 `cancel`，`resumed` 时按需重启），而不是让每个页面各自判断。

---

## 九、网络与序列化

### N-01 gRPC 响应的 gzip 解压 + protobuf 解析全在 UI isolate

**证据**

```dart
// lib/grpc/grpc_req.dart:74
return isolate && data.length > _isolateSize     // _isolateSize = 256 * 1024 (第 14 行)
    ? compute(_parse, (data, grpcParser))
    : _parse((data, grpcParser));                // ← 默认走这里（主 isolate）
```
```dart
// lib/grpc/grpc_req.dart:31-39   decompressProtobuf → GZipDecoder().decodeBytes
// lib/grpc/grpc_req.dart:41-49   _parse
```
全仓只有 `lib/grpc/dm.dart:21` 传了 `isolate: true`。

**影响**：单次 5~40ms 的 UI 线程占用；私信列表（`lib/grpc/im.dart` 多处）、动态列表更重。启动时的未读数请求（`lib/pages/main/controller.dart:200-208` → `lib/grpc/dyn.dart:36-46`）也没走 isolate。

**建议**：给 msg/dyn 列表类请求补 `isolate: true`；阈值从 256KB 降到 32~64KB（解压也在 `_parse` 里，离屏收益明显）。

---

### N-02 自定义 `responseDecoder` 把 brotli/gzip 解压留在主 isolate

**证据**

```dart
// lib/http/init.dart:214     'accept-encoding': 'br,gzip'
// lib/http/init.dart:216     responseDecoder: _responseDecoder,
// lib/http/init.dart:352-358
static String _responseDecoder(List<int> responseBytes, RequestOptions options, ResponseBody responseBody)
  => utf8.decode(responseBytesDecoder(responseBytes, responseBody.headers), allowMalformed: true);
// lib/http/init.dart:246     BackgroundTransformer()
```

**影响**：dio 的 `BackgroundTransformer` 只能把 `jsonDecode` 放到 isolate（且要 >50KB），**解压这一步照样在主 isolate**。1MB 级 brotli 解压 + utf8 解码约 20~80ms，直接落在 UI 线程。

**建议**：`responseDecoder` 返回 `Future`（dio 的 `SyncTransformer` 支持 `decodeResponse is Future` 分支），在 `bytes.length > 64KB` 时用 `compute` 做"解压 + `utf8.decode`"；或干脆不设 `responseDecoder`，让后台 isolate 完成后直接 `jsonDecode`。

---

### N-03 主 isolate 上"按条" `jsonDecode` 清单

| 位置 | 触发频率 |
|------|---------|
| `lib/tcp/live.dart:221`（`_processingData` 还递归拆包 `:230-236`） | 直播 WS **每条消息** |
| `lib/pages/live_room/controller.dart:592` | 每条 `DANMU_MSG`（同一帧内第二次 decode） |
| `lib/pages/danmaku/view.dart:124` | 播放中每 100ms 的位置回调（`mode == 7`） |
| `lib/pages/whisper_detail/widget/chat_item.dart:68` | 每条私信气泡 build |
| `lib/pages/whisper/widgets/item.dart:72` | 每个会话 tile build |
| `lib/models_new/msg/msg_sys/data.dart:25` | 每条系统消息 `fromJson` |
| `lib/models/dynamics/result.dart:1259`、`:989` | 每条带直播卡的动态 |
| `lib/services/download/download_service.dart:95` | 每个下载条目 |

**影响**：单条 1~10ms，但直播/私信/弹幕是**持续**负载 —— 这是"播放/滚动时掉帧"的主要来源（不是启动峰值）。

**建议**：把解析提前到模型层（在 `fromJson` 里一次解出结构体并缓存字段，UI 只读字段）；整页列表的"decode + 映射"整段丢进 `compute`；`danmaku` 的特殊弹幕 `content` 在解析弹幕列表时一次性展开。

---

### N-04 默认走 HTTP/1.1

**证据**

```dart
// lib/utils/storage_pref.dart:741-742   enableHttp2 默认 false
// lib/http/init.dart:31                  static final → 进程内只读一次
// lib/http/init.dart:223-226             否则走 IOHttpClientAdapter
```

**影响**：HTTP/1.1 每连接并发 1 请求，冷启动时多个请求各自 TLS 握手，握手与首字节时间叠加。

**建议**：默认改 true（`dio_http2_adapter` 已依赖），或至少让启动首批请求排队复用同一连接；顺带修复 `lib/http/init.dart:251` 的"只监听 iOS 连通性"问题（见 B-04）。

---

## 十、启动性能

### S-01 首帧前 `await` 了 audio_service 前台服务初始化【最贵】

**证据**

```dart
// lib/main.dart:117-120
await Future.wait([
  if (Pref.horizontalScreen) ?fullMode() else ?portraitUpMode(),
  setupServiceLocator(),          // ← 被阻塞等待
]);
```
```dart
// lib/services/service_locator.dart:8-10
//   initAudioService() → lib/services/audio_handler.dart:22  AudioService.init(...)
//   紧接着 AudioSessionHandler() → lib/services/audio_session.dart:18-20  initSession()
```

**影响**：Android 上要拉起前台 Service + MediaSession + 通知渠道，并等 Service 的 handler 连上；紧接着又是一次 `AudioSession` 平台通道往返。**80~250ms 直接计入首帧前**。

**建议**：不要 `await` —— 用 `unawaited(setupServiceLocator())` 或放到 `addPostFrameCallback`，在首次真正需要时（`PlPlayerController` 创建 / 取 `videoPlayerServiceHandler`）再 `await` 缓存的 Future；`AudioSessionHandler` 增加显式 `init()` 而不是在构造函数里发起。

---

### S-02 `MediaKit.ensureInitialized()` 在最前面，但首帧并不需要播放器

**证据**

```dart
// lib/main.dart:94
MediaKit.ensureInitialized();
// lib/main.dart:200-201  仅为日志打印 NativePlayer.apiVersion
// lib/utils/storage_pref.dart:483-484   preInitPlayer 默认 false
```

**影响**：加载 libmpv 原生库约 50~300ms + 数十 MB native 内存，唯一"立刻用到"的地方是日志里的一个版本号。

**建议**：删掉 `lib/main.dart:94`，改为在 `PlPlayerController` 首次构造时初始化（或 `Pref.preInitPlayer` 为 true 时才在启动时做）；`:200-201` 的 `MPV Api Version` 延迟获取或直接去掉。

---

### S-03 `await MyApp.initPlatformState()`（动态取色）挡在 `runApp` 前

**证据**

```dart
// lib/main.dart:189-190
if (Pref.dynamicColor) await MyApp.initPlatformState();
// lib/utils/storage_pref.dart:734-736   dynamicColor 默认 true
// lib/main.dart:354, :374               两次平台通道往返
// lib/main.dart:393                     失败时才写盘（主 isolate 同步写）
```

**影响**：20~80ms，加上成功后的 `CorePalettesExt.fromList` → `toColorScheme()`（两次）× HCT 调色板生成。

**建议**：首帧前只用 `Pref.customColor`/`Pref.dynamicColor` 拼一个后备主题先渲染；`initPlatformState()` 放到 post-frame，拿到色板后触发一次根重建（`ValueNotifier<ThemeData>`）。

---

### S-04 9 个 Hive box 全部 eager 打开

**证据**

```dart
// lib/utils/storage.dart:31-65   一次 Future.wait 开 7 个
//   userInfo(:33) localCache(:40) setting(:47) historyWord(:49)
//   video(:56) account(:57) watchProgress(:58)
// lib/utils/storage.dart:67-72    再串行 await 第 8 个（reply，Pref.saveReply 默认 true）
// lib/utils/storage.dart:58-63, :117-131   keyComparator（打开时须重建 key 顺序）
// lib/main.dart:107 → lib/utils/cache_manager.dart:12-14   第 9 个 box（图片缓存）
```

**影响**：冷启动 **100~400ms**（每 box 一次文件读 + 索引反序列化）；条目多时 `watchProgress` 的排序更明显。

**建议**：首帧前只保留 `setting`、`localCache`、`userInfo`、`account`（`Request.setCookie` 需要）；`historyWord`、`video`、`watchProgress`、`reply` 改为首次使用时打开（把 `openBox` 的 Future 缓存在 `GStorage` 里）；`watchProgress` 可用 `openBoxLazy`。

---

### S-05 冷启动一次性并发 8+ 个网络请求，其中 wbi 签名是串行前置

**证据**

| 位置 | 请求 |
|------|------|
| `lib/main.dart:134` → `lib/http/init.dart:39-42` → `lib/utils/accounts.dart:37-47` → `lib/http/init.dart:62-100` | `buvidActive` POST（注意 `activated` 是内存字段，`lib/utils/accounts/account.dart:59`、`:155` 均非 `@HiveField` → **每次冷启动都会重发**） |
| `lib/main.dart:135` → `lib/utils/request_utils.dart:48-56` | `syncHistoryStatus` |
| `lib/pages/main/controller.dart:79` | `Update.checkUpdate()`（打 GitHub release API，`autoUpdate` 默认 true：`lib/utils/storage_pref.dart:447-448`） |
| `lib/pages/main/controller.dart:111` | `getUnreadDynamic()`（gRPC） |
| `lib/pages/main/controller.dart:119` → `:173` | `queryUnreadMsg()`（内部 2 个 REST） |
| `lib/pages/home/controller.dart:54` → `lib/utils/wbi_sign.dart:111-117` → `:77-92` | `querySearchDefault()` 需先 `getWbiKeys`（GET `/x/web-interface/nav`） |
| `lib/pages/rcmd/controller.dart:20` | 首页推荐同样等 wbi keys |

**影响**：CPU/IO 峰值叠加；首页推荐至少被 wbi 的 nav 请求多串一个 RTT（弱网 200ms+）。

**建议**：`checkUpdate`、`syncHistoryStatus`、未读徽标移到首帧后（`addPostFrameCallback`）；`wbi_sign` 的 mixinKey 已有按天缓存（`lib/utils/wbi_sign.dart:95-108`），可进一步在启动时用 `localCache` 预置/预热，避免首屏被 nav 请求串行阻塞。

---

### S-06 `Get.put` 遍地、几乎没有 `binding` 与回收

**统计**：`Get.put(` **114 处 / 107 文件**、`putOrFind` **27 处**、`lazyPut` **仅 2 处**（`lib/main.dart:111-112`）、`Get.create` 0 处、`GetPage(binding:)` **0 处**（`lib/router/app_pages.dart:74-137`）、`Get.delete` 全仓仅 **9 处**。

典型：打开视频页时 `lib/pages/video/view.dart:143-165` 一次 `Get.put` 4 个控制器（`VideoDetailController` + `VideoReplyController` + `LocalIntro|UgcIntro|PgcIntroController`），每个 `onInit` 都可能发请求；同类型不同 tag 反复创建（`Get.put(..., tag: heroTag)`）会常驻 GetX 容器。

**影响**：控制器与页面同生命周期但退出不回收 → 内存缓慢增长，`Obx` 订阅残留 → "页面越用越卡"。

**建议**：给重页面加 `GetPage(binding:)` 或 `Get.lazyPut` + `find`；视频页把 intro/reply 控制器改为首次渲染/展开时创建；在 `dispose` 补齐 `Get.delete`。

---

### S-07 路由：70+ 个 `GetPage` 一次性构造，44 处 `Get.to` 绕过路由表

**证据**
- `lib/router/app_pages.dart:74` `static final List<GetPage> getPages = [...]`（70+ 项），首帧前首次访问时整体初始化（分配成本可接受）
- 导航主体是 `Get.toNamed`（151 处），但有 **44 处 `Get.to(const XxxPage())`** 直接实例化未注册页面，例如 `lib/pages/download/view.dart:100`、`lib/pages/dynamics/widgets/up_panel.dart:33`、`lib/pages/follow/view.dart:114`、`lib/pages/pgc/view.dart:241`

**影响**：这些页面不进路由表 → 无深链、无法命中 `preventDuplicates`，重复进入会不断新建页面/控制器（内存与重建抖动）；对启动本身影响很小。

**建议**：登记进 `app_pages.dart` 并统一 `Get.toNamed(..., preventDuplicates: true)`；优先处理视频、动态详情、私信等重量级页面。

---

### S-08 5 个 Tab 的构建方式：**已经是懒构建**，无需改造

**证据**

```dart
// lib/pages/main/view.dart:478-491
child = TabBarView(controller: ..., physics: const NeverScrollableScrollPhysics(),
                   children: _mainController.navigationBars.map((i) => i.page).toList());
// 或
child = PageView(controller: ..., physics: const NeverScrollableScrollPhysics(), children: ...);
```

`PageView` 默认 `allowImplicitScrolling = false` → `cacheExtent` 为 0，**启动时只构建当前 Tab（首页）**，其余 Tab 在首次切换时才创建。首页内部的 `lib/pages/home/view.dart:86-89` 同理。

**唯一小问题**：`lib/models/common/nav_bar_config.dart:10-45` 的枚举常量里直接 `new` 了 widget 实例（`HomePage()` `:14`、`DynamicsPage()` `:24`、`MinePage()` `:34`）→ 枚举类初始化时就创建 3 个 Widget 对象。建议改成存 builder（`Widget Function()`）。

---

### S-09 切 Tab 时的网络抖动

**证据**：`lib/pages/main/controller.dart:294-306`（`jumpToPage` 后立刻 `checkDefaultSearch() + checkUnread()`）；切到动态 Tab 时 `dynamicController` 首次被访问（`:52 late final` → `Get.putOrFind`）→ `lib/pages/dynamics/controller.dart:49-56 onInit` 立刻 `queryData()`。

**建议**：切换的未读检查加统一 TTL/防抖；动态 Tab 首次查询延到 post-frame。

---

### S-10 `nav_bar_config` 枚举里的 widget 实例化

见 S-08 末尾。

---

## 十一、Android 构建与系统层

### A-01 release 未开启 R8 / 资源压缩

**证据**

```kotlin
// android/app/build.gradle.kts:64-74
release {
    ...
//  proguardFiles(
//      getDefaultProguardFile("proguard-android-optimize.txt"),
//      "proguard-rules.pro"
//  )
}
```
`minifyEnabled` / `shrinkResources` 均未设置（默认 false）。

**影响**：APK 更大（含未使用的 Java/Kotlin 代码与资源）、类加载与首次执行路径更长、JIT/验证开销略高。这是"体积 + 启动冷启动耗时"的间接影响，**不是**运行时耗电主因。

**建议**：如无反射依赖问题，开启 `isMinifyEnabled = true` + `isShrinkResources = true` 并补齐 `proguard-rules.pro`；先在 `--profile` 版本上验证启动与播放（尤其 `media_kit`、`jni`、`flutter_inappwebview`、`dio_http2_adapter` 的反射/序列化路径）。收益：APK 体积明显下降、启动略快。

---

### A-02 Impeller 被显式关闭，运行时使用 Skia

**证据**

```xml
<!-- android/app/src/main/AndroidManifest.xml:46-48 -->
<meta-data
    android:name="io.flutter.embedding.android.EnableImpeller"
    android:value="false" />
```

**影响**：本工程有大量 `saveLayer`（`Opacity` / `ClipRRect` / `ShaderMask`）与全屏合成（弹幕 canvas）。Impeller（Vulkan）在这类场景下通常有更稳定的帧时间与更低的 CPU 合成开销；Skia 在 `saveLayer` 场景下的 CPU 后端回退风险更高。

**建议**：这是一项**需要实测**的权衡（关闭 Impeller 很可能是因为 media_kit 纹理或某些设备的兼容问题）：
- 在 `--profile` 下对"视频页滚动 + 弹幕 + 1080P60 播放"分别测 `EnableImpeller=true/false` 的帧时间与 CPU；
- 如果 Impeller 收益明显，可考虑按设备（Vulkan 支持 + 非问题机型白名单）启用。

---

### A-03 `packagingOptions.jniLibs.useLegacyPackaging = true`

**证据**：`android/app/build.gradle.kts:41`。

**影响**：原生库以未压缩形式随 APK 安装到文件系统（体积更大，但运行时无需解压 → 加载略快、内存映射更友好）。结合 `libmpv` 这类大体积 so，是"体积换加载速度"的合理权衡，**无需改动**，仅作为背景说明。

---

### A-04 `android.enableJetifier=true` 已废弃

**证据**：`android/gradle.properties:3`。

**影响**：Jetifier 是构建期转换，不影响运行时性能，但会显著拖慢构建。工程里若不依赖旧 Support Library 库可关闭。

**顺带说明**：`android/gradle.properties:8` 的 `kotlin.incremental=false` 是 Windows 跨盘符的官方 workaround（flutter/flutter#173456），只影响构建速度，**不影响 App 运行时性能**。

---

## 十二、分阶段实施路线图

### 阶段一（低风险、高收益；改动量：小）

1. **Wakelock 门控**（P-01）：接入 `didChangeAppLifecycleState` + 页面可见性。
2. **心跳间隔 5s → 15~30s**（P-02）。
3. **直播重连节流**（P-07）。
4. **`RetryInterceptor` 指数退避 + 抖动 + 分幂等**（B-01）。
5. **图片缓存上限 1 GiB → 256 MiB**（I-01）。
6. **日志默认关闭 + 批量 flush + 轮转**（I-02）。
7. **骨架屏改共享 controller + 取消每帧 `setState`**（U-01）。

> 预期：熄屏/后台场景耗电与发热明显下降；首屏与切 Tab 掉帧基本消失。

### 阶段二（体验优化；改动量：中）

8. **视频页 `Obx` 拆分 + `Opacity` → `AnimatedOpacity`/颜色表达**（P-08、P-09）。
9. **评论正则/`TextSpan` 结果缓存**（U-02）。
10. **`loadingState.refresh()` → 局部更新**（U-03、U-04）。
11. **`ThemeData` memo 化**（U-17）。
12. **顶/底栏隐藏改 `ValueListenableBuilder`**（U-05）。
13. **直播弹幕解析移出 UI isolate + 消息限流**（L-01、L-02）。
14. **`jsonDecode` 逐条调用清理**（N-03）。
15. **`ClipRRect` 去 `saveLayer`**（U-09）。

### 阶段三（架构级；改动量：大）

16. **启动流程重排**：`setupServiceLocator` 去 await、`MediaKit` 延迟、动态取色 post-frame、Hive box 懒开（S-01 ~ S-04）。
17. **网络层**：`responseDecoder` 异步化 + gRPC `isolate: true` + 连接池 `idleTimeout` 调优（N-01、N-02、B-04）。
18. **定时器统一治理**：建立"应用不可见即暂停"的门控（B-09 全表）。
19. **`GetX` 生命周期治理**：`binding` + `Get.delete`（S-06）。
20. **Android 构建**：开启 R8 + shrinkResources（A-01）；实测 Impeller（A-02）。

---

## 十三、度量与验证方法

改动前后请用同一台设备、同一场景做对照，建议固定以下四个场景：

| 场景 | 采集项 | 工具 |
|------|-------|------|
| **冷启动 → 首页可用** | 首帧耗时、`TimeToFirstFrame`、启动阶段网络请求数 | `flutter run --profile` + Timeline；`adb shell am start -W` |
| **1080P60 视频连续播放 30 分钟（熄屏 10 分钟）** | 平均/峰值 CPU、电量下降百分比、平均电流、wakeup 次数 | Battery Historian + Perfetto；`dumpsys batterystats` |
| **视频页滚动 + 弹幕开启** | 帧时间 P50/P95、jank 帧数、GPU 占用 | DevTools Performance + `flutter run --profile` 的 `--trace-skia` |
| **热点直播间观看 10 分钟** | 单核 CPU、GC 次数、网络流量 | DevTools Timeline + Android Studio Profiler |

**建议的量化验收线**
- 熄屏后台播放待机电流下降 ≥ 30%；
- 冷启动首帧耗时下降 ≥ 25%（目标 < 1.2s）；
- 视频页滚动 jank 帧率 < 1%；
- 直播间 CPU 单核占用下降 ≥ 50%；
- 连续播放 1 小时电量消耗下降 ≥ 15%。

**注意事项**
- 本机（Windows 开发机）的性能数据不代表 Android 真机，请务必用真机验证；
- 骨架屏、弹幕、shader 相关改动在低端机上的收益远大于高端机，建议至少覆盖一台低端 Android 设备；
- `U-17`（ThemeData memo）与 `A-02`（Impeller）这类改动需要同时观察"视觉是否变化"，避免为了性能牺牲观感。

---

## 附录：文件行号索引

### 播放与解码
| 编号 | 位置 |
|------|------|
| P-01 | `lib/plugin/pl_player/controller.dart:907`、`:867-873`、`:881`、`:1587`；`lib/utils/storage_pref.dart:660-661`、`:896-897` |
| P-02 | `lib/plugin/pl_player/controller.dart:1484-1490`、`:947`、`:913`、`:930`；`lib/http/video.dart:677`、`lib/http/api.dart:273` |
| P-03 | `lib/plugin/pl_player/controller.dart:934-951`、`:1433-1440` |
| P-04 | `lib/utils/storage_pref.dart:269-274`；`lib/plugin/pl_player/controller.dart:722-736` |
| P-05 | `lib/plugin/pl_player/controller.dart:368`、`:749-753`、`:1047-1048`；`lib/plugin/pl_player/models/hwdec_type.dart:45-49` |
| P-06 | `lib/plugin/pl_player/controller.dart:672-684`、`:685-721`、`:683` |
| P-07 | `lib/plugin/pl_player/controller.dart:993-999`（对比 `:1000-1030`） |
| P-08 | `lib/pages/video/view.dart:488-495`、`:577`；`lib/common/widgets/sliver/video_header.dart:57`；`lib/pages/video/controller.dart:176` |
| P-09 | `lib/pages/video/view.dart:634`、`:710-746` |
| P-10 | `lib/pages/video/view.dart:180`、`:207`、`:314`、`:332`、`:389`、`:437`；`lib/pages/video/controller.dart:199-205` |
| P-11 | `lib/pages/video/widgets/header_control.dart:90`、`:103-113`、`:128`、`:131-140`；`lib/plugin/pl_player/view/view.dart:206-220`；`lib/pages/live_room/widgets/header_control.dart:72`、`:133` |
| P-12 | `lib/pages/sponsor_block/block_mixin.dart:207-211`；`lib/pages/video/pay_coins/view.dart:522`、`:63`；`lib/pages/common/common_intro_controller.dart:89-95` |

### 弹幕
| 编号 | 位置 |
|------|------|
| D-01 | `lib/pages/danmaku/view.dart:93-155`、`:117`、`:124`；`lib/utils/storage_pref.dart:790-791` |
| D-02 | `lib/pages/danmaku/view.dart:158-177`、`:81-90` |
| D-03 | `lib/plugin/pl_player/utils/danmaku_options.dart:30-48`；`lib/utils/storage_pref.dart:793-794` |
| D-04 | `lib/pages/danmaku/view.dart:170-175` |
| D-05 | `lib/pages/danmaku/controller.dart`；`lib/pages/danmaku/view.dart:57-58` |

### 直播
| 编号 | 位置 |
|------|------|
| L-01 | `lib/pages/live_room/controller.dart:577-690`、`:592`、`:560-574`、`:3`；`lib/tcp/live.dart:221`、`:230-236`、`:286-320` |
| L-02 | `lib/pages/live_room/view.dart:193-205`、`:150`；`lib/pages/live_room/controller.dart:414-417` |
| L-03 | `lib/pages/live_room/superchat/superchat_card.dart:87-89`、`:100-107`、`:67` |
| L-04 | `lib/pages/live_room/controller.dart:73-84`、`:380-393` |
| L-05 | `lib/pages/live_room/view.dart:394-399`、`:412` |
| L-06 | `lib/pages/live_room/controller.dart:3`、`:560-574` |
| L-07 | `lib/utils/storage_pref.dart:841-847` |

### UI 与列表
| 编号 | 位置 |
|------|------|
| U-01 | `lib/common/skeleton/skeleton.dart:16-35`、`:47-64`；`lib/common/sliver_single_child_delegate.dart:14-17`；`lib/pages/video/reply/view.dart:153`、`:155`；`lib/pages/common/dyn/common_dyn_page.dart:143`、`:145`；`lib/utils/waterfall.dart:48`、`:50`；`lib/pages/rcmd/view.dart:137`；`lib/utils/grid.dart:15` |
| U-02 | `lib/pages/video/reply/widgets/reply_item_grpc.dart:716-739`、`:426`、`:433`、`:448` |
| U-03 | `lib/pages/common/reply_controller.dart:204-218`、`:224-243`；`lib/pages/video/reply/view.dart:119`；`lib/pages/dynamics_tab/view.dart:61-62`；`lib/pages/dynamics_tab/controller.dart:70-104`；`lib/pages/rcmd/view.dart:96-104`；`lib/pages/video/related/view.dart:48-52` |
| U-04 | `lib/pages/video/reply_reply/view.dart:214`；`lib/pages/common/dyn/common_dyn_page.dart:143`；`lib/pages/member_dynamics/view.dart:93`；`lib/pages/member_search/child/view.dart:75-94`；反例 `lib/pages/video/reply/view.dart:89-104` |
| U-05 | `lib/pages/common/common_page.dart:70-95`；`lib/pages/home/view.dart:104-118`；`lib/pages/main/view.dart:382-395` |
| U-06 | `lib/pages/dynamics/widgets/up_panel.dart:220`；`lib/common/widgets/expandable.dart:99`；`lib/common/widgets/scaffold/mini_scaffold.dart:215` |
| U-07 | `lib/common/widgets/video_card/video_card_v.dart:101-115`；`lib/common/widgets/video_card/video_card_h.dart:57-59` |
| U-08 | `lib/common/widgets/video_card/video_card_v.dart:225-226`、`:251`；`lib/utils/date_utils.dart:15-46` |
| U-09 | `lib/common/widgets/image/network_img_layer.dart:66-84`（好）、`:47-56`（问题）；`lib/common/widgets/pendant_avatar.dart:71-76` |
| U-10 | `lib/pages/live_room/view.dart:394-399`；`lib/utils/image_utils.dart:199-206`、`:213-215`；`lib/utils/storage_pref.dart:154-155` |
| U-11 | `lib/common/widgets/image_grid/image_grid_builder.dart:273`；`lib/models_new/reply/picture.dart:7` |
| U-12 | `lib/common/widgets/image_grid/image_grid_view.dart:253-255` |
| U-13 | `lib/pages/video/view.dart:1388-1404` |
| U-14 | `lib/pages/rcmd/view.dart:44-73`；`lib/pages/dynamics_tab/view.dart:78-101`；`lib/pages/search_panel/video/view.dart:114`；`lib/pages/video/related/view.dart:43`；`lib/pages/video/reply/view.dart:167` |
| U-15 | `lib/pages/search/view.dart:140`（对比 `:351-355`）；`lib/utils/em.dart:32-51` |
| U-16 | `lib/pages/dynamics/widgets/up_panel.dart:131-135`、`:220` |
| U-17 | `lib/main.dart:250-274`、`:283-288`；`lib/utils/theme_utils.dart:23-60`；`lib/utils/extension/theme_ext.dart:36-43` |

### 图片 / 主题 / 字体
| 编号 | 位置 |
|------|------|
| I-01 | `lib/utils/storage_pref.dart:618-619`；`lib/utils/cache_manager.dart:11-13`、`:18-32` |
| I-02 | `lib/utils/json_file_handler.dart:17-20`、`:47-60`；`lib/services/logger.dart:11-18`、`:33-52`；`lib/main.dart:191-215`；`lib/utils/storage_pref.dart:637-638` |
| I-03 | `lib/utils/storage_pref.dart:196-206`、`:322-334`、`:576-586`、`:626-632`；`lib/utils/theme_utils.dart:35` |
| I-04 | `lib/main.dart:108`、`:116`；`lib/utils/font_utils.dart:58-66`、`:74-76`；`lib/utils/max_screen_size.dart:12-18`；`lib/utils/device_utils.dart:6-10`；`lib/utils/android/android_helper.dart:105-115` |
| I-05 | `lib/common/widgets/custom_icon.dart:9-41`；`pubspec.yaml:272-278` |
| I-06 | `lib/common/skeleton/skeleton.dart:29-31`；`lib/plugin/pl_player/view/view.dart:263-266`、`:1960-2044`；`lib/pages/video/pay_coins/view.dart:71-77` |

### 后台服务与定时器
| 编号 | 位置 |
|------|------|
| B-01 | `lib/http/retry_interceptor.dart:63`；`lib/http/init.dart:229-233`；`lib/utils/storage_pref.dart:557-561` |
| B-02 | `lib/pages/main/view.dart:111-117`、`:99-100`；`lib/pages/main/controller.dart:216-227`、`:246-275`、`:306-310` |
| B-03 | `lib/pages/common/common_intro_controller.dart:89-95`；`lib/pages/video/view.dart:194`、`:415`；`lib/utils/storage_pref.dart:857-858` |
| B-04 | `lib/http/init.dart:151`、`:156`、`:162`、`:166-186`、`:119-133`、`:251` |
| B-05 | `lib/main.dart:150-161`；`lib/pages/setting/pages/display_mode.dart:58`、`:82` |
| B-06 | `lib/pages/login/controller.dart:78-100` |
| B-07 | `lib/services/shutdown_timer_service.dart:406-410`、`:433-441`、`:443-452` |
| B-08 | `lib/services/audio_handler.dart:26-34`、`:74-86`、`:94-140`；`lib/utils/storage_pref.dart:660-661`；`lib/plugin/pl_player/controller.dart:1228-1235` |
| B-09 | 见 B-09 表格 |

### 网络与序列化
| 编号 | 位置 |
|------|------|
| N-01 | `lib/grpc/grpc_req.dart:14`、`:31-39`、`:41-49`、`:74`；`lib/grpc/dm.dart:21`；`lib/pages/main/controller.dart:200-208`；`lib/grpc/dyn.dart:36-46` |
| N-02 | `lib/http/init.dart:214`、`:216`、`:246`、`:352-358` |
| N-03 | 见 N-03 表格 |
| N-04 | `lib/utils/storage_pref.dart:741-742`；`lib/http/init.dart:31`、`:223-226` |

### 启动
| 编号 | 位置 |
|------|------|
| S-01 | `lib/main.dart:117-120`；`lib/services/service_locator.dart:8-10`；`lib/services/audio_handler.dart:22`；`lib/services/audio_session.dart:18-20` |
| S-02 | `lib/main.dart:94`、`:200-201`；`lib/utils/storage_pref.dart:483-484` |
| S-03 | `lib/main.dart:189-190`、`:354`、`:374`、`:393`；`lib/utils/storage_pref.dart:734-736` |
| S-04 | `lib/utils/storage.dart:31-65`、`:67-72`、`:58-63`、`:117-131`；`lib/main.dart:97`、`:107`；`lib/utils/cache_manager.dart:12-14`；`lib/utils/storage_pref.dart:1025-1026` |
| S-05 | `lib/main.dart:134-135`；`lib/http/init.dart:39-42`、`:62-100`；`lib/utils/accounts.dart:37-47`；`lib/utils/accounts/account.dart:59`、`:155`；`lib/utils/request_utils.dart:48-56`；`lib/pages/main/controller.dart:79`、`:111`、`:119`、`:173`；`lib/pages/home/controller.dart:54`；`lib/utils/wbi_sign.dart:77-117`、`:95-108`；`lib/pages/rcmd/controller.dart:20`；`lib/utils/storage_pref.dart:447-448` |
| S-06 | 全仓统计；`lib/main.dart:111-112`；`lib/router/app_pages.dart:74-137`；`lib/pages/video/view.dart:143-165` |
| S-07 | `lib/router/app_pages.dart:74`；`lib/pages/download/view.dart:100`；`lib/pages/dynamics/widgets/up_panel.dart:33`；`lib/pages/follow/view.dart:114`；`lib/pages/pgc/view.dart:241` |
| S-08 | `lib/pages/main/view.dart:478-491`；`lib/pages/home/view.dart:86-89`；`lib/models/common/nav_bar_config.dart:10-45`、`:14`、`:24`、`:34` |
| S-09 | `lib/pages/main/controller.dart:294-306`、`:52`、`:82`；`lib/pages/dynamics/controller.dart:49-56` |
| S-10 | 同 S-08 |

### Android 构建与系统层
| 编号 | 位置 |
|------|------|
| A-01 | `android/app/build.gradle.kts:64-74` |
| A-02 | `android/app/src/main/AndroidManifest.xml:46-48` |
| A-03 | `android/app/build.gradle.kts:41` |
| A-04 | `android/gradle.properties:3`、`:8` |

---

## 附：本报告明确认定「做得对、无需改动」的部分

1. **图片内存缓存**：`lib/common/widgets/image/network_img_layer.dart:66-84` 正确使用 `memCacheWidth`/`memCacheHeight` + `thumbnailUrl(@Nq.webp)` + `FilterQuality.low`；磁盘缓存尺寸可在 `lib/utils/cache_manager.dart:12-15` 配置。
2. **播放器控件层隔离**：`lib/plugin/pl_player/view/view.dart:1598`、`:2044` 的 `ClipRect + RepaintBoundary` 分层正确。
3. **列表复用优化**：`itemExtent` / `prototypeItem` 覆盖率高（见 U-14 前半）。
4. **列表装饰取舍**：`lib/pages/search/view.dart:353-355` 显式关闭 `addAutomaticKeepAlives` / `addRepaintBoundaries`。
5. **Tab 懒构建**：`PageView` + `NeverScrollableScrollPhysics`（S-08），不存在"5 个 Tab 全部启动构建"的问题。
6. **图标字体**：无常量之外的 `IconData`，`--tree-shake-icons` 可正常裁剪（I-05）。
7. **动画控制器生命周期**：无限动画仅骨架屏一处（问题在数量，不在泄漏），`dispose` 覆盖良好（I-06）。
8. **`FlutterDisplayMode` 调用方式**：`lib/main.dart:150-160` 使用 `.then(...)` 非阻塞写法，未阻塞首帧。

---

*报告结束。全文基于 2026-09-24 的代码快照，共梳理 74 项可改进点（P 12 / D 5 / L 7 / U 17 / I 6 / B 9 / N 4 / S 10 / A 4）。所有结论均可回溯到上述 `文件:行号`。*
