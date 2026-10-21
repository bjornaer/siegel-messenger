// Widget tests for every screen built so far (section 15: Flutter tests per screen), against a
// fake core. Real network and storage paths are covered by core-api/tests/e2e.rs.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:archive/archive.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:siegel/app_lock.dart';
import 'package:siegel/discovery.dart';
import 'package:siegel/linked_devices.dart';
import 'package:siegel/links.dart' show appChannel;
import 'package:siegel/avatar.dart';
import 'package:siegel/backgrounds.dart';
import 'package:siegel/chats.dart';
import 'package:siegel/groups.dart';
import 'package:siegel/l10n/app_localizations.dart';
import 'package:siegel/main.dart';
import 'package:siegel/web.dart';
import 'package:siegel/media.dart';
import 'package:siegel/minors.dart';
import 'package:siegel/onboarding.dart';
import 'package:siegel/phone_field.dart';
import 'package:siegel/push.dart' show notificationStrings;
import 'package:siegel/report.dart';
import 'package:siegel/sticker_editor.dart';
import 'package:siegel/stickers.dart';
import 'package:siegel/suspended.dart';
import 'package:siegel/themes.dart';
import 'package:siegel/src/rust/api/core.dart';

class FakeCore implements Core {
  bool registered = false;
  bool linked = false;
  String? name;
  String? user;
  final settings = <String, String>{};
  final calls = <String>[];
  final failNext = <String, String>{}; // method -> CoreError code, thrown once

  Future<void> _maybeFail(String method) async {
    calls.add(method);
    final code = failNext.remove(method);
    if (code != null) throw CoreError(code: code);
  }

  @override
  Future<int> requestOtp({
    required String phoneE164,
    required String attestationToken,
    required DevicePlatform platform,
  }) async {
    await _maybeFail('requestOtp $phoneE164');
    return 30;
  }

  @override
  Future<bool> verify({
    required String phoneE164,
    required String otp,
    required String pin,
    required DevicePlatform platform,
  }) async {
    await _maybeFail('verify $otp $pin');
    registered = true;
    return false;
  }

  @override
  Future<void> setUsername({required String username}) async {
    await _maybeFail('setUsername $username');
    user = username;
  }

  @override
  Future<AppVersion> appVersion({required DevicePlatform platform}) async => const AppVersion(latest: 0, minimum: 0);
  String? link = 'https://siegel.schlk.in/u/ana#fp.c2VjcmV0';
  @override
  String? contactLink() => link;
  @override
  void setContactLink({required bool enabled}) => link = enabled ? 'https://siegel.schlk.in/u/ana#fp.bmV3' : null;
  @override
  void resetContactLink() => link = 'https://siegel.schlk.in/u/ana#fp.cmVzZXQ';
  @override
  Future<Uint8List> openContactLink({required String link}) async {
    await _maybeFail('openContactLink');
    return startChat(username: 'linked');
  }

  String? phone;
  bool discoverableOn = false;
  @override
  String? myPhone() => phone;
  @override
  void setMyPhone({required String phone}) => this.phone = phone;
  @override
  Future<bool> discoverable() async => discoverableOn;
  @override
  Future<void> setDiscoverable({required bool enabled}) async {
    await _maybeFail('setDiscoverable');
    discoverableOn = enabled;
  }

  bool removed = false;
  @override
  bool numberRemoved() => removed;
  @override
  Future<void> changeNumber({required String phoneE164, required String otp, required String pin}) async {
    await _maybeFail('changeNumber $phoneE164 $otp $pin');
    phone = phoneE164;
    removed = false;
  }

  @override
  Future<ServerData> serverData() async => ServerData(
    accountId: 'aa',
    phoneHash: '0123456789abcdef0123',
    createdDay: '2026-10-01',
    numberChangedDay: '',
    identityKey: 'beef',
    username: user ?? '',
    usernameClaimedDay: '2026-10-02',
    releasedUsernames: const ['old_ana'],
    registrationLock: lockSet,
    discoverable: discoverableOn,
    profile: true,
    profilePicture: false,
    numbersChecked: 12,
    minor: isMinor,
    devices: const [
      ServerDevice(
        id: 'd1',
        ios: false,
        lastSeenDay: '2026-10-18',
        pushToken: true,
        queued: 3,
        keyPackages: 50,
        thisDevice: true,
      ),
    ],
  );

  final reports = <String>[];
  @override
  Future<void> report({
    required List<int> groupId,
    required int category,
    required String note,
    required List<Uint8List> messageIds,
    required bool block,
  }) async {
    await _maybeFail('report');
    reports.add('$category ${messageIds.length} $note block=$block');
    if (block) await this.block(account: chatList.firstWhere((c) => listEquals(c.groupId, groupId)).peerAccount);
  }

  @override
  int takeReportsReviewed() => 0;
  @override
  Future<void> shareChatSetting({required List<int> groupId, required String name, required String value}) async =>
      calls.add('share $name=$value');

  final deviceList = <DeviceView>[
    DeviceView(id: Uint8List.fromList([1]), name: '', linked: false, lastSeenDay: '2026-10-20', thisDevice: true),
  ];
  @override
  Future<List<DeviceView>> devices() async => List.of(deviceList);
  @override
  Future<void> linkDevice({required String qr}) async => calls.add('linkDevice');
  @override
  Future<void> unlinkDevice({required List<int> deviceId}) async {
    calls.add('unlinkDevice');
    deviceList.removeWhere((d) => listEquals(d.id, deviceId));
  }

  @override
  Future<String> linkBegin({required String deviceName}) async => 'siegel-link:x.age1y.$deviceName';
  @override
  Future<bool> linkWait() async => linkApproved;
  bool linkApproved = false;
  @override
  Future<void> unlinkThisDevice() async => calls.add('unlinkThisDevice');
  @override
  bool isLinkedDevice() => linked;

  NoticeView? notice_;
  @override
  NoticeView? notice() => notice_;

  bool isMinor = false;
  @override
  bool minor() => isMinor;
  @override
  Future<void> setMinor({required bool minor}) async {
    calls.add('setMinor $minor');
    isMinor = minor;
  }

  @override
  Future<Uint8List> startChatByNumber({required String username, required List<int> proof}) {
    calls.add('startChatByNumber $username');
    return startChat(username: username);
  }

  List<String> searched = [];
  @override
  Future<List<FoundContact>> findContacts({required List<String> numbers}) async {
    searched = numbers;
    return [
      for (final n in numbers)
        if (n == '+34600111222') FoundContact(phone: n, username: 'bea', proof: Uint8List.fromList([9])),
    ];
  }

  final links = <GroupLinkView>[];
  @override
  Future<String> createGroupLink({required List<int> groupId}) async {
    await _maybeFail('createGroupLink');
    final l = GroupLinkView(link: 'https://siegel.schlk.in/g/abc#key', expires: 1893456000, id: Uint8List(1));
    links.add(l);
    return l.link;
  }

  @override
  List<GroupLinkView> groupLinks({required List<int> groupId}) => links;
  @override
  Future<void> revokeGroupLink({required List<int> groupId, required List<int> id}) async => links.clear();
  @override
  Future<GroupPreviewView> previewGroupLink({required String link}) async =>
      const GroupPreviewView(name: 'Climbers', members: 3);
  @override
  Future<Uint8List> joinGroupLink({required String link}) => createGroup(name: 'Climbers', usernames: const []);

  bool lockSet = false;
  @override
  bool hasRegistrationLock() => lockSet;
  @override
  Future<void> setRegistrationLock({required String pin}) => _maybeFail('setRegistrationLock $pin');
  @override
  Future<void> deleteAccount() => _maybeFail('deleteAccount');
  @override
  bool isRegistered() => registered;
  @override
  String? username() => user;
  @override
  String? displayName() => name;
  @override
  void setDisplayName({required String name}) => this.name = name;
  @override
  String? setting({required String key}) => settings[key];
  @override
  void setSetting({required String key, required String value}) => settings[key] = value;

  final stickerList = <StickerView>[];
  final stickerBytes = <String, Uint8List>{};
  @override
  StickerView addSticker({required List<int> data, required String mimeType, required String pack}) {
    if (!{'image/webp', 'image/png'}.contains(mimeType)) throw const CoreError(code: 'sticker_invalid');
    final id = '${data.length}-${data.isEmpty ? 0 : data.first}';
    final v = StickerView(id: id, pack: pack, mimeType: mimeType);
    if (!stickerList.any((s) => s.id == id && s.pack == pack)) stickerList.add(v);
    stickerBytes[id] = Uint8List.fromList(data);
    return v;
  }

  @override
  List<StickerView> stickers() => List.of(stickerList);
  @override
  Uint8List? stickerData({required String id}) => stickerBytes[id];
  @override
  void removeStickers({required String pack, required String id}) =>
      stickerList.removeWhere((s) => s.pack == pack && (id.isEmpty || s.id == id));
  // Chats: one list of messages per chat, keyed by group ID.
  final chatList = <ChatSummary>[];
  final history = <String, List<MessageView>>{};
  final events = StreamController<CoreEvent>.broadcast();

  @override
  List<ChatSummary> chats() => [
    for (final c in chatList)
      ChatSummary(
        groupId: c.groupId,
        peerAccount: c.peerAccount,
        peerDisplayName: c.peerDisplayName,
        peerUsername: c.peerUsername,
        request: c.request,
        peerVerified: verified.contains(base64Encode(c.groupId)),
        isGroup: c.isGroup,
        groupName: c.groupName,
        left: c.left,
        last: (history[base64Encode(c.groupId)] ?? []).lastOrNull,
        unread: (history[base64Encode(c.groupId)] ?? [])
            .where((m) => !m.outgoing && m.status == MessageStatus.delivered)
            .length,
      ),
  ];

  ChatSummary _with(ChatSummary c, {required bool request}) => ChatSummary(
    groupId: c.groupId,
    peerAccount: c.peerAccount,
    peerDisplayName: c.peerDisplayName,
    peerUsername: c.peerUsername,
    request: request,
    peerVerified: false,
    isGroup: false,
    left: false,
    unread: 0,
  );

  /// Someone who isn't a contact started a chat with us (MSG-15).
  void incomingRequest(String name) {
    final id = Uint8List.fromList(utf8.encode('g-req-$name'));
    chatList.add(
      ChatSummary(
        groupId: id,
        peerAccount: Uint8List(16),
        peerDisplayName: name,
        request: true,
        peerVerified: false,
        isGroup: false,
        left: false,
        unread: 0,
      ),
    );
    receive(id, 'hi, it is $name');
  }

