# PiliPlus 针对 Android 17 + 小米 15（澎湃 OS 4）的可修改项清单

**性能与功能优化建议 · 只读分析 · 本文档不修改任何代码**

---

## 0. 文档信息与阅读方式

| 项目 | 内容 |
| --- | --- |
| 目标设备 | 小米 15（Snapdragon 8 Elite / Adreno 830，LTPO 1–120Hz，AMOLED） |
| 目标系统 | 澎湃 OS 4（基于 Android 17 / API 37） |
| 工程版本 | PiliPlus 3.0.1+1；Flutter 3.47.5；compileSdk / targetSdk = 37；AGP 9.0.1；Kotlin 2.3.20 |
| 分析方式 | 纯静态代码走查 + Android 官方行为变更逐条对照；**未运行 App、未修改文件** |
| 代码快照 | 2026-09-25（`lib/`、`android/`、`pubspec.yaml`） |
| 与已有报告的关系 | `perf-report/PiliPlus-Android.md` 已覆盖通用性能项（74 项）。本文**不重复其已完成部分**，聚焦「Android 17 行为变更」+「小米 15 / 澎湃 OS 4 机型与系统层」+「Android 专有代码（不含 iOS/桌面）」 |

### 实施状态（2026-09-25 更新）

本文档主体是建议清单；其中**「最要紧的三条」已按下述方式落地**（改动均带 Android 平台守卫，不影响 iOS / 桌面）：

| 条目 | 落地位置 | 实现要点 |
| --- | --- | --- |
| A17-02 本地网络权限 | `android/app/src/main/AndroidManifest.xml`、`lib/pages/dlna/view.dart` | 声明 `ACCESS_LOCAL_NETWORK`；`DeviceUtils.sdkInt >= 37` 时在搜索前申请；被拒时提示「打开设置」并区分「无权限」与「无设备」 |
| A17-01 后台音频加固 | `lib/services/audio_handler.dart`、`lib/plugin/pl_player/controller.dart`、`lib/services/audio_session.dart` | ① 播放前先把「播放中」状态推给 audio_service，让前台服务先于音频写入进入前台；② 打断结束后的自动续播，**仅 Android 17+** 在「应用不可见且前台服务未运行」时改为挂起，回到前台再续（Android 12–16 保持原有"打断结束即续播"，不回归） |
| A17-03 应用内存上限 | `lib/utils/memory_budget.dart`（新增）、`lib/main.dart`、`lib/utils/storage_pref.dart` | 按设备物理内存设图片缓存预算（低内存/&lt;4 GiB = 64 MiB、≥8 GiB = 192 MiB、其它 128 MiB），内存紧张时点播/直播解码缓冲减半 |

其余条目仍为待办。历史快照（阶段一）中已完成的项见第 5 节 PF-01，勿重复实施。

### 第二批实施状态（2026-09-25 更新）

> 正文条目未逐一加 ✅ 标记，以本表为准。

| 条目 | 落地位置 | 实现要点 |
| --- | --- | --- |
| **A17-06** 预测性返回 ✅ | `AndroidManifest.xml` | `enableOnBackInvokedCallback` 由 `false` 改为 `true`：Android 16+ 已强制、写 `false` 无任何效果，改为显式声明才能与真实行为一致（Flutter 也只有在该值为 true 时注册返回回调）。`BackDetector` 只是鼠标返回键监听，不受影响 |
| **A17-08** MessageQueue ⏳ 需真机回归 | 无代码改动 | 全仓无 `MessageQueue` 反射；release 也不挂性能监控 SDK（`enableLog` 默认 false）。回归清单见第 10 节 |
| **MI-02** 场景化刷新率 ✅ | 新增 `lib/utils/android/display_mode_utils.dart`；`play_settings.dart` 新增开关；`display_mode.dart` 联动 | 视频场景（`container-fps` ≤ 45）、低功耗、画中画时降到 60Hz 档，退出后恢复用户档位；默认不主动提升刷新率；帧率设置页打开期间暂停降档，避免把降档结果写回成"用户档位" |
| **MI-03** 通知权限 ✅ | `play_settings.dart` | 开启「后台音频服务」时申请 `POST_NOTIFICATIONS`（未授权时媒体控制条/锁屏控件不显示，用户会误判"后台播放无效"） |
| **MI-04** 低功耗降档 ✅ | 新增 `lib/services/power_save_watcher.dart`、`lib/utils/device_state.dart`；`AndroidHelper.java` 新增 `thermalStatus()` | 省电模式 / 未充电且 &lt;20% / 温控 ≥ MODERATE 判定为低功耗 → 刷新率 60Hz + 临时清空 glsl-shaders（不落盘改用户设置）+ 弹幕区域 ×0.6 且去描边 + 缓冲 ×0.75；仅应用可见时 3 分钟轮询 |
| **MI-08** 音频输出 ✅（默认值）/⏳ 取值仍建议实测 | `audio_output_type.dart`；`mpv_convert_webp.dart` | `ao` 默认顺序改为 **AAudio → AudioTrack → OpenSL ES**（OpenSL ES 已被官方标记待弃用）；顺带修掉转码路径 `no,auto-copy` 的无效拼接（会让 mpv 完全关掉硬解） |
| **PL-01** Impeller ✅（开关化） | `build.gradle.kts` + 清单占位符 | `android:value="${enableImpeller}"`，默认仍为关闭；A/B 只需 `flutter build apk --android-project-arg=enableImpeller=true`，无需改代码 |
| **PL-02** 输出后端 ✅（开关化） | `video_settings.dart` 新增「视频输出后端」；`controller.dart` 注入 mpv `opt` | 默认「不设置」= 完全沿用 mpv 默认（行为不变）；可选 `vo=gpu-next` / `vo=gpu-next,gpu-api=vulkan` 等，需重新打开视频生效 |
| **PL-04** AV1 / 硬解核验 ✅ | `header_control.dart` 播放信息面板 | 新增 `video-codec` / `container-fps` / `estimated-vf-fps` 三项，用来确认"是否真走硬解、是否为 AV1"。另核实：`lib/http/video.dart:102` 的 `fnval=976` **本身就包含 AV1 位(128)**，请求侧无需改动 |
| **PL-05** 硬解降级链 ✅ | `controller.dart` + `video_settings.dart` 开关 | 解码失败时运行时改 `hwdec` 并重新 `open`（mpv 无法热切换解码器）：`mediacodec-copy` → `auto-copy` → 软解；每部媒体最多 3 次、换片重置；默认开启可关闭 |
| **PL-06** 视频同步默认 ✅ | `storage_pref.dart` | Android 默认 `video-sync` 由 `display-resample` 改为 `audio`（设置项保留，可改回） |
| **PL-08** PiP 降载 ✅ | `AndroidHelper.java` + `MainActivity.kt` 新增 PiP 回调、`bindings.g.dart` 同步绑定、`power_save_watcher.dart` 消费 | PiP 进入/退出时切换刷新率档并临时关闭超分，退出后（非低功耗时）恢复 |

> 验证状态：`dart analyze lib` = **36 条 info、0 error / 0 warning**（与改动前基线一致，本次改动未新增任何 issue）；Dart/Java/Kotlin/Gradle/清单改动已用一次 release 构建验证。

### 标记说明

- **★ 数量**：优先级。`★★★` = 不做会出功能故障；`★★` = 收益明显；`★` = 优化项。
- **平台影响**：`仅 Android` = 改动落在 `android/` 目录，或用 `Platform.isAndroid` 守卫，**不会改变 iOS / 桌面行为**；`共享(lib/)` = 文件被多端共用，需加平台判断后再改。

### 关于「只修改影响 Android 的代码」

本工程 `lib/` 与 iOS / macOS / Windows / Linux 共用。要满足「只影响 Android」，有三种干净的落点：

1. **`android/` 目录**（清单、Gradle、`res/xml`、Kotlin/Java）—— 天然只影响 Android。
2. **`lib/` 中的平台守卫**：`if (Platform.isAndroid) ...`、`if (PlatformUtils.isMobile) ...`、`DeviceUtils.sdkInt`。
3. **播放器 mpv 参数**：集中在 `lib/plugin/pl_player/controller.dart:749-775` 的 `opt` map（该 map 已有 `if (Platform.isAndroid) 'ao': ...` 的平台守卫先例），新增项同样加守卫即可；Android 侧默认值集中在 `lib/utils/storage_pref.dart`。

---

## 1. 结论摘要

Android 17 + 澎湃 OS 4 对本 App 的影响可归为三条主线：

1. **后台音频被系统加固（最紧急）**。Android 17 起，音频框架限制"后台音频交互"；对 targetSdk 37 的应用，后台播放要求前台服务具备 **使用时（WIU）** 能力，否则音频会被**静默**掐断（不抛异常、无错误码）。本 App `enableBackgroundPlay` 默认开启，且 `libmpv` 走 NDK `AudioTrack.write`，正好落在受影响 API 清单里。
2. **本地网络权限强制（功能会直接坏）**。Android 17 对 targetSdk 37 应用强制 `ACCESS_LOCAL_NETWORK` 运行时权限，而本 App 有 **DLNA 投屏**（`dlna_dart` 的 SSDP 组播发现）——不加权限会"搜不到设备"。
3. **小米侧两件事：后台存活 + 刷新率策略**。澎湃 OS 4 的省电/冻结策略决定"后台播放能不能活"；LTPO 1–120Hz 决定"应用内钉死高刷会不会白烧电"。

| # | 建议项 | 预期收益 | 优先级 |
| --- | --- | --- | --- |
| 1 | 后台音频加固适配：FGS 生命周期重排 + 测试开关 | 后台/熄屏播放不再被静默掐断 | ★★★ |
| 2 | 申请并请求 `ACCESS_LOCAL_NETWORK` | DLNA 投屏在 Android 17 上恢复可用 | ★★★ |
| 3 | 应用内存上限（MemLimiter）适配：图片缓存 + libmpv 缓冲预算 | 避免进程因内存上限被杀 | ★★★ |
| 4 | 新增 `network_security_config.xml`（CT / ECH / 明文策略） | 规避 CT 默认开启与代理场景的连接异常 | ★★ |
| 5 | 澎湃 OS 后台存活引导（自启动 + 电池优化白名单） | 后台播放不被系统冻结 | ★★ |
| 6 | 场景化刷新率（视频/弹幕/静态分别定档） | LTPO 可降频，续航与温控改善 | ★★ |
| 7 | Impeller 在 Adreno 830 上实测 | 帧时间更稳、CPU 合成占用下降 | ★★ |
| 8 | HDR10 / 杜比视界输出与 tone-mapping | 小米 15 屏幕上画质与亮度明显提升 | ★★ |
| 9 | AV1 硬解 + hwdec 降级链 | 同画质更省电；兼容性失败可自愈 | ★★ |
| 10 | 预测性返回适配（现有开关已失效） | 手势返回动画一致，去掉无效配置 | ★★ |
| 11 | 显式 URI 授权（分享 / 拍照 / 裁剪） | 为 Android 18 收紧做准备，避免分享失效 | ★ |
| 12 | R8 + 资源压缩（release 当前关闭） | APK 体积下降、冷启动略快 | ★ |

---

## 2. 第一部分：Android 17（API 37）行为变更适配清单

> 对照官方文档：《行为变更：以 Android 17 或更高版本为目标平台的应用》与《行为变更：所有应用》（最后更新 2026-09-16 / 18）。下面每条都注明是"所有应用都受影响"还是"仅 targetSdk 37"。

### A17-01 后台音频加固：后台播放、音频焦点、音量 API 会被静默限制 ★★★ ✅已实施

**变更内容**

