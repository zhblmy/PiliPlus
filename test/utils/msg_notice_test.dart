import 'dart:typed_data';

import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart'
    show
        FoldId,
        GroupId,
        MsgSummary,
        PrivateId,
        Session,
        SessionId,
        SessionInfo,
        Unread,
        UnreadStyle;
import 'package:PiliPlus/grpc/bilibili/dagw/component/avatar/common.pb.dart'
    show RemoteRes, ResourceSource;
import 'package:PiliPlus/grpc/bilibili/dagw/component/avatar/v1.pb.dart'
    show AvatarItem, BasicLayerResource, Layer, LayerGroup, ResImage;
import 'package:PiliPlus/services/message_badge.dart';
import 'package:PiliPlus/utils/msg_notice.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildMsgNotices', () {
    test('只保留有未读标记的会话', () {
      final items = buildMsgNotices([
        _session(privateUid: 1, number: Int64(2)),
        _session(
          privateUid: 2,
          style: UnreadStyle.UNREAD_STYLE_NONE,
          number: Int64(0),
        ),
      ]);
      expect(items.map((e) => e.key), ['p:1']);
    });

    test('未读口径与消息列表一致，Int64 会转成 int', () {
      final items = buildMsgNotices([
        // 只有圆点，没有数字
        _session(privateUid: 3, style: UnreadStyle.UNREAD_STYLE_DOT),
        // number 为 0，但服务端给了 numberShow
        _session(
          privateUid: 4,
          style: UnreadStyle.UNREAD_STYLE_NUMBER,
          number: Int64(0),
          numberShow: '99+',
        ),
        _session(privateUid: 5, number: Int64(7)),
      ]);
      expect(items.map((e) => e.unread), [1, 1, 7]);
      expect(items.last.unread, isA<int>());
    });

    test('私聊与群会话使用不同的稳定 key', () {
      final items = buildMsgNotices([
        _session(privateUid: 1001, number: Int64(1)),
        _session(groupId: 2002, number: Int64(1)),
      ]);
      expect(items.map((e) => e.key), ['p:1001', 'g:2002']);
    });

    test('折叠/系统等非联系人会话不进通知', () {
      final items = buildMsgNotices([
        Session(
          id: SessionId(foldId: FoldId()),
          sessionInfo: SessionInfo(sessionName: '折叠会话'),
          unread: Unread(
            style: UnreadStyle.UNREAD_STYLE_NUMBER,
            number: Int64(3),
          ),
        ),
      ]);
      expect(items, isEmpty);
    });

    test('最多只发布 5 条', () {
      final items = buildMsgNotices([
        for (var i = 1; i <= 6; i++)
          _session(privateUid: i, number: Int64(1)),
      ]);
      expect(items, hasLength(5));
      expect(items.map((e) => e.key), ['p:1', 'p:2', 'p:3', 'p:4', 'p:5']);
    });

    test('名称与摘要为空时降级为兜底文案', () {
      final items = buildMsgNotices([
        _session(privateUid: 7, name: '  ', preview: '  ', number: Int64(1)),
      ]);
      expect(items.single.name, '新消息');
      expect(items.single.content, '有新消息');
    });

    test('头像取 fallbackLayers 第一层的资源地址', () {
      final items = buildMsgNotices([
        _session(
          privateUid: 8,
          number: Int64(1),
          avatar: _avatar('https://i0.hdslb.com/bfs/face/a.jpg'),
        ),
        _session(privateUid: 9, number: Int64(1)),
      ]);
      expect(items.first.avatarUrl, 'https://i0.hdslb.com/bfs/face/a.jpg');
      expect(items.last.avatarUrl, isEmpty);
    });

    test('免打扰原样透传，会话时间戳由微秒转成毫秒', () {
      final items = buildMsgNotices([
        _session(privateUid: 10, number: Int64(1), muted: true),
      ]);
      expect(items.single.muted, isTrue);
      // Session.timestamp 是微秒，通知的 setWhen 需要毫秒
      expect(items.single.timestamp, 1700000000000);
    });
  });

  group('changedNoticeKeys', () {
    MsgNoticeItem item(
      String key, {
      String content = '在吗',
      int timestamp = 1700000000000,
    }) => MsgNoticeItem(
      key: key,
      name: '张三',
      avatarUrl: '',
      content: content,
      unread: 1,
      muted: false,
      timestamp: timestamp,
    );

    test('新会话、内容变化、时间变化都要提醒', () {
      final previous = {
        'p:1': '1700000000000\u0001在吗',
        'p:2': '1700000000000\u0001在吗',
      };
      final keys = changedNoticeKeys([
        item('p:1'),
        item('p:2', content: '新消息'),
        item('p:3'),
      ], previous);
      expect(keys, {'p:2', 'p:3'});
    });

    test('只有未读数变化（在别处读掉一条）不算新消息', () {
      final previous = {'p:1': '1700000000000\u0001在吗'};
      expect(changedNoticeKeys([item('p:1')], previous), isEmpty);
    });

    test('时间变化同样算新消息', () {
      final previous = {'p:1': '1700000000000\u0001在吗'};
      expect(
        changedNoticeKeys([item('p:1', timestamp: 1700000000001)], previous),
        {'p:1'},
      );
    });
  });

  group('message notification fingerprint', () {
    test('stable for identical data and changes with timestamp or avatar', () {
      final item = <String, Object?>{
        'key': 'p:1',
        'name': '张三',
        'avatarUrl': 'https://example.com/avatar.webp',
        'content': '你好',
        'unread': 1,
        'muted': false,
        'timestamp': 1700000000000,
        'avatar': null,
      };

      final initial = MessageBadge.signatureForTesting([item]);
      expect(MessageBadge.signatureForTesting([Map.of(item)]), initial);
      expect(
        MessageBadge.signatureForTesting([
          {...item, 'timestamp': 1700000000001},
        ]),
        isNot(initial),
      );
      expect(
        MessageBadge.signatureForTesting([
          {...item, 'avatar': Uint8List.fromList([1])},
        ]),
        isNot(initial),
      );
      // alert 只是"这次要不要响"，不属于内容身份，不应影响去重
      expect(
        MessageBadge.signatureForTesting([
          {...item, 'alert': false},
        ]),
        initial,
      );
      // 桌面角标开关切换后要按新状态重发（带数字 ↔ 不带数字）
      expect(
        MessageBadge.signatureForTesting([item], badge: false),
        isNot(initial),
      );
    });
  });
}

Session _session({
  int? privateUid,
  int? groupId,
  String name = '张三',
  String preview = '在吗',
  Int64? number,
  String numberShow = '',
  UnreadStyle style = UnreadStyle.UNREAD_STYLE_NUMBER,
  bool muted = false,
  AvatarItem? avatar,
}) {
  return Session(
    id: privateUid != null
        ? SessionId(privateId: PrivateId(talkerUid: Int64(privateUid)))
        : SessionId(groupId: GroupId(groupId: Int64(groupId!))),
    sessionInfo: SessionInfo(sessionName: name, avatar: avatar),
    unread: Unread(
      style: style,
      number: number ?? Int64(0),
      numberShow: numberShow,
    ),
    msgSummary: MsgSummary(rawMsg: preview),
    isMuted: muted,
    // 真实数据是微秒（会话列表 UI 用 ~/ 1000000 取秒）
    timestamp: Int64(1700000000000000),
  );
}

AvatarItem _avatar(String url) => AvatarItem(
  fallbackLayers: LayerGroup(
    layers: [
      Layer(
        resource: BasicLayerResource(
          resImage: ResImage(
            imageSrc: ResourceSource(remote: RemoteRes(url: url)),
          ),
        ),
      ),
    ],
  ),
);
