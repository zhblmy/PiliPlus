import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:jni/jni.dart';

abstract final class PiliAndroidHelper {
  @pragma('vm:prefer-inline')
  static void back() => AndroidHelper.back();

  static void biliSendCommAntifraud(
    int action,
    int oid,
    int type,
    int rpId,
    int root,
    int parent,
    int ctime,
    String commentText,
    List pictures,
    String sourceId,
    int uid,
    String cookie,
  ) {
    final jCommentText = commentText.toJString();
    final jSourceId = sourceId.toJString();
    final jCookie = cookie.toJString();
    final jPictures = pictures.isEmpty
        ? null
        : jsonEncode(pictures).toJString();

    try {
      AndroidHelper.biliSendCommAntifraud(
        action,
        oid,
        type,
        rpId,
        root,
        parent,
        ctime,
        jCommentText,
        jPictures,
        jSourceId,
        uid,
        jCookie,
      );
    } catch (e) {
      Utils.reportError(e);
    } finally {
      jCommentText.release();
      jSourceId.release();
      jCookie.release();
      jPictures?.release();
    }
  }

  @pragma('vm:prefer-inline')
  static void openLinkVerifySettings() =>
      AndroidHelper.openLinkVerifySettings();

  static bool openMusic(String title, String? artist, String? album) {
    final jTitle = title.toJString();
    final jArtist = artist?.toJString();
    final jAlbum = album?.toJString();
    try {
      return AndroidHelper.openMusic(jTitle, jArtist, jAlbum);
    } finally {
      jTitle.release();
      jArtist?.release();
      jAlbum?.release();
    }
  }

  @pragma('vm:prefer-inline')
  static void enterPip(
    int width,
    int height, {
    required bool autoEnter,
    required bool isLive,
    required bool isPlaying,
  }) => AndroidHelper.enterPip(
    PlatformDispatcher.instance.engineId!,
    width,
    height,
    autoEnter,
    isLive,
    isPlaying,
  );

  @pragma('vm:prefer-inline')
  static void disableAutoEnterPip() =>
      AndroidHelper.disableAutoEnterPip(PlatformDispatcher.instance.engineId!);

  static (int, int)? maxScreenSize() {
    final jIArr = AndroidHelper.maxScreenSize();
    if (jIArr != null) {
      try {
        return (jIArr[0], jIArr[1]);
      } finally {
        jIArr.release();
      }
    }
    return null;
  }

  /// 当前设备热状态（`PowerManager.THERMAL_STATUS_*`，API 29 以下返回 0 = NONE）。
  /// 供低功耗降档判断（性能报告 MI-04）。
  @pragma('vm:prefer-inline')
  static int thermalStatus() => AndroidHelper.thermalStatus();

  /// 是否已加入电池优化白名单（“省电策略 = 无限制”的前置条件）
  @pragma('vm:prefer-inline')
  static bool isIgnoringBatteryOptimizations() =>
      AndroidHelper.isIgnoringBatteryOptimizations() == 1;

  /// 申报持续性能模式（长时播放/弹幕下帧时间更平缓，性能报告 MI-15）
  @pragma('vm:prefer-inline')
  static void setSustainedPerformanceMode(bool enable) =>
      AndroidHelper.setSustainedPerformanceMode(
        PlatformDispatcher.instance.engineId!,
        enable,
      );

  /// 跳转系统/澎湃 OS 设置页。
  ///
  /// [type]：`autostart`（自启动）| `battery`（电池优化白名单）|`permission`（权限管理，
  /// 后台弹出界面在其中）| `notification`（通知）| `display`（显示）| 其它 = 应用详情页。
  /// 原生侧失败会自行回退，这里不需要处理结果。
  static void openAppSettings(String type) {
    final jType = type.toJString();
    try {
      AndroidHelper.openAppSettings(jType);
    } finally {
      jType.release();
    }
  }

  static void createShortcut(String id, String uri, String label, String path) {
    final jId = id.toJString();
    final jUri = uri.toJString();
    final jLabel = label.toJString();
    final jPath = path.toJString();
    try {
      AndroidHelper.createShortcut(jId, jUri, jLabel, jPath);
    } finally {
      jId.release();
      jUri.release();
      jLabel.release();
      jPath.release();
    }
  }

  static void openUrl(String url, {String domain = '*.bilibili.com'}) {
    if (!Platform.isAndroid || DeviceUtils.sdkInt < 31) {
      PageUtils.launchURL(url);
      return;
    }
    final jDomain = domain.toJString();
    JString? jUrl;
    try {
      if (AndroidHelper.isDomainVerified(jDomain)) {
        jUrl = url.toJString();
        final jStr = AndroidHelper.openUrl(jUrl);
        if (jStr != null) {
          SmartDialog.showToast(jStr.toDartString(releaseOriginal: true));
        }
      } else {
        PageUtils.launchURL(url);
      }
    } finally {
      jDomain.release();
      jUrl?.release();
    }
  }
}
