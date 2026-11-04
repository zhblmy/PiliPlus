# Android 真机性能测试接入指南（供 AI 协作使用）

> 目的：让 AI（本仓库中的 Copilot 助手）能够在你自己的 Android 手机上，**跑起来 → 采数据 → 定位瓶颈 → 改代码 → 复测** 闭环工作。
> 本文只说明"你该怎么做、我需要什么"，不涉及任何代码改动。

---

## 0. 一分钟速查

| 步骤 | 你要做的事 | 验证命令 |
| --- | --- | --- |
| 1 | 手机开启「开发者选项 → USB 调试」 | `adb devices -l` 能看到设备且状态为 `device` |
| 2 | 数据线连接电脑，手机上点「允许 USB 调试」 | `flutter devices` 能看到你的手机 |
| 3 | 告诉我：设备序列号 + 要测的场景 | —— |
| 4 | 我执行 profile 构建与数据采集，你按提示操作 App | `flutter run --profile -d <serial>` |
| 5 | 我改代码，你再跑一遍相同场景，对比数据 | 复测前后数值 |

最小必要条件：**手机连着（USB 或无线）、`adb devices` 显示 `device`、App 已安装、你能配合点屏幕。**

---

## 1. 本机环境现状（已核对，2026-11-01）

| 项目 | 现状 | 说明 |
| --- | --- | --- |
| Flutter | `C:\Users\zhang\flutter\bin\flutter.bat`，版本 **3.47.9** | 与 [pubspec.yaml](../pubspec.yaml) 要求的 `flutter: 3.47.9` 完全一致，无需 FVM |
| Dart | 3.13.7 | 满足 `sdk: ">=3.13.0"` |
| DevTools | 2.60.0 | 性能面板来源 |
| adb | `C:\Users\zhang\AppData\Local\Android\Sdk\platform-tools\adb.exe` | 已在 PATH 中 |
| Android SDK | `C:\Users\zhang\AppData\Local\Android\Sdk` | 见 `android/local.properties` |
| 当前设备 | **未连接**（`adb devices` 为空） | 需要你完成第 2 节 |

包名（后续命令都要用，注意后缀）：

| 构建类型 | applicationId | 启动 Activity |
| --- | --- | --- |
| debug | `com.example.piliplus.debug` | `com.example.piliplus/.MainActivity` |
| release（`-Pdev`） | `com.example.piliplus.dev` | 同上 |
| release | `com.example.piliplus` | 同上 |

> 依据：[android/app/build.gradle.kts](../android/app/build.gradle.kts) 中 `debug { applicationIdSuffix = ".debug" }`、`release` 下 `-Pdev` 时追加 `.dev`；Manifest 中唯一 LAUNCHER 组件是 `.MainActivity`（`namespace = com.example.piliplus`）。

已知构建注意点（会显著影响"改一次代码要等多久"）：

- `android/gradle.properties` 里 `kotlin.incremental=false`——因为 pub cache 在 C 盘、项目在 F 盘，增量缓存会报 `different roots`。所以**每次改动后重新构建比常规项目慢**，这是预期的。
- `org.gradle.jvmargs=-Xmx4G`，首次/清理后构建可能 5~15 分钟。
- Impeller 通过 Manifest placeholder 控制：默认 `true`，可用 `-PenableImpeller=false` 关闭（见 [AndroidManifest.xml](../android/app/src/main/AndroidManifest.xml) 第 49 行）。

---

## 2. 第一步：手机与电脑建立连接

### 2.1 USB 连接（首选，稳定、可传大文件）

1. 手机 → 设置 → 关于手机 → 连点「版本号」7 次 → 开启开发者选项。
2. 设置 → 系统 → 开发者选项：
   - 打开 **「USB 调试」**；
   - **小米 / HyperOS 额外两项（很关键）**：
     - **「USB 调试（安全设置）」**：不打开则 `adb shell input tap/swipe` 无法注入，我就没法替你滑动屏幕；
     - **「USB 安装」**：不打开则无法用 `adb install` 装包（只能靠 `flutter run` 推）。
   - 关闭「USB 调试（撤销授权）」如果之前误点过，需要重新授权。
