import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;

/// M8: the few things only a browser has. Phones (and tests) get these no-op stand-ins; the
/// web build swaps in browser_web.dart.

/// The core, already started by the page (web/siegel_core.js); phones load it themselves.
Future<ExternalLibrary?> coreLibrary() async => null;
String? load(String key) => null;
void save(String key, String? value) {}
void reload() {}
void openUrl(String url) {}

/// M8 part 6: Web Push.
bool get pushSupported => false;
Future<bool> pushEnabled() async => false;

/// Subscribes this browser (asking for permission); the subscription as JSON, or null.
Future<String?> pushSubscribe(String serverUrl) async => null;
Future<void> pushUnsubscribe() async {}

/// A notification from the open (but hidden) page.
Future<void> notify(String title, String body, String tag) async {}

/// M8 part 6, media in the browser: a blob: URL for bytes (video playback), and its release.
String objectUrl(Uint8List bytes, String mime) => throw UnsupportedError('browser only');
void revokeUrl(String url) {}

/// The bytes behind a blob: URL (a finished voice recording).
Future<Uint8List> fetchBytes(String url) => throw UnsupportedError('browser only');

/// An image re-encoded on a canvas (EXIF dropped), scaled down so its shorter side is at most
/// [side]: the bytes and their type ('image/png' when the browser can't write [mime]).
Future<(Uint8List, String)> compressImage(Uint8List data, int side, int quality, String mime) =>
    throw UnsupportedError('browser only');

/// Files dropped on the page go to [onDrop] while it is set (an open chat), as (name, type, bytes).
void Function(List<(String, String, Uint8List)>)? onDrop;

/// What the phone's Linked devices list calls this browser.
String deviceName() => 'Browser';
