<#
.SYNOPSIS
    Generate / verify android/app/src/main/baseline-prof.txt.

.DESCRIPTION
    Uses javap on the real compiled artifacts to emit AGP's baseline profile (HRF) lines.
    Dart is AOT-compiled, so this profile only covers the Android side DEX:
    Flutter embedding, startup plugins and the app's own Java/Kotlin classes.

    Prerequisite: run one release build first (otherwise the class files do not exist):
        flutter build apk --release --target-platform android-arm64 --split-per-abi `
            --dart-define-from-file=pili_release.json --no-pub

    NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less scripts as ANSI,
    so non-ASCII comments break parsing (same reason lib/scripts/patch.ps1 is ASCII).

.PARAMETER FlutterRoot
    Flutter SDK root. Defaults to the parent of the flutter command on PATH, then FLUTTER_ROOT.

.PARAMETER OutFile
    Output path. Defaults to <repo>/android/app/src/main/baseline-prof.txt

.PARAMETER Check
    Do not write; regenerate in memory and compare with the existing file.
    Exit 0 = identical, 1 = differs (prints the first differing lines).

.EXAMPLE
    powershell -NoProfile -File tool/gen_baseline_profile.ps1

.EXAMPLE
    powershell -NoProfile -File tool/gen_baseline_profile.ps1 -Check

.NOTES
    Class names / signatures change between Flutter versions. If javap reports a missing class,
    confirm the name first: jar tf <jar> | findstr <ClassName>
    Keep the class list in sync with the baseline profile report: docs/PiliPlus-BaselineProfile*.md (section 4).
#>
[CmdletBinding()]
param(
    [string]$FlutterRoot = '',
    [string]$OutFile = '',
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
if (-not $OutFile) {
    $OutFile = [IO.Path]::Combine($root, 'android', 'app', 'src', 'main', 'baseline-prof.txt')
}

if (-not $FlutterRoot) {
    if ($env:FLUTTER_ROOT) {
        $FlutterRoot = $env:FLUTTER_ROOT
    } else {
        $flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
        if (-not $flutterCmd -or -not $flutterCmd.Source) { throw 'flutter command not found; pass -FlutterRoot' }
        $FlutterRoot = Split-Path (Split-Path $flutterCmd.Source -Parent) -Parent
    }
}
if (-not (Test-Path ([IO.Path]::Combine($FlutterRoot, 'bin', 'internal', 'engine.version')))) {
    throw "Invalid FlutterRoot '$FlutterRoot' (bin/internal/engine.version not found); pass -FlutterRoot"
}
if (-not (Get-Command javap -ErrorAction SilentlyContinue)) {
    throw 'javap not found on PATH; it ships with the JDK used by the Android build (JAVA_HOME\bin)'
}

# ---------------------------------------------------------------------------
# Resolve classpaths
# ---------------------------------------------------------------------------
$engineVersion = (Get-Content ([IO.Path]::Combine($FlutterRoot, 'bin', 'internal', 'engine.version'))).Trim()
# Windows uses %USERPROFILE%/.gradle, Linux/macOS (CI) use $HOME/.gradle
$gradleHome = if ($env:GRADLE_USER_HOME) { $env:GRADLE_USER_HOME }
              elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.gradle' }
              else { Join-Path $HOME '.gradle' }
# [IO.Path]::Combine keeps this cross-platform ('\' literals would break on Linux CI)
$embDir = [IO.Path]::Combine($gradleHome, 'caches', 'modules-2', 'files-2.1', 'io.flutter',
                             'flutter_embedding_release', "1.0.0-$engineVersion")
if (-not (Test-Path $embDir)) {
    throw "Flutter embedding jar not found (engine $engineVersion). Run a release build first."
}
$embJar = (Get-ChildItem $embDir -Recurse -Filter '*.jar' | Select-Object -First 1).FullName

$appJavacDir = [IO.Path]::Combine($root, 'build', 'app', 'intermediates', 'javac', 'release',
                                  'compileReleaseJavaWithJavac', 'classes')
$appKotlinDir = [IO.Path]::Combine($root, 'build', 'app', 'tmp', 'kotlin-classes', 'release')
if (-not (Test-Path $appJavacDir) -or -not (Test-Path $appKotlinDir)) {
    throw ("App classes not found ($appJavacDir / $appKotlinDir). " +
           "Run: flutter build apk --release --target-platform android-arm64 --split-per-abi " +
           "--dart-define-from-file=pili_release.json --no-pub")
}
# javap -cp uses ';' on Windows and ':' elsewhere
$appCp = $appJavacDir + [IO.Path]::PathSeparator + $appKotlinDir

function PluginJar([string]$module) {
    $dir = [IO.Path]::Combine($root, 'build', $module, 'intermediates', 'aar_main_jar', 'release')
    if (-not (Test-Path $dir)) {
        throw "Plugin $module not built ($dir). Run a release build first."
    }
    $jar = Get-ChildItem $dir -Recurse -Filter classes.jar | Select-Object -First 1
    if (-not $jar) { throw "classes.jar not found for $module" }
    $jar.FullName
}

$jAudio   = PluginJar 'audio_service'
$jSession = PluginJar 'audio_session'
$jJni     = PluginJar 'jni'
$jJniFl   = PluginJar 'jni_flutter'
$jMkv     = PluginJar 'media_kit_video'
$jPrefs   = PluginJar 'shared_preferences_android'
$jDevinfo = PluginJar 'device_info_plus'
$jPkginfo = PluginJar 'package_info_plus'
$jBright  = PluginJar 'screen_brightness_android'
$jBattery = PluginJar 'battery_plus'
$jDynamic = PluginJar 'dynamic_color'
$jDisp    = PluginJar 'flutter_displaymode'
$jLinks   = PluginJar 'app_links'

# ---------------------------------------------------------------------------
# Selected classes. f = flags (H/S/P); the L...; class descriptor is added by this script.
#   HSP = cold start critical path, H = post first frame / conditional path
# Rationale for every group: docs/PiliPlus-BaselineProfile*.md (section 4).
# ---------------------------------------------------------------------------
$groups = @(
    # Flutter embedding: cold start
    @{ f = 'HSP'; cp = $embJar; classes = @(
        'io.flutter.FlutterInjector'
        'io.flutter.embedding.android.FlutterActivity'
        'io.flutter.embedding.android.FlutterActivityAndFragmentDelegate'
        'io.flutter.embedding.android.FlutterActivityAndFragmentDelegate$Host'
        'io.flutter.embedding.android.FlutterView'
        'io.flutter.embedding.android.FlutterSurfaceView'
        'io.flutter.embedding.android.FlutterTextureView'
        'io.flutter.embedding.android.AndroidTouchProcessor'
        'io.flutter.embedding.android.MotionEventTracker'
        'io.flutter.embedding.android.KeyboardManager'
        'io.flutter.embedding.engine.FlutterEngine'
        'io.flutter.embedding.engine.FlutterEngineConnectionRegistry'
        'io.flutter.embedding.engine.FlutterJNI'
        'io.flutter.embedding.engine.FlutterShellArgs'
        'io.flutter.embedding.engine.dart.DartExecutor'
        'io.flutter.embedding.engine.dart.DartMessenger'
        'io.flutter.embedding.engine.dart.DartMessenger$Reply'
        'io.flutter.embedding.engine.dart.PlatformTaskQueue'
        'io.flutter.embedding.engine.loader.FlutterLoader'
        'io.flutter.embedding.engine.loader.ApplicationInfoLoader'
        'io.flutter.embedding.engine.renderer.FlutterRenderer'
        'io.flutter.embedding.engine.renderer.SurfaceTextureSurfaceProducer'
        'io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding'
        'io.flutter.embedding.engine.plugins.FlutterPlugin$FlutterPluginBinding'
        'io.flutter.embedding.engine.dart.DartExecutor$DartEntrypoint'
        'io.flutter.embedding.engine.loader.FlutterApplicationInfo'
        'io.flutter.embedding.engine.plugins.lifecycle.HiddenLifecycleReference'
        'io.flutter.embedding.engine.plugins.util.GeneratedPluginRegister'
        'io.flutter.embedding.engine.systemchannels.SystemChannel'
        'io.flutter.embedding.engine.systemchannels.LifecycleChannel'
        'io.flutter.embedding.engine.systemchannels.NavigationChannel'
        'io.flutter.embedding.engine.systemchannels.PlatformChannel'
        'io.flutter.embedding.engine.systemchannels.SettingsChannel'
        'io.flutter.embedding.engine.systemchannels.KeyEventChannel'
        'io.flutter.embedding.engine.systemchannels.KeyboardChannel'
        'io.flutter.embedding.engine.systemchannels.AccessibilityChannel'
        'io.flutter.embedding.engine.systemchannels.LocalizationChannel'
        'io.flutter.embedding.engine.systemchannels.RestorationChannel'
        'io.flutter.embedding.engine.systemchannels.MouseCursorChannel'
        'io.flutter.embedding.engine.systemchannels.TextInputChannel'
        'io.flutter.embedding.engine.systemchannels.ScribeChannel'
        'io.flutter.embedding.engine.systemchannels.SensitiveContentChannel'
        'io.flutter.embedding.engine.systemchannels.BackGestureChannel'
        'io.flutter.embedding.engine.systemchannels.SpellCheckChannel'
        'io.flutter.embedding.engine.systemchannels.PlatformViewsChannel'
        'io.flutter.embedding.engine.systemchannels.DeferredComponentChannel'
        'io.flutter.embedding.engine.systemchannels.ProcessTextChannel'
        'io.flutter.plugin.common.MethodChannel'
        'io.flutter.plugin.common.MethodChannel$IncomingMethodCallHandler'
        'io.flutter.plugin.common.MethodChannel$IncomingResultHandler'
        'io.flutter.plugin.common.BasicMessageChannel'
        'io.flutter.plugin.common.BasicMessageChannel$IncomingMessageHandler'
        'io.flutter.plugin.common.EventChannel'
        'io.flutter.plugin.common.EventChannel$IncomingStreamRequestHandler'
        'io.flutter.plugin.common.MethodCall'
        'io.flutter.plugin.common.StandardMethodCodec'
        'io.flutter.plugin.common.StandardMessageCodec'
        'io.flutter.plugin.common.StringCodec'
        'io.flutter.plugin.platform.PlatformPlugin'
        'io.flutter.plugin.platform.PlatformViewsControllerDelegator'
        'io.flutter.plugin.platform.PlatformViewsController2'
        'io.flutter.view.VsyncWaiter'
        'io.flutter.util.HandlerCompat'
        'io.flutter.util.ViewUtils'
        'io.flutter.Log'
    ) }

    # Flutter embedding: post first frame / conditional
    @{ f = 'H'; cp = $embJar; classes = @(
        'io.flutter.embedding.android.FlutterImageView'
        'io.flutter.plugin.editing.TextInputPlugin'
        'io.flutter.plugin.editing.InputConnectionAdaptor'
        'io.flutter.plugin.editing.ListenableEditingState'
        'io.flutter.plugin.platform.PlatformViewsController'
        'io.flutter.view.AccessibilityBridge'
        'io.flutter.embedding.engine.image.ImageDecoderDefaultImpl'
        'io.flutter.embedding.engine.image.FlutterImageDecoder'
    ) }

    # Plugins registered / used at startup
    @{ f = 'HSP'; cp = $jAudio; classes = @(
        'com.ryanheise.audioservice.AudioServiceActivity'   # super class of MainActivity
        'com.ryanheise.audioservice.AudioServicePlugin'
        'com.ryanheise.audioservice.AudioServicePlugin$AudioHandlerInterface'
        'com.ryanheise.audioservice.AudioServicePlugin$ClientInterface'
        'com.ryanheise.audioservice.AudioService'           # foreground service started at boot
        'com.ryanheise.audioservice.AudioService$MediaSessionCallback'
    ) }
    @{ f = 'HSP'; cp = $jSession; classes = @(
        'com.ryanheise.audio_session.AudioSessionPlugin'
        'com.ryanheise.audio_session.AudioManagerSingleton'
    ) }
    @{ f = 'HSP'; cp = $jJniFl; classes = @('com.github.dart_lang.jni_flutter.JniFlutterPlugin') }
    @{ f = 'HSP'; cp = $jJni; classes = @('com.github.dart_lang.jni.JniPlugin', 'com.github.dart_lang.jni.JniUtils') }
    @{ f = 'HSP'; cp = $jPrefs; classes = @('io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin') }
    @{ f = 'HSP'; cp = $jDevinfo; classes = @(
        'dev.fluttercommunity.plus.device_info.DeviceInfoPlusPlugin'
        'dev.fluttercommunity.plus.device_info.MethodCallHandlerImpl'
    ) }
    @{ f = 'HSP'; cp = $jPkginfo; classes = @('dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin') }
    @{ f = 'HSP'; cp = $jBattery; classes = @('dev.fluttercommunity.plus.battery.BatteryPlusPlugin') }
    @{ f = 'HSP'; cp = $jDynamic; classes = @('io.material.plugins.dynamic_color.DynamicColorPlugin') }
    @{ f = 'HSP'; cp = $jDisp; classes = @('com.ajinasokan.flutterdisplaymode.DisplayModePlugin') }
    @{ f = 'HSP'; cp = $jLinks; classes = @(
        'com.llfbandit.app_links.AppLinksPlugin'
        'com.llfbandit.app_links.AppLinksHelper'
    ) }
    @{ f = 'HSP'; cp = $jMkv; classes = @('com.alexmercerind.media_kit_video.MediaKitVideoPlugin') }

    # Used only after the first frame
    @{ f = 'H'; cp = $jMkv; classes = @(
        'com.alexmercerind.media_kit_video.VideoOutput'
        'com.alexmercerind.media_kit_video.VideoOutputManager'
        'com.alexmercerind.media_kit_video.Utils'
    ) }
    @{ f = 'H'; cp = $jBright; classes = @('com.aaassseee.screen_brightness_android.ScreenBrightnessAndroidPlugin') }

    # App's own Android layer
    # NOTE: BiliDocumentsProvider is a ContentProvider, created by the system BEFORE
    # Application.onCreate, so it belongs to the startup profile (S), not to H.
    @{ f = 'HSP'; cp = $appCp; classes = @(
        'com.example.piliplus.MainActivity'
        'com.example.piliplus.AndroidHelper'   # static init + maxScreenSize() run before first frame
        'com.example.piliplus.BiliDocumentsProvider'
    ) }
    # Only reached after the first frame:
    #   MediaHelper   -> PiP actions (AndroidHelper.updatePipActions / setPipActions)
    #   DownloadForegroundService -> started on the first download
    # NOTE: AndroidHelper$ToDart is intentionally NOT listed: it is a static-only holder
    # class that is never instantiated and has no <clinit>, so it has nothing to compile.
    @{ f = 'H'; cp = $appCp; classes = @(
        'com.example.piliplus.MediaHelper'
        'com.example.piliplus.DownloadForegroundService'
    ) }
)

# ---------------------------------------------------------------------------
# A class may only appear in one group: a duplicated entry would silently keep the
# first flag and hide a wrong classification.
$seenClass = @{}
$dupes = @()
foreach ($g in $groups) {
    foreach ($c in $g.classes) {
        if ($seenClass.ContainsKey($c)) { $dupes += "$c ($($seenClass[$c]) / $($g.f))" }
        else { $seenClass[$c] = $g.f }
    }
}
if ($dupes.Count -gt 0) { throw "class listed in more than one group: $($dupes -join '; ')" }

# ---------------------------------------------------------------------------
# javap -> HRF
# ---------------------------------------------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
$seen = New-Object 'System.Collections.Generic.HashSet[string]'

foreach ($g in $groups) {
    $raw = & javap -p -s -cp $g.cp @($g.classes) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "javap failed (classpath: $($g.cp)); see error above" }

    $cur = $null; $simple = $null; $pending = $null
    foreach ($lineRaw in $raw) {
        $line = ("$lineRaw").Trim()
        if ($line -eq '' -or $line -like 'Compiled from*' -or $line -eq '}') { continue }

        if ($line.EndsWith('{')) {                                   # class header
            $m = [regex]::Match($line, '\b(?:class|interface|enum|record)\s+([A-Za-z0-9_.$]+)')
            if ($m.Success) {
                $cur = $m.Groups[1].Value
                $simple = $cur.Substring($cur.LastIndexOf('.') + 1)
                $pending = $null
            }
            continue
        }

        if ($line -like 'descriptor:*') {                            # follows a signature line
            if ($pending -and $cur) {
                $desc = $line.Substring(11).Trim()
                $rule = $g.f + 'L' + $cur.Replace('.', '/') + ';->' + $pending + $desc
                if ($seen.Add($rule)) { $lines.Add($rule) }
            }
            $pending = $null
            continue
        }

        if ($line -eq 'static {};') { $pending = '<clinit>'; continue }

        if ($line.Contains('(')) {                                   # method (fields have no parens)
            $name = (($line.Substring(0, $line.IndexOf('('))) -split '\s+')[-1]
            # javap prints constructors with the fully qualified name
            if ($name -eq $simple -or $name -eq $cur) { $name = '<init>' }
            $pending = $name
        } else {
            $pending = $null
        }
    }
}

$header = '# PiliPlus baseline profile: Flutter embedding + startup plugins + app Android layer'
$text = $header + "`n" + ($lines -join "`n") + "`n"