3. 数据线连接电脑，手机弹「是否允许 USB 调试」，勾选 **一律允许** 后确定。
   - 如果没弹窗：换数据线（部分线只充电）、换 USB 口、执行 `adb kill-server; adb start-server` 后重新插拔。
4. 验证：

```powershell
adb devices -l
# 期望输出示例：
# List of devices attached
# 3f9a1b2c  device product:nuwa model:2211133C device:nuwa transport_id:3

flutter devices
```

状态含义：

- `device` → 可以开工。
- `unauthorized` → 手机上还没点允许（或需要「撤销 USB 调试授权」后重插）。
- `offline` → `adb kill-server; adb start-server`，仍不行就换线/换口。
- 列表为空 → 线是纯充电线、驱动问题、或开发者选项没开。

### 2.2 无线调试（Android 11+ / HyperOS，可边充电边测、手不受线约束）

手机与电脑连**同一个 Wi-Fi**，然后：

1. 开发者选项 → **无线调试** → 打开 → 点「使用配对码配对设备」，手机显示 `IP:端口` 与 6 位配对码。
2. 电脑上：

```powershell
adb pair 192.168.1.23:37123      # 端口来自配对弹窗，输入弹窗上的 6 位码
adb connect 192.168.1.23:42233   # 端口是"无线调试"主页面显示的那个（与配对端口不同）
adb devices -l
```

注意事项：

- 两个端口号不一样：**配对用弹窗里的**，**connect 用主页面显示的**。
- 手机重启 / 切 Wi-Fi / 息屏久了之后端口会变，需要重新 `adb connect`；建议正式测试用 USB，无线只用于"不方便插线"的场景。
- 无线调试的延迟抖动会影响帧率数据，**做性能基线时优先 USB**。
- 不要 USB 和无线同时连同一台手机，会出现两个设备条目导致命令打错设备。

---

## 3. 第二步：让我"看到"你的手机

### 3.1 我能做 / 不能做

| 能力 | 说明 |
| --- | --- |
| ✅ 执行 adb / flutter / gradle 命令 | 在本会话里跑构建、安装、抓日志、抓帧数据 |
| ✅ 读取 logcat、崩溃栈、帧统计 | `adb logcat`、DevTools 报告的文本指标 |
| ✅ 截图并"看见"界面 | `adb shell screencap` + `adb pull`，然后我读取图片判断当前在哪个页面 |
| ✅ 模拟点击/滑动/返回 | `adb shell input tap` / `swipe` / `keyevent`（需 2.1 中的「USB 调试（安全设置）」） |
| ✅ 改代码并重新构建安装 | 编辑 `lib/**`，`flutter run` 或 `flutter build apk --profile` + `adb install -r` |
| ❌ 解锁手机 / 点系统授权弹窗 | 首次 USB 授权、安装未知来源确认、登录账号等必须你手动点 |
| ❌ 代替你登录 B 站账号 | 账号/扫码必须你操作 |
| ❌ 感知"手感是否顺滑" | 卡顿的主观位置需要你描述（比如"首页下滑到第 3 屏开始掉帧"） |

### 3.2 请提供给我的 3 条信息

1. **设备标识**：`adb devices -l` 里的序列号（USB 是 8~16 位十六进制，无线是 `IP:端口`）。
2. **测试机型/系统**：例如 小米 15 / HyperOS 2.0 / Android 15 / 120Hz。仓库 [docs/](./) 里已有针对小米 15 的优化清单，机型信息能让我对齐历史结论。
3. **场景与预期**：例如"冷启动 → 首页下滑 10 秒 → 点开视频 → 播 30 秒 → 拉评论区 → 返回"，以及"哪里觉得卡"。

### 3.3 隐私与安全（重要）

- `adb logcat`、录屏、DevTools 抓包可能包含 **账号 Cookie / 播放记录 / 设备标识**。给我看之前请：只贴相关片段、不要把完整 logcat 直接贴到公开 issue。
- 无线调试仅在可信 Wi-Fi 下开启；测完关掉「无线调试」。
- 我不会把设备日志、抓包内容发到任何外部服务，也不会写进提交的代码里。

---

## 4. 第三步：构建与运行的两种模式

### 4.1 迭代模式（改代码时用 debug）

```powershell
flutter run -d <serial>
# 运行中：r = 热重载，R = 热重启，p = 帧率/性能叠加层，q = 退出
```