- 所有应用（不论 targetSdk）：在后台与音频 API 交互时，必须有**可见的 Activity** 或**运行中的非 `SHORT_SERVICE` 前台服务**。
- 仅 targetSdk 37 的应用：该前台服务还必须具备**使用时（WIU）**能力；否则后台音频播放**静默失败**（NDK `AudioTrack.write` / AAudio / OpenSL ES 无声、无异常），音频焦点请求直接返回 `AUDIOFOCUS_REQUEST_FAILED`，音量类 API 调用被静默忽略。
- 官方明确：**画中画（PiP）模式视为可见 Activity，不受该变更影响**。

**对本 App 的影响（证据）**

- `lib/utils/storage_pref.dart:664-665`：`enableBackgroundPlay` 默认 **true**——即"默认就有后台音频功能"，属于官方点名的需合规场景。
- `lib/services/audio_handler.dart:26-34`：`androidNotificationOngoing: true` + `androidStopForegroundOnPause: true`（暂停即退出前台）。
- `lib/services/service_locator.dart:8-10` → `lib/services/audio_handler.dart:22`：`AudioService.init(...)` 在 `lib/main.dart:117-120` 被 **`await`**（此时 App 在前台 → 该 FGS 天然获得 WIU 能力，这是好事）。
- `libmpv` 的音频输出走 NDK 音频写入，属于官方"受影响 API 完整列表"中的第一类。
- `lib/services/audio_session.dart:18-20`：音频焦点与耳机拔出监听（焦点 API 也在受影响清单内）。
- 风险点：播放结束后 FGS 若未及时停止、或用户在**后台**通过某些路径重新起播，FGS 可能不具备 WIU → 表现为"后台播放走着走着没声音/不自动续播"，且**没有任何报错**。

**建议改法**

1. 保持"**在用户点击播放（App 可见）时启动 `mediaPlayback` FGS**"这一模式；不要在后台/开机等场景起播。
2. 播放**永久结束**（播完不自动连播、`AUDIOFOCUS_LOSS`、用户从通知暂停并结束）时，停止 FGS 与媒体会话；用户显式恢复播放时再启动。
3. **瞬时故障**（缓冲、`AUDIOFOCUS_LOSS_TRANSIENT`）期间保持 FGS 有效（官方建议 <10 分钟内不要停）。
4. 检查 `androidStopForegroundOnPause: true`：暂停即退出前台，在 Android 17 下"从后台恢复播放"的路径会变脆；建议改为**暂停时保留 FGS 一段时间或依赖媒体按键事件**（媒体按键/通知点击属于官方列出的 WIU 豁免场景）。
5. 统一在一个入口做"音频交互前置检查"：`AppLifecycleState` + FGS 状态 + `continuePlayInBackground`，避免各页面各自判断。

**优点**

- 后台/熄屏播放不再被系统静默掐断；音频焦点行为可预期；避免"用户以为在播、其实没声音"这类无法定位的投诉。
- 顺带把"后台播放"从"默认开"改成"有明确生命周期"的状态机，减少误耗电。

**平台影响**：`共享(lib/)`，改动集中在 `lib/services/audio_handler.dart`、`lib/services/service_locator.dart`、`lib/plugin/pl_player/controller.dart`，均可用 `Platform.isAndroid` / 平台守卫隔离。
**验证方式**：`adb shell cmd audio set-enable-hardening enable` 后跑后台播放；`adb dumpsys audio` 或 logcat 过滤 `AudioHardening`，`level: full` = FGS 缺 WIU，`level: partial` = 完全没有 FGS。

---

### A17-02 本地网络权限：DLNA 投屏必须先申请 `ACCESS_LOCAL_NETWORK` ★★★ ✅已实施

**变更内容**：Android 17 对 targetSdk 37 应用强制 `ACCESS_LOCAL_NETWORK` 运行时权限（属 `NEARBY_DEVICES` 权限组）。Android 16 是可选项，Android 17 起强制执行。

**对本 App 的影响（证据）**

- `pubspec.yaml:75`：`dlna_dart: ^0.1.0`。
- `lib/pages/dlna/view.dart:19-20`：`DLNAManager()`；`:36` `_searcher.start()`（SSDP 组播发现）；`:118` `device.setUrl(...)` + `device.play()`（向局域网设备发 HTTP 控制指令）。
- `android/app/src/main/AndroidManifest.xml` **未声明** `ACCESS_LOCAL_NETWORK`。
- 结果：Android 17 上"投屏"页搜索不到任何设备（组播被系统阻断），且很可能**不报错**。

**建议改法**

1. `AndroidManifest.xml` 增加 `<uses-permission android:name="android.permission.ACCESS_LOCAL_NETWORK" />`。
2. 进入投屏页（`lib/pages/dlna/view.dart` 的 `_onSearch`）或点击"投屏"按钮时（`lib/pages/video/widgets/header_control.dart:1816`、`lib/pages/video/controller.dart:1607`）先请求权限；被拒时给出明确文案 + 跳转设置。
3. 权限只对 Android 17+ 请求（`DeviceUtils.sdkInt >= 37`），旧版本保持原行为。
4. 搜索失败时区分"无权限"与"无设备"两种提示（当前 `:88-92` 只提示"没有设备"，会掩盖权限问题）。

**优点**

- 投屏功能在 Android 17 上恢复可用；错误提示可诊断，避免"设备明明在线却搜不到"的无效排查。

**平台影响**：`android/`（清单）+ `共享(lib/)`（权限请求加 `Platform.isAndroid && sdkInt >= 37` 守卫）。

---

### A17-03 应用内存上限（MemLimiter）：需要给图片缓存与 libmpv 缓冲设预算 ★★★ ✅已实施

**变更内容**：Android 17 引入**按设备总 RAM 计算的应用内存上限**（所有应用生效，不论 targetSdk），命中时通过 `ApplicationExitInfo` 报告，退出原因为 `REASON_OTHER`、描述含 `"MemoryLimiter:AnonSwap"`。官方提供 `adb shell am memory-limiter status|manual|ignore` 调试。

**对本 App 的影响（证据）**

- 图片：`lib/utils/storage_pref.dart:620-621` 磁盘缓存上限 256 MiB（阶段一已从 1 GiB 下调），但**内存**缓存另有 Flutter `ImageCache`（默认 100 MiB / 1000 张），大图瀑布流 + 宫格会顶到上限。
- 播放：`lib/utils/storage_pref.dart:827-828` `bufferSize` 默认 4.0；`:841-848` 直播缓冲 `demuxer-max-bytes = bufferSize * 0x200000`（**2 倍系数**）→ 直播默认约 8 MiB 解码缓冲，加上 libmpv 内部缓存与 4K 解码帧缓冲，native 侧占用不小。
- 弹幕：热门视频/直播间的弹幕与聊天列表在 UI isolate 常驻（`lib/pages/live_room/controller.dart:3` `_kMaxChatCount = 500`）。
- 风险：内存上限是"按设备"的，小米 15 有 12/16 GiB 通常较宽松，但**上限与大内存设备的高峰叠加**仍可能触发；触发是"进程直接被收"，用户感知为"用着用着闪退/回到桌面"。

**建议改法**

1. 启动后读取设备内存等级（`ActivityManager.memoryClass` / `isLowRamDevice`，可通过现有 JNI 通道 `lib/utils/android/android_helper.dart` + `bindings.g.dart` 增加一个方法），据此设置：图片内存缓存上限、`cacheExtent`、`bufferSize` 与直播缓冲系数。
2. 把 `libmpv` 相关缓冲改为"声明式预算"：给"图片内存 + 解码缓冲 + 列表缓存"设一个总预算，超预算时优先砍列表缓存与预读（而非砍解码缓冲）。
3. 在"设置 → 关于/清理缓存"里展示当前预算与占用（顺带修掉 `lib/utils/cache_manager.dart:18-32` 递归 `stat` 的重 I/O，改走缓存库接口）。
4. 灰度观察：用 `adb shell dumpsys activity exit-info <包名>` 检查是否出现 `MemoryLimiter:AnonSwap`。

**优点**

- 把"内存超限被杀"变成"提前降级"；在 12 GB 机型上留出余量，在低内存机型上不再白屏或闪退。
- 预算化的好处是可解释、可调，避免"到处都有缓存，谁都不敢动"。

**平台影响**：`共享(lib/)`（新增 JNI 方法本身在 `android/`）。

---

### A17-04 证书透明度（CT）默认开启 + ECH 默认启用：建议新增网络安全配置 ★★

**变更内容**

- **CT 默认启用**：targetSdk 37 起，证书透明度默认开启（Android 16 需主动选择启用）。
- **ECH 默认启用**：targetSdk 37 起 TLS 使用加密 Client Hello；官方提供 `network_security_config.xml` 的 `<domainEncryption>` 元素用于按域开关（`enabled` / `disabled`）。
- **`usesCleartextTraffic` 弃用计划**：官方建议改用网络安全配置文件表达明文策略。

**对本 App 的影响（证据）**

- 工程**完全没有** `android:networkSecurityConfig`（`AndroidManifest.xml` 中无该属性，`res/xml/` 下也没有对应文件）。
- 网络栈：`dio` + `dart:io HttpClient`（`lib/http/init.dart:151` 起）与可选的 HTTP/2（`lib/utils/storage_pref.dart:745-746` `enableHttp2` 默认 false）；`flutter_inappwebview` 走系统 WebView（Chromium 系，**支持 ECH**）。
- 风险场景：① 部分 CDN / 直播源证书链缺 SCT 时，CT 强制可能导致连接被拒；② 用户使用代理、抓包或企业网络时，ECH 与中间盒的交互可能异常；③ 未来某版本移除 `usesCleartextTraffic` 后，若靠它放行明文，会突然失效。

**建议改法**

1. 新增 `android/app/src/main/res/xml/network_security_config.xml`，并在清单 `application` 上引用 `android:networkSecurityConfig="@xml/network_security_config"`。
2. 基线：`<base-config cleartextTrafficPermitted="false">`（显式声明比依赖默认更稳）；仅对确需明文的域开例外（本工程 `lib/` 中未检索到 `http://` 直连，可先不开例外）。
3. 预留开关位：`<domainEncryption>disabled</domainEncryption>` 与 CT 相关配置**默认不写**，仅保留注释与排障说明；一旦实测出现 TLS 失败，再对具体域关闭。这比"提前关闭安全性"更保守。
4. 把这份配置同时当作"明文策略"的唯一来源，为 `usesCleartextTraffic` 未来弃用做好准备。
5. 若使用代理：在"设置 → 网络"中提示，并要求用户同步在网络安全配置里对该域放行（不要全局关闭 CT）。

**优点**

- 把"系统默认策略变化"变成"应用显式声明"，出问题时改一个 XML 即可定位；避免上线后被 CT/ECH 变更"劈头盖脸"。
- 明文策略集中管理，未来 Android 版本移除旧开关时不会突然断网。

**平台影响**：`仅 Android`。

---

### A17-05 隐式 URI 授权收紧（Android 18 生效，现在就该改） ★

**变更内容**：目前 `ACTION_SEND` / `ACTION_SEND_MULTIPLE` / `ACTION_IMAGE_CAPTURE` 由系统自动授予 URI 读写权限；**从 Android 18 起不再自动授予**。官方建议现在就显式加 `FLAG_GRANT_READ_URI_PERMISSION`（拍照再加 WRITE）。

**对本 App 的影响（证据）**

- 分享：`share_plus` / `lib/pages/... ` 的分享入口（图片、动态、视频链接）。
- 图片链路：`image_picker`（拍照/选图）→ `image_cropper`（UCrop，`AndroidManifest.xml` 中注册了 `com.yalantis.ucrop.UCropActivity`）→ `saver_gallery`（保存）。
- 现状：`AndroidHelper.openUrl()`（`AndroidHelper.java:302-338`）与外部跳转（`biliSendCommAntifraud`、`openMusic`）也没显式加授权标志。

