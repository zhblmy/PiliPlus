part of 'package:PiliPlus/pages/live_room/controller.dart';

mixin _LiveDMStreamMixin
    on
        GetxController,
        _LiveDMTrimMixin,
        _LiveSCMixin,
        _LiveDMMixin,
        _LiveBlockMixin {
  LiveMessageStream? _msgStream;
  LiveMessageStream? get msgStream => _msgStream;

  /// 正在申请弹幕服务器 token（避免重复建流：多一条 WSS 会一直在后台耗电）
  bool _dmConnecting = false;

  /// 长连接代次：stopLiveMsgStream 会自增，用于作废仍在飞行中的 token 请求与重试
  int _dmGeneration = 0;

  /// token 申请失败后的退避重试（弱网 / 刚回前台时常见，次数有限）
  static const int _dmMaxRetry = 3;
  static const Duration _dmRetryDelay = Duration(seconds: 3);
  Timer? _dmRetryTimer;
  int _dmRetryCount = 0;

  late final headerKey = GlobalKey<TimeBatteryMixin>();
  late final RxString title = ''.obs;
  late final RxnString onlineCount = RxnString();
  late final RxnString watchedShow = RxnString();
  Widget get watchedWidget => Obx(() {
    if (watchedShow.value case final watchedShow?) {
      return Text(
        watchedShow,
        style: const TextStyle(
          fontSize: 12,
          color: Colors.white,
        ),
      );
    }
    return const SizedBox.shrink();
  });

  void startLiveMsgStream() {
    if (messages.isEmpty) {
      prefetchDM();
      if (showSuperChat) getSuperChatMsg();
    }
    if (_msgStream != null || _dmConnecting) {
      return;
    }
    if (dmInfo != null) {
      initDm(dmInfo!);
      return;
    }
    _dmConnecting = true;
    final generation = _dmGeneration;
    LiveHttp.liveRoomGetDanmakuToken(roomId: roomId)
        .then((res) {
          if (generation != _dmGeneration) return;
          if (res case Success(:final response)) {
            _dmRetryCount = 0;
            initDm(dmInfo = response);
          } else {
            _scheduleDmRetry(generation);
          }
        })
        .whenComplete(() => _dmConnecting = false);
  }

  /// 申请 token 失败时退避重试（否则弹幕会一直不恢复，而长连接本身没有自动重连）
  void _scheduleDmRetry(int generation) {
    if (generation != _dmGeneration || _dmRetryCount >= _dmMaxRetry) {
      return;
    }
    _dmRetryCount++;
    _dmRetryTimer?.cancel();
    _dmRetryTimer = Timer(_dmRetryDelay, () {
      _dmRetryTimer = null;
      if (generation != _dmGeneration) return;
      startLiveMsgStream();
    });
  }

  Future<void> initDm(LiveDmInfoData info) async {
    if (info.hostList.isEmpty) return;
    _msgStream =
        LiveMessageStream(
            streamToken: info.token,
            roomId: roomId,
            uid: Accounts.heartbeat.mid,
            servers: info.hostList
                .map((host) => 'wss://${host.host}:${host.wssPort}/sub')
                .toList(),
          )
          ..addEventListener(_danmakuListener)
          ..init();
  }

  void addDm(dynamic msg, [DanmakuContentItem<DanmakuExtra>? item]) {
    _trimDm();

    if (plPlayerController.showDanmaku) {
      if (item != null && plPlayerController.enableShowLiveDanmaku.value) {
        danmakuController?.addDanmaku(item);
      }
      if (autoScroll && !disableAutoScroll.value) {
        messages.add(msg);
        scrollToBottom();
        return;
      }
    }

    messages.addOnly(msg);
  }

  @pragma('vm:notify-debugger-on-exception')
  void _danmakuListener(dynamic obj) {
    try {
      // logger.i(' 原始弹幕消息 ======> ${jsonEncode(obj)}');
      switch (obj['cmd']) {
        case 'DANMU_MSG':
          final info = obj['info'];
          final first = info[0];
          final content = first[15];
          final user = content['user'];
          // final midHash = first[7];
          final uid = user['uid'] as int;
          final msg = info[1];
          if (isBlocked(msg, uid)) {
            return;
          }
          final Map<String, dynamic> extra = jsonDecode(content['extra']);
          final name = user['base']['name'];
          BaseEmote? uemote;
          if (first[13] case Map<String, dynamic> map) {
            uemote = BaseEmote.fromJson(map);
          }
          final checkInfo = info[9];
          final liveExtra = LiveDanmaku(
            id: extra['id_str'],
            mid: uid,
            dmType: extra['dm_type'],
            ts: checkInfo['ts'],
            ct: checkInfo['ct'],
          );
          Owner? reply;
          final replyMid = extra['reply_mid'];
          if (replyMid != null && replyMid != 0) {
            reply = Owner(
              mid: replyMid,
              name: extra['reply_uname'],
            );
          }
          addDm(
            DanmakuMsg(
              name: name,
              text: msg,
              emots: (extra['emots'] as Map<String, dynamic>?)?.map(
                (k, v) => MapEntry(k, BaseEmote.fromJson(v)),
              ),
              uemote: uemote,
              extra: liveExtra,
              reply: reply,
              medalInfo: GlobalData().showMedal
                  ? UinfoMedal.lightMedal(user['medal'])
                  : null,
            ),
            DanmakuContentItem(
              msg,
              color: DanmakuOptions.blockColorful
                  ? Colors.white
                  : DmUtils.decimalToColor(extra['color']),
              type: DmUtils.getPosition(extra['mode']),
              // extra['send_from_me'] is invalid
              selfSend: isMainLogin && uid == mid,
              extra: liveExtra,
            ),
          );
          break;
        case 'SUPER_CHAT_MESSAGE' when showSuperChat:
          final item = SuperChatItem.fromJson(obj['data'], roomId);
          superChatMsg.insert(0, item);
          addDm(item);
          if (!enableFSSC) return;
          if (Platform.isAndroid && AndroidHelper.isPipMode) return;
          if (plPlayerController.showDanmaku &&
              (isFullScreen || plPlayerController.isDesktopPip)) {
            fsSC.value = item.copyWith(
              endTime: math.min(
                item.endTime,
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 10,
              ),
            );
          }
          break;
        // case 'SUPER_CHAT_MESSAGE_DELETE' when showSuperChat:
        //   if (obj['roomid'] == roomId) {
        //     final ids = obj['data']?['ids'] as List?;
        //     if (ids != null && ids.isNotEmpty) {
        //       if (superChatType == .valid) {
        //         superChatMsg.removeWhere((e) => ids.contains(e.id));
        //       } else {
        //         bool? refresh;
        //         for (final id in ids) {
        //           if (superChatMsg.firstWhereOrNull((e) => e.id == id)
        //               case final item?) {
        //             item.deleted = true;
        //             refresh ??= true;
        //           }
        //         }
        //         if (refresh ?? false) {
        //           superChatMsg.refresh();
        //         }
        //       }
        //     }
        //   }
        case 'WATCHED_CHANGE':
          watchedShow.value = obj['data']['text_large'];
          break;
        case 'ONLINE_RANK_COUNT':
          onlineCount.value = NumUtils.numFormat(obj['data']['count']);
          break;
        case 'ROOM_CHANGE':
          title.value = obj['data']['title'];
          break;
        case 'MESSAGEBOX_USER_MEDAL_CHANGE':
          if (kDebugMode) {
            debugPrint(Utils.jsonEncoder.convert(obj));
          }
          if (isMainLogin) {
            final json = obj['data']['uinfo_medal'];
            final updateRuid = json['ruid'];
            final medalRuid = medal.rawValue?.ruid;
            if (medalRuid == updateRuid ||
                (medalRuid == null && updateRuid == ruid)) {
              medal.value = .fromJson(json);
            }
          }
          break;
      }
    } catch (e, s) {
      if (kDebugMode) {
        Utils.reportError(e, s);
      }
    }
  }

  void stopLiveMsgStream() {
    // 作废仍在飞行中的 token 请求，否则它回来后会又建一条长连接（应用已经在后台）
    _dmGeneration++;
    _dmRetryTimer?.cancel();
    _dmRetryTimer = null;
    _dmRetryCount = 0;
    _msgStream?.close();
    _msgStream = null;
  }
}
