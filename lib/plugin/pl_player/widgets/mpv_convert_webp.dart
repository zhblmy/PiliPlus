// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:ffi';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/utils/media_kit_util.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:get/get_rx/get_rx.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/ffi/src/allocation.dart';
import 'package:media_kit/ffi/src/utf8.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/core/initializer.dart';

class MpvConvertWebp {
  // 冷启动优化 S-02：libmpv 改在首帧后预热，这里改为惰性取值，
  // 保证先经过 `_init()` 里的 ensureMediaKitInitialized 再访问 NativePlayer.mpv。
  late final _mpv = NativePlayer.mpv;
  late final Pointer<generated.mpv_handle> _ctx;
  final _completer = Completer<bool>();

  bool _success = false;

  final String url;
  final String outFile;
  final double start;
  final double duration;
  final RxDouble? progress;
  final WebpPreset preset;

  /// 转码（导出 WebP）只支持 copy 模式的硬解：去掉 `no` 后追加 `auto-copy` 兜底。
  ///
  /// 原实现是直接拼接 `'${Pref.hardwareDecoding},auto-copy'`，用户在设置里选
  /// 「启用软解」(no) 时会得到 `no,auto-copy` —— mpv 会因为 `no` 而完全关闭硬解。
  static String get _transcodeHwdec {
    final items = Pref.hardwareDecoding
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != 'no')
        .toList();
    if (items.isEmpty) return 'auto-copy';
    return '${items.join(',')},auto-copy';
  }

  MpvConvertWebp(
    this.url,
    this.outFile,
    this.start,
    double end, {
    this.progress,
    this.preset = WebpPreset.def,
  }) : duration = end - start;

  Future<void> _init() async {
    // 冷启动优化 S-02：libmpv 改在首帧后预热，使用前必须确保已加载
    ensureMediaKitInitialized();
    final enableHA = Pref.enableHA;
    _ctx = await Initializer.create(
      _mpv,
      _onEvent,
      options: {
        'idle': 'once',
        'o': outFile,
        'start': start.toStringAsFixed(3),
        'end': (start + duration).toStringAsFixed(3),
        'of': 'webp',
        'ovc': 'libwebp_anim',
        'ofopts': 'loop=0',
        'ovcopts': 'preset=${preset.flag}',
        if (enableHA) 'vo': 'gpu',
        if (enableHA)
          // 转码只支持 copy 模式（性能报告 PL-05 附带修复）
          'hwdec': _transcodeHwdec,
      },
    );
    _mpv.mpv_request_event(
      _ctx,
      generated.mpv_event_id.MPV_EVENT_VIDEO_RECONFIG,
      0,
    );
    NativePlayer.setHeader(
      _mpv,
      _ctx,
      userAgent: BrowserUa.pc,
      referer: HttpString.baseUrl,
    );
    if (progress != null) {
      _observeProperty('time-pos');
    }
    final level = (kDebugMode ? 'info' : 'error').toNativeUtf8();
    _mpv.mpv_request_log_messages(_ctx, level);
    calloc.free(level);
  }

  void dispose() {
    Initializer.dispose(_ctx);
    _mpv.mpv_terminate_destroy(_ctx);
    if (!_completer.isCompleted) _completer.complete(false);
  }

  Future<bool> convert() async {
    await _init();
    _command(['loadfile', url]);
    return _completer.future;
  }

  Future<void>? _onEvent(Pointer<generated.mpv_event> event) {
    switch (event.ref.event_id) {
      case generated.mpv_event_id.MPV_EVENT_PROPERTY_CHANGE:
        final prop = event.ref.data.cast<generated.mpv_event_property>().ref;
        if (prop.name.toDartString() == 'time-pos' &&
            prop.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
          progress!.value = (prop.data.cast<Double>().value - start) / duration;
        }
        break;
      case generated.mpv_event_id.MPV_EVENT_FILE_LOADED:
        _success = true;
        break;
      case generated.mpv_event_id.MPV_EVENT_LOG_MESSAGE:
        final log = event.ref.data.cast<generated.mpv_event_log_message>().ref;
        final prefix = log.prefix.toDartString().trim();
        final level = log.level.toDartString().trim();
        final text = log.text.toDartString().trim();
        debugPrint('WebpConvert: $level $prefix : $text');
        if (kDebugMode) {
          if (level == 'error' || level == 'fatal') _success = false;
        } else {
          _success = false;
        }
        break;
      case generated.mpv_event_id.MPV_EVENT_SHUTDOWN:
        progress?.value = 1;
        _completer.complete(_success);
        dispose();
        break;
    }
    return null;
  }

  void _command(List<String> args) {
    final pointers = args.map((e) => e.toNativeUtf8()).toList();
    final arr = calloc<Pointer<Uint8>>(pointers.length + 1);
    for (int i = 0; i < args.length; i++) {
      arr[i] = pointers[i];
    }

    _mpv.mpv_command(_ctx, arr);

    calloc.free(arr);
    pointers.forEach(calloc.free);
  }

  void _observeProperty(String property) {
    final name = property.toNativeUtf8();
    _mpv.mpv_observe_property(
      _ctx,
      property.hashCode,
      name,
      generated.mpv_format.MPV_FORMAT_DOUBLE,
    );

    calloc.free(name);
  }
}

enum WebpPreset {
  none('none', '无', '不使用预设'),
  def('default', '默认', '默认预设'),
  picture('picture', '图片', '数码照片，如人像、室内拍摄'),
  photo('photo', '照片', '户外摄影，自然光环境'),
  drawing('drawing', '绘图', '手绘或线稿，高对比度细节'),
  icon('icon', '图标', '小型彩色图像'),
  text('text', '文本', '文字类'),
  ;

  final String flag;
  final String name;
  final String desc;

  const WebpPreset(this.flag, this.name, this.desc);
}