**建议改法**

1. 凡是主动构造 `ACTION_SEND*` / `ACTION_IMAGE_CAPTURE` 的地方（含 Kotlin/Java 侧）补 `FLAG_GRANT_READ_URI_PERMISSION`（拍照再补 WRITE）。
2. 用官方给的 StrictMode 探针扫一遍：`StrictMode.VmPolicy.Builder().detectImplicitUriPermissionGrant()`，或 `adb logcat | grep "Please set the grant explicitly in the app"`。
3. 用 `FileProvider` 的 `content://` 而不是 `file://` 传递临时文件（若仍有 `file://` 传递，Android 17 上也可能直接抛 `FileUriExposedException` 类问题）。

**优点**

- 分享/裁剪/保存这三条"看似与性能无关但用户天天用"的链路不会在系统升级后突然坏掉；现在改的成本远低于将来救火。

**平台影响**：`仅 Android`（Kotlin/Java 侧）+ `共享(lib/)` 中带平台的分享调用。

---

### A17-06 预测性返回：现有"关闭"开关已失效，自实现的返回桌面逻辑要复核 ★★

**变更内容**：Android 16 起，对 targetSdk 36+ 的应用**预测性返回默认开启且忽略退订**。本工程 targetSdk 37，却仍写着退订。

**对本 App 的影响（证据）**

- `android/app/src/main/AndroidManifest.xml:33`：`android:enableOnBackInvokedCallback="false"` —— 在 Android 17 上**已不产生效果**。
- `AndroidHelper.back()`（`AndroidHelper.java:71-76`）自己构造 `ACTION_MAIN` + `CATEGORY_HOME` 启动桌面，而不是让系统 finish Activity；配合系统预测性返回动画，可能出现"动画已经播完但界面行为不一致"或返回手势与自实现逻辑抢跑。
- 视频/直播全屏有大量自定义返回处理（`lib/plugin/pl_player/utils/fullscreen.dart`、`lib/pages/video/view.dart` 的 `PopScope` 一类逻辑）。

**建议改法**

1. 删掉 `enableOnBackInvokedCallback="false"`（该配置已无意义，留着会误导后续维护）。
2. 全量核对返回路径：优先使用 `PopScope` / `SystemNavigator.pop()` 表达"能返回则返回"；只有"首页再按一次返回桌面"这类语义才保留 `AndroidHelper.back()`。
3. 全屏、锁屏、弹幕输入框、PiP 四种状态各回归一次返回手势，确认动画与状态一致。

**优点**

- 去掉无效配置，减少"以为是它在生效"的误判；返回手势动画与系统一致，观感更"原生"。

**平台影响**：`仅 Android`。

---

### A17-07 静态 final 不可修改 + 原生库动态加载必须只读：校验 JNI 与 `.so` 加载 ★★

**变更内容**

- targetSdk 37 起，通过反射修改 `static final` 字段会抛 `IllegalAccessException`；通过 JNI（如 `SetStaticLongField()`）修改会**直接崩溃**。
- 更安全的原生 DCL：`System.load()` 加载的原生库文件**必须标记为只读**，否则抛 `UnsatisfiedLinkError`（Android 14 对 DEX/JAR 的同类保护扩展到原生库）。

**对本 App 的影响（证据）**

- 反射读系统静态字段：`AndroidHelper.fontFamilies()`（`AndroidHelper.java:253-273`）通过 `getDeclaredMethod("getSystemFontMap")` / `getDeclaredField("sSystemFontMap")` 读 `Typeface` 内部字段。**只读**，理论上安全（且已在 try/catch 内），但属于"隐藏 API + 静态字段"组合，Android 17 上需实测"系统字体"页是否仍能列出字体。
- 原生库：`media_kit` 的 `libmpv.so`、`jni_flutter` 的 `libjni.so`、`flutter_inappwebview` 等；`android/app/build.gradle.kts:41` 的 `packagingOptions.jniLibs.useLegacyPackaging = true` 意味着库会**解压到文件系统**（`extractNativeLibs` 语义），加载路径和文件权限更值得校验。
- 现有 JNI 桥：`lib/utils/android/android_helper.dart` + `lib/utils/android/bindings.g.dart`（与 `AndroidHelper.java` 方法签名逐一对应，此前已核对一致）。

**建议改法**

1. 在真机上回归：启动、播放、投屏、图片选择、字体列表、PiP、快捷方式创建。
2. 校验加载路径与权限：确认所有 `.so` 从只读的 `/data/app/.../lib/arm64/` 加载，不存在"先拷到可写目录再 `System.load()`"的实现。
3. 给 `fontFamilies()` 增加失败兜底（返回 null → UI 回退到内置字体列表），避免该入口在系统升级后白屏。
4. **不建议**主动去"修"反射本身（风险高）；优先确认行为 + 加兜底。

**优点**

- 把"系统升级后偶发崩溃/加载失败"提前暴露在回归阶段；兜底后即使隐藏 API 变更也不会影响主流程。

**平台影响**：`仅 Android`。

---

### A17-08 MessageQueue 换新实现：插件的反射使用需回归 ★

**变更内容**：targetSdk 37 起 `android.os.MessageQueue` 使用新的无锁实现，**可能破坏反射其私有字段/方法的客户端**。

**对本 App 的影响**

- Flutter / Dart 层不使用 `MessageQueue` 反射；风险主要在**原生插件**：任何做"主线程卡顿检测 / 消息队列监控 / 反射 `mMessages`"的库（常见于性能监控 SDK）会受影响。
- 本工程 release 默认 `enableLog = false`（`lib/utils/storage_pref.dart:641-642`），不上报 SDK（`lib/main.dart:191-215` 的 Catcher2 也只在开启日志时才挂），**风险因此较低**。
- 但 `flutter_inappwebview`、`saver_gallery`、`audio_service`、`image_cropper` 等都有原生代码，仍需一次全链路回归。

**建议改法**

1. 不新增任何"反射主线程消息队列"的监控代码。
2. 回归清单：WebView 播放/全屏、保存图片、通知控制、裁剪、PiP、投屏。
3. 若有自定义 `MessageQueue` 相关代码，改用 `Looper.getMainLooper().setMessageLogging(...)` 之类的公开 API。

**优点**

- 以极低的成本（一次回归）避开一类难以定位的"系统升级后偶发崩溃"。

**平台影响**：`仅 Android`。

---

### A17-09 大屏（sw ≥ 600dp）忽略方向/尺寸限制：折叠屏与平板需要横向适配 ★

**变更内容**：Android 16 起，大屏（sw ≥ 600dp）设备会忽略应用的屏幕方向、宽高比与可调整大小性限制；Android 17 起该行为对 targetSdk 37 强制，**不再提供退订**。

**对本 App 的影响（证据）**

- 默认竖屏锁定：`lib/main.dart:117-120` 走 `portraitUpMode()`（`Pref.horizontalScreen` 为 false 时），全屏播放时再切横屏（`lib/plugin/pl_player/controller.dart` 的 `_onOrientationChanged`）。
- 已有折叠屏/多窗口感知：`AndroidHelper.isFoldable`（`AndroidHelper.java:48-53`）、`lib/utils/max_screen_size.dart:12-18`（监听 `onConfigurationChanged` + `MaxScreenSize.isWindowMode`）、`MainActivity.kt:11-16`。
- 小米 15 本身是手机（sw < 600dp），**不受影响**；但同族设备（MIX Fold / 平板）与"手机 + 分屏"会走大屏路径。

**建议改法**

1. 明确"大屏布局"策略：`Pref.horizontalScreen` 已存在，可扩展为"大屏自动启用横向布局 + 不锁定方向"。
2. 校验 `MaxScreenSize.isWindowMode()` 在 Android 17 分屏/悬浮窗下的判定仍正确（该方法用 jni 从 Java 取最大窗口尺寸，`:12-18`）。
3. 校验视频页在"分屏 + 横屏 + 悬浮窗"下的全屏/退出全屏与 `fullscreen.dart` 的 `edgeToEdge` / `immersiveSticky` 切换不打架。

**优点**

- 折叠屏展开、平板与分屏场景不再出现"布局锁死/被系统拉伸"；同时避免在 Android 17 上出现"应用想锁竖屏但系统不理会"的观感问题。

**平台影响**：`共享(lib/)`，可只用 `Platform.isAndroid` + `isFoldable` 守卫。

---

### A17-10 旋转后 IME 可见性不再自动恢复 ★

**变更内容**：所有应用（Android 17 起），若配置变更未被应用自身处理，旋转后**不会**恢复之前的软键盘可见状态；需要 `windowSoftInputMode="stateAlwaysVisible"` 或代码显式请求。

**对本 App 的影响（证据）**

- 清单里 Activity 的 `configChanges` 已包含 `orientation|screenSize|keyboardHidden|keyboard`（`AndroidManifest.xml:38-46`），即**应用自己处理**旋转 —— 这条变更大概率不触发。
- 但 `android:windowSoftInputMode="adjustResize"` 已设置，而全屏播放/横屏时键盘相关页面（搜索、弹幕输入、评论、私信）需要各测一次。

**建议改法**

1. 只做回归：竖屏输入 → 旋转 → 确认键盘与焦点正常。
2. 若确实出现"旋转后键盘消失且无法唤起"，再在对应输入框上加显式 `requestFocus` + `showKeyboard`。

**优点**

- 用最小成本确认"这条变更与我们无关"，避免为一条不适用的变更做过度改动。

**平台影响**：`仅 Android`。

---

### A17-11 内容捕获 API 弃用：如需防录屏请改用 `FLAG_SECURE`（可选功能） ★

**变更内容**：targetSdk 37 起 `ContentCaptureManager.setContentCaptureEnabled(false)` 不再停用内容捕获；如需阻止系统捕获屏幕内容，必须用 `WindowManager.LayoutParams.FLAG_SECURE`。

**对本 App 的影响**

- 工程未使用 `setContentCaptureEnabled`，**无兼容问题**。
- 但它可以变成一个**功能**：为"登录页 / 二维码 / 部分付费或私人内容页"加 `FLAG_SECURE`（同时获得"防截屏 + 不进入最近任务预览"的效果）。小米 15 支持"最近任务模糊预览"，`FLAG_SECURE` 同时覆盖该行为。

**建议改法**

1. 作为可选开关加入"设置 → 隐私"（默认关），仅对 Android 生效，在 `MainActivity` 通过一个 JNI 方法切换窗口标志。
2. 不要在播放页全局开启（会影响正常的截图分享与 PiP 观感）。

**优点**

- 拿到一个用户可感知的隐私功能，同时把"系统 AI 屏幕内容分析"挡在门外（澎湃 OS 4 的端侧智能会读取屏幕内容）。

**平台影响**：`仅 Android`。

---

### A17-12 蓝牙重新配对、跨配置文件回环流量、Keystore 密钥上限：确认无影响 ★

- **蓝牙自动重新配对**：仅影响"绑定丢失后的重连"流程；本 App 通过 `audio_session`（`lib/services/audio_session.dart`）监听音频路由，不直接操作蓝牙，**无需改**。回归时用蓝牙耳机断连/重连验证一次"拔出耳机暂停"与音频焦点。
- **跨配置文件回环流量被阻断**：本 App 不监听本地端口（`lib/main.dart:398` 的 `_CustomHttpOverrides` 只做证书校验覆盖，不是本地服务），**无需改**；工作资料（分身）场景下若有用户反馈"分屏/投屏异常"，再排查。
- **Keystore 每应用密钥上限**（targetSdk 37：5 万）：本 App 不批量生成密钥，**无需改**。

---

## 3. 第二部分：澎湃 OS 4 / 小米 15 系统层（性能 + 功能）

