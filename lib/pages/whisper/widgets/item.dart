import 'dart:convert';

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/common/widgets/dialog/simple_dialog_option.dart';
import 'package:PiliPlus/common/widgets/flutter/list_tile.dart';
import 'package:PiliPlus/common/widgets/pendant_avatar.dart';
import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart'
    show Session, SessionId, SessionPageType;
import 'package:PiliPlus/grpc/im.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/msg.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/pages/whisper_secondary/view.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/rsp_session_msg_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

class WhisperSessionItem extends StatelessWidget {
  const WhisperSessionItem({
    super.key,
    required this.item,
    required this.onSetTop,
    required this.onSetMute,
    required this.onRemove,
    this.onRefresh,
    this.onUnreadChanged,
  });

  final Session item;
  final Function(bool isTop, SessionId id) onSetTop;
  final Function(bool isMuted, Int64 talkerUid) onSetMute;
  final ValueChanged<int> onRemove;

  /// 从详情/子列表返回后刷新当前会话列表，避免摘要、排序停留在旧数据
  final VoidCallback? onRefresh;

  /// 本地改完未读状态后同步通知，避免通知栏等下一轮轮询才消失
  final VoidCallback? onUnreadChanged;

  Future<void> _updateAck(BuildContext context) async {
    final talkerId = item.id.privateId.talkerUid.toInt();
    // ack_seqno 要传「标到哪一条」即会话最新序号；会话对象里的 ackSeqno
    // 是当前已读指针，回传它等于什么都没做
    final res = await ImGrpc.syncFetchSessionMsgs(talkerId: talkerId);
    if (res case Success(:final response)) {
      final ackSeqno = response.newestSeqno;
      if (ackSeqno <= 0) {
        SmartDialog.showToast('未获取到会话最新消息序号');
        return;
      }
      final ackRes = await MsgHttp.ackSessionMsg(
        talkerId: talkerId,
        ackSeqno: ackSeqno,
      );
      if (ackRes.isSuccess) {
        SmartDialog.showToast('已标为已读');
        item.clearUnread();
        onUnreadChanged?.call();
        if (context.mounted) {
          (context as Element).markNeedsBuild();
        }
        // 未读角标以服务端汇总为准
        if (Get.isRegistered<MainController>()) {
          Get.find<MainController>().queryUnreadMsg();
        }
      } else {
        ackRes.toast();
      }
    } else {
      res.toast();
    }
  }

