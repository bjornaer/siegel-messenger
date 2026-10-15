import 'dart:isolate';
import 'dart:ui' show IsolateNameServer, PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'chats.dart' show chatTitle;
import 'l10n/app_localizations.dart';
import 'main.dart' show openCore;
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

/// One notification per chat, replaced by its newest message. Hidden on the lock screen
/// unless the user allows private content there (Android's "private" visibility).
Future<void> notifyMessage(Core core, MessageView m) async {
  if (m.outgoing) return;
  final t = lookupAppLocalizations(PlatformDispatcher.instance.locale);
  final chat = core.chats().where((c) => listEquals(c.groupId, m.groupId)).firstOrNull;
  await _notifications.show(
    id: Object.hashAll(m.groupId) & 0x7fffffff,
    title: chat == null ? null : chatTitle(t, chat),
    body: m.text,
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

/// Runs in a background isolate when a push arrives and the app isn't in the foreground.
@pragma('vm:entry-point')
Future<void> _onBackgroundPush(RemoteMessage _) async {
  final running = IsolateNameServer.lookupPortByName(_mainPort);
  if (running != null) {
    running.send(null); // the app holds the database and stream; let it fetch
    return;
  }
  // ponytail: if the user opens the app during these seconds, both isolates use the database
  // at once. SQLite locking serializes writes; move this into the core with a file lock if it bites.
  await RustLib.init();
  final core = await openCore();
  if (!core.isRegistered()) return;
  await _initNotifications();
  await for (final e in core.drain()) {
    if (e.kind == CoreEventKind.message && e.message != null) await notifyMessage(core, e.message!);
  }
}

/// Sets up push for the running app. `wake` reconnects the stream right away.
/// Without Google Play services this fails quietly: messages still arrive while the app is open.
Future<void> startPush(Core core, VoidCallback wake) async {
  final port = ReceivePort()..listen((_) => wake());
  IsolateNameServer.removePortNameMapping(_mainPort);
  IsolateNameServer.registerPortWithName(port.sendPort, _mainPort);
  try {
    await _initNotifications();
    await Firebase.initializeApp(options: _firebase);
    FirebaseMessaging.onBackgroundMessage(_onBackgroundPush);
    FirebaseMessaging.onMessage.listen((_) => wake());
    final fcm = FirebaseMessaging.instance;
    await fcm.requestPermission(); // Android 13+ asks the user
    fcm.onTokenRefresh.listen((t) => core.setPushToken(pushToken: t));
    final token = await fcm.getToken();
    if (token != null) await core.setPushToken(pushToken: token);
  } on Object catch (e) {
    debugPrint('push unavailable: $e');
  }
}
