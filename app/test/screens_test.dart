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
  Future<void> requestOtp({required String phoneE164, required String attestationToken}) =>
      _maybeFail('requestOtp $phoneE164');
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
        last: (history[base64Encode(c.groupId)] ?? []).lastOrNull,
      ),
  ];

  ChatSummary _with(ChatSummary c, {required bool request}) => ChatSummary(
    groupId: c.groupId,
    peerAccount: c.peerAccount,
    peerDisplayName: c.peerDisplayName,
    peerUsername: c.peerUsername,
    request: request,
  );

  /// Someone who isn't a contact started a chat with us (MSG-15).
  void incomingRequest(String name) {
    final id = Uint8List.fromList(utf8.encode('g-req-$name'));
    chatList.add(ChatSummary(groupId: id, peerAccount: Uint8List(16), peerDisplayName: name, request: true));
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
    chatList.removeWhere((c) => listEquals(c.peerAccount, account)); // blocked chats are hidden
  }

  @override
  List<MessageView> messages({required List<int> groupId, required int limit}) => history[base64Encode(groupId)] ?? [];
  @override
  Future<Uint8List> startChat({required String username}) async {
    await _maybeFail('startChat $username');
    final id = Uint8List.fromList(utf8.encode('g-$username'));
    chatList.add(ChatSummary(groupId: id, peerAccount: Uint8List(16), peerUsername: username, request: false));
    return id;
  }

  @override
  Future<MessageView> sendText({required List<int> groupId, required String text}) async {
    await _maybeFail('sendText $text');
    final m = msg(groupId, text, outgoing: true);
    (history[base64Encode(groupId)] ??= []).add(m);
    return m;
  }

  @override
  Stream<CoreEvent> runStream() => events.stream;

  /// Simulates a message arriving from the peer.
  void receive(List<int> groupId, String text) {
    (history[base64Encode(groupId)] ??= []).add(msg(groupId, text, outgoing: false));
    events.add(CoreEvent(kind: CoreEventKind.message, groupId: Uint8List.fromList(groupId)));
  }

  static int _n = 0;
  static MessageView msg(List<int> groupId, String text, {required bool outgoing}) => MessageView(
    groupId: Uint8List.fromList(groupId),
    messageId: Uint8List.fromList([_n++]),
    senderAccount: Uint8List(16),
    sentAt: DateTime(2026, 10, 15, 9, 30).millisecondsSinceEpoch,
    text: text,
    outgoing: outgoing,
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
}
