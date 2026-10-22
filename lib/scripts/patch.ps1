param(
    [string]$platform = ""
)

git config --global user.name "ci"
git config --global user.email "example@example.com"

# TODO: remove
# https://github.com/flutter/flutter/issues/182281
$NewOverScrollIndicator = "362b1de29974ffc1ed6faa826e1df870d7bec75f";

# set `gestureSettings`
$BottomSheetAndroidPatch = "lib/scripts/bottom_sheet_android.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1906
$BottomSheetIOSFlutterPatch = "lib/scripts/bottom_sheet_ios_flutter.patch"
$BottomSheetIOSPiliPlusPatch = "lib/scripts/bottom_sheet_ios_piliplus.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1662
# handle bottom scroll event
$ScrollViewPatch = "lib/scripts/scroll_view.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2106
# use `TouchGestureRecognizer` on all platforms
$TextSelectionPatch = "lib/scripts/text_selection.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1947
$NavigatorPatch = "lib/scripts/navigator.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2107
$ImageAnimPatch = "lib/scripts/image_anim.patch"

# remove `_scheduleRebuild`
$LayoutBuilderPatch = "lib/scripts/layout_builder.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2308
$NavigationDrawerPatch = "lib/scripts/navigation_drawer.patch"

# apply text color to icon color
$PopupMenuPatch = "lib/scripts/popup_menu.patch"

# remove `Hero` effect
$FABPatch = "lib/scripts/fab.patch"

# https://github.com/flutter/flutter/issues/139890
# https://github.com/flutter/flutter/issues/174689
# separator support
# clamp handle offset
# widgetspan selection support
# clear selection when tapping outside
# free selection if there is only one text
# clamp dragging selection behavior on Android
# show selection menu if secondary tap position is in text region on desktop
$SelectableRegionPatch = "lib/scripts/selectable_region.patch"

# https://github.com/flutter/flutter/issues/132047
# https://github.com/flutter/flutter/issues/174689
$EditableTextPatch = "lib/scripts/editable_text.patch"

# set `selectAllOnFocus` to `false` by default
$TextFieldPatch = "lib/scripts/text_field.patch"

# notify `userScrollDirection` only if position is actually changing
$ScrollPositionPatch = "lib/scripts/scroll_position.patch"

# expose `_shouldIgnorePointer`
$ScrollablePatch = "lib/scripts/scrollable.patch"

# expose
$ScaffoldPatch = "lib/scripts/scaffold.patch"

# fix nested scrollable gesture
# custom `HorizontalDragGestureRecognizer` support
$ScrollableGesturePatch = "lib/scripts/scrollable_gesture.patch"

# expose
$DraggableScrollableSheetPatch = "lib/scripts/draggable_scrollable_sheet.patch"

# expose
$TextPatch = "lib/scripts/text.patch"

# expose
$TextPainterPatch = "lib/scripts/text_painter.patch"

$SliverPatch = "lib/scripts/sliver.patch"

$RefreshIndicatorPatch = "lib/scripts/refresh_indicator.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/124078
# https://github.com/flutter/flutter/pull/183261
$NullSafetySelectableRegionPatch = "lib/scripts/null_safety_for_selectable_region.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/90223
$ModalBarrierPatch = "lib/scripts/modal_barrier.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/182466
$MouseCursorPatch = "lib/scripts/mouse_cursor.patch"

$GeetestIOSPatch = "lib/scripts/geetest_ios.patch"

$DoubleTapGesturePatch = "lib/scripts/double_tap_gesture.patch"

if ($platform.ToLower() -eq "ios") {
    git apply $BottomSheetIOSPiliPlusPatch
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$BottomSheetIOSPiliPlusPatch applied"
    } else {
        throw "$LASTEXITCODE"
    }
    git apply $GeetestIOSPatch
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$GeetestIOSPatch applied"
    } else {
        throw "$LASTEXITCODE"
    }
}

Set-Location $env:FLUTTER_ROOT

$picks   = @()
$reverts = @()
$patches = @($ModalBarrierPatch, $TextSelectionPatch, $MouseCursorPatch,
            $ImageAnimPatch, $LayoutBuilderPatch, $NavigationDrawerPatch,
            $PopupMenuPatch, $FABPatch, $NullSafetySelectableRegionPatch,
            $SelectableRegionPatch, $EditableTextPatch, $TextFieldPatch,
            $ScrollPositionPatch, $ScrollablePatch, $ScrollableGesturePatch,
            $DraggableScrollableSheetPatch, $ScaffoldPatch, $TextPatch,
            $TextPainterPatch, $SliverPatch, $RefreshIndicatorPatch,
            $DoubleTapGesturePatch)

switch ($platform.ToLower()) {
    "android" {
        $patches += $BottomSheetAndroidPatch
        $patches += $ScrollViewPatch
        $patches += $NavigatorPatch

        git reset --hard HEAD
    }
    "ios" {
        $patches += $ScrollViewPatch
        $patches += $BottomSheetIOSFlutterPatch
        $patches += $NavigatorPatch
    }
    "linux" {
        git reset --hard HEAD
    }
    "macos" {
    }
    "windows" {
    }
    default {}
}