  @override
  Widget build(BuildContext context) {
    final resource =
        item.sessionInfo.avatar.fallbackLayers.layers.first.resource;
    final avatar = resource.hasResImage()
        ? resource.resImage.imageSrc.remote.url
        : resource.hasResAnimation()
        ? resource.resAnimation.webpSrc.remote.url
        : resource.resNativeDraw.drawSrc.remote.url;
    Map? vipInfo = item.sessionInfo.hasVipInfo()
        ? jsonDecode(item.sessionInfo.vipInfo)
        : null;

    final theme = Theme.of(context);

    // 未读标识：只要会话报告了未读就显示。
    // 服务端可能只给「有未读」不给 style（或只给 number_show），
    // 只看 style 会把这类会话的角标整个吞掉。
    final unread = item.hasUnread() ? item.unread : null;
    final showUnread =
        unread != null &&
        (unread.style != .UNREAD_STYLE_NONE ||
            unread.number > 0 ||
            unread.numberShow.isNotEmpty);
    // style 明确是圆点时只显示圆点，不被历史 number 值带成数字
    final unreadText = !showUnread || unread.style == .UNREAD_STYLE_DOT
        ? null
        : unread.numberShow.isNotEmpty
        ? unread.numberShow
        : unread.number > 0
        ? unread.number.toString()
        : null;

    return ListTile(
      safeArea: true,
      tileColor: item.isPinned
          ? theme.colorScheme.onInverseSurface.withValues(
              alpha: theme.isDark ? 0.4 : 0.8,
            )
          : null,
      onLongPress: () => showDialog(
        context: context,
        builder: (_) => SimpleDialog(
          clipBehavior: .hardEdge,
          contentPadding: const .symmetric(vertical: 12),
          children: [
            DialogOption(
              onPressed: () {
                Get.back();
                onSetTop(item.isPinned, item.id);
              },
              child: Text(item.isPinned ? '移除置顶' : '置顶'),
            ),
            if (item.id.privateId.hasTalkerUid()) ...[
              if (kDebugMode || item.hasUnread())
                DialogOption(
                  onPressed: () {
                    Get.back();
                    _updateAck(context);
                  },
                  child: const Text('标为已读'),
                ),
              DialogOption(
                onPressed: () {
                  Get.back();
                  onSetMute(item.isMuted, item.id.privateId.talkerUid);
                },
                child: Text('${item.isMuted ? '关闭' : '开启'}免打扰'),
              ),
              DialogOption(
                onPressed: () {
                  Get.back();
                  showConfirmDialog(
                    context: context,
                    title: const Text('确定删除该对话？'),
                    onConfirm: () =>
                        onRemove(item.id.privateId.talkerUid.toInt()),
                  );
                },
                child: const Text('删除'),
              ),
            ],
          ],
        ),
      ),
      onSecondaryTapUp: PlatformUtils.isDesktop
          ? (details) => showMenu(
              context: context,
              position: PageUtils.menuPosition(details.globalPosition),
              items: <PopupMenuEntry<Never>>[
                PopupMenuItem(
                  height: 42,
                  onTap: () => onSetTop(item.isPinned, item.id),
                  child: Text(item.isPinned ? '移除置顶' : '置顶'),
                ),
                if (item.id.privateId.hasTalkerUid()) ...[
                  if (kDebugMode || item.hasUnread())
                    PopupMenuItem(
                      height: 42,
                      onTap: () => _updateAck(context),
                      child: const Text('标为已读'),
                    ),
                  // if (kDebugMode)
                  //   PopupMenuItem(
                  //     height: 42,
                  //     onTap: () {
                  //       item.unread = Unread(
                  //         style: .UNREAD_STYLE_NUMBER,
                  //         number: .ONE,
                  //       );
                  //       (context as Element).markNeedsBuild();
                  //     },
                  //     child: const Text('标为未读'),
                  //   ),
                  PopupMenuItem(
                    height: 42,
                    onTap: () =>
                        onSetMute(item.isMuted, item.id.privateId.talkerUid),
                    child: Text('${item.isMuted ? '关闭' : '开启'}免打扰'),
                  ),
                  const PopupMenuDivider(height: 10),
                  PopupMenuItem(
                    height: 42,
                    onTap: () => showConfirmDialog(
                      context: context,
                      title: const Text('确定删除该对话？'),
                      onConfirm: () =>
                          onRemove(item.id.privateId.talkerUid.toInt()),
                    ),
                    child: Text(
                      '删除',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ],
            )
          : null,
      onTap: () async {
        if (item.id.privateId.hasTalkerUid()) {
          await Get.toNamed(
            '/whisperDetail',
            arguments: {
              'talkerId': item.id.privateId.talkerUid.toInt(),
              'name': item.sessionInfo.sessionName,
              'face': avatar,
              if (item.sessionInfo.avatar.hasMid())
                'mid': item.sessionInfo.avatar.mid.toInt(),
              'isLive': item.sessionInfo.isLive,
            },
          );
          // 详情页会按最新序号 ack 已读；返回后以服务端数据刷新摘要、未读与排序
          onRefresh?.call();
          return;
        }

        if (item.id.foldId.hasType()) {
          SessionPageType? sessionPageType = switch (item.id.foldId.type) {
            .SESSION_TYPE_UNKNOWN => .SESSION_PAGE_TYPE_UNKNOWN,
            .SESSION_TYPE_GROUP => .SESSION_PAGE_TYPE_GROUP,
            .SESSION_TYPE_GROUP_FOLD => .SESSION_PAGE_TYPE_GROUP,
            .SESSION_TYPE_UNFOLLOWED => .SESSION_PAGE_TYPE_UNFOLLOWED,
            .SESSION_TYPE_STRANGER => .SESSION_PAGE_TYPE_STRANGER,
            .SESSION_TYPE_DUSTBIN => .SESSION_PAGE_TYPE_DUSTBIN,
            .SESSION_TYPE_CUSTOMER_FOLD => .SESSION_PAGE_TYPE_CUSTOMER,
            .SESSION_TYPE_AI_FOLD => .SESSION_PAGE_TYPE_AI,
            .SESSION_TYPE_CUSTOMER_ACCOUNT => .SESSION_PAGE_TYPE_CUSTOMER,
            _ => null,
          };
          if (sessionPageType != null) {
            await Get.to(
              WhisperSecPage(
                name: item.sessionInfo.sessionName,
                sessionPageType: sessionPageType,
              ),
            );
            onRefresh?.call();
          } else {
            SmartDialog.showToast(item.id.foldId.type.name);
          }
          return;
        }

        if (item.id.hasSystemId()) {
          switch (item.id.systemId.type) {
            case .SESSION_TYPE_SYSTEM:
              await Get.toNamed('/sysMsg');
              onRefresh?.call();
            case .SESSION_TYPE_AI_FOLD:
            case .SESSION_TYPE_CUSTOMER_ACCOUNT:
            case .SESSION_TYPE_CUSTOMER_FOLD:
            case .SESSION_TYPE_DUSTBIN:
            case .SESSION_TYPE_GROUP:
            case .SESSION_TYPE_GROUP_FOLD:
            case .SESSION_TYPE_PRIVATE:
            case .SESSION_TYPE_STRANGER:
            case .SESSION_TYPE_UNFOLLOWED:
            case .SESSION_TYPE_UNKNOWN:
              SmartDialog.showToast(item.id.systemId.type.name);
          }
        }
      },
      leading: Builder(
        builder: (context) {
          final pendant = item.sessionInfo.avatar.fallbackLayers.layers
              .elementAtOrNull(1)
              ?.resource;
          final official = item
              .sessionInfo
              .avatar
              .fallbackLayers
              .layers
              .lastOrNull
              ?.resource
              .resImage
              .imageSrc;

          return GestureDetector(
            onTap: item.sessionInfo.avatar.hasMid()
                ? () =>
                      Get.toNamed('/member?mid=${item.sessionInfo.avatar.mid}')
                : null,
            child: PendantAvatar(
              avatar,
              size: 42,
              badgeSize: 14,
              pendantImage: pendant?.resImage.imageSrc.remote.hasUrl() == true
                  ? pendant!.resImage.imageSrc.remote.url
                  : pendant?.resAnimation.webpSrc.remote.url,
              vipStatus: vipInfo?['status'],
              officialType: official?.hasLocalValue() == true
                  ? switch (official!.localValue) {
                      3 => 0,
                      4 => 1,
                      _ => null,
                    }
                  : null,
            ),
          );
        },
      ),
      title: Row(
        spacing: 5,
        children: [
          Expanded(
            child: Row(
              spacing: 5,
              children: [
                Flexible(
                  child: Text(
                    item.sessionInfo.sessionName,
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      color:
                          vipInfo?['status'] != null &&
                              vipInfo!['status'] > 0 &&
                              vipInfo['type'] == 2
                          ? theme.colorScheme.vipColor
                          : null,
                    ),
                  ),
                ),
                if (item.sessionInfo.userLabel.style.borderedLabel.hasText())
                  PBadge(
                    isStack: false,
                    type: .line_secondary,
                    size: .small,
                    fontSize: 10,
                    isBold: false,
                    text: item.sessionInfo.userLabel.style.borderedLabel.text,
                  ),
                if (item.sessionInfo.isLive)
                  Image.asset(
                    Assets.livingRect,
                    height: 15,
                    cacheHeight: 15.cacheSize(context),
                    filterQuality: .low,
                  ),
              ],
            ),
          ),
          if (item.hasTimestamp())
            Text(
              DateFormatUtils.dateFormat((item.timestamp ~/ 1000000).toInt()),
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.outline,
              ),
            ),
        ],
      ),
      subtitle: Row(
        spacing: 6,
        children: [
          Expanded(
            child: Text(
              item.msgSummary.rawMsg,
              maxLines: 1,
              overflow: .ellipsis,
              style: theme.textTheme.labelMedium!.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          // 免打扰和未读是两件事：被免打扰的会话同样可能有未读，
          // 之前用 if/else 会让免打扰图标把未读角标顶掉
          if (item.isMuted)
            Icon(
              size: 16,
              Icons.notifications_off,
              color: theme.colorScheme.outline,
            ),
          if (showUnread)
            Badge(label: unreadText == null ? null : Text(unreadText)),
        ],
      ),
    );
  }
}