> 这一部分依赖具体 ROM 行为，**所有结论都要在真机上复核**；下面给出可执行的验证方式，避免"照抄参数"。

### MI-01 后台存活：自启动白名单 + 电池优化引导 ★★

**现状**：Android 17 已经用"WIU 前台服务"给后台播放立了规矩（A17-01），而澎湃 OS 4 在系统层还会做"应用冻结 / 后台清理 / 省电策略"。两者叠加时，表现往往是"系统层把进程冻结"而不是"音频框架拒绝"。

**建议改法**

1. 新增"后台播放健康检查"引导页（仅 Android）：一键跳转 ① 应用详情 → 省电策略设为"无限制"；② 自启动管理；③ 锁定最近任务（上滑加锁）。
2. 跳转实现：优先 `Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`（`package:` URI）；小米自启动页用 `ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")` 并**必须 try/catch 回退**到应用详情页（`Settings.ACTION_APPLICATION_DETAILS_SETTINGS`），因为澎湃 OS 4 的组件名可能变化。
3. 在用户开启"后台播放"时做一次检查（而不是启动时弹窗打扰）。
4. 与 A17-01 的 FGS 生命周期改造一起做，两者是同一问题的两面。

**优点**

- 后台播放的存活率显著提升；把"用户以为是 App bug"的问题转成"明确的系统设置项"。

**平台影响**：`仅 Android`（`android/` 清单不需要改，属运行时跳转）。

---

### MI-02 场景化刷新率：别在应用内钉死高刷（LTPO 1–120Hz） ★★

**现状（证据）**

- `lib/main.dart:150-161`：启动后 `FlutterDisplayMode.setPreferredMode(displayMode ?? DisplayMode.auto)`。
- `lib/pages/setting/pages/display_mode.dart:58`、`:82`：用户可任选任意 `DisplayMode`（含 120Hz 档位）。
- 已知代价：`Opacity`（`lib/pages/video/view.dart:634`）、全屏 `saveLayer`（`lib/pages/live_room/view.dart:412`）、弹幕 Canvas（`lib/pages/danmaku/view.dart:158-177`）、骨架屏（`lib/common/skeleton/skeleton.dart`）都是"每帧重绘"型负载，高刷下显示子系统功耗接近翻倍；小米 15 的 LTPO 本来可以在静态界面降到 1Hz，一旦应用要求 120Hz，面板就下不去。

**建议改法**

1. **默认不再主动提升刷新率**：`DisplayMode.auto` 保持（不写死 120），把"强制高刷"下沉为高级选项。
2. 场景化定档（仅 Android）：进入视频播放页 → 按**视频帧率**匹配（24/25/30fps 内容优先 60Hz 档，60fps 内容才用 90/120Hz），暂停/停止后回到系统默认；直播间/弹幕密集场景固定 60Hz；纯列表浏览跟随系统。
3. 在设置项里加功耗提示文案（现在的列表只有档位名）。
4. 与温控联动（见 MI-04）：温度高或省电模式时强制降到 60Hz。

**优点**

- LTPO 能真正降频 → 静态界面待机功耗下降；高刷只在"需要动"的场景付出代价。
- "视频 24fps 用 120Hz"本身没有收益，只会让面板与 GPU 白烧电。

**平台影响**：`仅 Android`（`flutter_displaymode` 本身即 Android 专用）。

---

### MI-03 通知权限与澎湃媒体控件 ★★

**现状**

- `AndroidManifest.xml` 已声明 `POST_NOTIFICATIONS`；`audio_service` 提供 `mediaPlayback` 前台服务与 `MediaButtonReceiver`。
- `lib/services/audio_handler.dart:26-34`：`androidNotificationOngoing: true`、`androidStopForegroundOnPause: true`；`:74-140` 每次状态/位置变化都会更新通知。
- 澎湃 OS 4 的媒体控件从 `MediaSession` 读取元数据（标题/封面/进度），并对通知做渠道分组与"折叠成小胶囊"。

**建议改法**

1. 首次**主动**请求通知权限（在用户第一次播放或开启后台播放时），被拒时明确告知"后台播放将没有控制条"。
2. 通知渠道细分：播放控制 / 下载进度 / 应用更新 各自独立渠道（用户可单独静音，也避免"关掉一个全都没了"）。
3. 给 `MediaItem` 补全 `artwork`（小米锁屏/胶囊控件依赖它显示封面），并确认 `MediaSession` 的播放状态与真实 `playerStatus` 一致。
4. 位置更新节流（配合已有的 `onUpdateState` 去重），避免澎湃 OS 上"通知频繁刷新被降级"。

**优点**

- 锁屏/灵动胶囊/通知栏的播放控制稳定显示（这是"后台播放"用户唯一的交互面）；渠道分离避免用户一刀切关掉所有通知。

**平台影响**：`共享(lib/)` + `android/`。

---

### MI-04 低电量 / 温控降档：把系统信号接进播放与渲染策略 ★★

**现状**

- 工程已依赖 `battery_plus`（`lib/pages/video/widgets/header_control.dart:128-140` 用节流查电量，仅用于显示）。
- 缺"低电量 ⇒ 降档"的策略：超分着色器（`lib/plugin/pl_player/controller.dart:685-721` Anime4K CNN 系列）、弹幕描边/海量模式（`lib/plugin/pl_player/utils/danmaku_options.dart:30-48`）、高刷（MI-02）、预读缓冲（`lib/utils/storage_pref.dart:827-848`）都是"静态选项"，不会随设备状态变化。

**建议改法**

1. 新增 Android 平台能力读取：`PowerManager.isPowerSaveMode`（省电模式）、`isSustainedPerformanceModeSupported`、`BatteryManager` 温度/充电状态（可通过现有 JNI 通道扩展 `AndroidHelper.java` + `bindings.g.dart`）。
2. 策略表（仅 Android，默认开启，可在设置中关闭）：
   - 低电量（<20%）或省电模式：关闭超分、弹幕降为"仅滚动/去掉描边"、直播/点播缓冲下调一档、刷新率回到 60Hz。
   - 高温（`thermalservice` 报 `MODERATE` 以上）：同上，并暂停"弹幕海量模式"。
3. 在 UI 上以一行提示说明"已开启省电模式，画质/动效已降档"，避免用户以为画质变差是 bug。

**优点**

- 续航与温控直接改善（这是"发热/掉电"投诉最有效的处置方式）；同时把高清超分等高负载能力保留在"插电/高性能"场景，体验取舍更合理。

**平台影响**：`共享(lib/)` 中的策略层 + `android/` 的新 JNI 方法。

---

### MI-05 亮度策略：默认走"窗口亮度"而非系统亮度 ★

**现状（证据）**

- `lib/utils/storage_pref.dart:998-999`：`setSystemBrightness` 默认 **false** → 走 `ScreenBrightnessPlatform.setApplicationScreenBrightness`（`lib/pages/video/view.dart:419-431`、`lib/plugin/pl_player/view/view.dart:354-359`）；退出时 `resetApplicationScreenBrightness`。
- `AndroidManifest.xml` 却声明了 `WRITE_SETTINGS`（特殊权限，需在设置里手动授予）。启用"跟随系统亮度"时会走系统亮度路径。

**建议改法**

1. 保持默认（窗口亮度）不变——这是正确的、不需要特殊权限的做法。
2. 当用户开启"调节系统亮度"时才请求 `WRITE_SETTINGS`（`Settings.ACTION_MANAGE_WRITE_SETTINGS`），并给出已授予/未授予的明确状态；未授予时不静默失败。
3. 检查退出播放页/App 时一定复位亮度（`:374-375`、`lib/pages/live_room/view.dart:177-178`、`lib/plugin/pl_player/controller.dart:1795-1796` 已有复位，回归即可）。
4. 小米 15 的 AMOLED 在纯黑主题下更省电：`isPureBlackTheme` 已在工程内，可在"省电模式"下推荐开启（见 MI-06）。

**优点**

- 避免用户被"特殊权限"吓到；亮度回归时不会出现"退出播放页屏幕仍然很暗/很亮"。

**平台影响**：`仅 Android`。

---

### MI-06 纯黑主题 + 深色模式：AMOLED 省电与观感 ★

**现状**：`android/app/src/main/res/values-night-v31/styles.xml` 已提供夜间启动主题（`#212121`）与 `values-night` 主题；应用内已有 `isPureBlackTheme`、动态取色（`Pref.dynamicColor` 默认 true，`lib/main.dart:189-190`）。

**建议改法**

1. 启动主题的 `windowSplashScreenBackground` 建议改为**纯黑 `#000000`**（夜间）以匹配 AMOLED 纯黑，减少启动瞬间的"灰块"观感与一点功耗。
2. 在设置中说明"纯黑主题可省电（AMOLED）"，并在省电模式（MI-04）下询问是否切换。
3. `android:forceDarkAllowed=false` 已设（正确，避免系统二次反色）——保持不动。

**优点**

- 夜间启动不再闪白/闪灰；纯黑主题在 AMOLED 上是可量化的省电项（亮像素越少越省）。

**平台影响**：`仅 Android`（`res/` 资源与设置文案）。

---

### MI-07 16 KB 页大小与 `libmpv.so` 对齐校验 ★★

**现状**

- `android/app/build.gradle.kts:41`：`packagingOptions.jniLibs.useLegacyPackaging = true`（原生库解压安装）。
- 原生库体积大（`media_kit` 的 `libmpv.so`、`jni_flutter`），且工程用 `--split-per-abi` 打包。

**建议改法（校验优先，不急于改配置）**

1. 真机确认内核页大小：`adb shell getconf PAGE_SIZE`（16384 即 16 KB）。
2. 校验 16 KB 对齐：`zipalign -c -P 16 -v 4 app-arm64-v8a-release.apk`；对 `.so` 检查 ELF 段对齐（LOAD 段 `Align` 应为 `0x4000`）。
3. 若发现未对齐：优先升级 `media_kit` 版本/NDK 重新编译，而不是靠构建开关绕过。
4. `useLegacyPackaging = true` 与 `extractNativeLibs` 的取舍：保持现状（解压安装换更快的加载与内存映射）是合理的；只要对齐校验通过就不必改。

**优点**

- 避免在 16 KB 页设备上出现"原生库加载失败 / 性能异常"这类极难定位的问题；同时给"是否要改打包方式"一个**数据结论**而不是猜测。

**平台影响**：`仅 Android`（构建产物校验）。

---

### MI-08 音频输出：ao 选择与澎湃音频特性 ★

**现状**

- `lib/plugin/pl_player/controller.dart:751-756`：Android 下 `'ao': Pref.audioOutput`；默认值来自 `AudioOutput.defaultValue`（`lib/utils/storage_pref.dart:853-855`）。
- 音频会话配置为 `AudioSessionConfiguration.music()`（`lib/services/audio_session.dart:22-23`）。

**建议改法**

1. 在小米 15 上对比 `ao` 候选（如 `aaudio` 与 `audiotrack`）的**起播延迟、切轨断续、蓝牙切换表现**，把更稳的一个作为 Android 默认值（保持可切换）。
2. 与 A17-01 联动：音频焦点失败（`AUDIOFOCUS_REQUEST_FAILED`）要有兜底提示，否则用户会看到"能播但没声音"。
3. 检查"听视频"（`lib/pages/video/widgets/header_control.dart:593` `file-local-options/vid`）与后台播放组合时的音频路径是否稳定。
4. 不要主动去抢"空间音频 / 杜比全景声"等系统音效开关（由系统与耳机决定），避免与澎湃 OS 的音频策略冲突。

**优点**

- 起播更快、切歌/切轨更少爆音；蓝牙耳机场景（Snapdragon Sound / LHDC）稳定性提升。

**平台影响**：`仅 Android`（`if (Platform.isAndroid)` 守卫已有先例）。

---

