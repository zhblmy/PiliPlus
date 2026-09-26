import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/back_detector.dart';
import 'package:PiliPlus/common/widgets/custom_toast.dart';
import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/common/widgets/scale_app.dart';
import 'package:PiliPlus/common/widgets/scroll_behavior.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/theme/theme_color_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/router/app_pages.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/services/app_visibility.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/logger.dart';
import 'package:PiliPlus/services/power_save_watcher.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/android/display_mode_utils.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/calc_window_position.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/extension/core_palettes_ext.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/font_utils.dart';
import 'package:PiliPlus/utils/json_file_handler.dart';
import 'package:PiliPlus/utils/max_screen_size.dart';
import 'package:PiliPlus/utils/media_kit_util.dart';
import 'package:PiliPlus/utils/memory_budget.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/request_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:catcher_2/catcher_2.dart';
import 'package:dynamic_color/dynamic_color.dart' show DynamicColorPlugin;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:window_manager/window_manager.dart' hide calcWindowPosition;

WebViewEnvironment? webViewEnvironment;

final _dynamicColorObserver = _DynamicColorObserver();

EdgeInsets? tmpPadding;

Future<void> _initDownPath() async {
  if (PlatformUtils.isDesktop) {
    final customDownPath = Pref.downloadPath;
    if (customDownPath != null && customDownPath.isNotEmpty) {
      try {
        final dir = Directory(customDownPath);
        if (!dir.existsSync()) {
          await dir.create(recursive: true);
        }
        downloadPath = customDownPath;
      } catch (e) {
        downloadPath = defDownloadPath;
        await GStorage.setting.delete(SettingBoxKey.downloadPath);
        if (kDebugMode) {
          debugPrint('download path error: $e');
        }
      }
    } else {
      downloadPath = defDownloadPath;
    }
  } else if (Platform.isAndroid) {
    final externalStorageDirPath = (await getExternalStorageDirectory())?.path;
    downloadPath = externalStorageDirPath != null
        ? path.join(externalStorageDirPath, PathUtils.downloadDir)
        : defDownloadPath;
  } else {
    downloadPath = defDownloadPath;
  }
}

Future<void> _initTmpPath() async {
  tmpDirPath = (await getTemporaryDirectory()).path;
}

Future<void> _initAppPath() async {
  appSupportDirPath = (await getApplicationSupportDirectory()).path;
}

/// 存储初始化失败：拷贝错误信息后退出。
/// 与改动前 `GStorage.init()` 的失败路径保持完全一致。
Future<void> _exitOnStorageError(Object e) async {
  await Utils.copyText(e.toString(), needToast: false);
  if (kDebugMode) debugPrint('GStorage init error: $e');
  exit(0);
}

