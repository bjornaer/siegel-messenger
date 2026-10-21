import 'dart:js_interop';

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