debug 模式有 JIT 与断言开销，**不能用来出性能结论**，只用来验证功能/交互改对了。

### 4.2 测量模式（出数据时用 profile）

```powershell
flutter run --profile -d <serial>
```

- profile 模式是 AOT 编译 + 保留 tracing，**数据才有意义**。
- profile / release **不支持热重载与热重启**，每次改代码都要重新构建安装。
- 关键取舍：**先用 debug 把交互改对 → 再切 profile 采数**，不要每次小改动都等 profile 构建。

### 4.3 直接装 APK（构建一次、多次安装，最省时）

```powershell
flutter build apk --profile --target-platform android-arm64
adb install -r build\app\outputs\flutter-apk\app-profile.apk
```

- 真机基本都是 arm64，指定 `--target-platform android-arm64` 可显著缩短构建时间。
- `-r` 覆盖安装；若报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`（签名不一致，例如之前装过 release 签名包）→ 先 `adb uninstall com.example.piliplus.debug`。
- 切 Impeller 做 A/B：

```powershell
flutter build apk --profile --target-platform android-arm64 -PenableImpeller=false
```

### 4.4 首次启动 / shader 相关专项

```powershell
# 复现"首次进入才卡一下"的着色器编译抖动
flutter run --profile --purge-persistent-cache -d <serial>