foreach ($pick in $picks) {
    git stash
    git cherry-pick $pick --no-edit
    if ($LASTEXITCODE -eq 0) {
        git reset --soft HEAD~1
        Write-Host "$pick picked"
    } else {
        throw "$LASTEXITCODE"
    }
    git stash pop
}

foreach ($revert in $reverts) {
    git stash
    git revert $revert --no-edit
    if ($LASTEXITCODE -eq 0) {
        git reset --soft HEAD~1
        Write-Host "$revert reverted"
    } else {
        throw "$LASTEXITCODE"
    }
    git stash pop
}

foreach ($patch in $patches) {
    git apply "$env:GITHUB_WORKSPACE/$patch"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$patch applied"
    } else {
        throw "$LASTEXITCODE"
    }
}

Set-Location $env:GITHUB_WORKSPACE

$BottomSheetAndroidPatchMaterial = "lib/scripts/material/bottom_sheet_android.patch"

$BottomSheetIOSFlutterMaterialPatchMaterial = "lib/scripts/material/bottom_sheet_ios_flutter_material.patch"

$ModalBarrierPatchMaterial = "lib/scripts/material/modal_barrier_material.patch"

$NavigationDrawerPatchMaterial = "lib/scripts/material/navigation_drawer.patch"

$PopupMenuPatchMaterial = "lib/scripts/material/popup_menu.patch"

$FABPatchMaterial = "lib/scripts/material/fab.patch"

$TextFieldPatchMaterial = "lib/scripts/material/text_field.patch"

$ScaffoldPatchMaterial = "lib/scripts/material/scaffold.patch"

$RefreshIndicatorPatchMaterial = "lib/scripts/material/refresh_indicator.patch"

$TabsPatchMaterial = "lib/scripts/material/tabs.patch"

$patches_material = @($ModalBarrierPatchMaterial, $NavigationDrawerPatchMaterial, $PopupMenuPatchMaterial,
                    $FABPatchMaterial, $TextFieldPatchMaterial, $ScaffoldPatchMaterial, $RefreshIndicatorPatchMaterial,
                    $TabsPatchMaterial)

$PubCacheDir = "~/.pub-cache"

switch ($platform.ToLower()) {
    "android" {
        $patches_material += $BottomSheetAndroidPatchMaterial
    }
    "ios" {
        $patches_material += $BottomSheetIOSFlutterMaterialPatchMaterial
    }
    "linux" {
    }
    "macos" {
    }
    "windows" {
        $PubCacheDir = "$env:LOCALAPPDATA/Pub/Cache"
    }
    default {}
}

# `~/.pub-cache` is the layout of the Unix CI runners (android/ios/macos/linux
# jobs); when running the script on Windows locally that path does not exist, so
# fall back to the Windows pub cache instead of failing to find the packages.
if (-not (Test-Path $PubCacheDir)) {
    $WindowsPubCacheDir = "$env:LOCALAPPDATA/Pub/Cache"
    if (Test-Path $WindowsPubCacheDir) {
        $PubCacheDir = $WindowsPubCacheDir
    }
}

try {
    $MaterialUiDir = Get-ChildItem "$PubCacheDir/hosted/pub.dev" -Directory |
        Where-Object { $_.Name -like "material_ui-*" } |
        Select-Object -Last 1

    if ($MaterialUiDir) {
        Remove-Item -Path $MaterialUiDir.FullName -Recurse -Force
    }
} catch {
}

flutter pub get

$MaterialUiDir = Get-ChildItem "$PubCacheDir/hosted/pub.dev" -Directory |
    Where-Object { $_.Name -like "material_ui-*" } |
    Select-Object -Last 1

if (-not $MaterialUiDir) {
    throw "material_ui package not found in pub cache"
}

Write-Host "material_ui dir: $($MaterialUiDir.FullName)"

Get-ChildItem -Path "$env:GITHUB_WORKSPACE/lib/scripts/material" -Filter *.patch | ForEach-Object {
    (Get-Content $_.FullName -Raw) -replace "`r`n", "`n" | 
        Set-Content -NoNewline $_.FullName
}

cd $MaterialUiDir.FullName

foreach ($patch in $patches_material) {
    git apply "$env:GITHUB_WORKSPACE/$patch"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$patch applied"
    } else {
        throw "$LASTEXITCODE"
    }
}

$BottomSheetIOSFlutterPatchCupertino = "lib/scripts/cupertino/bottom_sheet_ios_flutter.patch"

$patches_cupertino = @()

switch ($platform.ToLower()) {
    "android" {
    }
    "ios" {
        $patches_cupertino += $BottomSheetIOSFlutterPatchCupertino
    }
    "linux" {
    }
    "macos" {
    }
    "windows" {
    }
    default {}
}

$CupertinoUiDir = Get-ChildItem "$PubCacheDir/hosted/pub.dev" -Directory |
    Where-Object { $_.Name -like "cupertino_ui-*" } |
    Select-Object -Last 1

