import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart'
    show AudioItem, VideoItem, FormatItem;
import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

abstract final class VideoUtils {
  static CDNService cdnService = Pref.defaultCDNService;
  static String? liveCdnUrl = Pref.liveCdnUrl;
  static bool disableAudioCDN = Pref.disableAudioCDN;

  static const _proxyTf = 'proxy-tf-all-ws.bilivideo.com';

  static final _mirrorRegex = RegExp(
    r'^https?://(?:upos-\w+-(?!302)\w+|(?:upos|proxy)-tf-[^/]+)\.(?:bilivideo|akamaized)\.(?:com|net)/upgcxcode',
  );

  static final _mCdnTfRegex = RegExp(
    r'^https?://(?:(?:(?:\d{1,3}\.){3}\d{1,3}|[^/]+\.mcdn\.bilivideo\.(?:com|cn|net))(?:\:\d{1,5})?/v\d/resource)',
  );

  static String getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
  }) {
    defaultCDNService ??= cdnService;

    if (defaultCDNService == CDNService.baseUrl) {
      return urls.first;
    }

    if (defaultCDNService == CDNService.akamai &&
        !(isAudio && disableAudioCDN)) {
      // Akamai URLs have their own signature (e.g. hdnts). Replacing another
      // CDN's host preserves the wrong signature and results in HTTP 403.
      // Keep the API-provided URL intact, including its encoded query string.
      return urls.firstWhere(
        (url) => Uri.tryParse(url)?.host == CDNService.akamai.host,
        orElse: () => urls.first,
      );
    }

    String? mcdnTf;
    String? mcdnUpgcxcode;

    String last = '';
    for (final url in urls) {
      last = url;
      if (_mirrorRegex.hasMatch(url)) {
        final uri = Uri.parse(url);
        if (uri.queryParameters['os'] == 'mcdn') {
          // upos-sz-mirrorcoso1.bilivideo.com os=mcdn
          mcdnUpgcxcode = url;
        } else {
          if (defaultCDNService == CDNService.backupUrl ||
              (isAudio && disableAudioCDN)) {
            return url;
          }
          return uri.replace(host: defaultCDNService.host).toString();
        }
      }

      if (_mCdnTfRegex.hasMatch(url)) {
        mcdnTf = url;
        continue;
      }

      // upos-\w*-302.* & bcache & mcdn host but upgcxcode path
      if (url.contains('/upgcxcode/')) {
        mcdnUpgcxcode = url;
        continue;
      }

      // may be deprecated
      if (url.contains('szbdyd.com')) {
        final uri = Uri.parse(url);
        final hostname =
            uri.queryParameters['xy_usource'] ?? defaultCDNService.host;
        return uri
            .replace(scheme: 'https', host: hostname, port: 443)
            .toString();
      }

      if (kDebugMode) {
        debugPrint('unknown cdn type: $url');
      }
    }

    return mcdnUpgcxcode == null
        ? mcdnTf == null
              ? last
              : Uri(
                  scheme: 'https',
                  host: _proxyTf,
                  queryParameters: {'url': mcdnTf},
                ).toString()
        : Uri.parse(mcdnUpgcxcode)
              .replace(host: defaultCDNService.host ?? CDNService.ali.host)
              .toString();
  }

  static String getLiveCdnUrl(CodecItem e, {int index = 0}) {
    final urlInfo = e.urlInfo.getOrFirst(index);
    return (liveCdnUrl ?? urlInfo.host) + e.baseUrl + urlInfo.extra;
  }

  static VideoDecodeFormatType selectCodec(
    Iterable<String> codecs,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    // 没有 codecs 信息时无法判断，优先按用户指定格式走
    if (codecs.isEmpty) {
      return preferCodecs.isNotEmpty
          ? preferCodecs.first
          : VideoDecodeFormatType.AVC;
    }
    if (preferCodecs.isNotEmpty) {
      int bestIndex = preferCodecs.length;
      for (final e in codecs) {
        for (int i = 0; i < bestIndex; i++) {
          if (preferCodecs[i].codes.any(e.startsWith)) {
            bestIndex = i;
            if (bestIndex == 0) {
              return preferCodecs[0];
            }
            break;
          }
        }
      }
      if (bestIndex < preferCodecs.length) {
        return preferCodecs[bestIndex];
      }
    }
    return VideoDecodeFormatType.fromString(codecs.first);
  }

  static int _findAvailableVideoQuality(
    List<VideoItem> videoList,
    List<int>? acceptQuality,
    int preferQuality,
  ) {
    final highestVideoQa = videoList.first.id;
    if (preferQuality >= highestVideoQa) {
      return highestVideoQa;
    }

    if (acceptQuality != null && acceptQuality.isNotEmpty) {
      return acceptQuality.findTargetMedia((e) => e, preferQuality);
    }

    return videoList.findTargetMedia((e) => e.id, preferQuality).quality.code;
  }

  /// 按 [preferQuality] 与 `accept_quality` 挑出可播放的码流。
  ///
  /// 画质选择规则：`accept_quality` 非空时在其中取 ≤ [preferQuality] 的最接近值；
  /// 为空（或缺失）时退回到「实际可用码流里 ≤ [preferQuality] 的最接近画质」，
  /// 都比 [preferQuality] 高才取最高的可用画质。
  ///
  /// dash / support_formats / codecs 缺失的响应（版权受限、试看失败、旧版本接口）
  /// 不抛异常，逐个降级；确实没有可播码流时返回 null，由调用方按「无资源」处理。
  static (
    int targetQuality,
    FormatItem? targetFormat,
    VideoDecodeFormatType targetDecode,
    VideoItem targetVideo,
  )?
  findTargetVideo(
    List<VideoItem>? videoList,
    int preferQuality,
    List<int>? acceptQuality,
    List<FormatItem>? supportFormats,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    if (videoList == null || videoList.isEmpty) return null;

    final targetQuality = _findAvailableVideoQuality(
      videoList,
      acceptQuality,
      preferQuality,
    );

    final targetQaVideoList = videoList
        .where((e) => e.id == targetQuality)
        .toList();
    if (targetQaVideoList.isEmpty) return null;

    final targetFormat =
        supportFormats?.firstWhereOrNull((e) => e.quality == targetQuality) ??
        supportFormats?.firstOrNull;

    final targetDecode = VideoUtils.selectCodec(
      targetFormat?.codecs ?? const [],
      preferCodecs,
    );

    final targetVideo = targetQaVideoList.firstWhere(
      (e) {
        final c = e.codecs;
        return c != null && targetDecode.codes.any(c.startsWith);
      },
      orElse: () => targetQaVideoList.first,
    );

    return (targetVideo.id, targetFormat, targetDecode, targetVideo);
  }

  static AudioItem findTargetAudio(
    List<AudioItem> audioList,
    int preferQuality,
  ) {
    assert(audioList.isNotEmpty);

    final preferredRank = AudioQuality.fromCode(preferQuality).rank;
    return audioList.findTargetMedia(
      (audio) => AudioQuality.fromCode(audio.id).rank,
      preferredRank,
    );
  }
}
