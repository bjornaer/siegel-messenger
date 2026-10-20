import 'package:web/web.dart' as web;

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