  @override
  Future<void> accept({required List<int> groupId}) async {
    await _maybeFail('accept');
    final i = chatList.indexWhere((c) => listEquals(c.groupId, groupId));
    chatList[i] = _with(chatList[i], request: false);
    events.add(const CoreEvent(kind: CoreEventKind.profileUpdated));
  }

  @override
  void clearChat({required List<int> groupId}) {
    calls.add('clearChat');
    history[base64Encode(groupId)] = [];
  }

  @override
  void deleteChat({required List<int> groupId}) {
    calls.add('deleteChat');
    chatList.removeWhere((c) => listEquals(c.groupId, groupId));
  }

  @override
  Future<void> block({required List<int> account}) async {
    await _maybeFail('block');
    for (final c in chatList.where((c) => listEquals(c.peerAccount, account))) {
      blockedList.add(BlockedContact(account: c.peerAccount, displayName: c.peerDisplayName));
    }
    chatList.removeWhere((c) => listEquals(c.peerAccount, account)); // blocked chats are hidden
  }

  final blockedList = <BlockedContact>[];
  @override
  List<BlockedContact> blocked() => blockedList;
  @override
  Future<void> unblock({required List<int> account}) async {
    await _maybeFail('unblock');
    blockedList.removeWhere((c) => listEquals(c.account, account));
  }

  @override
  List<MessageView> messages({required List<int> groupId, required int limit}) => history[base64Encode(groupId)] ?? [];
  @override
  Future<Uint8List> startChat({required String username}) async {
    await _maybeFail('startChat $username');
    final id = Uint8List.fromList(utf8.encode('g-$username'));
    chatList.add(
      ChatSummary(
        groupId: id,
        peerAccount: Uint8List(16),
        peerUsername: username,
        request: false,
        peerVerified: false,
        isGroup: false,
        left: false,
        unread: 0,
      ),
    );
    return id;
  }

  final sentMentions = <List<int>>[];
  @override
  Future<MessageView> sendText({
    required List<int> groupId,
    required String text,
    Uint8List? replyTo,
    required List<Uint8List> mentions,
  }) async {
    sentMentions.addAll(mentions);
    final m = msg(groupId, text, outgoing: true, replyTo: replyTo);
    (history[base64Encode(groupId)] ??= []).add(m);
    try {
      await _maybeFail('sendText $text');
    } on CoreError {
      _update(m.messageId, (v) => copy(v, status: MessageStatus.failed));
      rethrow;
    }
    return m;
  }

  @override
  Future<MessageView> sendAttachment({
    required List<int> groupId,
    required List<int> data,
    required String mimeType,
    required String fileName,
    required int durationMs,
    required bool voiceNote,
    required List<int> waveform,
    required int width,
    required int height,
    required List<int> thumbnail,
    required bool sticker,
    Uint8List? replyTo,
  }) async {
    calls.add(sticker ? 'sendSticker' : 'sendAttachment');
    final m = msg(
      groupId,
      '',
      outgoing: true,
      replyTo: replyTo,
      attachment: AttachmentView(
        mimeType: mimeType,
        fileName: fileName,
        size: BigInt.from(data.length),
        durationMs: durationMs,
        voiceNote: voiceNote,
        waveform: Uint8List.fromList(waveform),
        width: width,
        height: height,
        thumbnail: Uint8List.fromList(thumbnail),
        sticker: sticker,
      ),
    );
    (history[base64Encode(groupId)] ??= []).add(m);
    return m;
  }

  @override
  bool attachmentDownloaded({required List<int> messageId}) => false;

  final forwards = <String>[];
  @override
  Future<MessageView> forward({required List<int> messageId, required List<int> to}) async {
    forwards.add(base64Encode(to));
    final src = history.values.expand((l) => l).firstWhere((m) => listEquals(m.messageId, messageId));
    final m = msg(to, src.text, outgoing: true, attachment: src.attachment);
    (history[base64Encode(to)] ??= []).add(m);
    return m;
  }

  @override
  Future<Uint8List> attachmentData({required List<int> messageId}) async {
    calls.add('attachmentData');
    final d = blobs[base64Encode(messageId)];
    if (d == null) throw const CoreError(code: 'attachment_expired');
    return d;
  }

  /// Attachments this fake can hand out, by message ID.
  final blobs = <String, Uint8List>{};

  Uint8List? mine;
  final avatars = <String, Uint8List>{};

  @override
  Future<void> setAvatar({Uint8List? image}) async {
    calls.add(image == null ? 'removeAvatar' : 'setAvatar');
    mine = image;
  }

  @override
  Uint8List? myAvatar() => mine;

  @override
  Uint8List? avatar({required List<int> account}) => avatars[base64Encode(account)];

  @override
  Future<void> announceProfile() async => calls.add('announceProfile');

  final groupAvatars = <String, Uint8List>{};

  @override
  Future<void> setGroupAvatar({required List<int> groupId, Uint8List? image}) async {
    calls.add(image == null ? 'removeGroupAvatar' : 'setGroupAvatar');
    image == null ? groupAvatars.remove(base64Encode(groupId)) : groupAvatars[base64Encode(groupId)] = image;
  }

  @override
  Uint8List? groupAvatar({required List<int> groupId}) => groupAvatars[base64Encode(groupId)];

  /// Rewrites one stored message, like the core does for receipts and changes.
  void _update(List<int> id, MessageView Function(MessageView) f) {
    for (final list in history.values) {
      final i = list.indexWhere((m) => listEquals(m.messageId, id));
      if (i >= 0) list[i] = f(list[i]);
    }
    events.add(const CoreEvent(kind: CoreEventKind.updated));
  }

  final versionsOf = <String, List<String>>{};

  @override
  Future<void> retry({required List<int> messageId}) async {
    await _maybeFail('retry');
    _update(messageId, (v) => copy(v, status: MessageStatus.sent));
  }

  @override
  Future<void> react({required List<int> groupId, required List<int> messageId, required String emoji}) async {
    await _maybeFail('react $emoji');
    _update(
      messageId,
      (v) => copy(
        v,
        reactions: [if (emoji.isNotEmpty) Reaction(account: Uint8List(1), emoji: emoji)],
      ),
    );
  }

  @override
  Future<void> edit({required List<int> groupId, required List<int> messageId, required String text}) async {
    await _maybeFail('edit $text');
    _update(messageId, (v) {
      (versionsOf[base64Encode(messageId)] ??= []).add(v.text);
      return copy(v, text: text, edited: true);
    });
  }

  @override
  Future<void> deleteForEveryone({required List<int> groupId, required List<int> messageId}) async {
    await _maybeFail('deleteForEveryone');
    _update(messageId, (v) => copy(v, text: '', deleted: true));
  }

  @override
  void deleteForMe({required List<int> messageId}) {
    for (final list in history.values) {
      list.removeWhere((m) => listEquals(m.messageId, messageId));
    }
  }

  @override
  List<String> versions({required List<int> messageId}) => versionsOf[base64Encode(messageId)] ?? [];
  final verified = <String>{};
  @override
  String? safetyNumber({required List<int> groupId}) => '0123456789' * 6;
  @override
  bool verifySafetyNumber({required List<int> groupId, required String scanned}) {
    final ok = scanned == safetyNumber(groupId: groupId);
    if (ok) verified.add(base64Encode(groupId));
    return ok;
  }

  @override
  Future<void> markRead({required List<int> groupId}) async {
    calls.add('markRead');
    final list = history[base64Encode(groupId)] ?? [];
    for (var i = 0; i < list.length; i++) {
      if (!list[i].outgoing && list[i].status == MessageStatus.delivered) {
        list[i] = copy(list[i], status: MessageStatus.read);
      }
    }
  }

  @override
  Future<void> sendTyping({required List<int> groupId}) async => calls.add('sendTyping');

  int connects = 0;
  @override
  Stream<CoreEvent> runStream() {
    connects++;
    return events.stream;
  }

  @override
  Stream<CoreEvent> drain() => const Stream.empty();

  // Groups: one GroupInfoView per group; member accounts are [n] bytes, names in [names].
  static final me = Uint8List.fromList([0]);
  final groups = <String, GroupInfoView>{};
  final names = <String, String>{};
  Uint8List _account(String username) {
    final a = Uint8List.fromList([names.length + 1]);
    names[base64Encode(a)] = '@$username';
    return a;
  }

  GroupMemberView _member(Uint8List a, {bool admin = false, bool me = false}) =>
      GroupMemberView(account: a, admin: admin, me: me, username: names[base64Encode(a)]?.substring(1));

  void _setGroup(List<int> id, GroupInfoView g) {
    groups[base64Encode(id)] = g;
    final i = chatList.indexWhere((c) => listEquals(c.groupId, id));
    final c = ChatSummary(
      groupId: Uint8List.fromList(id),
      peerAccount: Uint8List(0),
      request: false,
      peerVerified: false,
      isGroup: true,
      groupName: g.name,
      left: false,
      unread: 0,
    );
    if (i < 0) {
      chatList.add(c);
    } else {
      chatList[i] = c;
    }
    events.add(const CoreEvent(kind: CoreEventKind.updated));
  }

  void systemLine(List<int> id, GroupEventKind kind, {String name = ''}) => (history[base64Encode(id)] ??= []).add(
    msg(
      id,
      '',
      outgoing: false,
      event: GroupEventView(kind: kind, actor: me, targets: const [], name: name),
      sender: me,
    ),
  );

  @override
  Future<Uint8List> createGroup({required String name, required List<String> usernames}) async {
    await _maybeFail('createGroup $name');
    final id = Uint8List.fromList(utf8.encode('grp-$name'));
    _setGroup(
      id,
      GroupInfoView(
        name: name,
        members: [_member(me, admin: true, me: true), for (final u in usernames) _member(_account(u))],
        adminsOnlyInfo: true,
        adminsOnlyAdd: true,
        meAdmin: true,
      ),
    );
    systemLine(id, GroupEventKind.created);
    return id;
  }

  @override
  GroupInfoView groupInfo({required List<int> groupId}) => groups[base64Encode(groupId)]!;

  GroupInfoView _copy(GroupInfoView g, {String? name, List<GroupMemberView>? members}) => GroupInfoView(
    name: name ?? g.name,
    members: members ?? g.members,
    adminsOnlyInfo: g.adminsOnlyInfo,
    adminsOnlyAdd: g.adminsOnlyAdd,
    meAdmin: g.meAdmin,
  );

  @override
  Future<void> renameGroup({required List<int> groupId, required String name}) async {
    await _maybeFail('renameGroup $name');
    _setGroup(groupId, _copy(groupInfo(groupId: groupId), name: name));
    systemLine(groupId, GroupEventKind.renamed, name: name);
  }

