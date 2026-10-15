// Widget tests for every screen built so far (section 15: Flutter tests per screen), against a
// fake core. Real network and storage paths are covered by core-api/tests/e2e.rs.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:siegel/app_lock.dart';
import 'package:siegel/chats.dart';
import 'package:siegel/l10n/app_localizations.dart';
import 'package:siegel/main.dart';
import 'package:siegel/onboarding.dart';
import 'package:siegel/src/rust/api/core.dart';

class FakeCore implements Core {
  bool registered = false;
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
  Future<void> requestOtp({
    required String phoneE164,
    required String attestationToken,
    required DevicePlatform platform,
  }) => _maybeFail('requestOtp $phoneE164');
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
        last: (history[base64Encode(c.groupId)] ?? []).lastOrNull,
      ),
  ];

  ChatSummary _with(ChatSummary c, {required bool request}) => ChatSummary(
    groupId: c.groupId,
    peerAccount: c.peerAccount,
    peerDisplayName: c.peerDisplayName,
    peerUsername: c.peerUsername,
    request: request,
    peerVerified: false,
  );

  /// Someone who isn't a contact started a chat with us (MSG-15).
  void incomingRequest(String name) {
    final id = Uint8List.fromList(utf8.encode('g-req-$name'));
    chatList.add(
      ChatSummary(groupId: id, peerAccount: Uint8List(16), peerDisplayName: name, request: true, peerVerified: false),
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
      ChatSummary(groupId: id, peerAccount: Uint8List(16), peerUsername: username, request: false, peerVerified: false),
    );
    return id;
  }

  @override
  Future<MessageView> sendText({required List<int> groupId, required String text, Uint8List? replyTo}) async {
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
  Future<void> markRead({required List<int> groupId}) async => calls.add('markRead');
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
  }) => MessageView(
    groupId: Uint8List.fromList(groupId),
    messageId: Uint8List.fromList([_n++]),
    senderAccount: Uint8List(16),
    sentAt: sentAt,
    text: text,
    outgoing: outgoing,
    replyTo: replyTo,
    status: outgoing ? MessageStatus.sent : MessageStatus.delivered,
    edited: false,
    deleted: false,
    reactions: const [],
    keyChange: keyChange,
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
Future<void> toCodeScreen(WidgetTester t, FakeCore core) async {
  await tapText(t, 'Continue');
  final send = find.widgetWithText(FilledButton, 'Send code');
  await enter(t, 'Your phone number', '+34 611 22 33 44');
  expect(find.text('I am at least 14 years old'), findsOneWidget, reason: 'CMP-02: Spain is 14');
  expect(t.widget<FilledButton>(send).onPressed, isNull, reason: 'age gate blocks sending');
  await tapText(t, 'I am at least 14 years old');
  await tapText(t, 'Send code');
  expect(core.calls.last, 'requestOtp +34611223344', reason: 'ID-01: E.164');
  expect(find.textContaining('Enter the 6-digit code'), findsOneWidget);
}

void main() {
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
    expect(find.text('App lock'), findsOneWidget);

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

  testWidgets('read receipts and typing toggles are reciprocal settings (MSG-13, MSG-14)', (t) async {
    final core = FakeCore()
      ..registered = true
      ..user = 'ana';
    await t.pumpWidget(wrap(SettingsScreen(core: core, onDeleted: () async {})));
    await t.scrollUntilVisible(find.text('Read receipts'), 100);
    await tapText(t, 'Read receipts');
    expect(core.settings['read_receipts'], 'off');
    await t.scrollUntilVisible(find.text('Typing indicators'), 100);
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
}
