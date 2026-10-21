import 'dart:isolate';
import 'dart:ui' show IsolateNameServer, PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'browser.dart' if (dart.library.js_interop) 'browser_web.dart' as browser;
import 'chats.dart' show chatTitle;
import 'groups.dart' show memberName, myAccount;
import 'l10n/app_localizations.dart';
import 'main.dart' show openCore;
import 'media.dart' show messageText;
import 'profile.dart' show isArchived, isMuted, isMutedAlways;
import 'src/rust/api/core.dart';
import 'src/rust/frb_generated.dart';

/// MSG-17: FCM only wakes the app (no content, no sender). The app fetches its queue,
/// decrypts, and shows the notification itself. FCM is the only third-party SDK (SEC-01).
/// These values ship in every APK anyway; the API key is restricted to this app in Google Cloud.
const _firebase = FirebaseOptions(
  apiKey: 'AIzaSyA4l8M9kW6dV6BnIgFzLfMDEbah7QDLFq8',
  appId: '1:779364744809:android:370b3e90c3cbe979126cf8',
  messagingSenderId: '779364744809',
  projectId: 'hidden-mapper-297900',
);

/// The running app registers under this name; a push then just nudges its stream.
const _mainPort = 'siegel.main';

final _notifications = FlutterLocalNotificationsPlugin();

Future<void> _initNotifications() => _notifications.initialize(
  settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')),
);

/// The app's strings for [locale], or English when the app isn't translated into it.
/// lookupAppLocalizations throws on an unsupported locale; outside the widget tree nothing
/// falls back for us (this silently broke every notification on non-English phones).
AppLocalizations notificationStrings(Locale locale) => lookupAppLocalizations(
  AppLocalizations.supportedLocales.firstWhere(
    (l) => l.languageCode == locale.languageCode,
    orElse: () => const Locale('en'),
  ),
);

/// The app is on screen, maybe partly covered (the notification shade, a dialog): inactive counts.
bool appVisible() => switch (WidgetsBinding.instance.lifecycleState) {
  AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => false,
  _ => true,
};

int _notificationId(List<int> groupId) => Object.hashAll(groupId) & 0x7fffffff;

/// The chat is on screen: its notification is stale.
Future<void> clearNotification(List<int> groupId) async {
  if (kIsWeb) return; // M8: the browser gets notifications in part 6
  await _notifications.cancel(id: _notificationId(groupId));
}

/// One notification per chat, replaced by its newest message. Hidden on the lock screen
/// unless the user allows private content there (Android's "private" visibility).
Future<void> notifyMessage(Core core, MessageView m) async {
  if (m.outgoing || m.event != null || isMutedAlways(core, m.groupId) || isArchived(core, m.groupId)) return;
  // GRP-15: an @mention gets through a timed mute.
  final me = myAccount(core, m.groupId);
  if (isMuted(core, m.groupId) && !m.mentions.any((a) => listEquals(a, me))) return;
  final t = notificationStrings(PlatformDispatcher.instance.locale);
  final chat = core.chats().where((c) => listEquals(c.groupId, m.groupId)).firstOrNull;
  final title = chat == null ? null : chatTitle(t, chat);
  final body = chat != null && chat.isGroup
      ? '${memberName(t, core, m.senderAccount)}: ${messageText(t, m)}'
      : messageText(t, m);
  // M8: a hidden browser tab shows it itself; a closed one only gets the content-free push.
  if (kIsWeb) return browser.notify(title ?? 'Siegel', body, '${_notificationId(m.groupId)}');
  await _notifications.show(
    id: _notificationId(m.groupId),
    title: title,
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        'messages',
        t.notificationChannel,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        visibility: NotificationVisibility.private,
      ),
    ),
  );
}

Core? _backgroundCore;

/// Runs in a background isolate when a push arrives and the app isn't in the foreground.
@pragma('vm:entry-point')
Future<void> _onBackgroundPush(RemoteMessage _) async {
  final running = IsolateNameServer.lookupPortByName(_mainPort);
  if (running != null) {
    // The app holds the database and stream: let it fetch, and stay in this handler until it
    // is done. Returning at once lets Android freeze the app again before anything arrives.
    final done = ReceivePort();
    running.send(done.sendPort);
    await done.first.timeout(const Duration(seconds: 18), onTimeout: () => null);
    done.close();
    return;
  }
  // ponytail: if the user opens the app during these seconds, both isolates use the database
  // at once. SQLite locking serializes writes; move this into the core with a file lock if it bites.
  // A process woken for one push stays around for the next: open everything once.
  final core = _backgroundCore ??= await () async {
    await RustLib.init();
    return openCore();
  }();
  if (!core.isRegistered()) return;
  await _initNotifications();
  await for (final e in core.drain()) {
    if (e.kind == CoreEventKind.message && e.message != null) await notifyMessage(core, e.message!);
  }
}

/// Sets up push for the running app. `fetch` reconnects at once and completes once what was
/// waiting has arrived. Without Google Play services this fails quietly: messages still arrive
/// while the app is open.
Future<void> startPush(Core core, Future<void> Function() fetch) async {
  if (kIsWeb) return; // web push is M8 part 6
  final port = ReceivePort()
    ..listen((reply) async {
      await fetch();
      if (reply is SendPort) reply.send(null);
    });
  IsolateNameServer.removePortNameMapping(_mainPort);
  IsolateNameServer.registerPortWithName(port.sendPort, _mainPort);
  try {
    await _initNotifications();
    await Firebase.initializeApp(options: _firebase);
    FirebaseMessaging.onBackgroundMessage(_onBackgroundPush);
    FirebaseMessaging.onMessage.listen((_) => fetch());
    final fcm = FirebaseMessaging.instance;
    await fcm.requestPermission(); // Android 13+ asks the user
    fcm.onTokenRefresh.listen((t) => core.setPushToken(pushToken: t));
    // Without a registered token the server can never wake us: retry if the network was down.
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        final token = await fcm.getToken();
        if (token != null) await core.setPushToken(pushToken: token);
        break;
      } on Object {
        await Future<void>.delayed(Duration(seconds: 10 << attempt));
      }
    }
  } on Object catch (e) {
    debugPrint('push unavailable: $e');
  }
}