  @override
  Future<void> addMembers({required List<int> groupId, required List<String> usernames}) async {
    await _maybeFail('addMembers ${usernames.join(',')}');
    final g = groupInfo(groupId: groupId);
    _setGroup(groupId, _copy(g, members: [...g.members, for (final u in usernames) _member(_account(u))]));
  }

  @override
  Future<void> removeMember({required List<int> groupId, required List<int> account}) async {
    await _maybeFail('removeMember');
    final g = groupInfo(groupId: groupId);
    _setGroup(groupId, _copy(g, members: g.members.where((m) => !listEquals(m.account, account)).toList()));
  }

  @override
  Future<void> setAdmin({required List<int> groupId, required List<int> account, required bool admin}) =>
      _maybeFail('setAdmin $admin');
  @override
  Future<void> setGroupSettings({
    required List<int> groupId,
    required bool adminsOnlyInfo,
    required bool adminsOnlyAdd,
  }) => _maybeFail('setGroupSettings');

  @override
  Future<void> leaveGroup({required List<int> groupId}) async {
    await _maybeFail('leaveGroup');
    final i = chatList.indexWhere((c) => listEquals(c.groupId, groupId));
    final c = chatList[i];
    chatList[i] = ChatSummary(
      groupId: c.groupId,
      peerAccount: c.peerAccount,
      request: false,
      peerVerified: false,
      isGroup: true,
      groupName: c.groupName,
      left: true,
      unread: 0,
    );
    events.add(const CoreEvent(kind: CoreEventKind.updated));
  }

  @override
  List<ReceiptView> messageReceipts({required List<int> messageId}) => const [];
  @override
  String? memberName({required List<int> account}) => names[base64Encode(account)];
  @override
  Future<void> setPushToken({required String pushToken}) async => calls.add('setPushToken');

  /// Simulates a message arriving from the peer.
  void receive(List<int> groupId, String text) {
    final m = msg(groupId, text, outgoing: false);
    (history[base64Encode(groupId)] ??= []).add(m);
    events.add(CoreEvent(kind: CoreEventKind.message, groupId: Uint8List.fromList(groupId), message: m));
  }

  static int _n = 0;
  static int sentAt = DateTime(2026, 10, 15, 9, 30).millisecondsSinceEpoch;
  static MessageView msg(
    List<int> groupId,
    String text, {
    required bool outgoing,
    Uint8List? replyTo,
    bool keyChange = false,
    GroupEventView? event,
    Uint8List? sender,
    AttachmentView? attachment,
  }) => MessageView(
    groupId: Uint8List.fromList(groupId),
    messageId: Uint8List.fromList([_n++]),
    senderAccount: sender ?? Uint8List(16),
    sentAt: sentAt,
    text: text,
    outgoing: outgoing,
    replyTo: replyTo,
    status: outgoing ? MessageStatus.sent : MessageStatus.delivered,
    edited: false,
    deleted: false,
    reactions: const [],
    keyChange: keyChange,
    event: event,
    mentions: const [],
    attachment: attachment,
  );

  static MessageView copy(
    MessageView m, {
    String? text,
    MessageStatus? status,
    bool? edited,
    bool? deleted,
    List<Reaction>? reactions,
  }) => MessageView(
    groupId: m.groupId,
    messageId: m.messageId,
    senderAccount: m.senderAccount,
    sentAt: m.sentAt,
    text: text ?? m.text,
    outgoing: m.outgoing,
    replyTo: m.replyTo,
    status: status ?? m.status,
    edited: edited ?? m.edited,
    deleted: deleted ?? m.deleted,
    reactions: reactions ?? m.reactions,
    keyChange: m.keyChange,
    event: m.event,
    mentions: m.mentions,
    attachment: m.attachment,
  );

  @override
  void dispose() {}
  @override
  bool get isDisposed => false;
}