if (-not $CupertinoUiDir) {
    throw "cupertino_ui package not found in pub cache"
}

Write-Host "cupertino_ui dir: $($CupertinoUiDir.FullName)"

Get-ChildItem -Path "$env:GITHUB_WORKSPACE/lib/scripts/cupertino" -Filter *.patch | ForEach-Object {
    (Get-Content $_.FullName -Raw) -replace "`r`n", "`n" | 
        Set-Content -NoNewline $_.FullName
}

cd $CupertinoUiDir.FullName

foreach ($patch in $patches_cupertino) {
    git apply "$env:GITHUB_WORKSPACE/$patch"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$patch applied"
    } else {
        throw "$LASTEXITCODE"
    }
}

$PackageConfigPath = Join-Path $env:GITHUB_WORKSPACE ".dart_tool/package_config.json"
if (-not (Test-Path $PackageConfigPath)) {
    throw "Dart package config not found: $PackageConfigPath"
}

$PackageConfig = Get-Content $PackageConfigPath -Raw | ConvertFrom-Json

# 从 package_config 取包目录，而不是猜 pub cache 里的目录名：改过 ref 之后
# cache 里会同时存在多个版本，按名字排序取最后一个未必是真正被解析到的那个。
function Get-PackageDir($Name) {
    $Package = $PackageConfig.packages |
        Where-Object { $_.name -eq $Name } |
        Select-Object -First 1
    if (-not $Package) {
        throw "$Name package not found in package config"
    }
    # rootUri 末位是否带斜杠取决于包的类型（仓库根目录会带），统一去掉，
    # 免得 `Split-Path -Parent` 之类拿到意料之外的结果
    $Dir = ([Uri]$Package.rootUri).LocalPath.TrimEnd('\', '/')
    if (-not (Test-Path (Join-Path $Dir "pubspec.yaml"))) {
        throw "$Name package directory not found: $Dir"
    }
    return $Dir
}

# getx 的 `Transition.cupertino` 只有位移：时长固定 300ms，也没有左缘拖动返回。
# 补丁把它换成 Flutter 原生的 `CupertinoRouteTransitionMixin`（500ms + 交互式
# 返回），命名路由和 `Get.to(...)` 都会生效。
$GetXIosTransitionPatch = "lib/scripts/getx_ios_transition.patch"

$GetXDir = Get-PackageDir "get"
if (-not (Test-Path (Join-Path $GetXDir ".git"))) {
    throw "getx must stay a git dependency for $GetXIosTransitionPatch to apply: $GetXDir is not a git repo"
}
Write-Host "getx dir: $GetXDir"

$GetXIosTransitionPatchPath = "$env:GITHUB_WORKSPACE/$GetXIosTransitionPatch"

# normalize CRLF -> LF, keep UTF-8 without BOM (the patch contains non-ASCII comments)
[System.IO.File]::WriteAllText($GetXIosTransitionPatchPath,
    ([System.IO.File]::ReadAllText($GetXIosTransitionPatchPath) -replace "`r`n", "`n"))

Push-Location $GetXDir
try {
    # `flutter pub get` 不会覆盖 pub cache 里的 git 依赖源码，所以补丁会一直留着；
    # 本脚本可能被重复执行，已打过就跳过（否则 git apply 会失败）。
    git apply --reverse --check $GetXIosTransitionPatchPath 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$GetXIosTransitionPatch already applied"
    } else {
        git apply $GetXIosTransitionPatchPath
        if ($LASTEXITCODE -eq 0) {
            Write-Host "$GetXIosTransitionPatch applied"
        } else {
            throw "failed to apply $GetXIosTransitionPatch to $GetXDir" +
                " (getx ref changed? delete the getx-* dir under the pub cache and re-run)"
        }
    }
}
finally {
    Pop-Location
}

# media_kit_video is a sub-package of the `media-kit` git dependency.
# Upstream only syncs the Android surface size when vo == 'gpu', so with
# vo=gpu-next the SurfaceTexture stays 1x1 (and android-surface-size is never
# set) and the picture collapses into a blurry solid color. vo=mediacodec_embed
# (MediaCodec output rendered straight into the Surface) needs the same sync.
$MediaKitVideoPatch = "lib/scripts/media_kit_video.patch"

$MediaKitVideoDir = Get-PackageDir "media_kit_video"
$MediaKitDir = Split-Path -Parent $MediaKitVideoDir
Write-Host "media-kit dir: $MediaKitDir"

$MediaKitVideoPatchPath = "$env:GITHUB_WORKSPACE/$MediaKitVideoPatch"

# normalize CRLF -> LF, keep UTF-8 without BOM (the patch contains non-ASCII comments)
[System.IO.File]::WriteAllText($MediaKitVideoPatchPath,
    ([System.IO.File]::ReadAllText($MediaKitVideoPatchPath) -replace "`r`n", "`n"))

git -C $MediaKitDir apply $MediaKitVideoPatchPath
if ($LASTEXITCODE -eq 0) {
    Write-Host "$MediaKitVideoPatch applied"
} else {
    throw "$LASTEXITCODE"
}
