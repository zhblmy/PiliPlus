import 'dart:io' show Platform;

import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/display_mode_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';

/// 澎湃 OS 兼容性检查（性能报告 MI-13，仅 Android 可用）。
///
/// 澎湃 OS 把「能不能在后台活着」「能不能从后台起界面」做成了开关：自启动、
/// 省电策略、后台弹出界面、通知权限。这些开关没打开时，后台播放、定时关闭、
/// 下载、更新安装都会"看似可用、实际不生效"，而系统不会给任何提示。
///
/// 本页把状态摊开并提供一键跳转；小米各版本的组件名/入口会变，原生侧
/// （`AndroidHelper.openAppSettings`）失败时会自动回退到应用详情页。
class HyperOsCompatPage extends StatefulWidget {
  const HyperOsCompatPage({super.key});

  @override
  State<HyperOsCompatPage> createState() => _HyperOsCompatPageState();
}

class _HyperOsCompatPageState extends State<HyperOsCompatPage>
    with WidgetsBindingObserver {
  bool _notificationGranted = false;
  bool _batteryUnrestricted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页返回（或切回应用）时重读状态，
  /// 否则用户改完开关回来仍看到旧状态，会以为设置没生效。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final granted = await Permission.notification.isGranted;
    final unrestricted = Platform.isAndroid
        ? PiliAndroidHelper.isIgnoringBatteryOptimizations()
        : false;
    if (!mounted) return;
    setState(() {
      _notificationGranted = granted;
      _batteryUnrestricted = unrestricted;
    });
  }

  void _jump(String type) {
    if (Platform.isAndroid) {
      PiliAndroidHelper.openAppSettings(type);
    }
  }

  Future<void> _onNotificationTap() async {
    if (_notificationGranted) {
      _jump('notification');
      return;
    }
    // 已被永久拒绝时 request() 不会再弹窗，直接引导到通知设置页
    if ((await Permission.notification.status).isPermanentlyDenied) {
      _jump('notification');
      return;
    }
    await Permission.notification.request();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return SimpleScaffold(
        appBar: AppBar(title: const Text('系统兼容性检查')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Text('本页仅适用于小米 / 澎湃 OS 设备。'),
        ),
      );
    }
    final colorScheme = ColorScheme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('澎湃 OS 兼容性检查'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 25, top: 12, bottom: 6),
            child: Text(
              '这些开关不打开时，后台播放 / 定时关闭 / 下载 / 更新安装都可能"看似可用、实际不生效"，且系统不会提示。',
              style: TextStyle(color: colorScheme.outline, fontSize: 13),
            ),
          ),
          _tile(
            icon: Icons.notifications_none,
            title: '通知权限',
            subtitle: _notificationGranted
                ? '已授予：媒体控制条、下载/更新通知可用'
                : '未授予：后台播放没有控制条，下载/更新通知也不显示',
            ok: _notificationGranted,
            onTap: _onNotificationTap,
          ),
          _tile(
            icon: Icons.battery_charging_full_outlined,
            title: '省电策略 / 电池优化',
            subtitle: _batteryUnrestricted
                ? '已是「无限制」：后台播放与下载不易被冻结'
                : '受限：请在省电策略中选择「无限制」',
            ok: _batteryUnrestricted,
            onTap: () => _jump('battery'),
          ),
          _tile(
            icon: Icons.restart_alt,
            title: '自启动',
            subtitle: '建议开启；系统不提供读取接口，需手动确认',
            onTap: () => _jump('autostart'),
          ),
          _tile(
            icon: Icons.open_in_new,
            title: '后台弹出界面',
            subtitle: '后台完成下载后拉起安装器、投屏控制等需要它',
            onTap: () => _jump('permission'),
          ),
          if (Pref.limitDisplayMode && DisplayModeUtils.systemOverridden)
            _tile(
              icon: Icons.screen_lock_portrait_outlined,
              title: '刷新率被系统覆盖',
              subtitle:
                  '播放时检测到系统覆盖了刷新率，场景化省电（降到 60Hz）不会生效，'
                  '请在显示设置里把它改为「跟随系统」',
              ok: false,
              onTap: () => _jump('display'),
            ),
          _tile(
            icon: Icons.settings_outlined,
            title: '应用详情页（兜底入口）',
            subtitle: '上述入口都打不开时，手动在这里设置',
            onTap: () => _jump('appDetail'),
          ),
        ],
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool? ok,
  }) {
    final colorScheme = ColorScheme.of(context);
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12.5)),
      trailing: Icon(
        ok == null
            ? Icons.chevron_right
            : (ok ? Icons.check_circle_outline : Icons.error_outline),
        color: ok == null
            ? null
            : (ok ? colorScheme.primary : colorScheme.error),
      ),
      onTap: onTap,
    );
  }
}
