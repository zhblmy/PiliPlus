import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:http2/http2.dart';

class RetryInterceptor extends Interceptor {
  final Dio _client;
  final int _count;
  final int _delay;

  RetryInterceptor(this._client, this._count, this._delay);

  /// 幂等方法：可以安全地完整重试
  static const _idempotentMethods = {'GET', 'HEAD', 'OPTIONS', 'TRACE'};

  /// 非幂等方法最多重试次数，避免弱网下放大流量与产生重复副作用
  static const _maxRetryForNonIdempotent = 1;

  /// 单次最大退避时间
  static const _maxBackoffMs = 30000;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.responseType == ResponseType.stream) {
      return handler.next(err);
    }
    if (err.response != null) {
      final options = err.requestOptions;
      if (options.followRedirects && options.maxRedirects > 0) {
        final status = err.response!.statusCode;
        if (status != null && 300 <= status && status < 400) {
          var redirectUrl = err.response!.headers.value('location');
          if (redirectUrl != null) {
            var uri = Uri.parse(redirectUrl);
            if (!uri.hasScheme) {
              uri = options.uri.resolveUri(uri);
              redirectUrl = uri.toString();
            }
            (options..path = redirectUrl).maxRedirects--;
            if (status == 303) {
              options
                ..data = null
                ..method = 'GET';
            }
            _client
                .fetch(options)
                .then(
                  (i) => handler.resolve(
                    i
                      ..redirects.add(
                        RedirectRecord(status, options.method, uri),
                      )
                      ..isRedirect = true,
                  ),
                )
                .onError<DioException>((error, _) => handler.next(error));
            return;
          }
        }
      }
      return handler.next(err);
    } else {
      switch (err.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.unknown:
          final options = err.requestOptions;
          final int retried = options.extra['_rt'] ??= 0;
          final int maxRetry = _idempotentMethods.contains(
            options.method.toUpperCase(),
          )
              ? _count
              : _maxRetryForNonIdempotent;
          if (retried < maxRetry &&
              err.error
                  is! TransportConnectionException // 网络中断, 此时请求可能已经被服务器所接收
                  ) {
            options.extra['_rt'] = retried + 1;
            Timer(
              Duration(milliseconds: _backoffMs(retried)),
              () => _client
                  .fetch(options)
                  .then(handler.resolve)
                  .onError<DioException>((error, _) => handler.reject(error)),
            );
          } else {
            handler.next(err);
          }
          return;
        default:
          return handler.next(err);
      }
    }
  }

  /// 指数退避 + 抖动：0.5s / 2s / 8s / 32s…，并上下浮动 30%
  /// 原实现固定 500ms/1000ms 的密集重试，正好落在射频无法进入空闲的窗口内
  /// （性能报告 B-01）。
  int _backoffMs(int retried) {
    final int base = _delay * (1 << (2 * retried.clamp(0, 4)));
    final int jitter = (base * 0.3 * (Random().nextDouble() * 2 - 1)).round();
    final int value = base + jitter;
    // 不用 clamp: num.clamp 在 lowerLimit > upperLimit（用户把重试间隔设得比上限还大）时会抛 ArgumentError
    final int maxDelay = _delay > _maxBackoffMs ? _delay : _maxBackoffMs;
    if (value < _delay) return _delay;
    return value > maxDelay ? maxDelay : value;
  }

  RetryInterceptor copyWith({Dio? client, int? count, int? delay}) =>
      .new(client ?? _client, count ?? _count, delay ?? _delay);
}