# 只抓启动阶段时间线，跑完自动退出并输出 trace 文件（默认在 build/ 目录）
flutter run --profile --trace-startup -d <serial>
```

---

## 5. 第四步：性能数据怎么取（按指标分类）

> ⚠️ **Flutter 专属坑**：`adb shell dumpsys gfxinfo <pkg>` 统计的是 HWUI 绘制的 View 帧。Flutter 在单个 SurfaceView/TextureView 上自绘，所以 gfxinfo 常常显示"几乎没有帧"，**不能作为 Flutter 卡顿依据**。请以 DevTools 帧图 + SurfaceFlinger 层延迟 + Perfetto 为准。

### 5.1 帧率与卡顿（最核心）

| 手段 | 命令 / 操作 | 看什么 |
| --- | --- | --- |
| DevTools Performance | `flutter run --profile` 后终端按提示打开 DevTools → Performance | UI/Raster 每帧耗时、超过 16.7ms(60Hz)/8.3ms(120Hz) 的帧、jank 占比 |
| 屏幕叠加帧率 | `flutter run --profile` 运行中按 `p`（或在 DevTools 里开 Performance Overlay） | 实时 UI/Raster 曲线，快速判断是 CPU 还是光栅化瓶颈 |
| SurfaceFlinger 层延迟 | `adb shell dumpsys SurfaceFlinger --latency`（先 `adb shell dumpsys SurfaceFlinger --list` 找 Flutter 层名） | 实际呈现到屏幕的帧间隔分布 |
| Perfetto / atrace | `adb shell atrace -a -t 10 -b 32768 gfx view sched freq -o /data/local/tmp/t.html`，再 `adb pull /data/local/tmp/t.html` | 系统侧 GPU/合成/调度耗时，判断是否是系统或 GPU 瓶颈 |
| Flutter 主动 systrace | `flutter run --profile --trace-systrace -d <serial>` | Flutter 引擎事件直接进系统 trace |

判定建议：

- 120Hz 设备目标帧预算 8.3ms，60Hz 为 16.7ms；**UI 线程（Dart build/layout）超预算 = 我们的代码问题；Raster 线程超预算 = 绘制/图片/着色器问题**。
- 用"同一场景、同一时长、同一台机器"的 **P90/P95 帧耗时 + jank 帧数** 做前后对比，不看单帧峰值。

### 5.2 启动耗时

```powershell
# 冷启动（-W 会输出 TotalTime/WaitTime）
adb shell am force-stop com.example.piliplus.debug
adb shell am start -W -n com.example.piliplus.debug/com.example.piliplus.MainActivity
```

配合 `flutter run --profile --trace-startup` 看首帧前的引擎/框架阶段（Dart VM 初始化、首帧 build、首帧 raster）。

### 5.3 CPU

```powershell
adb shell top -H -n 1 -d 1 -p <pid>      # 线程级，找 UI/Raster/IO 线程
```

深度分析用 DevTools CPU Profiler（profile 模式下可采集调用栈），或 Perfetto 抓 `sched freq idle`。

### 5.4 内存 / 泄漏

```powershell
adb shell dumpsys meminfo com.example.piliplus.debug
```

泄漏排查套路（视频类 App 高发）：进入页面 → 返回 → 重复 5~10 次，看 `TOTAL PSS` 是否单调上升；同时用 DevTools Memory 面板做 Diff / 快照对比。重点怀疑对象：控制器未 dispose、图片缓存、弹幕/播放器实例、全局监听未移除。

### 5.5 发热与耗电（视频 App 必测）

```powershell
adb shell dumpsys battery            # 温度、电量
adb shell dumpsys thermalservice     # 各温区
```

长视频播放 10 分钟后对比"改前/改后"的温度上升与 `mAh` 掉电速率，比单看帧率更能反映真实体验。

### 5.6 网络 / 下载性能（涉及 `lib/http/download.dart` 等）

- Flutter 侧日志：`flutter run --profile` 的终端输出 + `debugPrint`（profile 下仍在）。
- 系统侧：`adb logcat -s flutter`、`adb shell dumpsys netstats`。
- 关注点：并发数、分片大小、重试策略、抖动下的吞吐，而不是单次耗时。

### 5.7 包体积

```powershell
flutter build apk --release --analyze-size --target-platform android-arm64
```

### 5.8 采集前必须固定的环境变量（否则数据不可比）

- 关闭省电模式 / 均衡模式，屏幕亮度固定（或手动固定到 50%）；
- 若手机有「性能模式/高刷开关」，固定为同一档（例如强制 120Hz：`adb shell settings put system peak_refresh_rate 120`）；
- 清后台、关自动更新、关闭「开发者选项 → 强制 GPU 渲染」这类会干扰的开关；
- 同一网络（Wi-Fi 信道/信号强度也会影响视频加载）；
- 每次采样前 `am force-stop`，保证是冷启动路径。

---

## 6. 第五步：标准测试脚本（可复现·可比对）

建议每次测试跑同一个脚本，我负责用 adb 驱动、你负责必要时确认授权。

| # | 场景 | 我执行的等价命令（示例） | 采集内容 |
| --- | --- | --- | --- |
| 1 | 冷启动到首页可交互 | `am force-stop` → `am start -W` | 启动耗时、首帧 trace |
| 2 | 首页信息流连续下滑 10s | `adb shell input swipe 540 1800 540 400 200` ×N | 帧耗时 P90/P95、jank 数、Raster 峰值 |
| 3 | 顶栏收起/展开动画 | 点击 + 滑动组合 | 转场期间帧分布（对齐 [PiliPlus-顶栏底栏动画重构与视频转场优化报告.md](./PiliPlus-顶栏底栏动画重构与视频转场优化报告.md) 的结论） |
| 4 | 进入视频详情并上传首帧 | 点击封面 | 首帧时间、加载期 jank |
| 5 | 播放 30s（含弹幕开关对比） | 点击播放 / 关闭弹幕 | 平均帧耗时、CPU、温度 |
| 6 | 打开评论区并快速上下滑 | 多次 swipe | 列表帧耗时、内存增量 |
| 7 | 返回列表（复用/重建） | `input keyevent 4` | 返回动画帧、内存是否回落 |
| 8 | 重复进出 5 次 | 循环 2~7 | 内存泄漏趋势 |

产物建议：每次测试生成一份简短记录（我可以在 session 工作区里维护，不入库）：

```
设备: 小米15 / HyperOS x / 120Hz
提交: <git rev-parse --short HEAD>
模式: profile / Impeller=on / arm64
场景2 首页下滑: UI P90 9.1ms, Raster P90 7.8ms, jank 3/600
对比基线: UI P90 12.4ms → 改善 27%
```

---

## 7. 第六步：改代码 → 复测闭环

1. **定位**：我根据帧图/CPU 采样指出瓶颈点（例如某 `build()` 里重建了整棵子树、某动画用了 `Opacity`、列表未用 `itemExtent`、图片未指定 cacheWidth）。
2. **小步改**：一次只改一个变量，便于归因（多个改动混合会让数据无法解释）。
3. **验证**：
   - 静态检查：`flutter analyze`（仓库有 [analysis_options.yaml](../analysis_options.yaml)）；
   - 目标测试：`flutter test test\<相关>_test.dart`（[test/](../test) 目录既有单测）；
   - 功能回归：debug 模式热重载确认交互没坏。
4. **采数**：`flutter build apk --profile --target-platform android-arm64` → `adb install -r` → 跑同一脚本 → 与基线对比。
5. **入库**：只在数据确实改善且无回归时提交；提交前我会说明"改了什么、为什么、前后数据"。

**注意**：改动涉及 `android/`（Manifest、gradle、Kotlin）时必须全量重建，且 `local.properties` 里 `flutter.buildMode` 会被改写（这是 flutter 工具行为，不要提交）。

---

## 8. 常见问题排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `adb devices` 空 | 纯充电线 / USB 口 / 未开 USB 调试 | 换线换口；`adb kill-server; adb start-server` |
| `unauthorized` | 手机未授权 | 手机上点「允许」；或「撤销 USB 调试授权」后重插 |
| `offline` | adb 版本与服务不一致 / 线接触不良 | `adb kill-server` 后重启服务；`adb version` 与 SDK 版本核对 |
| `more than one device` | USB + 无线同时连 | 用 `-s <serial>` 指定，或 `adb disconnect` |
| 无线调试连不上 | 端口变化 / 不同网段 / AP 隔离 | 重新 `adb pair`；确认同一网段；关掉路由 AP 隔离 |
| `input tap` 无反应（小米） | 未开「USB 调试（安全设置）」 | 开发者选项里打开后重连 |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 签名/包名冲突 | `adb uninstall <pkg>` 后重装 |
| `flutter run` 卡在 Gradle | 首次构建 / 双盘增量缓存 | 正常，首次 5~15 分钟；保持 `kotlin.incremental=false` |
| DevTools 帧图不动 | 跑在 debug 模式 | 必须 `--profile` |
| `dumpsys gfxinfo` 显示 0 帧 | Flutter 自绘，不走 HWUI | 改用 DevTools / SurfaceFlinger / Perfetto（见 5.1） |
| 截图在 PowerShell 里是乱码/损坏 | PS 5.1 重定向破坏二进制 | 用 `adb shell screencap -p /sdcard/s.png` + `adb pull` |
| `flutter devices` 有设备但 `adb` 没有 | PATH/多份 adb | 统一用 `C:\Users\zhang\AppData\Local\Android\Sdk\platform-tools\adb.exe` |

---

## 9. 命令速查（可直接复制）

```powershell
# 连接与确认
adb devices -l
flutter devices