void main() async {
  ScaledWidgetsFlutterBinding.ensureInitialized();
  // 冷启动优化 S-02：不再在这里加载 libmpv.so。
  // `MediaKit.ensureInitialized()` 内部会 `DynamicLibrary.open('libmpv.so')`，
  // 而首帧并不需要播放器 —— 改为首帧之后、首次创建播放器之前执行
  // （见下方 addPostFrameCallback(…) 与 ensureMediaKitInitialized）。
  await _initAppPath();
  try {
    // 冷启动优化 S-04：只阻塞「首帧必需」的 box（setting / localCache /
    // userInfo / account），其余 box 与后续启动工作并发打开。
    await GStorage.initHot();
  } catch (e) {
    await _exitOnStorageError(e);
  }
  // 冷 box 的失败处理与热 box 一致：在 Future 内部消化，否则它会变成
  // Future.wait 里的未捕获异常，表现成「卡在启动画面」。
  final coldBoxes = GStorage.openColdBoxes().onError(
    (Object e, StackTrace s) => _exitOnStorageError(e),
  );
  ScaledWidgetsFlutterBinding.instance.scaleFactor = Pref.uiScale;
  // 冷启动优化 S-03：动态取色是一次 platform channel 往返，与下面的启动工作并行
  // 发起，不再像原来那样串行等在所有初始化之后（渲染前仍会等待完成，避免首帧
  // 闪一次默认配色）。
  final dynamicColorReady = Pref.dynamicColor
      ? MyApp.initPlatformState()
      : null;
  await Future.wait([
    _initDownPath(),
    _initTmpPath(),
    CacheManager.ensureInitialized(),
    // Android 17 应用内存上限适配：按设备内存给图片缓存 / 解码缓冲定预算
    // （非 Android 平台内部直接返回，不读设备信息、不改变原有行为）
    MemoryBudget.init(),
    ?FontUtils.init(),
    coldBoxes, // S-04
    ?dynamicColorReady, // S-03
  ]);
  Get
    ..lazyPut(AccountService.new)
    ..lazyPut(DownloadService.new);
  HttpOverrides.global = _CustomHttpOverrides();

  if (PlatformUtils.isMobile) {
    // PF-03：应用可见性统一门控（内部仅在 Android 注册生命周期观察者）
    AppVisibility.ensureInitialized();
    if (Platform.isAndroid) MaxScreenSize.init();
    // 冷启动优化 S-01：音频服务改为「同步发起、不等待」——冷启动关键路径上少一次
    // MethodChannel 往返 + 前台服务创建的等待。在应用可见时发起，该前台服务依旧
    // 会被系统记为具备 Android 17 要求的使用时(WIU)能力（见 A17-01）；真正需要
    // handler 的地方（如播放器 play()）会自己 `await ensureServiceLocator()`。
    setupServiceLocator();
    await Future.wait([
      if (Pref.horizontalScreen) ?fullMode() else ?portraitUpMode(),
    ]);
  } else if (Platform.isWindows) {
    if (await WebViewEnvironment.getAvailableVersion() != null) {
      webViewEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: path.join(appSupportDirPath, 'flutter_inappwebview'),
        ),
      );
    }
  } else if (Platform.isMacOS) {
    setupServiceLocator();
    await ensureServiceLocator();
  }

  Request();
  Request.setCookie();
  RequestUtils.syncHistoryStatus();

  SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);

  if (PlatformUtils.isMobile) {
    SystemChrome.setEnabledSystemUIMode(.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        statusBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
    );
    if (Platform.isAndroid) {
      // MI-04 / PL-08：省电模式、低电量、温控与画中画的降档调度（内部仅 Android 生效）
      PowerSaveWatcher.init();
      // MI-02：记录用户档位并应用场景化刷新率（内部仅 Android 生效）
      DisplayModeUtils.init();
    } else {
      ScreenBrightnessPlatform.instance.setAutoReset(false);
    }
  } else if (PlatformUtils.isDesktop) {
    FocusManager.instance.addEarlyKeyEventHandler(_onKeyEvent);

    await windowManager.ensureInitialized();

    final windowOptions = WindowOptions(
      minimumSize: const Size(400, 720),
      skipTaskbar: false,
      titleBarStyle: Pref.showWindowTitleBar
          ? TitleBarStyle.normal
          : TitleBarStyle.hidden,
      title: Constants.appName,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      final windowSize = Pref.windowSize;
      await windowManager.setBounds(
        await calcWindowPosition(windowSize) & windowSize,
      );
      if (Pref.isWindowMaximized) await windowManager.maximize();
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // 冷启动优化 S-03：动态取色已在上面的 Future.wait 里与其它启动工作并行完成
  // 系统主题色 / 壁纸变化后重新取色（见 MyApp.refreshDynamicColor）
  WidgetsBinding.instance.addObserver(_dynamicColorObserver);

  // 冷启动优化 S-02：首帧之后再加载 libmpv.so。放在 post-frame 里是为了让「首帧」
  // 不被 dlopen 与符号绑定拖慢；所有创建播放器的地方都还会调一次
  // ensureMediaKitInitialized（幂等），所以即使这里被推迟也不会漏初始化。
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => ensureMediaKitInitialized(),
  );

  if (Pref.enableLog) {
    // 异常捕获 logo记录
    // `NativePlayer.apiVersion` 需要 libmpv 已加载（S-02 之后不再由 main 顶部保证）
    ensureMediaKitInitialized();
    final customParameters = {
      'Build Time': DateFormatUtils.format(
        BuildConfig.buildTime,
        format: DateFormatUtils.longFormatDs,
      ),
      'Commit Hash': BuildConfig.commitHash,
      'MPV Api Version':
          '${NativePlayer.apiVersion >> 16}.${NativePlayer.apiVersion & 0xFFFF}',
    };
    final fileHandler = await JsonFileHandler.init();

    Catcher2(
      [?fileHandler, const ConsoleHandler()],
      const MyApp(),
      logger: logger,
      customParameters: customParameters,
    );
  } else {
    runApp(const MyApp());
  }
}