# distinct classes referenced by the profile
$classCount = ($lines |
    ForEach-Object { [regex]::Match($_, '^[A-Z]*L([^;]+);').Groups[1].Value } |
    Sort-Object -Unique).Count

# sanity check: every rule must be a well-formed HRF line.
# This catches javap output format changes instead of silently writing broken lines.
$rulePattern = '^H(S)?(P)?L[A-Za-z0-9_$/]+;->[A-Za-z0-9_$<>]+\([^()]*\)((L[A-Za-z0-9_$/]+;)|(\[+((L[A-Za-z0-9_$/]+;)|[ZBCSIJFD]))|[VZBCSIJFD])$'
$bad = @($lines | Where-Object { $_ -notmatch $rulePattern })
if ($bad.Count -gt 0) {
    $bad | Select-Object -First 10 | ForEach-Object { Write-Host "  BAD: $_" }
    throw "$($bad.Count) malformed profile line(s); check javap output / class names"
}

if ($Check) {
    if (-not (Test-Path $OutFile)) {
        Write-Host "MISSING: $OutFile"
        exit 1
    }
    $old = [IO.File]::ReadAllText($OutFile) -replace "`r`n", "`n"
    if ($old -ceq $text) {
        Write-Host ("OK: matches ({0} rules, {1} classes)" -f $lines.Count, $classCount)
        exit 0
    }
    $oldLines = $old.TrimEnd("`n").Split("`n")
    $newLines = $text.TrimEnd("`n").Split("`n")
    $diff = Compare-Object -CaseSensitive $oldLines $newLines
    Write-Host ("DIFF: current {0} lines / regenerated {1} lines, {2} differing" -f $oldLines.Count, $newLines.Count, $diff.Count)
    $diff | Select-Object -First 20 | ForEach-Object { Write-Host ("  {0} {1}" -f $_.SideIndicator, $_.InputObject) }
    exit 1
}

[IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false)))

$hsp = ($lines | Where-Object { $_ -like 'HSPL*' }).Count
$h = ($lines | Where-Object { $_ -like 'HL*' }).Count
Write-Host ("wrote {0}" -f $OutFile)
Write-Host ("rules {0} (HSP {1} / H {2}), classes {3}, bytes {4}" -f $lines.Count, $hsp, $h, $classCount, (Get-Item $OutFile).Length)