Widget wrap(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

Future<void> tapText(WidgetTester t, String text) async {
  await t.tap(find.text(text));
  await t.pumpAndSettle();
}

Future<void> enter(WidgetTester t, String label, String value) async {
  await t.enterText(find.widgetWithText(TextField, label), value);
  await t.pump();
}

/// Drives welcome -> phone -> code.
/// Picks January of [year] as the birth date on the sign-up phone step.
Future<void> pickBirth(WidgetTester t, int year) async {
  await t.tap(find.widgetWithText(DropdownButtonFormField<int>, 'Birth month'));
  await t.pumpAndSettle();
  await t.tap(find.text('January').last);
  await t.pumpAndSettle();
  await t.tap(find.widgetWithText(DropdownButtonFormField<int>, 'Birth year'));
  await t.pumpAndSettle();
  await t.scrollUntilVisible(find.text('$year').hitTestable(), 200, scrollable: find.byType(Scrollable).last);
  await t.tap(find.text('$year').hitTestable().last);
  await t.pumpAndSettle();
}

Future<void> toCodeScreen(WidgetTester t, FakeCore core) async {
  await tapText(t, 'Continue');
  final send = find.widgetWithText(FilledButton, 'Send code');
  await enter(t, 'Your phone number', '+34 611 22 33 44');
  expect(t.widget<FilledButton>(send).onPressed, isNull, reason: 'age gate blocks sending');
  await pickBirth(t, DateTime.now().year - 30);
  await tapText(t, 'Send code');
  expect(core.calls.last, 'requestOtp +34611223344', reason: 'ID-01: E.164');
  expect(find.textContaining('Enter the 6-digit code'), findsOneWidget);
}

void main() {
  // Widget tests run as Android: Play Integrity answers with a stand-in token (ID-02).
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('siegel/attest'),
      (_) async => 'test-attestation',
    );
  });

  testWidgets('onboarding happy path: welcome, phone, code, profile, PIN', (t) async {
    final core = FakeCore();
    var done = false;
    await t.pumpWidget(wrap(Onboarding(core: core, onDone: () => done = true)));
    expect(find.textContaining('stored only on this phone'), findsOneWidget, reason: 'ID-14');

    await toCodeScreen(t, core);
    await enter(t, 'Code', '123456');
    await tapText(t, 'Verify');
    expect(core.calls.last, 'verify 123456 ');

    await enter(t, '@username', 'ana.b');
    await enter(t, 'Display name', 'Ana');
    await tapText(t, 'Save');
    expect((core.user, core.name), ('ana.b', 'Ana'));

    await enter(t, '4-digit PIN', '1234');
    await tapText(t, 'Set PIN');
    expect(core.calls.last, 'setRegistrationLock 1234');
    expect(done, isTrue);
  });

  testWidgets('wrong code shows an error; Registration Lock asks for the PIN (ID-10)', (t) async {
    final core = FakeCore();
    await t.pumpWidget(wrap(Onboarding(core: core, onDone: () {})));
    await toCodeScreen(t, core);
    await enter(t, 'Code', '000000');

    core.failNext['verify 000000 '] = 'otp_invalid';
    await tapText(t, 'Verify');
    expect(find.text('Wrong or expired code.'), findsOneWidget);

    core.failNext['verify 000000 '] = 'registration_lock_required';
    await tapText(t, 'Verify');
    expect(find.text('This number is protected by a PIN. Enter it to continue.'), findsOneWidget);
    await enter(t, '4-digit PIN', '4321');
    await tapText(t, 'Verify');
    expect(core.calls.last, 'verify 000000 4321');
    expect(find.text('Your profile'), findsOneWidget);
  });

  testWidgets('skipping the PIN needs confirming the takeover warning', (t) async {
    final core = FakeCore()..registered = true; // resumes at the profile step
    var done = false;
    await t.pumpWidget(wrap(Onboarding(core: core, onDone: () => done = true)));
    core.failNext['setUsername taken'] = 'username_taken';
    await enter(t, '@username', 'taken');
    await enter(t, 'Display name', 'Ana');
    await tapText(t, 'Save');
    expect(find.text('That username is taken.'), findsOneWidget);
    await enter(t, '@username', 'free');
    await tapText(t, 'Save');

    await tapText(t, 'Skip');
    expect(find.text('Skip the PIN?'), findsOneWidget);
    await tapText(t, 'Cancel');
    expect(done, isFalse);
    await tapText(t, 'Skip');
    await tapText(t, 'Skip anyway');
    expect(done, isTrue);
  });

  testWidgets('settings show the account and deletes it after confirmation (ID-16)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana.b'
      ..name = 'Ana';
    var deleted = false;
    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async => deleted = true)));
    expect(find.text('You are @ana.b'), findsOneWidget);
    expect(find.textContaining('stored only on this phone'), findsOneWidget, reason: 'ID-14 in Settings');
    await t.scrollUntilVisible(find.text('App lock'), 200);
    expect(find.text('App lock'), findsOneWidget);

    await t.scrollUntilVisible(find.text('Delete account'), 200);
    await t.ensureVisible(find.text('Delete account'));
    await t.pumpAndSettle();
    await tapText(t, 'Delete account');
    await tapText(t, 'Cancel');
    expect(core.calls, isNot(contains('deleteAccount')));
    await tapText(t, 'Delete account');
    await tapText(t, 'Delete');
    expect(core.calls.last, 'deleteAccount');
    expect(deleted, isTrue);
  });

  testWidgets('app lock: locked on cold start when enabled, open when off (ID-15)', (t) async {
    final locked = FakeCore()..settings['app_lock'] = '60';
    await t.pumpWidget(wrap(AppLock(core: locked, child: const Text('secret chats'))));
    await t.pumpAndSettle();
    expect(find.text('Siegel is locked'), findsOneWidget);
    await tapText(t, 'Unlock'); // no device auth in tests: must stay locked
    expect(find.text('Siegel is locked'), findsOneWidget);

    await t.pumpWidget(wrap(AppLock(key: UniqueKey(), core: FakeCore(), child: const Text('secret chats'))));
    await t.pumpAndSettle();
    expect(find.text('Siegel is locked'), findsNothing);
    expect(find.text('secret chats'), findsOneWidget);
  });

  testWidgets('chat list, new chat by @username, send and receive (M2)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana';
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    await t.pumpWidget(wrap(ChatListScreen(core: core, service: service, settings: (_) => const Text('settings'))));
    expect(find.textContaining('No chats yet'), findsOneWidget);

    await tapText(t, 'New chat');
    core.failNext['startChat nobody'] = 'username_not_found';
    await enter(t, '@username', '@Nobody');
    await tapText(t, 'Start chat');
    expect(find.text('No one has that username.'), findsOneWidget);

    await enter(t, '@username', 'bob');
    await tapText(t, 'Start chat');
    expect(find.text('@bob'), findsOneWidget, reason: 'chat screen titled with the peer');

    await t.enterText(find.widgetWithText(TextField, 'Message'), 'hello bob');

    await t.pump();
    await t.tap(find.byTooltip('Send'));
    await t.pumpAndSettle();
    expect(find.text('hello bob'), findsOneWidget);
    expect(find.text('09:30'), findsOneWidget, reason: 'sender clock shown');

    core.receive(core.chatList.first.groupId, 'hi ana');
    await t.pumpAndSettle();
    expect(find.text('hi ana'), findsOneWidget, reason: 'stream event refreshes the open chat');

    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.text('@bob'), findsOneWidget);
    expect(find.text('hi ana'), findsOneWidget, reason: 'list shows the last message');
  });

  testWidgets('a deregistered event hands control back (ID-12)', (t) async {
    final core = FakeCore();
    var out = false;
    final service = ChatService(core, onDeregistered: () => out = true)..start();
    addTearDown(service.dispose);
    core.events.add(const CoreEvent(kind: CoreEventKind.deregistered));
    await t.pump();
    expect(out, isTrue);
  });

  testWidgets('message requests: listed apart, accept to reply, block from the chat (MSG-15, MSG-16)', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    await t.pumpWidget(wrap(ChatListScreen(core: core, service: service, settings: (_) => const SizedBox())));
    core.incomingRequest('Zoe');
    await t.pumpAndSettle();
    expect(find.text('1 message request'), findsOneWidget);
    expect(find.text('Zoe'), findsNothing, reason: 'requests stay out of the main list');

    await tapText(t, '1 message request');
    await tapText(t, 'Zoe');
    expect(find.textContaining('Zoe wants to chat with you'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Message'), findsNothing, reason: 'no replying before accepting');

    await tapText(t, 'Accept');
    expect(core.calls, contains('accept'));
    expect(find.widgetWithText(TextField, 'Message'), findsOneWidget);

    await t.tap(find.byType(PopupMenuButton<void>));
    await t.pumpAndSettle();
    await tapText(t, 'Block');
    expect(find.text('Block Zoe?'), findsOneWidget);
    await t.tap(find.widgetWithText(TextButton, 'Block'));
    await t.pumpAndSettle();
    expect(core.chatList, isEmpty);
  });

  testWidgets('deleting a request removes it', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    core.incomingRequest('Spam');
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: core.chatList.first.groupId)));
    await t.pumpAndSettle();
    await tapText(t, 'Delete');
    expect(core.calls, contains('deleteChat'));
    expect(core.chatList, isEmpty);
  });

  testWidgets('message actions: reply, react, edit, delete, retry, typing (MSG-04, 07-09, 11-14)', (t) async {
    FakeCore.sentAt = DateTime.now().millisecondsSinceEpoch; // inside the edit and delete windows
    addTearDown(() => FakeCore.sentAt = DateTime(2026, 10, 15, 9, 30).millisecondsSinceEpoch);
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    core.receive(id, 'lunch?');
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();
    expect(core.calls, contains('markRead'), reason: 'MSG-13: opening the chat reads it');

    await t.longPress(find.text('lunch?'));
    await t.pumpAndSettle();
    await tapText(t, 'Reply');
    await t.enterText(find.widgetWithText(TextField, 'Message'), 'yes');
    await t.pump();
    expect(core.calls, contains('sendTyping'), reason: 'MSG-14');
    await t.tap(find.byTooltip('Send'));
    await t.pumpAndSettle();
    expect(core.history.values.first.last.replyTo, isNotNull, reason: 'MSG-07');
    expect(find.text('lunch?'), findsNWidgets(2), reason: 'quoted above the reply');

    await t.longPress(find.text('lunch?').first);
    await t.pumpAndSettle();
    await tapText(t, '👍');
    expect(find.text('👍'), findsOneWidget, reason: 'MSG-08');

    await t.longPress(find.text('yes'));
    await t.pumpAndSettle();
    await tapText(t, 'Edit');
    await t.enterText(find.widgetWithText(TextField, 'Message'), 'yes!');
    await t.pump();
    await t.tap(find.byTooltip('Send'));
    await t.pumpAndSettle();
    expect(find.text('yes!'), findsOneWidget);
    await tapText(t, 'edited ');
    expect(find.text('yes'), findsOneWidget, reason: 'MSG-09: prior version viewable');
    await tapText(t, 'Close');

    await t.longPress(find.text('yes!'));
    await t.pumpAndSettle();
    await tapText(t, 'Delete for everyone');
    expect(find.textContaining('modified app could still keep a copy'), findsOneWidget, reason: 'MSG-11');
    await tapText(t, 'Delete');
    expect(find.text('This message was deleted'), findsOneWidget);

    core.failNext['sendText again'] = 'network';
    await t.enterText(find.widgetWithText(TextField, 'Message'), 'again');
    await t.pump();
    await t.tap(find.byTooltip('Send'));
    await t.pumpAndSettle();
    expect(find.text('Not sent. Tap to retry.'), findsOneWidget, reason: 'MSG-04');
    await t.tap(find.text('again'));
    await t.pumpAndSettle();
    expect(find.text('Not sent. Tap to retry.'), findsNothing);

    core.events.add(CoreEvent(kind: CoreEventKind.typing, groupId: id));
    await t.pump(); // stream event
    await t.pump(); // rebuild
    expect(find.text('typing…'), findsOneWidget);
    await t.pump(const Duration(seconds: 6));
    expect(find.text('typing…'), findsNothing);
  });

  testWidgets('swipe a bubble right to reply, own messages too; short drags do nothing (MSG-18)', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    core.receive(id, 'lunch?');
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();

    await t.drag(find.text('lunch?'), const Offset(30, 0));
    await t.pumpAndSettle();
    expect(find.text('lunch?'), findsOneWidget, reason: 'below the threshold: no reply');
    await t.drag(find.text('lunch?'), const Offset(120, 0));
    await t.pumpAndSettle();
    expect(find.text('lunch?'), findsNWidgets(2), reason: 'quoted above the composer');

    await t.enterText(find.widgetWithText(TextField, 'Message'), 'yes');

    await t.pump();
    await t.tap(find.byTooltip('Send'));
    await t.pumpAndSettle();
    await t.drag(find.text('yes'), const Offset(120, 0));
    await t.pumpAndSettle();
    expect(find.text('yes'), findsNWidgets(2), reason: 'own messages swipe too');
  });

  testWidgets('voice notes: shown with a waveform, previewed, quoted; the mic replaces Send (MED-09)', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    final voice = FakeCore.msg(
      id,
      '',
      outgoing: false,
      attachment: AttachmentView(
        mimeType: 'audio/mp4',
        fileName: '',
        size: BigInt.from(1000),
        durationMs: 4200,
        voiceNote: true,
        waveform: Uint8List.fromList([10, 200, 90]),
        width: 0,
        height: 0,
        thumbnail: Uint8List(0),
        sticker: false,
      ),
    );
    (core.history[base64Encode(id)] ??= []).add(voice);
    await t.pumpWidget(wrap(ChatListScreen(core: core, service: service, settings: (_) => const SizedBox())));
    await t.pumpAndSettle();
    expect(find.text('🎤 Voice message (0:04)'), findsOneWidget, reason: 'chat list preview');

    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.text('0:04'), findsOneWidget);
    expect(find.byTooltip('Record a voice message'), findsOneWidget, reason: 'empty box: the mic');
    await t.enterText(find.widgetWithText(TextField, 'Message'), 'hi');
    await t.pump();
    expect(find.byTooltip('Record a voice message'), findsNothing, reason: 'typing: Send');

    await t.longPress(find.byType(AudioMessage));
    await t.pumpAndSettle();
    expect(find.text('Copy'), findsNothing, reason: 'nothing to copy');
    await tapText(t, 'Reply');
    expect(find.text('🎤 Voice message (0:04)'), findsOneWidget, reason: 'quoted above the composer');
  });

  test('notifications use the phone language, English when the app lacks it (MSG-17, Q3)', () {
    expect(notificationStrings(const Locale('de', 'AT')).voiceMessage, 'Sprachnachricht');
    expect(notificationStrings(const Locale('es', 'ES')).voiceMessage, 'Mensaje de voz');
    expect(notificationStrings(const Locale('pt', 'BR')).voiceMessage, 'Mensagem de voz');
    expect(notificationStrings(const Locale('fr')).voiceMessage, 'Voice message');
    expect(notificationStrings(const Locale('en', 'GB')).voiceMessage, 'Voice message');
  });

  testWidgets('profile photos: contacts show theirs; ours can be removed in Settings (MED-15)', (t) async {
    // A 1x1 PNG.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    final core = FakeCore()
      ..registered = true
      ..mine = png;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    final peer = core.chats().firstWhere((c) => listEquals(c.groupId, id)).peerAccount;
    core.avatars[base64Encode(peer)] = png;
    await t.pumpWidget(wrap(ChatListScreen(core: core, service: service, settings: (_) => const SizedBox())));
    await t.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is CircleAvatar && w.backgroundImage != null),
      findsOneWidget,
      reason: "bob's photo in the chat list",
    );

    // A group's photo shows in the list too (MED-15).
    final group = await core.createGroup(name: 'Climbers', usernames: ['bob']);
    core.groupAvatars[base64Encode(group)] = png;
    service.refresh();
    await t.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is CircleAvatar && w.backgroundImage != null), findsNWidgets(2));

    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async {})));
    await t.pumpAndSettle();
    await t.tap(find.byType(AvatarEditor));
    await t.pumpAndSettle();
    await tapText(t, 'Remove photo');
    expect(core.calls, contains('removeAvatar'));
    expect(core.myAvatar(), isNull);
  });

  testWidgets('unread chats show a count and bold text until opened', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    core.receive(id, 'one');
    core.receive(id, 'two');
    await t.pumpWidget(wrap(ChatListScreen(core: core, service: service, settings: (_) => const SizedBox())));
    await t.pumpAndSettle();
    expect(find.widgetWithText(Badge, '2'), findsOneWidget);
    expect(t.widget<Text>(find.text('two')).style?.fontWeight, FontWeight.bold);

    await t.tap(find.text('two'));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byType(Badge), findsNothing, reason: 'read once opened');
  });

  test('read ticks stand out from our bubble and from delivered ticks, in every theme (MSG-04)', () {
    for (final th in siegelThemes) {
      for (final b in Brightness.values) {
        final theme = th.data(b);
        final read = readTickColor(theme);
        final g = theme.extension<SiegelGradient>();
        // Ticks sit bottom right: check the gradient from its middle to its end.
        final backgrounds = g == null
            ? [theme.colorScheme.primaryContainer]
            : [Color.lerp(g.colors.first, g.colors.last, 0.5)!, g.colors.last];
        for (final bg in backgrounds) {
          expect(contrast(read, bg), greaterThanOrEqualTo(3), reason: '${th.id} ${b.name} on $bg');
        }
        expect(HSLColor.fromColor(read).saturation, greaterThanOrEqualTo(0.35), reason: '${th.id}: not grey');
        expect(read, isNot(g?.on ?? theme.colorScheme.onSurfaceVariant), reason: th.id);
        if (g == null) {
          final d = (HSLColor.fromColor(read).hue - HSLColor.fromColor(theme.colorScheme.primaryContainer).hue).abs();
          expect(math.min(d, 360 - d), greaterThanOrEqualTo(60), reason: '${th.id} ${b.name}: a different hue');
        }
      }
    }
  });

  test('gradient themes: Drache, Krampus, Lindwurm, Edelweiß and Krähe; Edelweiß stays light', () {
    final gradient = [
      for (final th in siegelThemes)
        if (th.gradient != null) th.id,
    ];
    expect(gradient, unorderedEquals(['drache', 'krampus', 'lindwurm', 'edelweiss', 'kraehe']));
    final edelweiss = themeById('edelweiss');
    expect(edelweiss.data(Brightness.dark).brightness, Brightness.light);
    expect(edelweiss.data(Brightness.dark).extension<SiegelGradient>(), isNotNull);
    expect(themeById('siegel').data(Brightness.light).extension<SiegelGradient>(), isNull);
  });

  testWidgets('photos and files show in bubbles; any message can be forwarded (MED-07, MED-10, MED-14)', (t) async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    final other = await core.startChat(username: 'carol');
    AttachmentView att(String mime, String name) => AttachmentView(
      mimeType: mime,
      fileName: name,
      size: BigInt.from(2 << 20),
      durationMs: 0,
      voiceNote: false,
      waveform: Uint8List(0),
      width: 4,
      height: 3,
      thumbnail: png,
      sticker: false,
    );
    (core.history[base64Encode(id)] ??= []).addAll([
      FakeCore.msg(id, '', outgoing: false, attachment: att('image/jpeg', '')),
      FakeCore.msg(id, '', outgoing: false, attachment: att('application/pdf', 'plan.pdf')),
    ]);
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();
    expect(find.byType(ImageMessage), findsOneWidget);
    expect(find.text('plan.pdf'), findsOneWidget);
    expect(find.text('2.0 MB'), findsOneWidget);

    await t.longPress(find.text('plan.pdf'));
    await t.pumpAndSettle();
    expect(find.text('Save to device'), findsOneWidget);
    await tapText(t, 'Forward');
    await tapText(t, '@carol');
    expect(core.forwards, [base64Encode(other)]);
    expect(core.history[base64Encode(other)]!.last.attachment?.fileName, 'plan.pdf');
  });

  test('auto-download defaults: photos on Wi-Fi and mobile data, video and files manual (MED-12)', () {
    final core = FakeCore();
    expect(autoDownloadKinds(core, metered: false), {'image'});
    expect(autoDownloadKinds(core, metered: true), {'image'});
    setAutoDownloadKinds(core, metered: true, kinds: {});
    expect(autoDownloadKinds(core, metered: true), isEmpty);
  });

  testWidgets('read receipts and typing toggles are reciprocal settings (MSG-13, MSG-14)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana';
    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async {})));
    await t.scrollUntilVisible(find.text('Read receipts'), 100);
    await t.ensureVisible(find.text('Read receipts'));
    await t.pumpAndSettle();
    await tapText(t, 'Read receipts');
    expect(core.settings['read_receipts'], 'off');
    await t.scrollUntilVisible(find.text('Typing indicators'), 100);
    await t.ensureVisible(find.text('Typing indicators'));
    await t.pumpAndSettle();
    await tapText(t, 'Typing indicators');
    expect(core.settings['typing_indicators'], 'off');
  });

  testWidgets('key change notice opens the safety number; verified shows a badge (CRY-12, CRY-13)', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    (core.history[base64Encode(id)] ??= []).add(FakeCore.msg(id, '', outgoing: false, keyChange: true));
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();
    expect(find.textContaining("@bob's safety number changed"), findsOneWidget);
    expect(find.byIcon(Icons.verified_user), findsNothing);

    await t.tap(find.textContaining('safety number changed'));
    await t.pumpAndSettle();
    expect(find.text('01234  56789  ' * 5 + '01234  56789'), findsOneWidget, reason: '60 digits in groups of 5');
    expect(find.text('Scan their code'), findsOneWidget);

    core.verifySafetyNumber(groupId: id, scanned: '0123456789' * 6); // what a successful scan does
    await t.pageBack();
    await t.pumpAndSettle();
    core.events.add(const CoreEvent(kind: CoreEventKind.updated));
    await t.pump();
    await t.pump();
    expect(find.byIcon(Icons.verified_user), findsOneWidget);
  });

  testWidgets('blocked people are listed in Settings and can be unblocked (MSG-16)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana';
    core.incomingRequest('Zoe');
    await core.block(account: core.chatList.first.peerAccount);
    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async {})));
    await t.scrollUntilVisible(find.text('Blocked people'), 100);
    await t.ensureVisible(find.text('Blocked people'));
    await t.pumpAndSettle();
    await tapText(t, 'Blocked people');
    expect(find.text('Zoe'), findsOneWidget);
    await tapText(t, 'Unblock');
    expect(core.calls.last, 'unblock');
    expect(find.text("You haven't blocked anyone."), findsOneWidget);
  });

  testWidgets('a push wake-up reconnects the stream; new messages reach onMessage (MSG-17)', (t) async {
    final core = FakeCore()..registered = true;
    final got = <String>[];
    final service = ChatService(core, onDeregistered: () {}, onMessage: (m) => got.add(m.text))..start();
    addTearDown(service.dispose);
    await t.pump();
    expect(core.connects, 1);
    service.wake();
    await t.pump();
    await t.pump();
    expect(core.connects, 2, reason: 'reconnects at once, no backoff');
    core.receive(Uint8List.fromList([1]), 'hello');
    await t.pump();
    expect(got, ['hello']);
  });

  testWidgets('themes: pick one in Settings, saved and applied (Lions, Dragons, Krampus...)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana';
    await t.pumpWidget(
      ValueListenableBuilder(
        valueListenable: themeChoice,
        builder: (_, th, _) => MaterialApp(
          theme: th.data(Brightness.light),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsScreen(core: core, onDeleted: () async {}),
        ),
      ),
    );
    addTearDown(() => themeChoice.value = siegelThemes.first);
    await tapText(t, 'Theme');
    await t.scrollUntilVisible(find.text('Krampus'), 100);
    await tapText(t, 'Krampus');
    expect(core.settings['theme'], 'krampus');
    final scheme = Theme.of(t.element(find.text('Krampus'))).colorScheme;
    expect(scheme, siegelThemes.firstWhere((x) => x.id == 'krampus').data(Brightness.light).colorScheme);
    expect(themeById('nope').id, 'siegel', reason: 'unknown stored id falls back to the default');
  });

  testWidgets('contact profile: safety number, mute, block; message info (section 11)', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    await core.sendText(groupId: id, text: 'hi bob', mentions: const []);
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();

    await t.longPress(find.text('hi bob'));
    await t.pumpAndSettle();
    await tapText(t, 'Message info');
    expect(find.text('@bob: Sent'), findsOneWidget);
    await tapText(t, 'Close');

    await tapText(t, '@bob'); // the title opens the profile
    expect(find.text('Safety number'), findsOneWidget);
    await tapText(t, 'Mute notifications');
    await tapText(t, 'Always'); // GRP-14: 8 hours, 1 week or always
    expect(core.settings['mute.${base64Encode(id)}'], 'always');
    await tapText(t, 'Block');
    expect(find.text('Block @bob?'), findsOneWidget);
  });

  testWidgets('groups: create, sender names, system lines, rename, leave (M3)', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    await t.pumpWidget(wrap(ChatListScreen(core: core, service: service, settings: (_) => const SizedBox())));
    await tapText(t, 'New chat');
    await tapText(t, 'New group');
    await enter(t, 'Group name', 'Hikers');
    await enter(t, 'Add people', '@bob');
    await t.tap(find.byTooltip('Add'));
    await t.pump();
    expect(find.text('@bob'), findsOneWidget, reason: 'chip for the added person');
    await tapText(t, 'Create');
    expect(core.calls, contains('createGroup Hikers'));
    expect(find.text('Hikers'), findsOneWidget, reason: 'the group chat opens');
    expect(find.text('You created the group'), findsOneWidget, reason: 'GRP-12 system line');

    final id = core.chatList.last.groupId;
    final bob = core.groupInfo(groupId: id).members[1].account;
    (core.history[base64Encode(id)] ??= []).add(FakeCore.msg(id, 'hi all', outgoing: false, sender: bob));
    core.events.add(CoreEvent(kind: CoreEventKind.updated, groupId: id));
    await t.pumpAndSettle();
    expect(find.text('@bob'), findsOneWidget, reason: 'sender name above group messages');

    await tapText(t, 'Hikers'); // group info
    expect(find.text('2 members'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
    await tapText(t, 'Rename');
    await t.enterText(find.widgetWithText(TextField, 'Group name'), 'Hikers 2026');
    await tapText(t, 'Save');
    expect(core.calls, contains('renameGroup Hikers 2026'));

    await t.scrollUntilVisible(find.text('Leave group'), 100);
    await t.ensureVisible(find.text('Leave group'));
    await t.pumpAndSettle();
    await tapText(t, 'Leave group');
    await t.tap(find.widgetWithText(TextButton, 'Leave group'));
    await t.pumpAndSettle();
    expect(core.calls, contains('leaveGroup'));
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.text("You're no longer in this group."), findsOneWidget, reason: 'read-only after leaving');
    expect(find.widgetWithText(TextField, 'Message'), findsNothing);
  });

  testWidgets('re-registering keeps the @username and an existing PIN (ID-09)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana.b'
      ..lockSet = true;
    var done = false;
    await t.pumpWidget(wrap(Onboarding(core: core, onDone: () => done = true)));
    expect(find.text('You are @ana.b'), findsOneWidget);
    expect(find.widgetWithText(TextField, '@username'), findsNothing, reason: 'no new username');
    await enter(t, 'Display name', 'Ana');
    await tapText(t, 'Save');
    expect(core.calls, isNot(contains(startsWith('setUsername'))));
    expect(done, isTrue, reason: 'no PIN offer when the account has one');
  });

  testWidgets('resend code waits for the countdown the server sets (ID-04)', (t) async {
    final core = FakeCore();
    await t.pumpWidget(wrap(Onboarding(core: core, onDone: () {})));
    await toCodeScreen(t, core);
    await t.pump(const Duration(seconds: 1));
    expect(find.textContaining('Resend code in 0:'), findsOneWidget);
    expect(t.widget<TextButton>(find.widgetWithText(TextButton, 'Resend code in 0:29')).onPressed, isNull);
    await t.pump(const Duration(seconds: 31));
    await tapText(t, 'Resend code');
    expect(core.calls.where((c) => c.startsWith('requestOtp')).length, 2);
    expect(find.text('Code sent again.'), findsOneWidget);
    await t.pump(const Duration(seconds: 31)); // let the countdown timer finish
  });

  testWidgets('@mentions: typing @ suggests members; the mention goes with the message (GRP-15)', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.createGroup(name: 'Hikers', usernames: ['bob', 'carol']);
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Message'), 'hey @bo');
    await t.pump();
    expect(find.text('@bob'), findsOneWidget, reason: 'suggestion');
    expect(find.text('@carol'), findsNothing);
    await t.tap(find.text('@bob'));
    await t.pump();
    expect(find.text('hey @bob '), findsOneWidget);
    await t.tap(find.byTooltip('Send'));
    await t.pumpAndSettle();
    expect(core.sentMentions, [core.groupInfo(groupId: id).members[1].account]);
  });

  testWidgets('my contact link: on by default, shown as a code, can be turned off (DISC-08)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana';
    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async {})));
    expect(find.text('My link'), findsOneWidget);
    await tapText(t, 'Show code');
    expect(find.textContaining('without a message request'), findsOneWidget);
    await tapText(t, 'Copy');
    await tapText(t, 'My link');
    expect(core.link, isNull, reason: 'turned off');
    expect(find.text('Show code'), findsNothing);
  });

  testWidgets('find me by number asks for the number once; finding contacts (DISC-03..07)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana';
    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async {})));
    await t.pumpAndSettle();
    await tapText(t, 'Let people who have my number find me');
    await t.enterText(find.byType(TextField).last, '+34 600 999 888');
    await tapText(t, 'Save');
    expect((core.phone, core.discoverableOn), ('+34600999888', true));

    const channel = appChannel;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'contacts') return null;
      return [
        ['Bea', '600 111 222'], // no country code: ours (Spain)
        ['Bea', '+34 600-111-222'],
        ['Carl', '+49 1512 3456789'],
        ['Junk', '12'],
      ];
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final service = ChatService(core, onDeregistered: () {});
    addTearDown(service.dispose);
    await t.pumpWidget(wrap(FindContactsScreen(core: core, service: service)));
    await tapText(t, 'Check my contacts');
    expect(core.searched, unorderedEquals(['+34600111222', '+4915123456789']));
    expect(find.text('Bea'), findsOneWidget);
    expect(find.text('@bea'), findsOneWidget);
    expect(find.text('Carl'), findsNothing);
    await tapText(t, 'Start chat');
    expect(core.calls, contains('startChatByNumber bea'), reason: 'the discovery proof finds under-18s too');
  });

  testWidgets('change number: new number, code and PIN; a numberless account is warned', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana'
      ..lockSet = true
      ..phone = ''
      ..removed = true;
    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async {})));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.textContaining('No phone number'), 100);
    await tapText(t, 'Change number');
    await t.enterText(find.byType(TextField).first, '+34 611 222 333');
    await tapText(t, 'Send code');
    await t.enterText(find.widgetWithText(TextField, 'Code'), '123456');
    await t.enterText(find.widgetWithText(TextField, '4-digit PIN'), '1234');
    await t.tap(find.widgetWithText(FilledButton, 'Change number'));
    await t.pumpAndSettle();
    expect(core.calls, contains('changeNumber +34611222333 123456 1234'));
    expect(core.removed, isFalse);
    expect(find.text('Your number is now +34611222333.'), findsOneWidget);
  });

  testWidgets('what Siegel knows about me shows the server data in plain words (RM-01)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana'
      ..lockSet = true;
    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async {})));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('What Siegel knows about me'), 100);
    await tapText(t, 'What Siegel knows about me');
    expect(find.textContaining('0123456789abcdef…'), findsOneWidget); // the number only as a hash
    expect(find.text('@ana, since Oct 2, 2026'), findsOneWidget);
    expect(find.text('@old_ana'), findsOneWidget);
    await t.scrollUntilVisible(find.text('12. Only how many, never which ones.'), 100);
    await t.scrollUntilVisible(find.text('This phone'), 100);
    expect(find.textContaining('Encrypted messages waiting: 3'), findsOneWidget);
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await t.scrollUntilVisible(find.text('Copy as JSON'), 100);
    await tapText(t, 'Copy as JSON');
    final json = jsonDecode(copied!) as Map<String, dynamic>;
    expect((json['phone_number_hmac'], json['devices'][0]['queued_messages']), ('0123456789abcdef0123', 3));
  });

  testWidgets('chat background: the theme pattern by default, plain, or my photo', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana';
    final service = ChatService(core, onDeregistered: () {});
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    Future<void> openChat() async {
      await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
      await t.pumpAndSettle();
    }

    await openChat();
    bool seal(Widget w) =>
        w is DecoratedBox && (w.decoration as BoxDecoration?)?.image?.image == const AssetImage('assets/seal_tile.png');
    expect(find.byWidgetPredicate(seal), findsOneWidget, reason: 'the Siegel theme: our seal over green');
    themeChoice.value = themeById('kraehe');
    addTearDown(() => themeChoice.value = siegelThemes.first);
    await openChat();
    expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is ThemePattern), findsOneWidget);

    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async {})));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Chat background'), 100);
    expect(find.text("The theme's pattern"), findsOneWidget);
    await t.ensureVisible(find.text('Chat background'));
    await t.pumpAndSettle();
    await tapText(t, 'Chat background');
    await tapText(t, 'Plain');
    expect(core.settings['chat_background'], 'plain');
    await openChat();
    expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is ThemePattern), findsNothing);

    core.settings
      ..['chat_background'] = 'photo'
      ..['chat_background_photo'] =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    await openChat();
    expect(find.descendant(of: find.byType(ChatBackground), matching: find.byType(Image)), findsOneWidget);
  });

  testWidgets('archive and delete chats from the list; archived chats stay silent', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {});
    addTearDown(service.dispose);
    final bob = await core.startChat(username: 'bob');
    core.receive(bob, 'hi');
    final group = await core.createGroup(name: 'Hikers', usernames: ['carol']);
    core.receive(group, 'stove?');
    await t.pumpWidget(wrap(ChatListScreen(core: core, service: service, settings: (_) => const SizedBox())));
    await t.pumpAndSettle();

    await t.longPress(find.text('@bob'));
    await t.pumpAndSettle();
    await tapText(t, 'Archive');
    expect(core.calls, contains('share archive=1'), reason: 'M8: our other devices archive it too');
    expect(find.text('@bob'), findsNothing);
    expect(find.text('Archived'), findsOneWidget);
    expect(find.text('1'), findsWidgets, reason: 'archived chats with unread messages');
    await tapText(t, 'Archived');
    expect(find.text('@bob'), findsOneWidget);
    await t.longPress(find.text('@bob'));
    await t.pumpAndSettle();
    await tapText(t, 'Unarchive');
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.text('@bob'), findsOneWidget);
    expect(find.text('Archived'), findsNothing);

    // Delete a 1:1 chat: gone until the next message.
    await t.longPress(find.text('@bob'));
    await t.pumpAndSettle();
    await tapText(t, 'Delete chat');
    expect(find.text('Delete the chat with @bob?'), findsOneWidget);
    await tapText(t, 'Delete');
    expect(core.calls, containsAll(['clearChat', 'share hidden=1']));
    expect(find.text('@bob'), findsNothing);
    core.receive(bob, 'back again');
    service.refresh();
    await t.pumpAndSettle();
    expect(find.text('@bob'), findsOneWidget);

    // Delete a group: leave and delete in one step.
    await t.longPress(find.text('Hikers'));
    await t.pumpAndSettle();
    await tapText(t, 'Delete chat');
    expect(find.text('Leave Hikers and delete the chat?'), findsOneWidget);
    await tapText(t, 'Delete');
    expect(core.calls, containsAllInOrder(['leaveGroup', 'deleteChat']));
    expect(find.text('Hikers'), findsNothing);
  });

  test('group name colours: 20, readable on incoming bubbles in every theme, stable per person', () {
    expect(memberColorCount, inInclusiveRange(16, 24));
    for (final th in siegelThemes) {
      for (final b in Brightness.values) {
        final bubble = th.data(b).colorScheme.surfaceContainerHighest;
        final colours = {for (var i = 0; i < memberColorCount; i++) memberColorAt(i, bubble)};
        expect(colours.length, memberColorCount, reason: '${th.id} ${b.name}: all distinct');
        for (final c in colours) {
          expect(contrast(c, bubble), greaterThanOrEqualTo(4.5), reason: '${th.id} ${b.name} $c');
          expect(HSLColor.fromColor(c).saturation, greaterThan(0.5), reason: 'colourful, not grey');
        }
      }
    }
    final bubble = siegelThemes.first.data(Brightness.light).colorScheme.surfaceContainerHighest;
    expect(memberColor([1, 2, 3], bubble), memberColor([1, 2, 3], bubble));
  });

  testWidgets('react with any emoji: + opens the full picker; a custom one shows in the quick row', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    core.receive(id, 'summit!');
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();
    await t.longPress(find.text('summit!'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('More reactions'));
    await t.pumpAndSettle();
    expect(find.byType(EmojiPicker), findsOneWidget);
    await t.tap(find.text('😀').first);
    await t.pumpAndSettle();
    expect(find.byType(EmojiPicker), findsNothing);
    expect(find.text('😀'), findsOneWidget, reason: 'shown under the bubble');

    await t.longPress(find.text('summit!'));
    await t.pumpAndSettle();
    final quick = find.ancestor(of: find.text('😀'), matching: find.byType(IconButton));
    expect(t.widget<IconButton>(quick.first).isSelected, isTrue, reason: 'ours, in the last quick slot');
  });

  testWidgets('stickers: send one from the Siegel pack; a sticker shows without a bubble; save one', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    final theirs = FakeCore.msg(
      id,
      '',
      outgoing: false,
      attachment: AttachmentView(
        mimeType: 'image/webp',
        fileName: '',
        size: BigInt.from(png.length),
        durationMs: 0,
        voiceNote: false,
        waveform: Uint8List(0),
        width: 512,
        height: 512,
        thumbnail: Uint8List(0),
        sticker: true,
      ),
    );
    core.blobs[base64Encode(theirs.messageId)] = png;
    (core.history[base64Encode(id)] ??= []).add(theirs);
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();
    expect(find.byType(StickerMessage), findsOneWidget);
    expect(
      messageText(lookupAppLocalizations(const Locale('en')), theirs),
      '💟 Sticker',
      reason: 'chat list, notifications',
    );

    await t.longPress(find.byType(StickerMessage));
    await t.pumpAndSettle();
    expect(find.text('Save to device'), findsNothing, reason: 'stickers are saved to the collection instead');
    await tapText(t, 'Add to my stickers');
    expect(core.stickers().single.pack, '');
    expect(find.text('Added to your stickers.'), findsOneWidget);
    await t.pump(const Duration(seconds: 5)); // the snackbar covers the composer
    await t.pumpAndSettle();

    // With stickers of their own, Mine opens first; what they send most goes on top.
    await t.tap(find.byTooltip('Stickers'));
    await t.pumpAndSettle();
    expect(find.text('Most used'), findsNothing);
    Finder inSheet(Finder f) => find.descendant(of: find.byType(BottomSheet), matching: f);
    await t.tap(inSheet(find.bySemanticsLabel('Sticker')).first);
    await t.pumpAndSettle();
    expect(core.calls, contains('sendSticker'));
    await t.pump(const Duration(seconds: 5)); // the snackbar covers the composer
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Stickers'));
    await t.pumpAndSettle();
    expect(find.text('Most used'), findsOneWidget);
    expect(inSheet(find.bySemanticsLabel('Sticker')), findsNWidgets(2), reason: 'in Most used and in Mine');
    Navigator.of(t.element(find.text('Most used'))).pop();
    await t.pumpAndSettle();

    core.calls.clear();
    await t.tap(find.byTooltip('Stickers'));
    await t.pumpAndSettle();
    await t.tap(find.text('Siegel'));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      await t.tap(find.bySemanticsLabel('seal'));
      await Future<void>.delayed(const Duration(milliseconds: 500)); // drawn to a PNG
    });
    await t.pumpAndSettle();
    expect(core.calls, contains('sendSticker'));
  });

  test('a .wastickers pack imports its WebP stickers under its title', () {
    final core = FakeCore();
    final zip = ZipEncoder().encodeBytes(
      Archive()
        ..add(ArchiveFile.bytes('title.txt', utf8.encode('Alpine cats')))
        ..add(ArchiveFile.bytes('tray.png', Uint8List.fromList([1, 2])))
        ..add(ArchiveFile.bytes('1.webp', Uint8List.fromList([1, 1, 1])))
        ..add(ArchiveFile.bytes('2.webp', Uint8List.fromList([2, 2]))),
    );
    expect(importStickerPack(core, zip, fallbackName: 'cats'), 2);
    expect(core.stickers().map((s) => s.pack).toSet(), {'Alpine cats'});
    expect(importStickerPack(core, Uint8List.fromList([1, 2, 3]), fallbackName: 'junk'), 0, reason: 'not a zip');
  });

  testWidgets('terms, guidelines and privacy open from sign-up and Settings (M7, DSA Art. 14)', (t) async {
    final opened = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(appChannel, (call) async {
      if (call.method == 'open') opened.add(call.arguments as String);
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(appChannel, null));
    await t.pumpWidget(wrap(Onboarding(core: FakeCore(), onDone: () {})));
    await tapText(t, 'Continue');
    expect(find.text('By continuing you accept our'), findsOneWidget);
    await tapText(t, 'Terms');
    await tapText(t, 'Guidelines');
    await tapText(t, 'Privacy policy');
    expect(opened, [
      for (final p in ['/terms', '/guidelines', '/privacy']) 'https://siegel.schlk.in$p',
    ]);

    final core = FakeCore()
      ..registered = true
      ..user = 'ana';
    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async {})));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Terms and community guidelines'), 100);
    await tapText(t, 'Terms and community guidelines');
    expect(opened.last, 'https://siegel.schlk.in/terms');
  });

  test('age from birth month and year never overstates it', () {
    final now = DateTime(2026, 10, 19);
    expect(ageAt(now, 2008, 9), 18);
    expect(ageAt(now, 2008, 10), 17, reason: 'this month: the day is unknown, so not yet');
    expect(ageAt(now, 2008, 11), 17);
    expect(ageAt(now, 2012, 1), 14);
  });

  testWidgets('sign-up asks the birth date: too young stops, under 18 is told to the server (M7)', (t) async {
    final core = FakeCore();
    await t.pumpWidget(wrap(Onboarding(core: core, onDone: () {})));
    await tapText(t, 'Continue');
    await enter(t, 'Your phone number', '+34 611 22 33 44');
    final send = find.widgetWithText(FilledButton, 'Send code');
    await pickBirth(t, DateTime.now().year - 10);
    expect(find.text('Siegel is for people aged 14 and over.'), findsOneWidget);
    expect(t.widget<FilledButton>(send).onPressed, isNull);

    await pickBirth(t, DateTime.now().year - 16);
    await tapText(t, 'Send code');
    expect(core.settings['birth'], '${DateTime.now().year - 16}-01', reason: 'kept on the phone');
    await enter(t, 'Code', '123456');
    await tapText(t, 'Verify');
    expect(core.calls, contains('setMinor true'));
    expect(core.settings['group_adds'], 'contacts');
  });

  testWidgets('existing accounts are asked once; under 18 locks group adds to contacts', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana'
      ..phone = '+34611223344';
    await t.pumpWidget(wrap(BirthDateGate(core: core, onDelete: (_) async {}, child: const Text('chats'))));
    await t.pumpAndSettle();
    expect(find.text('When were you born?'), findsOneWidget);
    expect(find.text('chats'), findsNothing);
    await t.tap(find.widgetWithText(DropdownButtonFormField<int>, 'Birth month'));
    await t.pumpAndSettle();
    await t.tap(find.text('January').last);
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(DropdownButtonFormField<int>, 'Birth year'));
    await t.pumpAndSettle();
    final year = DateTime.now().year - 15;
    await t.scrollUntilVisible(find.text('$year').hitTestable(), 200, scrollable: find.byType(Scrollable).last);
    await t.tap(find.text('$year').hitTestable().last);
    await t.pumpAndSettle();
    await tapText(t, 'Save');
    expect(find.text('chats'), findsOneWidget);
    expect(core.calls, contains('setMinor true'));

    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async {})));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text("Contacts only: you're under 18."), 100);
    expect(
      t
          .widget<ListTile>(
            find.ancestor(of: find.text("Contacts only: you're under 18."), matching: find.byType(ListTile)),
          )
          .onTap,
      isNull,
    );

    core.settings['birth'] = '${DateTime.now().year - 10}-01'; // younger than allowed
    await t.pumpWidget(
      wrap(BirthDateGate(key: UniqueKey(), core: core, onDelete: (_) async {}, child: const Text('chats'))),
    );
    await t.pumpAndSettle();
    expect(find.text('Siegel is for people aged 14 and over.'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
  });

  testWidgets('media from a message request stays blurred and undownloaded until tapped (M7)', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    core.incomingRequest('Zoe');
    final id = core.chatList.last.groupId;
    final photo = FakeCore.msg(
      id,
      '',
      outgoing: false,
      attachment: AttachmentView(
        mimeType: 'image/jpeg',
        fileName: '',
        size: BigInt.from(1000),
        durationMs: 0,
        voiceNote: false,
        waveform: Uint8List(0),
        width: 4,
        height: 3,
        thumbnail: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        ),
        sticker: false,
      ),
    );
    (core.history[base64Encode(id)] ??= []).add(photo);
    await autoDownload(core, photo);
    expect(core.calls, isNot(contains('attachmentData')), reason: 'nothing downloads by itself');
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();
    expect(find.text("From someone you haven't accepted. Tap to view."), findsOneWidget);
    expect(find.byType(ImageMessage), findsNothing);
    await tapText(t, "From someone you haven't accepted. Tap to view.");
    expect(find.byType(ImageMessage), findsOneWidget);
  });

  testWidgets('report a message: preselected, a reason, sent sealed (CMP-03)', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.startChat(username: 'bob');
    core.receive(id, 'first');
    await core.sendText(groupId: id, text: 'mine', mentions: const []);
    core.receive(id, 'nasty');
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();
    await t.longPress(find.text('nasty'));
    await t.pumpAndSettle();
    await tapText(t, 'Report');
    expect(find.text('Messages to send (2 of 50)'), findsOneWidget, reason: "bob's two, not mine");
    expect(find.textContaining("sent to Siegel's moderators, readable"), findsOneWidget);
    final page = find.descendant(of: find.byType(ReportScreen), matching: find.byType(Scrollable)).first;
    final note = find.widgetWithText(TextField, 'Anything else we should know? (optional)');
    await t.scrollUntilVisible(find.text('Send report'), 200, scrollable: page);
    expect(
      t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send report')).onPressed,
      isNull,
      reason: 'a reason first',
    );
    await t.scrollUntilVisible(find.text('Harassment or threats'), -200, scrollable: page);
    await t.ensureVisible(find.text('Harassment or threats'));
    await t.pumpAndSettle();
    await tapText(t, 'Harassment or threats');
    await t.scrollUntilVisible(note, 200, scrollable: page);
    await t.enterText(note, 'every night');
    await t.scrollUntilVisible(find.text('Send report'), 200, scrollable: page);
    await tapText(t, 'Send report');
    expect(core.reports, ['2 2 every night block=false']);
    expect(find.text('Thanks. Your report was sent.'), findsOneWidget);
  });

  testWidgets('report and block from a message request; child safety says what happens', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    core.incomingRequest('Zoe');
    final id = core.chatList.last.groupId;
    await t.pumpWidget(wrap(ChatScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();
    await tapText(t, 'Report and block');
    await t.ensureVisible(find.text('Sexual content involving a minor'));
    await t.pumpAndSettle();
    await tapText(t, 'Sexual content involving a minor');
    expect(find.textContaining('within 24 hours'), findsOneWidget);
    await t.scrollUntilVisible(
      find.text('Send report'),
      200,
      scrollable: find.descendant(of: find.byType(ReportScreen), matching: find.byType(Scrollable)).first,
    );
    expect(t.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Also block Zoe')).value, isTrue);
    await tapText(t, 'Send report');
    expect(core.reports.single, startsWith('4 1 '));
    expect(core.reports.single, endsWith('block=true'));
  });

  testWidgets('suspended: what, why, until when, how to appeal; deleting still works (M7)', (t) async {
    final until = DateTime(2026, 11, 2, 9, 30);
    var deleted = false;
    await t.pumpWidget(
      wrap(
        SuspendedScreen(
          notice: NoticeView(
            suspended: true,
            rule: 2,
            reason: 'threats to another user',
            untilMs: until.millisecondsSinceEpoch,
          ),
          onDelete: (_) async => deleted = true,
        ),
      ),
    );
    expect(find.text('Your account is suspended'), findsOneWidget);
    expect(find.textContaining('until Nov 2, 2026'), findsOneWidget);
    expect(find.text('Rule: Harassment or threats'), findsOneWidget);
    expect(find.text('threats to another user'), findsOneWidget);
    expect(find.textContaining('A person reviews every appeal'), findsOneWidget);
    await tapText(t, 'Delete account');
    expect(deleted, isTrue);
  });

  testWidgets('a removed @username: the reason, then a new one (M7)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..notice_ = const NoticeView(suspended: false, rule: 7, reason: 'looks like staff', untilMs: 0);
    await t.pumpWidget(wrap(Onboarding(core: core, onDone: () {})));
    await t.pumpAndSettle();
    expect(find.textContaining('Your @username was removed by our moderators'), findsOneWidget);
    expect(find.textContaining('Rule: Pretending to be someone else'), findsOneWidget);
    expect(find.textContaining('looks like staff'), findsOneWidget);
  });

  test('files picked or shared: WebP and PNG to my stickers, packs as packs, the rest skipped', () {
    final core = FakeCore();
    final webp = Uint8List.fromList([...'RIFF'.codeUnits, 1, 0, 0, 0, ...'WEBP'.codeUnits, 7, 7]);
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    final pack = ZipEncoder().encodeBytes(
      Archive()
        ..add(ArchiveFile.bytes('title.txt', utf8.encode('Cats')))
        ..add(ArchiveFile.bytes('1.webp', Uint8List.fromList([1, 2, 3]))),
    );
    final added = importStickerFiles(core, [
      ('a.webp', webp),
      ('b.png', png),
      ('notes.txt', Uint8List.fromList(utf8.encode('hello'))),
      ('cats.wastickers', pack),
    ]);
    expect(added, 3);
    expect(
      [for (final s in core.stickers()) (s.pack, s.mimeType)],
      [('', 'image/webp'), ('', 'image/png'), ('Cats', 'image/webp')],
    );
  });

  testWidgets('edit a sticker: add text, move it, colour it, save a new PNG', (t) async {
    final png = await t.runAsync(() => renderSiegelSticker('flame'));
    Uint8List? saved;
    await t.pumpWidget(
      wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                saved = await Navigator.of(context)
                    .push<Uint8List>(MaterialPageRoute(builder: (_) => StickerEditor(image: png!))),
            child: const Text('open'),
          ),
        ),
      ),
    );
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 2.75; // a phone: the editor fits on screen
    addTearDown(t.view.reset);
    await tapText(t, 'open');
    await tapText(t, 'Add text');
    await t.enterText(find.byType(TextField), 'hot!');
    await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Save')));
    await t.pumpAndSettle();
    expect(find.text('hot!'), findsNWidgets(2), reason: 'outline and fill');
    await t.drag(find.text('hot!').first, const Offset(0, -60));
    await t.pump();
    await t.tap(find.bySemanticsLabel('#ffd54f'));
    await t.pump();
    await t.runAsync(() async {
      await t.tap(find.descendant(of: find.byType(SiegelBar), matching: find.text('Save')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await t.pumpAndSettle();
    expect(saved, isNotNull);
    expect(saved!.sublist(1, 4), 'PNG'.codeUnits);
  });

  test('a link QR code carries the device name', () {
    final name = base64Url.encode(utf8.encode('Firefox on Linux')).replaceAll('=', '');
    expect(linkName('siegel-link:abc.age1xyz.$name'), 'Firefox on Linux');
    expect(linkName('https://siegel.schlk.in/u/ana#x.y'), isNull);
  });

  testWidgets('linked devices: listed, unlinked after confirming, at most 4 (M8)', (t) async {
    final core = FakeCore()..registered = true;
    core.deviceList.add(
      DeviceView(
        id: Uint8List.fromList([2]),
        name: 'Firefox on Linux',
        linked: true,
        lastSeenDay: '2026-10-19',
        thisDevice: false,
      ),
    );
    await t.pumpWidget(wrap(LinkedDevicesScreen(core: core)));
    await t.pumpAndSettle();
    expect(find.text('Phone'), findsOneWidget);
    expect(find.textContaining('This device'), findsOneWidget);
    expect(find.text('Firefox on Linux'), findsOneWidget);
    await tapText(t, 'Unlink');
    expect(find.text('Unlink Firefox on Linux?'), findsOneWidget);
    await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Unlink')));
    await t.pumpAndSettle();
    expect(core.calls, contains('unlinkDevice'));
    expect(find.text('Firefox on Linux'), findsNothing);

    for (var i = 0; i < 4; i++) {
      core.deviceList.add(
        DeviceView(id: Uint8List.fromList([10 + i]), name: 'tab $i', linked: true, lastSeenDay: '', thisDevice: false),
      );
    }
    await t.pumpWidget(wrap(LinkedDevicesScreen(key: UniqueKey(), core: core)));
    await t.pumpAndSettle();
    expect(find.text('You can link up to 4 devices. Unlink one first.'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.ancestor(of: find.text('Link a device'), matching: find.byType(FilledButton)))
          .onPressed,
      isNull,
    );
  });

  testWidgets('a wide window shows the open chat beside the list; narrow, over it (M8)', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    await core.startChat(username: 'bob');
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(wrap(ChatsHome(core: core, service: service, settings: (_) => const SizedBox())));
    await t.pumpAndSettle();
    expect(find.text('Choose a chat on the left.'), findsOneWidget);
    await t.tap(find.text('@bob').first);
    await t.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(ChatListScreen), findsOneWidget, reason: 'the list stays');

    t.view.physicalSize = const Size(400, 800);
    await t.pumpWidget(
      wrap(ChatsHome(key: UniqueKey(), core: core, service: service, settings: (_) => const SizedBox())),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('@bob').first);
    await t.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(ChatListScreen).hitTestable(), findsNothing, reason: 'over the list on a phone');
  });

  testWidgets('a linked browser: no account settings, unlinks itself instead of deleting the account (M8)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..linked = true
      ..user = 'ana.b';
    var done = false;
    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async => done = true)));
    await t.scrollUntilVisible(find.text('Unlink this browser'), 200);
    expect(find.text('Delete account'), findsNothing);
    expect(find.text('Linked devices'), findsNothing, reason: 'only the phone links');
    expect(find.text('Change number'), findsNothing);
    await t.ensureVisible(find.text('Unlink this browser'));
    await t.pumpAndSettle();
    await tapText(t, 'Unlink this browser');
    await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Unlink')));
    await t.pumpAndSettle();
    expect(core.calls.last, 'unlinkThisDevice');
    expect(done, isTrue);
  });

  testWidgets('web PIN: chosen twice, must match; a wrong one says how many tries are left (W3)', (t) async {
    String? chosen;
    await t.pumpWidget(
      wrap(
        PinScreen.create(
          onPin: (p) async {
            chosen = p;
            return true;
          },
        ),
      ),
    );
    final go = find.widgetWithText(FilledButton, 'Continue');
    await enter(t, 'PIN (4 to 6 digits)', '12');
    expect(t.widget<FilledButton>(go).onPressed, isNull, reason: '4 to 6 digits');
    await enter(t, 'PIN (4 to 6 digits)', '4821');
    await enter(t, 'Enter it again', '4822');
    await tapText(t, 'Continue');
    expect(find.text("The PINs don't match."), findsOneWidget);
    expect(chosen, isNull);
    await enter(t, 'Enter it again', '4821');
    await tapText(t, 'Continue');
    expect(chosen, '4821');

    var forgot = false;
    await t.pumpWidget(
      wrap(PinScreen.unlock(onPin: (p) async => p == '1234', triesLeft: () => 9, onForgot: () => forgot = true)),
    );
    await enter(t, 'PIN (4 to 6 digits)', '0000');
    await tapText(t, 'Unlock');
    expect(find.text('Wrong PIN. 9 tries left before Siegel forgets this browser.'), findsOneWidget);
    await tapText(t, 'Forgot the PIN? Link again');
    expect(forgot, isTrue);
  });

  testWidgets('web link screen: a QR code for the phone, done once the phone approves (M8)', (t) async {
    final core = FakeCore();
    var linked = false;
    await t.pumpWidget(wrap(LinkScreen(core: core, onLinked: () => linked = true)));
    await t.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('Settings → Linked devices'), findsOneWidget);
    core.linkApproved = true;
    await t.pump(const Duration(seconds: 3));
    expect(linked, isTrue);
    await t.pumpWidget(const SizedBox()); // stops the polling
  });

  testWidgets('phone numbers: the SIM country, national numbers with a trunk 0, the number the SMS goes to', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(appChannel, (call) async {
      return call.method == 'countries'
          ? {
              'sim': 'BR',
              'names': {'BR': 'Brasil', 'ES': 'España'},
            }
          : null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(appChannel, null));
    String? got;
    await t.pumpWidget(wrap(Scaffold(body: PhoneNumberField(onChanged: (p) => got = p?.international))));
    await t.pumpAndSettle();
    expect(find.text('🇧🇷 +55'), findsOneWidget, reason: "the SIM's country, not the phone's language");
    // As dialled at home in Campinas: trunk 0, area 19.
    await t.enterText(find.byType(TextField), '019 99876-5432');
    await t.pump();
    expect(got, '+5519998765432');
    expect(find.textContaining("We'll text +55 19 99876-5432 (Brasil)."), findsOneWidget);
    // A number typed with its + code wins, and the flag follows it.
    await t.enterText(find.byType(TextField), '+34 611 22 33 44');
    await t.pump();
    expect(got, '+34611223344');
    expect(find.text('🇪🇸 +34'), findsOneWidget);
  });

  testWidgets('group invite links: admins create, show and revoke them (GRP-16)', (t) async {
    final core = FakeCore()..registered = true;
    final service = ChatService(core, onDeregistered: () {})..start();
    addTearDown(service.dispose);
    final id = await core.createGroup(name: 'Hikers', usernames: ['bob']);
    await t.pumpWidget(wrap(GroupInfoScreen(core: core, service: service, groupId: id)));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Create invite link'), 100);
    await tapText(t, 'Create invite link');
    expect(find.textContaining('join the group straight away'), findsOneWidget);
    await tapText(t, 'Copy');
    await t.scrollUntilVisible(find.text('Revoke'), 100);
    expect(find.textContaining('Expires'), findsOneWidget);
    await tapText(t, 'Revoke');
    expect(core.links, isEmpty);
  });
}
