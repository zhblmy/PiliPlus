import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/logger.dart';
import 'package:brotli/brotli.dart';
import 'package:flutter/foundation.dart' show kDebugMode, compute;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class PackageHeader {
  final int protocolVer;
  final int operationCode;
  final int seq;

  @override
  String toString() {
    return 'PackageHeader{protocolVer: $protocolVer, operationCode: $operationCode, seq: $seq}';
  }

  const PackageHeader({
    required this.protocolVer,
    required this.operationCode,
    required this.seq,
  });

  Uint8List toBytes(int contentSize) {
    final bytes = ByteData(0x10)
      ..setInt32(0, 0x10 + contentSize, Endian.big)
      ..setInt16(4, 0x10, Endian.big)
      ..setInt16(6, protocolVer, Endian.big)
      ..setInt32(8, operationCode, Endian.big)
      ..setInt32(12, seq, Endian.big);
    return bytes.buffer.asUint8List();
  }
}

class PackageHeaderRes extends PackageHeader {
  PackageHeaderRes({
    required this.totalSize,
    required this.headerSize,
    required super.protocolVer,
    required super.operationCode,
    required super.seq,
  });
  final int totalSize;
  final int headerSize;

  static PackageHeaderRes? fromBytesData(Uint8List data) {
    // 包头固定 0x10 字节（seq 位于偏移 12~15），少于 16 字节无法解析
    if (data.length < 0x10) {
      logger.w('数据不足以解析PackageHeader');
      return null;
    }
    final byteData = ByteData.sublistView(data);

    final totalSize = byteData.getUint32(0, Endian.big);
    final headerSize = byteData.getUint16(4, Endian.big);
    final protocolVer = byteData.getUint16(6, Endian.big);
    final operationCode = byteData.getUint32(8, Endian.big);
    final seq = byteData.getUint32(12, Endian.big);

    return PackageHeaderRes(
      totalSize: totalSize,
      headerSize: headerSize,
      protocolVer: protocolVer,
      operationCode: operationCode,
      seq: seq,
    );
  }

  @override
  String toString() {
    return 'PackageHeaderRes{totalSize: $totalSize, headerSize: $headerSize, protocolVer: $protocolVer, operationCode: $operationCode, seq: $seq}';
  }
}

abstract class Message {
  String toJsonStr();
}

class AuthMessage implements Message {
  int roomid;
  int uid;
  int protover;
  String platform;
  int type;
  String key;

  AuthMessage({
    required this.roomid,
    required this.uid,
    required this.protover,
    required this.platform,
    required this.type,
    required this.key,
  });

  @override
  String toJsonStr() {
    final message = {
      'roomid': roomid,
      'uid': uid,
      'protover': protover,
      'platform': platform,
      'type': type,
      'key': key,
    };
    return jsonEncode(message);
  }
}

abstract class AbstractPackage<T> {
  PackageHeader header;
  T body;
  Uint8List marshal();
  AbstractPackage({required this.header, required this.body});
}

//认证包
class AuthPackage extends AbstractPackage<Message> {
  AuthPackage({required super.header, required super.body});

  @override
  Uint8List marshal() {
    final json = utf8.encode(body.toJsonStr());
    final buffer = BytesBuilder()
      ..add(header.toBytes(json.length))
      ..add(json);
    return buffer.toBytes();
  }
}

//心跳包
class HeartbeatPackage extends AbstractPackage<dynamic> {
  HeartbeatPackage({required super.header, super.body});

  @override
  Uint8List marshal() {
    return header.toBytes(0);
  }
}

class LiveMessageStream {
  String streamToken;
  int roomId, uid;
  List<String> servers;
  final List<void Function(dynamic obj)> _eventListeners = [];
  LiveMessageStream({
    required this.streamToken,
    required this.roomId,
    required this.uid,
    required this.servers,
  });

  static final _zlib = ZLibDecoder();

  /// 单个压缩包超过该体积才值得付 isolate 启动开销
  static const _isolateThreshold = 64 * 1024;

  bool _active = true;
  WebSocketChannel? _channel;
  StreamSubscription? _socketSubscription;
  Timer? _timer;
  static const String logTag = "LiveStreamService";

  int _pendingDecompress = 0;
  int _generation = 0;
  Future<void> _decompressQueue = Future<void>.value();