# 无线
adb pair <ip>:<配对端口>
adb connect <ip>:<调试端口>

# 装包与启停（debug 包）
adb install -r build\app\outputs\flutter-apk\app-profile.apk
adb shell am force-stop com.example.piliplus.debug
adb shell am start -W -n com.example.piliplus.debug/com.example.piliplus.MainActivity

# 性能模式运行（含 DevTools）
flutter run --profile -d <serial>

# 采集
adb shell dumpsys SurfaceFlinger --list
adb shell dumpsys SurfaceFlinger --latency
adb shell top -H -n 1 -d 1 -p <pid>
adb shell dumpsys meminfo com.example.piliplus.debug
adb shell dumpsys battery
adb shell dumpsys thermalservice
adb shell atrace -a -t 10 -b 32768 gfx view sched freq -o /data/local/tmp/t.html
adb pull /data/local/tmp/t.html
adb logcat -s flutter

# 截图（PowerShell 下务必用 pull，不要用 > 重定向）
adb shell screencap -p /sdcard/s.png
adb pull /sdcard/s.png F:\Github\PiliPlus\build\s.png

# 固定屏幕/刷新率（部分机型需要）
adb shell settings put system peak_refresh_rate 120
adb shell settings put global window_animation_scale 1
```

---

## 10. 我现在需要你做的三件事

1. 按第 2 节把手机连上，贴给我 `adb devices -l` 的输出。
2. 告诉我机型 + 系统版本 + 刷新率设置。
3. 描述一个**具体卡顿场景**（在哪个页面、做什么操作、期望是什么）。

拿到这三项，我就能：构建 profile 包 → 按第 6 节脚本采集基线 → 定位瓶颈 → 提交最小化改动 → 用同一脚本复测并给出前后对比数据。
