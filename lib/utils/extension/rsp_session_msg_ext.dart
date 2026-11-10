import 'package:PiliPlus/grpc/bilibili/im/interfaces/v1.pb.dart'
    show RspSessionMsg;

extension RspSessionMsgExt on RspSessionMsg {
  /// 本次返回的消息中的最新序号（首屏/刷新时即会话最新一条）。
  ///
  /// 标记已读（update_ack 的 ack_seqno）只能用这个值：消息按时间倒序返回，
  /// [messages] 的最后一条是本页最旧的一条，那是分页游标，不能当已读位置用。
  int get newestSeqno {
    var seqno = maxSeqno.toInt();
    // maxSeqno 缺失时退回消息里的最大序号
    for (final msg in messages) {
      final value = msg.msgSeqno.toInt();
      if (value > seqno) seqno = value;
    }
    return seqno;
  }
}
