import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:web/web.dart' as web;

@JS('siegelCoreReady')
external JSPromise<JSAny?> get _coreReady;

/// The core, started by web/siegel_core.js; flutter_rust_bridge's own loader needs eval.
Future<ExternalLibrary?> coreLibrary() async {
  await _coreReady.toDart;
  // The analyzer reads the phones' ExternalLibrary; this file only builds for the browser's.
  // ignore: const_with_undefined_constructor_default
  return const ExternalLibrary(debugInfo: 'web/siegel_core.js');
}

String? load(String key) => web.window.localStorage.getItem(key);

void save(String key, String? value) =>
    value == null ? web.window.localStorage.removeItem(key) : web.window.localStorage.setItem(key, value);

void reload() => web.window.location.reload();

void openUrl(String url) => web.window.open(url, '_blank', 'noopener');

@JS('JSON.stringify')
external String _stringify(JSAny value);

const _pushWorker = 'siegel_push_sw.js';

bool get pushSupported =>
    web.window.navigator.has('serviceWorker') && web.window.has('PushManager') && web.window.has('Notification');

Future<web.ServiceWorkerRegistration> _registration() async {
  await web.window.navigator.serviceWorker.register(_pushWorker.toJS).toDart;
  return web.window.navigator.serviceWorker.ready.toDart;
}

Future<bool> pushEnabled() async {
  if (!pushSupported || web.Notification.permission != 'granted') return false;
  return (await (await _registration()).pushManager.getSubscription().toDart) != null;
}

/// Asks for permission, then subscribes with the server's VAPID key (GET /v1/push/vapid).
Future<String?> pushSubscribe(String serverUrl) async {
  if (!pushSupported) return null;
  if ((await web.Notification.requestPermission().toDart).toDart != 'granted') return null;
  final res = await web.window.fetch('$serverUrl/v1/push/vapid'.toJS).toDart;
  if (!res.ok) return null; // the server has no web push key
  final key = (await res.text().toDart).toDart;
  final reg = await _registration();
  final sub = await reg.pushManager
      .subscribe(web.PushSubscriptionOptionsInit(userVisibleOnly: true, applicationServerKey: key.toJS))
      .toDart;
  return _stringify(sub.toJSON());
}

Future<void> pushUnsubscribe() async {
  if (!pushSupported) return;
  final sub = await (await _registration()).pushManager.getSubscription().toDart;
  await sub?.unsubscribe().toDart;
}

/// Only while the page is hidden, and only once the person allowed notifications.
Future<void> notify(String title, String body, String tag) async {
  if (!web.document.hidden || !pushSupported || web.Notification.permission != 'granted') return;
  final reg = await _registration();
  await reg.showNotification(title, web.NotificationOptions(body: body, tag: tag, icon: 'icons/Icon-192.png')).toDart;
}

String objectUrl(Uint8List bytes, String mime) =>
    web.URL.createObjectURL(web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime)));

void revokeUrl(String url) => web.URL.revokeObjectURL(url);

Future<Uint8List> fetchBytes(String url) async {
  final res = await web.window.fetch(url.toJS).toDart;
  return (await res.arrayBuffer().toDart).toDart.asUint8List();
}

Future<(Uint8List, String)> compressImage(Uint8List data, int side, int quality, String mime) async {
  final bmp = await web.window.createImageBitmap(web.Blob([data.toJS].toJS)).toDart;
  try {
    final scale = math.min(1.0, math.max(side / bmp.width, side / bmp.height));
    final (w, h) = (math.max(1, (bmp.width * scale).round()), math.max(1, (bmp.height * scale).round()));
    final canvas = web.OffscreenCanvas(w, h);
    (canvas.getContext('2d') as web.OffscreenCanvasRenderingContext2D).drawImage(bmp, 0, 0, w, h);
    final blob = await canvas.convertToBlob(web.ImageEncodeOptions(type: mime, quality: quality / 100)).toDart;
    return ((await blob.arrayBuffer().toDart).toDart.asUint8List(), blob.type);
  } finally {
    bmp.close();
  }
}

void Function(List<(String, String, Uint8List)>)? _onDrop;
bool _dropListening = false;

void Function(List<(String, String, Uint8List)>)? get onDrop => _onDrop;

set onDrop(void Function(List<(String, String, Uint8List)>)? f) {
  _onDrop = f;
  if (_dropListening) return;
  _dropListening = true;
  // Without preventDefault on dragover the browser would open a dropped file itself.
  web.window.addEventListener('dragover', ((web.DragEvent e) => e.preventDefault()).toJS);
  web.window.addEventListener(
    'drop',
    ((web.DragEvent e) {
      e.preventDefault();
      final files = e.dataTransfer?.files;
      final handler = _onDrop;
      if (files == null || handler == null || files.length == 0) return;
      () async {
        final out = <(String, String, Uint8List)>[];
        for (var i = 0; i < files.length; i++) {
          final f = files.item(i)!;
          if (f.size > 128 << 20) continue; // over any attachment's limit: don't read it all
          out.add((f.name, f.type, (await f.arrayBuffer().toDart).toDart.asUint8List()));
        }
        handler(out);
      }();
    }).toJS,
  );
}

String deviceName() {
  final ua = web.window.navigator.userAgent;
  final browser = ua.contains('Firefox/')
      ? 'Firefox'
      : ua.contains('Edg/')
      ? 'Edge'
      : ua.contains('Chrome/')
      ? 'Chrome'
      : ua.contains('Safari/')
      ? 'Safari'
      : 'Browser';
  final os = ua.contains('Windows')
      ? 'Windows'
      : ua.contains('Android')
      ? 'Android'
      : ua.contains('iPhone') || ua.contains('iPad')
      ? 'iOS'
      : ua.contains('Mac OS')
      ? 'macOS'
      : ua.contains('Linux')
      ? 'Linux'
      : '';
  return os.isEmpty ? browser : '$browser on $os';
}