KeyEventResult _onKeyEvent(KeyEvent event) {
  if (event.logicalKey == .escape && event is KeyDownEvent) {
    _onBack();
    return .handled;
  }
  return .ignored;
}

void _onBack() {
  if (SmartDialog.checkExist()) {
    SmartDialog.dismiss();
    return;
  }

  final route = Get.routing.route;
  if (route is GetPageRoute) {
    if (route.popDisposition == .doNotPop) {
      route.onPopInvokedWithResult(false, null);
      return;
    }
  }

  final navigator = Get.key.currentState!;
  if (navigator.canPop()) {
    navigator.pop();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static ColorScheme? _light, _dark;

  static (ThemeData, ThemeData) getAllTheme() {
    final dynamicColor = _light != null && _dark != null && Pref.dynamicColor;

    final ColorScheme lightScheme, darkScheme;
    if (dynamicColor) {
      lightScheme = _light!;
      darkScheme = _dark!;
    } else {
      final customColor = Pref.customColor;
      final brandColor =
          colorThemeTypes.elementAtOrNull(customColor)?.color ??
          Color(customColor);
      final variant = Pref.schemeVariant;

      lightScheme = brandColor.asColorSchemeSeed(variant, .light);
      darkScheme = brandColor.asColorSchemeSeed(variant, .dark);
    }

    return (
      ThemeUtils.lightTheme = ThemeUtils.getThemeData(
        colorScheme: lightScheme,
        isDynamic: dynamicColor,
      ),
      ThemeUtils.darkTheme = ThemeUtils.getThemeData(
        isDark: true,
        colorScheme: darkScheme,
        isDynamic: dynamicColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (light, dark) = getAllTheme();
    return GetMaterialApp(
      title: Constants.appName,
      theme: light,
      darkTheme: dark,
      themeMode: ThemeUtils.themeMode = Pref.themeMode,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      locale: const Locale("zh", "CN"),
      fallbackLocale: const Locale("zh", "CN"),
      supportedLocales: const [Locale("zh", "CN"), Locale("en", "US")],
      initialRoute: '/',
      getPages: Routes.getPages,
      defaultTransition: Pref.pageTransition,
      builder: FlutterSmartDialog.init(
        toastBuilder: CustomToast.new,
        loadingBuilder: LoadingWidget.new,
        notifyStyle: const FlutterSmartNotifyStyle(
          warningBuilder: NotifyWarning.new,
        ),
        builder: _builder,
      ),
      navigatorObservers: [
        routeObserver,
        FlutterSmartDialog.observer,
      ],
      scrollBehavior: PlatformUtils.isDesktop
          ? const CustomScrollBehavior()
          : null,
    );
  }

  static Widget _builder(BuildContext context, Widget? child) {
    final uiScale = Pref.uiScale;
    final mediaQuery = MediaQuery.of(context);
    final textScaler = TextScaler.linear(Pref.defaultTextScale);
    if (uiScale != 1.0) {
      child = MediaQuery(
        data: mediaQuery.copyWith(
          textScaler: textScaler,
          size: mediaQuery.size / uiScale,
          padding: tmpPadding ?? mediaQuery.padding / uiScale,
          viewInsets: mediaQuery.viewInsets / uiScale,
          viewPadding: tmpPadding ?? mediaQuery.viewPadding / uiScale,
          devicePixelRatio: mediaQuery.devicePixelRatio * uiScale,
        ),
        child: child!,
      );
    } else {
      child = MediaQuery(
        data: mediaQuery.copyWith(
          textScaler: textScaler,
          padding: tmpPadding,
          viewPadding: tmpPadding,
        ),
        child: child!,
      );
    }
    if (PlatformUtils.isDesktop) {
      return BackDetector(
        onBack: _onBack,
        child: child,
      );
    }
    return child;
  }

  /// 重新向系统取一次调色板。
  ///
  /// 系统主题色 / 壁纸变化后 App 的颜色要跟着变（原来只在启动前取一次，
  /// 改完壁纸必须重启才生效）；颜色没变就不重建主题，避免白跑一次全量重绘。
  static Future<void> refreshDynamicColor() async {
    if (!Pref.dynamicColor) return;
    final light = _light?.primary;
    final dark = _dark?.primary;
    if (!await initPlatformState(force: true)) return;
    if (_light?.primary != light || _dark?.primary != dark) {
      Get.updateMyAppTheme();
    }
  }

  /// from [DynamicColorBuilderState.initPlatformState]
  static Future<bool> initPlatformState({bool force = false}) async {
    final hadPalette = _light != null || _dark != null;
    if (hadPalette && !force) return true;
    // Platform messages may fail, so we use a try/catch PlatformException.
    try {
      final colors = await DynamicColorPlugin.channel.invokeMethod(
        DynamicColorPlugin.methodName,
      );

      if (colors != null) {
        final corePalettes = CorePalettesExt.fromList(colors.toList());
        if (kDebugMode) {
          debugPrint('dynamic_color: Core palette detected.');
        }
        _light = corePalettes.toColorScheme();
        _dark = corePalettes.toColorScheme(brightness: Brightness.dark);
        return true;
      }
    } on PlatformException {
      if (kDebugMode) {
        debugPrint('dynamic_color: Failed to obtain core palette.');
      }
    }

    // 已经有调色板时只是“刷新失败”：保留上一次的颜色，
    // 不能因为一次偶发失败就把用户的「动态取色」设置改掉
    if (hadPalette) return true;

    try {
      final Color? accentColor = await DynamicColorPlugin.getAccentColor();

      if (accentColor != null) {
        if (kDebugMode) {
          debugPrint('dynamic_color: Accent color detected.');
        }
        final variant = Pref.schemeVariant;
        _light = accentColor.asColorSchemeSeed(variant, .light);
        _dark = accentColor.asColorSchemeSeed(variant, .dark);
        return true;
      }
    } on PlatformException {
      if (kDebugMode) {
        debugPrint('dynamic_color: Failed to obtain accent color.');
      }
    }
    if (kDebugMode) {
      debugPrint('dynamic_color: Dynamic color not detected on this device.');
    }
    GStorage.setting.put(SettingBoxKey.dynamicColor, false);
    return false;
  }
}

class _DynamicColorObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台时比较系统调色板是否变了（颜色没变不会重建主题）
    if (state == AppLifecycleState.resumed) {
      MyApp.refreshDynamicColor().ignore();
    }
  }
}

class _CustomHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // ..maxConnectionsPerHost = 32
    /// The default value is 15 seconds.
    //   ..idleTimeout = const Duration(seconds: 15);
    if (kDebugMode || Pref.badCertificateCallback) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    return client;
  }
}
