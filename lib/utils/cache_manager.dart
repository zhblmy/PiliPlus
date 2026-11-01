import 'dart:io' show Directory, File;
import 'dart:isolate' show Isolate;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

Future<Directory> _cacheDirectoryProvider() async {
  final tmpDirPath = await PathProviderPlatform.instance.getTemporaryPath();
  if (tmpDirPath == null) {
    throw MissingPlatformDirectoryException(
      'Unable to get temporary directory',
    );
  }
  if (PlatformUtils.isDesktop) {
    return Directory(path.join(tmpDirPath, Constants.appName));
  }
  return Directory(tmpDirPath);
}

abstract final class CacheManager {
  static late final DefaultCacheManager manager;

  static Future<void> ensureInitialized() => DefaultCacheManager.init(
    maxNrOfCacheLength: Pref.maxCacheSize.toInt(),
    cacheDirectoryProvider: _cacheDirectoryProvider,
  ).then((i) => manager = i);

  // 获取缓存目录
  @pragma('vm:notify-debugger-on-exception')
  static Future<int> loadApplicationCache() async {
    try {
      if (PlatformUtils.isDesktop) {
        return manager.getTotalLength();
      }

      final Directory tempDirectory = await getTemporaryDirectory();
      if (tempDirectory.existsSync()) {
        return await getTotalSizeOfFilesInDir(tempDirectory);
      }
    } catch (_) {}
    return 0;
  }

  // 循环计算文件的大小
  // I-01b：目录遍历放到独立 isolate 里跑 —— 原来是在主 isolate 上逐个文件 await
  // length()，缓存条目多时「设置 → 缓存大小」所在页面会明显掉帧。统计口径不变。
  @pragma('vm:notify-debugger-on-exception')
  static Future<int> getTotalSizeOfFilesInDir(Directory file) {
    final managedCacheDir = manager.cacheDir;
    final managedCacheSize = manager.getTotalLength();
    final root = file.path;
    return Isolate.run(
      () => _dirSize(
        root,
        managedCacheDir: managedCacheDir,
        managedCacheSize: managedCacheSize,
      ),
    );
  }

  /// 清除 Library/Caches 目录及文件缓存
  ///
  /// 单个条目删不掉时不中断其余条目的删除，最后抛出第一个错误，
  /// 让调用方能把"清除失败"和"清除成功"分开提示。
  @pragma('vm:notify-debugger-on-exception')
  static Future<void> clearLibraryCache() async {
    await manager.emptyCache();
    if (PlatformUtils.isDesktop) return;

    final tempDirectory = await getTemporaryDirectory();
    if (!tempDirectory.existsSync()) return;

    (Object, StackTrace)? failure;
    await for (final file in tempDirectory.list(recursive: false)) {
      if (file is Directory && path.equals(file.path, manager.cacheDir)) {
        continue;
      }
      try {
        await file.delete(recursive: true);
      } catch (e, s) {
        failure ??= (e, s);
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
  }
}

/// I-01b：在独立 isolate 里跑的目录体积统计（同步 IO，避免主 isolate 上的 await 抖动）。
/// 参数都是可序列化的原始类型，所以能直接跨 isolate 传递。
int _dirSize(
  String root, {
  required String managedCacheDir,
  required int managedCacheSize,
}) {
  var total = 0;
  try {
    for (final child in Directory(root).listSync(
      recursive: false,
      followLinks: false,
    )) {
      if (child is File) {
        total += _fileSize(child);
      } else if (child is Directory) {
        if (path.equals(child.path, managedCacheDir)) {
          // 该目录由 flutter_cache_manager 管理，体积它自己维护
          total += managedCacheSize;
        } else {
          for (final entity in child.listSync(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is File) {
              total += _fileSize(entity);
            }
          }
        }
      }
    }
  } catch (_) {}
  return total;
}

int _fileSize(File file) {
  try {
    return file.lengthSync();
  } catch (_) {
    return 0;
  }
}
