# tool

一些不进构建流水线、需要手动运行的辅助脚本。

## jnigen.dart — 重新生成 JNI 绑定

```
dart run tool/jnigen.dart
```

生成/更新 `lib/utils/android/bindings.g.dart`。改动 `AndroidHelper.java` / `MediaHelper.java`
的方法签名后必须重跑，否则 Dart 侧调用会因签名不一致在运行时报错。

## gen_baseline_profile.ps1 — 生成 / 校验 Android Baseline Profile

产物：`android/app/src/main/baseline-prof.txt`（AGP 会自动合并，无需改 `build.gradle.kts`）。

**前置条件**：先做一次 release 构建，脚本要用编译产物里的类。

```powershell
# 一次 release 构建（也可用 lib/scripts/build.ps1 android 那套）
flutter build apk --release --target-platform android-arm64 --split-per-abi `
    --dart-define-from-file=pili_release.json --no-pub

# 1) 生成 / 更新
powershell -NoProfile -File tool/gen_baseline_profile.ps1

# 2) 只校验（exit 0 = 现有文件与重新生成的一致；1 = 已过期）
powershell -NoProfile -File tool/gen_baseline_profile.ps1 -Check
```

何时需要重跑：

- **升级 Flutter SDK 后**（类名/签名会变，例如 3.47.9 已没有
  `io.flutter.plugin.common.MethodChannel$OutgoingMethodCallHandler`）；
- 新增/移除**插件**（脚本按 `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`
  覆盖全部已注册插件的**入口类**，新增依赖后除了重跑，还要在 `$groups` 里补一组 `HSP`）；
- 改了 `AndroidHelper` / `MediaHelper` / `MainActivity` 的公开方法。

注意：

- 脚本刻意保持 **ASCII-only**：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按 ANSI 读取，
  中文注释会导致解析失败（与 `lib/scripts/patch.ps1` 同样的约束）。
- 生成后会逐行做 HRF 格式校验：若 `javap` 输出格式变化（新增注解行、泛型打印变化），脚本会直接失败
  并打印前 10 条畸形行，而不是静默写出坏规则。`-Check` 用的是大小写敏感比较（`-ceq`）。
- 同一个类写进两个分组会直接报错（否则第二个分组的 flag 会被去重逻辑静默丢掉）。
- 脚本会读 `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`，做两道硬校验：
  **任何已注册插件缺少入口类**、或**入口类被标成 `H` 而不是 `HSP`**，都直接抛错并列出名单
  —— 前三轮就是因为靠人肉记忆，29 个插件只盖了 13 个，且 `screen_brightness` 错标为 `H`。
  输出末行的 `plugins N` 就是这个校验的结果（registrant 不存在时为 `plugins n/a`）。
- **写进 profile 不等于进了包**：新增类后要做一次 release 构建，再到
  `build/app/outputs/mapping/release/mapping.txt` 查该类的类级映射
  （`SomeClass -> xx:`）。没有这一行就说明 R8 把它消除了，对应规则永远不会落地，应该从脚本里删掉。
  不要拿 `combined_art_profile/.../baseline-prof.txt` 按原名 grep —— 那里是混淆名，必然 0 命中。
- 路径拼接一律用 `[IO.Path]::Combine`、classpath 用 `[IO.Path]::PathSeparator`，所以 Windows 本地与
  Linux CI 都能跑（早期版本用 `\` 与 `;` 字面量，在 Linux 上会找不到类）。
- `android/app/src/main/baseline-prof.txt` 在 `.gitattributes` 里固定为 `text eol=lf`，
  避免 `core.autocrlf=true` 时工作区变成 CRLF 导致 `-Check` 需要额外归一。
- 选类依据、作用边界、构建验证数据见 `docs/PiliPlus-BaselineProfile接入报告-20261107.md`。