### MI-09 超分（Anime4K）与弹幕的"功耗提示 + 自动降档" ★

**现状**

- `lib/plugin/pl_player/controller.dart:685-721`：`efficiency` / `quality` 两档着色器；`quality` 是 CNN 卷积系列（高负载）。
- 反例（做得好）：`lib/plugin/pl_player/controller.dart` 只在 `isAnim` 且用户主动开启时生效，入口是安全的。
- 缺口：没有功耗提示、没有"仅插电时启用"、没有低电量自动关闭。

**建议改法**

1. 设置页文案标注"高耗电 / 明显发热"，并提供"仅插电时启用"选项。
2. 低电量 / 省电模式 / 高温时自动切换到 `efficiency` 或关闭（与 MI-04 合并实现）。
3. 弹幕侧同样分级：`massiveMode`（海量模式）标注为高耗电；低电量时自动降低显示区域与描边（`lib/plugin/pl_player/utils/danmaku_options.dart:30-48`）。

**优点**

- 把"画质功能"与"续航"解耦，用户可预期；发热投诉显著减少。

**平台影响**：`共享(lib/)`（超分本身跨平台，但策略可只对 Android 生效）。

---

### MI-10 小米 15 深色 / 高亮屏的显示细节（HDR 见 PL-03） ★

- **峰值亮度**：小米 15 手动/激发亮度差异大，播放页"亮度手势"在窗口亮度模式下最大只能到 100%（无法超过系统亮度）。可在提示中说明"提升亮度需关闭跟随系统亮度"，避免用户误以为手势失效。
- **分辨率/像素密度**：`lib/utils/max_screen_size.dart` 取的是"最大窗口尺寸"（dp），在小米 15 上用于判断"是否窗口模式"（`:21-29`）。建议在超宽屏/分屏下回归一次，确保视频卡片宽高比与 `Style.aspectRatio` 不被拉伸。
- **护眼/色温**：系统级功能，App 不应自实现；播放页不要覆盖系统色温设置。

**优点**

- 减少"手感/观感类"投诉；不改代码即可确认的部分先确认，避免过度改动。

**平台影响**：`仅 Android`。

---

## 3.1 澎湃 OS 专项补充：还可做的高收益优化（第三批，均未实施）

> 前 10 条（MI-01 ~ MI-10）覆盖的是"通用 + 机型"层面。下面 6 条是**澎湃 OS 特有**的收益项：同样的做法在 AOSP 上收益有限，但在澎湃 OS 上因为"冻结后台进程、拦截后台起 Activity、安装/通知附加系统门槛"而价值很高。

**实施状态（2026-09-25，第三批）**：**MI-13 / MI-14 / MI-15 / MI-16 已实施**；MI-11（后台长任务前台服务）与 MI-12（应用内更新安装链路）仍为待办。本节正文条目未逐一加 ✅ 标记，**以本表为准**。

| 条目 | 落地位置 | 实现要点 |
| --- | --- | --- |
| **MI-13** ✅ | 新增 `lib/pages/setting/pages/hyperos_compat.dart`；`extra_settings.dart` 加入口；`AndroidHelper.java` 新增 `openAppSettings(type)` 与 `isIgnoringBatteryOptimizations()`；`bindings.g.dart` 同步绑定 | 「其它设置 → 澎湃 OS 兼容性检查」展示四项状态（通知权限、省电策略/电池优化白名单读真实值；自启动与后台弹出界面系统不给读接口，标注需手动确认）并一键跳转；小米组件名各版本会变，原生侧失败自动回退到应用详情页 |
| **MI-14** ✅ | `lib/utils/android/display_mode_utils.dart` | 请求低档 1.2s 后回读真实生效值（`FlutterDisplayMode.active`），被系统"按应用自定义刷新率"覆盖时置位 `systemOverridden`，并在兼容性检查页给出告警 + 跳转显示设置 |
| **MI-15** ✅ | `AndroidHelper.java` 新增 `setSustainedPerformanceMode()`；`pl_player/controller.dart` 播放/暂停/退出时开关 | 播放期间向系统申报持续性能模式（长时播放 + 弹幕帧时间更平缓），暂停或离开播放页立即取消 |
| **MI-16** ✅ | `lib/utils/memory_budget.dart` | 实现 `didHaveMemoryPressure` → 清空图片缓存（30s 冷却，只清缓存不动在显示的图）+ 本进程解码缓冲锁定 0.5 档，把"被冻结/杀掉"变成"先降级" |

### MI-11 后台长任务存活：下载 / 导出改前台服务 ★★★

**现状（证据）**

- `lib/services/download/download_manager.dart`、`lib/services/download/download_service.dart`（`DownloadService extends GetxService`）是纯 Dart 侧实现：该目录下**无前台服务、无通知、无 wakelock、无独立 Isolate**（逐项 grep 均无命中）。
- 即下载 / 导出完全依赖 App 进程存活。澎湃 OS 对后台进程的冻结比 AOSP 激进，切后台或锁屏后容易被冻结或回收，用户看到的是"下载莫名暂停/失败""导出到一半没了"。

**建议改法**

1. 下载与长时导出（WebP 导出、离线缓存）转为 Android 前台服务，类型 `dataSync`（清单加 `FOREGROUND_SERVICE_DATA_SYNC`），通知里给出进度与暂停/继续按钮。
2. 注意 Android 15+ 对 `dataSync` 前台服务有"每天 6 小时"上限：超长任务建议改用 Android 14+ 的**用户发起数据传输 Job**（`JobInfo.Builder.setUserInitiated(true)`，由系统托管进度通知，不受 6 小时限制）。
3. 下载完成/失败在通知与页面双通道播报，避免"后台完成了但用户不知道"。

**优点**：下载/导出在澎湃 OS 上不再被冻结，从"得盯着它"变成"丢后台就行"。
**成本/风险**：中等；需新增原生能力与一个通知渠道，注意 FGS 类型与时长合规。
**平台影响**：`仅 Android`。

### MI-12 应用内更新：补齐安装链路 ★★★

**现状（证据）**

- `lib/utils/update.dart:119-146`：`onDownload()` 只做 `PageUtils.launchURL(browser_download_url)`，即把 APK 链接丢给浏览器。
- 全仓（dart / yaml / xml / kt / java）**没有** `REQUEST_INSTALL_PACKAGES`、没有 `FileProvider`、没有安装相关代码。
- 后果：国内直连 GitHub 慢且易失败；即便下完，澎湃 OS 还要"允许安装未知应用"的 per-app 授权 + 安全扫描 + 二次确认，用户常在半路流失。

**建议改法**

1. 应用内下载（复用 MI-11 的前台服务），支持断点续传与加速/镜像地址回退。
2. 下载完成后用 `FileProvider` 的 `content://` + `ACTION_VIEW`（`application/vnd.android.package-archive`）拉起安装器；清单加 `REQUEST_INSTALL_PACKAGES`，未授权时跳"安装未知应用"设置页（见 MI-13）。
3. 安装前校验签名 / `sha256`，避免下载被篡改。
4. 保留"前往 GitHub Release"作为兜底入口。

**优点**：更新成功率大幅提升 —— 这直接决定用户能否拿到本报告里的所有优化。
**成本/风险**：中等；涉及安装权限与签名校验，需在各 ROM 回归。
**平台影响**：`仅 Android`。

### MI-13 澎湃 OS 权限引导页：一键直达四个开关 ★★★

**现状（证据）**：全仓无任何小米 / 澎湃 OS 设置页跳转（`miui.*`、`com.miui.*`、`IGNORE_BATTERY_OPTIMIZATIONS` 均无命中）；MI-01 提出过但未实施。

**建议改法**：新增"澎湃 OS 兼容性检查"页（仅 Android 显示），逐项检测 + 跳转：

| 项 | 用途 | 跳转方式 |
| --- | --- | --- |
| 自启动 | 后台播放 / 下载存活 | `ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")` |
| 省电策略＝无限制 | 同上；并申请电池优化白名单 | `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` + `package:` URI |
| 后台弹出界面 | 后台完成下载后拉起安装器/外部 App、投屏控制 | 小米权限管理页 |
| 通知权限 | 媒体控制条、下载/更新通知 | `POST_NOTIFICATIONS`（MI-03 已做请求） |

所有小米组件名**必须 try/catch 回退**到 `ACTION_APPLICATION_DETAILS_SETTINGS` —— 澎湃 OS 各版本组件名会变。

**优点**：一次引导解决四类"玄学问题"，是澎湃 OS 上性价比最高的一项；把系统限制转成用户可执行的明确动作。
**成本/风险**：低（纯 Intent 跳转 + 一个设置页）。
**平台影响**：`仅 Android`。

### MI-14 MI-02 的落地校验：系统"按应用自定义刷新率"会覆盖 `setPreferredMode` ★★

**现状（风险）**：`lib/utils/android/display_mode_utils.dart` 通过 `FlutterDisplayMode.setPreferredMode` 切档，但澎湃 OS 的"设置 → 显示 → 屏幕刷新率 → 自定义"可为**单个应用**指定刷新率，此时系统会忽略应用请求 → MI-02 的省电收益静默失效。

**建议改法**

1. 切档后校验实际生效值（`FlutterDisplayMode.active` / `preferred` 与期望不符即视为被系统覆盖）。
2. 检测到被覆盖时，在播放设置页给一次性提示"系统里为 PiliPlus 指定了刷新率，请改为跟随系统"，并提供跳转（`Settings.ACTION_DISPLAY_SETTINGS`）。
3. 本项唯一未知点是该开关的真实行为，需在小米 15 + 澎湃 OS 4 上确认。

**优点**：避免"写了优化却没效果"；把不可控项变成可诊断项。
**成本/风险**：低。
**平台影响**：`仅 Android`。

### MI-15 长时性能稳定：申报持续性能模式 ★

**现状**：全仓无 `setSustainedPerformanceMode`（grep 无命中）。

**建议改法**：在 `MainActivity` 对窗口申请持续性能模式（`Window.setSustainedPerformanceMode(true)`），进入播放页/全屏时开启、退出时关闭；与已实施的温控降档（MI-04）配合使用。

**优点**：长时播放 + 弹幕场景下系统不再"先冲高频再骤降"，帧时间更平缓。
**成本/风险**：低（一行原生调用 + 生命周期管理），需实测对温控策略的影响。
**平台影响**：`仅 Android`。

### MI-16 内存压力主动释放：把"被杀"变成"降级" ★★

**现状**：已有 `lib/utils/memory_budget.dart`（按设备内存定预算），但没有对系统内存压力做响应 —— 全仓无 `didHaveMemoryPressure`（grep 无命中）。

**建议改法**：实现 `WidgetsBindingObserver.didHaveMemoryPressure` → `PaintingBinding.instance.imageCache.clear()` + 清理列表预读/弹幕缓存，并在低内存时把 `MemoryBudget.bufferScale` 再降一档。澎湃 OS 的内存回收比 AOSP 激进，主动释放能明显降低"后台被冻结后回不来"的概率。

**优点**：与 A17-03、MI-04 形成闭环 —— 内存上限从"被动挨打"变成"主动腾挪"。
**成本/风险**：低。
**平台影响**：`仅 Android`（回调本身跨平台，只在 Android 放大降级幅度）。

### 附：澎湃 OS 上**不建议**做的三件事

1. **接 MiPush / 第三方推送**：本应用没有服务端，**无法让 B 站把消息推给第三方客户端**；MiPush 只能推自家通知（下载/更新），却需要小米开放平台审核 → 收益/成本比很差。
2. **私有 API**（焦点通知 `miui.focus.*`、超级岛、视频工具箱、传送门）：未公开、随 ROM 变化、可能违反小米规范 → 最多用标准 `MediaSession` + 通知渠道。
3. **绕过系统安全默认值**（关闭 CT/ECH、直写系统亮度、自实现护眼色温）：与安全/规范冲突，收益低。

