/// M8: the few things only a browser has. Phones (and tests) get these no-op stand-ins; the
/// web build swaps in browser_web.dart.
String? load(String key) => null;
void save(String key, String? value) {}
void reload() {}
void openUrl(String url) {}

/// What the phone's Linked devices list calls this browser.
String deviceName() => 'Browser';
