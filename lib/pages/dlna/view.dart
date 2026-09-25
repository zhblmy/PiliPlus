import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_sliver_safe_area.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:dlna_dart/dlna.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class DLNAPage extends StatefulWidget {
  const DLNAPage({super.key});

  @override
  State<DLNAPage> createState() => _DLNAPageState();
}

class _DLNAPageState extends State<DLNAPage> {
  final _searcher = DLNAManager();
  final Map<String, DLNADevice> _deviceList = {};
  late final _url = Get.parameters['url']!;
  late final _title = Get.parameters['title'];

  Timer? _timer;
  bool _isSearching = false;
  bool _permissionDenied = false;
  DLNADevice? _lastDevice;
  String? _lastDeviceKey;

  @override
  void initState() {
    super.initState();
    _onSearch(isInit: true);
  }

  /// Android 17 (API 37) 起，访问局域网（组播发现 + 向投屏设备发控制请求）需要
  /// `ACCESS_LOCAL_NETWORK` 运行时权限，且该权限对 targetSdk 37 的应用强制执行。
  /// 未授予时 SSDP 会被系统阻断，只表现为「搜不到设备」而不会报错，所以这里
  /// 先申请、失败后给出可诊断的提示。低版本 Android / 其它平台无需申请。
  Future<bool> _ensureLocalNetworkPermission() async {
    if (!Platform.isAndroid || DeviceUtils.sdkInt < 37) return true;
    if (await Permission.accessLocalNetwork.isGranted) return true;
    return (await Permission.accessLocalNetwork.request()).isGranted;
  }

  Future<void> _openAppSettingsPage() async {
    await openAppSettings();
  }

  Future<void> _onSearch({bool isInit = false}) async {
    if (_isSearching) return;
    // 先置位：下面的权限申请会 await（可能弹系统对话框），期间不允许被重复触发
    _isSearching = true;
    if (!isInit && mounted) {
      setState(() {
        _permissionDenied = false;
        _lastDevice = null;
        _deviceList.clear();
      });
    }
    if (!await _ensureLocalNetworkPermission()) {
      if (!mounted) return;
      setState(() {
        _permissionDenied = true;
        _isSearching = false;
        _deviceList.clear();
        _lastDevice = null;
        _lastDeviceKey = null;
      });
      return;
    }
    final deviceManager = await _searcher.start();
    if (!mounted) {
      return;
    }
    _timer = Timer(const Duration(seconds: 20), _searcher.stop);
    await for (final deviceList in deviceManager.devices.stream) {
      if (mounted) {
        _deviceList.addAll(deviceList);
        setState(() {});
      }
    }
    if (mounted) {
      setState(() {
        _isSearching = false;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _searcher.stop();
    _lastDevice = null;
    _lastDeviceKey = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('投屏'),
        actions: [
          IconButton(
            tooltip: '搜索',
            onPressed: _onSearch,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          if (_isSearching) linearLoading,
          ViewSliverSafeArea(sliver: _buildBody(colorScheme)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (!_isSearching && _deviceList.isEmpty) {
      return HttpError(
        errMsg: _permissionDenied
            ? '未授予「本地网络」权限，无法搜索局域网内的投屏设备\n'
                  '请在系统设置中允许「本地网络」后点击搜索重试'
            : '没有设备',
        btnText: _permissionDenied ? '打开设置' : null,
        onReload: _permissionDenied ? _openAppSettingsPage : _onSearch,
      );
    }
    if (_deviceList.isNotEmpty) {
      final keys = _deviceList.keys.toList();
      return SliverList.builder(
        itemCount: keys.length,
        itemBuilder: (context, index) {
          final key = keys[index];
          final device = _deviceList[key]!;
          final isCurr = key == _lastDeviceKey;
          return ListTile(
            title: Text(
              device.info.friendlyName,
              style: isCurr ? TextStyle(color: colorScheme.primary) : null,
            ),
            subtitle: Text(key),
            onTap: () async {
              if (isCurr) return;
              _lastDevice?.pause();
              _lastDevice = device;
              _lastDeviceKey = key;
              setState(() {});
              await device.setUrl(_url, title: _title ?? '');
              await device.play();
            },
          );
        },
      );
    }
    return const SliverToBoxAdapter();
  }
}