---

## 4. 第三部分：播放与解码（Snapdragon 8 Elite + Adreno 830 + media_kit/mpv）

> 所有 mpv 参数都通过 `lib/plugin/pl_player/controller.dart:749-775` 的 `opt` map 传入（`PlayerConfiguration(options: opt)`）；默认值集中在 `lib/utils/storage_pref.dart`。**新增项请沿用 `if (Platform.isAndroid)` 守卫**，这样 iOS/桌面行为不变。

### PL-01 Impeller 在 Adreno 830 上实测（当前被显式关闭） ★★

**现状（证据）**：`android/app/src/main/AndroidManifest.xml:46-48` 显式设置 `io.flutter.embedding.android.EnableImpeller = false`（即运行在 Skia 上）；工程内大量 `saveLayer` 场景（`Opacity`、`ClipRRect`、`ShaderMask`、全屏弹幕 Canvas）。

**建议改法**

1. 在 `--profile` 下用同一段视频做 A/B：1080P60 播放、视频页滚动 + 弹幕、直播间 10 分钟，比较帧时间 P50/P95 与 CPU 占用。
2. 若 Impeller 收益明显：可先只对 **Adreno + Vulkan 可用**的机型放行（在 `MainActivity` 或 Flutter 的启动参数层做设备白名单），而不是全局开启。
3. 关闭 Impeller 很可能有历史原因（media_kit 纹理 / 兼容性），务必一并对"播放画面、PiP、投屏、截图/WebP 导出（`lib/plugin/pl_player/widgets/mpv_convert_webp.dart`）"做回归。

**优点**

- 帧时间更稳、CPU 合成开销下降（弹幕 + 滚动这类"每帧重绘"场景最受益）；在 Adreno 830 这种新 GPU 上 Skia 的 CPU 回退风险高于 Impeller。

**平台影响**：`仅 Android`。

---

### PL-02 视频输出后端：`vo` / `gpu-api` 的 Android 取值 ★

**现状**：Android 侧未显式指定 `vo`/`gpu-api`（`opt` map 里只有 `video-sync`、`ao`、`volume`、`autosync`）；转码导出路径里写了 `'vo': 'gpu'`（`lib/plugin/pl_player/widgets/mpv_convert_webp.dart:55`）。

**建议改法**

1. 在 Android 上显式测试 `vo=gpu-next`（若 `media_kit` 版本支持）与 `gpu-api=vulkan` / `opengl` 的组合，观察功耗、帧丢弃与 HDR 表现（与 PL-03 一起测）。
2. 一旦确定，用 `if (Platform.isAndroid)` 写入 `opt`，并保留设置项供高级用户回退。
3. **必须**实测"硬解直通 + 纹理上屏"三种组合下的黑屏/花屏/绿屏情况，再决定默认值。

**优点**

- 消除"默认后端在 8 Elite 上并非最优"的隐性损失；同时为 HDR/色彩管理提供正确的后端基础。

**平台影响**：`仅 Android`。

---

### PL-03 HDR10 / 杜比视界输出与 tone-mapping ★★

**现状**：`opt` 中没有任何色彩/HDR 相关参数；B 站在番剧/影视上提供 HDR（HLG/HDR10）与部分杜比视界内容；小米 15 屏幕支持 HDR10+ / 杜比视界。默认情况下 mpv 会把 HDR 内容做 tone-map 到 SDR 输出（画面偏灰/偏暗，是高亮屏上最明显的观感差异）。

**建议改法**

1. 新增 Android 专属选项：`target-colorspace-hint`（向系统声明 HDR 输出，需要后端支持）与 tone-mapping 曲线（如 `bt.2390` / `spline`）、`hdr-compute-peak` 的组合，做成设置页的"HDR 输出：自动 / 关闭 / 强制"。
2. 仅在设备与内容都支持时开启；**必须先确认**在窗口亮度模式下 HDR 是否仍能正常提升亮度（否则用户会看到"开了 HDR 反而更暗"）。
3. 杜比视界（尤其 Profile 5）通常无法直通，保持 tone-map → SDR 并明确提示，避免"打开就黑屏"。
4. 与 PL-01/PL-02 联动测试（后端不同，HDR 行为不同）。

**优点**

- 在小米 15 的高亮度屏上直接提升对比度与亮度表现；同时给"不支持的内容"一条不会翻车的路径。这是"功能优化"里用户最能直观感知的一项。

**平台影响**：`仅 Android`。

---

### PL-04 AV1 硬解与解码器白名单 ★★

**现状**：`hwdec` 由用户设置决定（`lib/plugin/pl_player/models/hwdec_type.dart:45-49`：默认 `mediacodec,auto-safe`）；`lib/plugin/pl_player/controller.dart:782-790` 把它交给 `VideoControllerConfiguration(hwdec: ...)`。

**建议改法**

1. 明确 `hwdec-codecs` 允许列表（在 `opt` 中显式列出 `h264,hevc,vp9,av1` 等），避免不同 `media_kit` 版本默认值变化导致"某些编码忽硬忽软"。
2. Snapdragon 8 Elite 具备 AV1 硬解能力；B 站部分内容提供 AV1。确认 AV1 走硬解后，可把"优先 AV1 流"作为设置项（省流量 + 省电）。
3. 失败降级链（见 PL-05）与 `hwdec-codecs` 一起测：`mediacodec` → `mediacodec-copy` → `auto-safe` → `no`。

**优点**

- 同画质下码率更低、解码更省电；避免"用户选了硬解但实际在软解"的隐性发热。

**平台影响**：`仅 Android`。

---

### PL-05 硬解失败自动降级链 ★★

**现状（证据）**：解码失败只弹一次 toast（`lib/plugin/pl_player/controller.dart:1047-1048` 附近），不会自动切换解码器；用户一旦手动关掉"硬件加速"（`Pref.enableHA`，默认 true，`lib/utils/storage_pref.dart:787-788`），就变成纯软解，4K/高码率会直接跑满 CPU。

**建议改法**

1. 建立"自动降级链"：首次失败 → `mediacodec-copy`（拷回内存，兼容性更好）→ `auto-safe` → 软解；每级只尝试一次，并在 UI 上以一行轻提示说明"已切换为兼容解码模式"。
2. 记录"本机/本视频首次失败的 hwdec"，下次同编码直接采用可用档（缓存到 `GStorage.setting` 或本地缓存）。
3. 在设置里对"关闭硬件加速"给出明确警告（现在只是一个开关）。

**优点**

- 用户不再"硬解失败就只能忍受卡顿或手动折腾"；减少因软解导致的发热与耗电。

**平台影响**：`仅 Android`（该降级链可只对 Android 启用）。

---

### PL-06 视频同步策略：`display-resample` 在 LTPO 120Hz 上成本偏高 ★★

**现状（证据）**

- `lib/utils/storage_pref.dart:269-270`：`videoSync` 默认 `'display-resample'`。
- `lib/utils/storage_pref.dart:272-274`：`autosync` 在 Android 默认 `'30'`。
- 二者被写入 `opt`（`lib/plugin/pl_player/controller.dart:751-760`）。
- `display-resample` 会让 mpv 持续重采样音频并动态微调播放速度以匹配显示刷新；在 120Hz LTPO 屏上这是持续的重采样 + 帧重定时开销。

**建议改法**

1. Android 默认改为 `audio`（或 `desync`），把 `display-resample` 作为高级选项；`autosync` 默认调小或关闭。
2. 与 MI-02 联动：视频页刷新率匹配内容帧率后，同步开销本身也会下降（因为不再需要"重定时到 120Hz"）。
3. 改动后必须回归"音画同步"（尤其 24fps 内容 + 60Hz 档）。

**优点**

- 持续音频重采样与帧重定时的 CPU/功耗开销下降；配合 MI-02 效果叠加，是最省电的一组播放器改动。

**平台影响**：`仅 Android`（默认值可只对 Android 生效）。

---

### PL-07 直播缓冲与重连策略（配合网络抖动） ★

**现状**：`lib/utils/storage_pref.dart:841-848` 直播缓冲 `demuxer-max-bytes = bufferSize * 0x200000`；`lib/plugin/pl_player/controller.dart:873` 起已有单定时器 + 3/6/12/24s 退避（阶段一已实施）。

**建议改法**

1. 按设备内存等级调整直播缓冲系数（见 A17-03），低内存设备降到 `1×`。
2. 弱网下动态降一档清晰度（若已有"自动清晰度"逻辑，接入 `ConnectivityResult` 变化）。
3. 断流重连时不要重新走完整的 `setDataSource`（会重建 mpv 实例），优先 `loadfile` 同源重连。

**优点**

- 弱网/移动网络下的重连更快、内存更省；避免"断流一次就要重新缓冲 10 秒"。

**平台影响**：`仅 Android`（可只对 Android 生效）。

---

### PL-08 PiP 与后台播放的边界（与 A17-01 强相关） ★★

**现状（证据）**

- `AndroidHelper.java:169-215`：`enterPip`（含 `setAutoEnterEnabled`）、`updatePipActions`、`disableAutoEnterPip`。
- `MainActivity.kt:31-34`：`onPictureInPictureModeChanged` 写入 `AndroidHelper.isPipMode`。
- `lib/plugin/pl_player/controller.dart:577-583`：`autoPiP` + `sdkInt < 31` 分支。
- `lib/pages/danmaku/view.dart:96`：PiP 下不显示弹幕（可配置）。

**建议改法**

1. 明确"PiP / 后台播放 / 熄屏"三种状态的优先级：PiP = 可见（音频限制豁免，见 A17-01），后台播放 = 依赖 FGS，熄屏 = 走 FGS + 唤醒锁门控（已实施）。
2. PiP 期间继续降载：关闭弹幕、暂停骨架屏等无意义动画、按 Mi-02 固定帧率档。
3. Android 15+ 的 PiP 转场与"无缝 resize"：可考虑在 `PictureInPictureParams` 中启用（评估后决定），减少进出 PiP 时的重布局。

**优点**

- PiP 场景既符合 Android 17 的音频规则（不会莫名静音），又不会在"小窗口"里白烧 GPU。

**平台影响**：`仅 Android`。

---

### PL-09 截图/导出（WebP）路径的原生初始化 ★

**现状**：`lib/plugin/pl_player/widgets/mpv_convert_webp.dart:37-60` 直接使用 `Initializer.create(...)` 创建了**独立的 mpv 实例**（`'idle': 'once'`，`'vo': 'gpu'`，`hwdec: '${Pref.hardwareDecoding},auto-copy'`）。

**建议改法**

1. 该实例会额外占用一份 native 内存与 GPU 上下文；建议：① 截图/导出结束后确保 `Initializer.dispose`（`:74-76` 已有 `dispose`，回归确认所有路径都调用）；② 与 A17-03 的内存预算一起核算（导出 4K 时会短时占用较大内存）。
2. `hwdec` 字符串拼接（`'${Pref.hardwareDecoding},auto-copy'`）在用户设置为 `no` 时会得到 `no,auto-copy`，语义可疑——建议与 PL-05 一起规范化。

**优点**

- 避免"截图一次内存涨一截"；消除解码器参数的隐性错误配置。

**平台影响**：`共享(lib/)`（可只对 Android 调整默认值）。

---

### PL-10 播放器实例生命周期与页面复用 ★

**现状**：`lib/plugin/pl_player/controller.dart:616-628`（`_playerCount` 计数、"`_playerCount == 0` 则 return"）表明作者已在处理多页面共享实例；`Pref.preInitPlayer` 默认 false（`lib/utils/storage_pref.dart:483-484`）。

**建议改法**

