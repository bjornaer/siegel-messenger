import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;

/// M8: the few things only a browser has. Phones (and tests) get these no-op stand-ins; the
/// web build swaps in browser_web.dart.

/// The core, already started by the page (web/siegel_core.js); phones load it themselves.
Future<ExternalLibrary?> coreLibrary() async => null;
String? load(String key) => null;
void save(String key, String? value) {}
void reload() {}
void openUrl(String url) {}

/// What the phone's Linked devices list calls this browser.
String deviceName() => 'Browser';