  static Uint8List _decompress((Uint8List, int) args) {
    final (payload, protocolVer) = args;
    final data = protocolVer == 2
        ? _zlib.convert(payload)
        : const BrotliDecoder().convert(payload);
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  /// 解压是这条链上唯一可能上毫秒级的操作，按体积决定是否投到后台 isolate。
  ///
  /// 弹幕消息之间有顺序语义（弹幕引擎按到达顺序排轨道），所以只要还有包在排队，
  /// 后续包也必须排队，否则小包会越过先到的大包。
  void _handleCompressed(Uint8List payload, int protocolVer) {
    if (_pendingDecompress > 0 || payload.length >= _isolateThreshold) {
      _enqueue(
        () => payload.length >= _isolateThreshold
            ? compute(_decompress, (payload, protocolVer))
            : _decompress((payload, protocolVer)),
      );
      return;
    }
    try {
      _processingData(_decompress((payload, protocolVer)));
    } catch (_) {}
  }

  /// 未压缩的包也要跟队伍走，否则会越过前面还没解压完的包
  void _handlePlain(Uint8List data) {
    if (_pendingDecompress == 0) {
      _processingData(data);
    } else {
      _enqueue(() => data);
    }
  }

  void _enqueue(FutureOr<Uint8List> Function() job) {
    final generation = _generation;
    _pendingDecompress++;
    _decompressQueue = _decompressQueue.then((_) async {
      try {
        if (generation != _generation) return;
        final data = await job();
        if (generation != _generation) return;
        _processingData(data);
      } catch (_) {
      } finally {
        if (generation == _generation) _pendingDecompress--;
      }
    });
  }

  Future<void> init() async {
    final authPackage = AuthPackage(
      header: const PackageHeader(
        protocolVer: 1,
        operationCode: 7,
        seq: 1,
      ),
      body: AuthMessage(
        roomid: roomId,
        uid: uid,
        protover: 3,
        platform: 'web',
        type: 2,
        key: streamToken,
      ),
    );

    // final marshaledData = authPackage.marshal();
    // logger.d(marshaledData);
    try {
      Future<WebSocketChannel> getSocket() async {
        for (final server in servers) {
          try {
            final channel = WebSocketChannel.connect(Uri.parse(server));
            await channel.ready;
            return channel;
          } catch (_) {}
        }
        throw Exception("all servers connect failed");
      }

      _channel = await getSocket();
      if (!_active) {
        if (kDebugMode) logger.i("$logTag init inactive $hashCode");
        close();
        return;
      }
      // logger
      //   ..d('$logTag ===> TCP连接建立')
      //   ..d('$logTag ===> 发送认证包');
      _socketSubscription = _channel?.stream.listen(
        onData,
        onDone: close,
        onError: (_) => close(),
      );
      _channel?.sink.add(authPackage.marshal());
    } catch (e) {
      SmartDialog.showToast("弹幕地址链接失败: $e");
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  void _processingData(Uint8List data) {
    try {
      final subHeader = PackageHeaderRes.fromBytesData(data);
      if (subHeader != null) {
        if (_eventListeners.isNotEmpty) {
          final msgBody = jsonDecode(
            utf8.decode(
              Uint8List.sublistView(
                data,
                subHeader.headerSize,
                subHeader.totalSize,
              ),
            ),
          );
          for (final f in _eventListeners) {
            f(msgBody);
          }
        }
        if (subHeader.totalSize < data.length) {
          _processingData(Uint8List.sublistView(data, subHeader.totalSize));
        }
      }
    } catch (_) {}
  }

  Future<void> _heartBeat() async {
    if (!_active) {
      if (kDebugMode) logger.i("$logTag init heartBeat inactive $hashCode");
      close();
      return;
    }
    if (kDebugMode) logger.i("$logTag 直播间信息流认证成功 $hashCode");
    int heartBeatCount = 1;
    _timer ??= Timer.periodic(const Duration(seconds: 30), (timer) {
      if (!_active) {
        if (kDebugMode) logger.i("$logTag heartBeat inactive $hashCode");
        timer.cancel();
        close();
        return;
      }
      if (kDebugMode) logger.i("$logTag heartBeat $hashCode");
      final package = HeartbeatPackage(
        header: PackageHeader(
          protocolVer: 1,
          operationCode: 2,
          seq: heartBeatCount,
        ),
      );
      try {
        _channel?.sink.add(package.marshal());
      } catch (_) {
        timer.cancel();
      }
      heartBeatCount++;
    });
  }

  void addEventListener(void Function(dynamic) func) {
    _eventListeners.add(func);
  }

  @pragma('vm:notify-debugger-on-exception')
  void onData(dynamic data) {
    final header = PackageHeaderRes.fromBytesData(data as Uint8List);
    if (header != null) {
      //心跳包回复不用处理
      if (header.operationCode == 3) return;
      if (header.operationCode == 8) {
        _heartBeat();
      }
      switch (header.protocolVer) {
        case 0:
        case 1:
          _handlePlain(data);
        case 2:
        case 3:
          _handleCompressed(
            Uint8List.sublistView(data, 0x10),
            header.protocolVer,
          );
        //debugPrint('Body: ${utf8.decode()}');
        default:
          return;
      }
    }
  }

  void close() {
    _active = false;
    // 丢弃还挂在队列里的解压任务
    _generation++;
    _pendingDecompress = 0;
    _decompressQueue = Future<void>.value();
    if (kDebugMode) logger.i("$logTag close $hashCode");
    _timer?.cancel();
    _timer = null;
    _eventListeners.clear();
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _channel?.sink.close();
    _channel = null;
  }
}