1. 保持 `preInitPlayer` 默认关闭（延迟到真正需要时初始化 mpv，节省启动 50–300 ms 与 native 内存）。
2. 复核"退出视频页 → 再进另一个视频"时是否复用同一个 `Player` 实例；如果不复用，则每次都要重新加载 `libmpv` 与解码器，冷启动开销明显。
3. 与 `lib/main.dart:94` 的 `MediaKit.ensureInitialized()` 一起评估（见 PF-04）。

**优点**

- 连续看视频（B 站典型用法）时不再反复初始化原生播放器，切视频更快、更省内存。

**平台影响**：`共享(lib/)`。

---

## 5. 第四部分：Android 专有性能与耗电（补充清单）

> `perf-report/PiliPlus-Android.md` 已给出 74 项完整分析。下表只列**与 Android 强相关、且当前仍未实施**的部分，并标注"改动是否只影响 Android"。

### PF-01 已完成项（不要重复做）

| 项 | 位置 | 状态 |
| --- | --- | --- |
| 唤醒锁按"前台 + 可见 + 播放中"门控 | `lib/plugin/pl_player/controller.dart:946` `_updateWakeLock()` | 已实施 |
| 播放心跳 5s → 15s | 同文件 `_heartBeatInterval = 15` | 已实施 |
| 直播重连退避（单定时器 + 3/6/12/24s） | 同文件 `_scheduleLiveReconnect()`（`:873`） | 已实施 |
| 骨架屏全局共享 Ticker | `lib/common/skeleton/skeleton.dart:16-101` | 已实施 |
| 图片磁盘缓存 1 GiB → 256 MiB | `lib/utils/storage_pref.dart:620-621` | 已实施 |
| 日志默认关闭 + 批量 flush + 轮转 | `lib/utils/storage_pref.dart:641-642` | 已实施 |
| 重试拦截器指数退避 + 抖动 | `lib/http/retry_interceptor.dart` | 已实施 |

### PF-02 仍未实施的 Android 高收益项

| # | 项目 | 证据位置 | 改动落点 | 优点 |
| --- | --- | --- | --- | --- |
| 1 | 视频页整页 `Obx` + `scrollRatio` 每帧回写 Rx | `lib/pages/video/view.dart:488-495`；`lib/common/widgets/sliver/video_header.dart:57` | 共享(lib/) | 视频页滚动帧率与 GPU 占用 |
| 2 | 悬浮工具栏用 `Opacity`（每帧 `saveLayer`） | `lib/pages/video/view.dart:634-640` | 共享(lib/) | 去掉整层合成，滚动不再掉帧 |
| 3 | 评论项每次 build 重编译正则 | `lib/pages/video/reply/widgets/reply_item_grpc.dart:716-739` | 共享(lib/) | 评论滚动 CPU 明显下降 |
| 4 | `loadingState.refresh()` 导致整列表重建 | `lib/pages/common/reply_controller.dart:204-243` | 共享(lib/) | 点赞/删除不再全量重建 |
| 5 | `ThemeData` 每次 build 重建 | `lib/main.dart:250-288` | 共享(lib/) | 主题类变更不再全树重建 |
| 6 | 顶/底栏滚动写 Rx 每帧重建 | `lib/pages/common/common_page.dart:70-95` | 共享(lib/) | 首页滚动更稳 |
| 7 | 直播弹幕逐条 `jsonDecode` 在 UI isolate | `lib/pages/live_room/controller.dart:577-690`；`lib/tcp/live.dart:221` | 共享(lib/) | 直播间单核 CPU 大幅下降 |
| 8 | `ClipRRect` 默认 `antiAlias` → 每图一次 `saveLayer` | `lib/common/widgets/image/network_img_layer.dart:47-56` | 共享(lib/) | 列表滚动合成开销 |
| 9 | 启动流程：`setupServiceLocator` 去 await、`MediaKit` 延迟、Hive 懒开、动态取色 post-frame | `lib/main.dart:94`、`:117-120`、`:189-190`；`lib/utils/storage.dart:31-72` | 共享(lib/) | 冷启动首帧 -200~500 ms |
| 10 | 网络层：`responseDecoder` 异步化、gRPC `isolate: true`、连接池 `idleTimeout` 15s → 60~120s | `lib/http/init.dart:151-186`、`:352-358`；`lib/grpc/grpc_req.dart:74` | 共享(lib/) | 弱网/移动网络的耗电与卡顿 |
| 11 | 定时器统一治理（App 不可见即暂停） | `lib/services/shutdown_timer_service.dart:433`、`lib/pages/login/controller.dart:78`、`lib/pages/live_room/superchat/superchat_card.dart:87` 等 | 共享(lib/) | 待机唤醒次数、耗电 |
| 12 | 未设 `cacheExtent` / 部分列表缺 `prototypeItem` | `lib/pages/rcmd/view.dart:44-73`；`lib/pages/video/reply/view.dart:167` 等 | 共享(lib/) | 长列表快速滑动白屏率 |

> 建议顺序：先做 9、10、11（与 Android 生命周/系统唤醒强相关），再做 1、2、7（视频与直播这两个最重场景）。

### PF-03 应用不可见时的统一门控（Android 尤其重要）

Android 在 Doze/App Standby 下对后台进程的限制比其它平台严格。建议新增一个"应用可见性门控"服务（仅移动端启用）：`AppLifecycleState.paused` 时集中 `cancel` 所有非必要定时器 / 暂停弹幕 Canvas / 关闭直播 WSS，`resumed` 时按需恢复。落点可以是 `lib/services/` 下的一个新服务，用 `PlatformUtils.isMobile` 守卫。

**优点**：一次性解决"熄屏后仍有一堆定时器在跑"的系统性问题，比逐处修改更可靠（也更容易验证）。

---

## 6. 第五部分：功能增强（Android 专有）

| # | 功能 | 落点 | 优点 |
| --- | --- | --- | --- |
| FT-01 | 快捷方式动态化：`res/xml/shortcuts.xml` 已有静态定义，可改为按使用习惯动态增删（`ShortcutManager` 已在 `AndroidHelper.java:224-251` 使用） | `仅 Android` | 长按图标直达"稍后再看/历史/搜索"，提升启动转化 |
| FT-02 | 动态通知渠道（播放控制/下载/更新分离，见 MI-03） | `共享(lib/)` + `android/` | 用户可精细控制，避免"关一个全都没" |
| FT-03 | 深色/纯黑 + 主题图标（Android 13+ 的 `monochrome` 层）：`mipmap-anydpi-v26/ic_launcher.xml` 已有自适应图标，可补 `monochrome` | `仅 Android` | 桌面图标跟随澎湃 OS 主题，观感统一 |
| FT-04 | PiP 增强：无缝 resize、PiP 内弹幕开关、进出 PiP 动效 | `仅 Android` | 多任务体验更"原生" |
| FT-05 | 隐私防护：登录页/敏感页 `FLAG_SECURE`（见 A17-11） | `仅 Android` | 防截屏/防最近任务预览 |
| FT-06 | 应用内语言切换（当前 `lib/main.dart:290-291` 硬编码 `zh_CN`）：如需国际化，加 `android:localeConfig` + `res/xml/locales_config.xml` 支持"按应用设置语言" | `仅 Android` | 兼容 Android 13+ 的按应用语言设置 |
| FT-07 | "后台播放健康检查"引导页（见 MI-01） | `仅 Android` | 把系统限制转成可执行的设置指引 |
| FT-08 | 无障碍：Android 17 新增复杂 IME 的文本变化事件支持；加权限请求说明与 `contentDescription` 审查 | `共享(lib/)` + `android/` | 无障碍合规与可用性 |

---

## 7. 第六部分：构建与发布（Android 侧）

### BD-01 release 未开启 R8 / 资源压缩 ★

**现状（证据）**：`android/app/build.gradle.kts:64-74` 里 `proguardFiles(...)` 被注释，`isMinifyEnabled` / `isShrinkResources` 均未设置（默认 false）。`proguard-rules.pro` 只有 3 条 `-dontwarn`。

**建议改法**

1. 开启 `isMinifyEnabled = true` + `isShrinkResources = true`，补齐 keep 规则（重点：`media_kit`/`jni`、`flutter_inappwebview`、`audio_service`、`dio_http2_adapter`、`Catcher2`、UCrop）。
2. 先在 profile 构建上验证启动、播放、投屏、通知、裁剪、快捷方式，再出 release。
3. 注意：Android 17 的"静态 final 不可修改 + 原生 DCL 只读"对 R8 无直接冲突，但 R8 的类合并会影响反射路径，需重点回归 `AndroidHelper.fontFamilies()`。

**优点**：APK 体积与 DEX 体积下降、首次执行路径变短（冷启动略快），这是"只影响 Android"且零风险面较小的改动。

**平台影响**：`仅 Android`。

---

### BD-02 构建配置清理：`enableJetifier` 与 `kotlin.incremental` ★

**现状（证据）**：`android/gradle.properties:3` `android.enableJetifier=true`（已废弃，显著拖慢构建）；`:8` `kotlin.incremental=false`（Windows 跨盘符 workaround，flutter/flutter#173456，仅影响构建速度）。

**建议改法**

1. `enableJetifier` 若无旧 Support Library 依赖则关闭（先跑一次 `flutter build apk --release` 验证）。
2. `kotlin.incremental` 保持 `false` 直到把 pub 缓存与工程放到同一盘符（根治办法见仓库笔记），**不要**为了构建速度反复开关。

**优点**：构建时间下降，且不影响运行时行为。

---

### BD-03 ABI 与原生库打包 ★

**现状**：`android/app/build.gradle.kts:41` `useLegacyPackaging = true`；CI 用 `--split-per-abi`（`lib/scripts/build.ps1`）。

**建议改法**

1. 保持"分 ABI 打包 + 解压安装"；小米 15 只需 `arm64-v8a`。
2. 与 MI-07 的 16 KB 校验一起做；若未来切回压缩打包，需重新评估加载耗时（`libmpv.so` 体积大，解压开销明显）。

**优点**：安装包体积与加载速度的取舍保持清晰、可解释。

---

### BD-04 签名与更新链路 ★

**现状**：`android/key.properties` 不存在 → release 使用 debug 签名（能装能用，但不能上架、且无法与正式包互升）。`Pref.autoUpdate` 默认 true（`lib/utils/storage_pref.dart:447-448`）会在启动时请求 GitHub API。

**建议改法**

1. 补齐正式签名（本地生成 keystore，勿入库）；`build.gradle.kts:45-58` 已有读取 `key.properties` 的逻辑，只缺文件。
2. 更新检查移到首帧后（`addPostFrameCallback`），并尊重"后台不请求"的门控（与 PF-03 合并）。
3. 更新下载走"仅 WLAN + 前台"策略（现在缺少网络类型判断）。

**优点**：可发布、可覆盖安装；启动阶段少一个外部请求（对冷启动有实测收益）。

---

### BD-05 targetSdk 37 合规自查清单（避免上架/审核类问题） ★

| 检查项 | 现状 | 结论 |
| --- | --- | --- |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | 均已声明（`AndroidManifest.xml`） | ✅ |
| FGS 类型：`mediaPlayback` | `AudioService` 上已声明 | ✅ |
| `POST_NOTIFICATIONS` | 已声明，需运行时请求（见 MI-03） | ⚠️ 补请求 |
| `ACCESS_LOCAL_NETWORK`（Android 17 强制） | **未声明** | ❌ 必补（A17-02） |
| 预测性返回 | `enableOnBackInvokedCallback="false"` 已失效 | ⚠️ 删除并复核（A17-06） |
| 网络安全配置 | 缺失 | ⚠️ 建议新增（A17-04） |
| 大屏方向限制 | 依赖系统默认（会被忽略） | ⚠️ 明确策略（A17-09） |
| 16 KB 页对齐 | 未校验 | ⚠️ 校验（MI-07） |
| `READ_MEDIA_VISUAL_USER_SELECTED`（Android 14+ 部分授权） | 未声明 | ⚠️ 选图体验问题（可选） |

