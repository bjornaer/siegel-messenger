// CMP-05 (EN 301 549 / WCAG 2.1 AA): every main screen, in every theme, light and dark, meets
// Flutter's tap-target, label and text-contrast guidelines, and still lays out at 200% text.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:siegel/app_lock.dart';
import 'package:siegel/chats.dart';
import 'package:siegel/discovery.dart';
import 'package:siegel/groups.dart';
import 'package:siegel/l10n/app_localizations.dart';
import 'package:siegel/main.dart';
import 'package:siegel/number.dart';
import 'package:siegel/onboarding.dart';
import 'package:siegel/profile.dart';
import 'package:siegel/server_data.dart';
import 'package:siegel/src/rust/api/core.dart';
import 'package:siegel/themes.dart';

import 'screens_test.dart' show FakeCore;

Widget themed(Widget child, ThemeData theme, {double textScale = 1}) => MaterialApp(
  theme: theme,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, c) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
    child: c!,
  ),
  home: child,
);

/// A chat with both sides talking, our messages in every status.
Future<(FakeCore, ChatService, List<int>)> chatting() async {
  final core = FakeCore()..registered = true;
  final service = ChatService(core, onDeregistered: () {});
  final id = await core.startChat(username: 'bob');
  core.receive(id, 'Are you coming to the hut on Saturday?');
  for (final s in [MessageStatus.sent, MessageStatus.delivered, MessageStatus.read]) {
    await core.sendText(groupId: id, text: 'Yes, ${s.name}', mentions: const []);
    final list = core.history.values.first;
    list[list.length - 1] = FakeCore.copy(list.last, status: s);
  }
  return (core, service, id);
}

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

AttachmentView _att(String mime, String name, {bool voice = false}) => AttachmentView(
  mimeType: mime,
  fileName: name,
  size: BigInt.from(2 << 20),
  durationMs: voice ? 4000 : 0,
  voiceNote: voice,
  waveform: Uint8List.fromList(List.generate(voice ? 40 : 0, (i) => i * 6)),
  width: 4,
  height: 3,
  thumbnail: base64Decode(_png),
  sticker: false,
);

Future<Map<String, Widget>> screens() async {
  final (core, service, id) = await chatting();
  final media = await core.startChat(username: 'carol');
  (core.history[base64Encode(media)] ??= []).addAll([
    FakeCore.msg(media, '', outgoing: false, attachment: _att('image/jpeg', '')),
    FakeCore.msg(media, '', outgoing: false, attachment: _att('application/pdf', 'plan.pdf')),
    FakeCore.msg(media, '', outgoing: true, attachment: _att('audio/ogg', '', voice: true)),
  ]);
  final group = await core.createGroup(name: 'Hikers', usernames: ['bob', 'carol']);
  core.receive(group, 'Who brings the stove?');
  Uint8List u(List<int> b) => Uint8List.fromList(b);
  return {
    'onboarding': Onboarding(core: FakeCore(), onDone: () {}),
    'chat list': ChatListScreen(core: core, service: service, settings: (_) => const SizedBox()),
    'chat': ChatScreen(core: core, service: service, groupId: u(id)),
    'media chat': ChatScreen(core: core, service: service, groupId: u(media)),
    'group chat': ChatScreen(core: core, service: service, groupId: u(group)),
    'group info': GroupInfoScreen(core: core, service: service, groupId: u(group)),
    'contact profile': ContactProfileScreen(core: core, groupId: u(id), onBlock: () {}),
    'settings': SettingsScreen(core: core, onDeleted: () async {}),
    'themes': ThemePicker(onPick: (_) {}),
    'find contacts': FindContactsScreen(core: core, service: service),
    'server data': ServerDataScreen(core: core),
    'change number': ChangeNumberScreen(core: core),
    'blocked': BlockedScreen(core: core),
    'app lock': AppLock(core: FakeCore()..settings['app_lock'] = '60', child: const SizedBox()),
  };
}

const _names = [
  'onboarding', 'chat list', 'chat', 'media chat', 'group chat', 'group info', 'contact profile', 'settings', //
  'themes', 'find contacts', 'server data', 'change number', 'blocked', 'app lock',
];

void main() {
  for (final th in siegelThemes) {
    for (final b in [Brightness.light, if (!th.lightOnly) Brightness.dark]) {
      testWidgets('${th.name} ${b.name}: tap targets, labels and contrast', (t) async {
        final handle = t.ensureSemantics();
        final failures = <String>[];
        for (final MapEntry(key: name, value: screen) in (await screens()).entries) {
          await t.pumpWidget(themed(screen, th.data(b)));
          await t.pumpAndSettle();
          for (final g in [androidTapTargetGuideline, labeledTapTargetGuideline, textContrastGuideline]) {
            final e = await g.evaluate(t);
            if (!e.passed) failures.add('$name: ${e.reason}');
          }
        }
        handle.dispose();
        expect(failures, isEmpty, reason: failures.join('\n'));
      });
    }
  }

  for (final name in _names) {
    testWidgets('200% text: $name still lays out', (t) async {
      t.view.physicalSize = const Size(1080, 2340); // a common phone, 2.75x
      t.view.devicePixelRatio = 2.75;
      addTearDown(t.view.reset);
      await t.pumpWidget(themed((await screens())[name]!, siegelThemes.first.data(Brightness.light), textScale: 2));
      await t.pumpAndSettle();
    });
  }

  testWidgets('screen readers hear who sent a bubble, get Reply instead of the swipe, and unread counts', (t) async {
    final h = t.ensureSemantics();
    final all = await screens();
    await t.pumpWidget(themed(all['chat list']!, siegelThemes.first.data(Brightness.light)));
    await t.pumpAndSettle();
    expect(find.semantics.byLabel(RegExp('1 unread message')), findsOne);

    await t.pumpWidget(themed(all['chat']!, siegelThemes.first.data(Brightness.light)));
    await t.pumpAndSettle();
    final mine = t.getSemantics(find.text('Yes, read'));
    expect(mine.label, startsWith('You\n'));
    expect(mine.getSemanticsData().customSemanticsActionIds, isNotEmpty, reason: 'Reply');
    expect(t.getSemantics(find.text('Are you coming to the hut on Saturday?')).label, startsWith('@bob\n'));

    await t.pumpWidget(themed(all['media chat']!, siegelThemes.first.data(Brightness.light)));
    await t.pumpAndSettle();
    expect(t.getSemantics(find.text('0:04')).label, contains('Voice message, 0:04'));

    h.dispose();
  });
}