---

## 8. 优先级路线图

### 批次一：不做出问题（1–2 天）

1. **A17-02** 声明并请求 `ACCESS_LOCAL_NETWORK`（投屏恢复）。
2. **A17-01** 后台音频加固适配：FGS 生命周期 + `androidStopForegroundOnPause` 复核 + 用 `cmd audio set-enable-hardening` 验证。
3. **A17-06** 删除失效的 `enableOnBackInvokedCallback`，复核返回桌面逻辑。
4. **BD-05** 清单合规自查（清单改动集中在 `android/`，风险最低）。
5. **MI-07** 16 KB 对齐校验（只读校验，先拿数据）。

### 批次二：耗电与发热（1–2 周）

6. **A17-03** 内存预算（图片缓存 / 解码缓冲 / 列表缓存）。
7. **MI-02** 场景化刷新率 + **PL-06** 视频同步策略（同一主题的两面，合并实施）。
8. **MI-04** 低电量/温控降档（含 MI-09 超分与弹幕降档）。
9. **A17-04** 网络安全配置。
10. **PF-03** 应用不可见统一门控（把已有的零散定时器治理收口）。

### 批次三：画质与体验（2–4 周）

11. **PL-01 / PL-02 / PL-03** 后端与 HDR（必须先做 A/B 实测，再定默认值）。
12. **PL-04 / PL-05** AV1 硬解与失败降级链。
13. **PL-08 / MI-03** PiP、后台播放、通知三者的状态机统一。
14. **PF-02** 中的第 1、2、7 项（视频页 `Obx`、`Opacity`、直播弹幕解析）。
15. **BD-01 / BD-04** R8 与正式签名。

### 批次四：澎湃 OS 兼容与体验（1–2 周，见 3.1 节）

16. ~~**MI-13** 澎湃 OS 权限引导页（自启动 / 省电无限制 / 后台弹出界面 / 通知）~~ ✅ 已实施（2026-09-25）
17. ~~**MI-16** 内存压力主动释放（`didHaveMemoryPressure`）~~ ✅ 已实施
18. ~~**MI-14** MI-02 的落地校验（系统"按应用自定义刷新率"是否覆盖）+ 提示引导~~ ✅ 已实施
19. ~~**MI-15** 持续性能模式申报~~ ✅ 已实施
20. **MI-11 → MI-12** 后台长任务前台服务 → 应用内更新安装链路（两者同源，建议连做）—— **仍是待办**

---

## 9. 明确不建议改动 / 无需改动的部分

1. **不要动 `lib/common/widgets/flutter/**`**：那是 Flutter 的 fork，改动风险高、收益低。
2. **不要用"全局关闭 CT/ECH"来规避 TLS 问题**：只在确证有问题的域上关闭，并保留配置文件的可追溯性。
3. **不要为了省电去关掉 `FLAG_SECURE` 之外的安全默认值**（如 `allowBackup=false`、`forceDarkAllowed=false`）。
4. **不要主动提升刷新率**（`DisplayMode` 写死 120Hz 是纯负担）。
5. **不要新增"反射主线程 MessageQueue / 写入 static final"的代码**（Android 17 已明确会崩）。
6. **不要为了跑分而全局开 Impeller**：先做机型白名单 + A/B。
7. **`useLegacyPackaging = true`** 本身是合理的取舍（体积换加载速度），无需改，只需校验对齐。
8. **`kotlin.incremental=false`** 是 Windows 跨盘符的官方 workaround，与运行时性能无关，别当性能问题处理。

---

## 10. 度量与验证方法（只读命令）

| 主题 | 命令 | 判读 |
| --- | --- | --- |
| 后台音频加固 | `adb shell cmd audio set-enable-hardening enable`；`adb dumpsys audio`；`adb logcat \| Select-String AudioHardening` | 出现 `level: full` = FGS 缺 WIU；`level: partial` = 无 FGS |
| 内存上限 | `adb shell am memory-limiter status`；`adb shell dumpsys activity exit-info <包名>` | 是否出现 `MemoryLimiter:AnonSwap` |
| 本地网络权限 | `adb shell dumpsys package <包名> \| Select-String LOCAL_NETWORK` | 权限是否已声明/已授予 |
| 页大小与对齐 | `adb shell getconf PAGE_SIZE`；`zipalign -c -P 16 -v 4 <apk>` | 16384 时需 16 KB 对齐 |
| 刷新率 | `adb shell dumpsys display \| Select-String -Pattern "refreshRate"`；`adb shell dumpsys SurfaceFlinger --latency` | 视频页是否按内容降档 |
| 温度/温控 | `adb shell dumpsys thermalservice` | 是否已触发降频档位 |
| 隐式 URI 授权 | `adb logcat \| Select-String "Please set the grant explicitly in the app"` | 是否仍有隐式授权依赖 |
| 耗电基线 | `adb shell dumpsys batterystats --reset` → 场景运行 → `adb shell dumpsys batterystats <包名>` | 对比改动前后的电流/唤醒次数 |
| 帧率与掉帧 | `flutter run --profile` + DevTools Performance（视频页滚动 + 弹幕） | P50/P95 帧时间与 jank 帧 |

**第二批新增能力的验证方式**

| 主题 | 操作 / 命令 | 判读 |
| --- | --- | --- |
| PL-01 Impeller A/B | `flutter build apk --release --target-platform android-arm64 --split-per-abi --dart-define-from-file=pili_release.json --android-project-arg=enableImpeller=true`（不加该参数即当前行为） | 同一场景比帧时间 P50/P95 与 CPU；**必须一并回归播放画面、PiP、投屏、截图/WebP 导出** |
| MI-02 刷新率 | 播放一个 24/30fps 视频，然后 `adb shell dumpsys display \| Select-String refreshRate` | 播放中应为 60Hz 档，离开播放页恢复用户档位；开关在「播放设置 → 场景化刷新率」 |
| MI-04 低功耗降档 | `adb shell settings put global low_power 1`（强制省电模式）后播放视频 | 应看到"低功耗降档"提示、刷新率 60Hz、超分被临时清空（播放信息里 `glsl-shaders` 为空） |
| MI-04 温控 | `adb shell dumpsys thermalservice` | 人为加热到 MODERATE 以上，观察是否自动降档 |
| PL-04 是否走硬解/AV1 | 播放页 → 播放信息面板，看 `VideoCodec` / `ContainerFps` | `video-codec` 形如 `hevc (hevc_mediacodec)`＝走硬解；`av1 (av1_mediacodec)`＝AV1 硬解生效 |
| PL-05 降级链 | 用不支持的编码或临时把 `hwdec` 设为 `mediacodec` 触发失败 | 应依次提示并切换 `mediacodec-copy` → `auto-copy` → 软解，且不再无限重试 |
| PL-02 输出后端 | 「播放设置 → 视频输出后端」逐个试，重启视频页看播放信息 | `vo=gpu-next` 是否可用取决于 bundled libmpv 的编译选项；不可用时 mpv 会回退并打日志 |
| MI-03 通知权限 | 首次开启「后台音频服务」，拒绝后再开启 | 应弹出系统通知权限请求；拒绝时媒体控制条不显示属预期 |
| A17-08 回归清单 | 逐项走查：WebView 播放/全屏、保存图片、通知控制、裁剪、PiP、投屏 | 任一环节崩溃/无响应即为 MessageQueue 新实现影响到了相插件，需改用公开 API |
| MI-13 引导页 | 「其它设置 → 澎湃 OS 兼容性检查」 | 通知与省电两项应显示**真实状态**；自启动/后台弹出界面能跳到对应小米页面（跳不过去会自动回退到应用详情页） |
| MI-14 刷新率被覆盖 | 播放一个视频 30s，再打开兼容性检查页 | 若出现"刷新率被系统覆盖"告警，说明系统里给 PiliPlus 指定了刷新率，需改为"跟随系统" |
| MI-15 持续性能 | 无公开读取接口；用 `flutter run --profile` + DevTools 对比长时播放的帧时间波动 | 声明后长时播放的帧时间应更平缓（变化幅度变小） |
| MI-16 内存压力 | `adb shell am send-trim-memory <包名> RUNNING_LOW` | 图片缓存被释放；DevTools 里 ImageCache 的 currentBytes 回落，随后的滚动会重新解码 |

**建议的量化验收线（小米 15 真机）**

- 后台播放（熄屏 30 分钟）：待机电流下降 ≥ 30%，后台播放不被静默掐断（`AudioHardening` 无 `level: partial`）。
- 冷启动首帧：下降 ≥ 25%（目标 < 1.2 s）。
- 视频页滚动 + 弹幕：jank 帧率 < 1%。
- 直播间：单核 CPU 占用下降 ≥ 50%。
- 连续播放 1 小时：电量消耗下降 ≥ 15%。

---

## 附录 A：本文涉及的关键文件索引

| 主题 | 文件 |
| --- | --- |
| Android 17 清单类改动 | `android/app/src/main/AndroidManifest.xml`、新增 `android/app/src/main/res/xml/network_security_config.xml` |
| 构建配置 | `android/app/build.gradle.kts`、`android/gradle.properties`、`android/app/proguard-rules.pro` |
| 主题/启动图 | `android/app/src/main/res/values*/styles.xml`、`values-night-v31/styles.xml` |
| 原生桥 | `android/app/src/main/java/com/example/piliplus/AndroidHelper.java`、`MediaHelper.java`、`MainActivity.kt`、`Utils.kt`；`lib/utils/android/android_helper.dart`、`lib/utils/android/bindings.g.dart` |
| 播放器 | `lib/plugin/pl_player/controller.dart`、`lib/plugin/pl_player/models/hwdec_type.dart`、`lib/plugin/pl_player/utils/fullscreen.dart`、`lib/plugin/pl_player/view/view.dart`、`lib/plugin/pl_player/widgets/mpv_convert_webp.dart` |
| 后台播放/音频 | `lib/services/audio_handler.dart`、`lib/services/audio_session.dart`、`lib/services/service_locator.dart` |
| 偏好默认值 | `lib/utils/storage_pref.dart`、`lib/utils/storage_key.dart` |
| 投屏 | `lib/pages/dlna/view.dart`、`lib/pages/video/controller.dart`、`lib/pages/video/widgets/header_control.dart` |
| 刷新率 | `lib/main.dart`、`lib/pages/setting/pages/display_mode.dart` |
| 网络层 | `lib/http/init.dart`、`lib/http/retry_interceptor.dart`、`lib/grpc/grpc_req.dart` |
| 已有性能报告 | `perf-report/PiliPlus-Android.md` |

## 附录 B：参考的官方文档

- 《行为变更：以 Android 17 或更高版本为目标平台的应用》（developer.android.com/about/versions/17/behavior-changes-17，最后更新 2026-09-18）
- 《行为变更：所有应用》（developer.android.com/about/versions/17/behavior-changes-all，最后更新 2026-09-16）
- 《后台音频强化》（developer.android.com/about/versions/17/changes/bg-audio）
- 《网络安全配置 / 证书透明度 / 加密 Client Hello》（developer.android.com/privacy-and-security/security-config）
- 《前台服务限制与 WIU 能力》（developer.android.com/develop/background-work/services/fgs）
- 《应用内存管理》（developer.android.com/topic/performance/memory）

---

*本文档为静态分析与官方行为变更对照结论，**未修改任何项目文件**。所有"建议改法"均按"只影响 Android"的原则给出落点；实施前请在小米 15 + 澎湃 OS 4 真机上按第 10 节命令复核，并同步更新 `perf-report/PiliPlus-Android.md` 的实施状态。*
