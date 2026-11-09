import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'browser.dart' if (dart.library.js_interop) 'browser_web.dart' as browser;
import 'l10n/app_localizations.dart';
import 'links.dart';

/// A shared location travels as an ordinary text message with a map link, so older apps show a
/// link that opens a map. No map is drawn here: loading tiles would tell a map server where it is.
typedef Location = ({double lat, double lon});

String locationText(Location l) {
  final at = '${l.lat.toStringAsFixed(5)}/${l.lon.toStringAsFixed(5)}';
  return '📍 https://www.openstreetmap.org/?mlat=${l.lat.toStringAsFixed(5)}&mlon=${l.lon.toStringAsFixed(5)}#map=17/$at';
}

final _shared = RegExp(r'^📍 https://www\.openstreetmap\.org/\?mlat=(-?\d{1,2}\.\d+)&mlon=(-?\d{1,3}\.\d+)#map=\S+$');

/// The location in a message that only shares one, else null.
Location? locationOf(String text) {
  final m = _shared.firstMatch(text);
  if (m == null) return null;
  final lat = double.parse(m[1]!), lon = double.parse(m[2]!);
  return lat.abs() <= 90 && lon.abs() <= 180 ? (lat: lat, lon: lon) : null;
}

/// This device's position and its accuracy in metres; null without permission or a fix.
Future<(Location, double)?> currentLocation() async {
  final r = kIsWeb ? await browser.location() : await appChannel.invokeListMethod<double>('location');
  return r == null ? null : ((lat: r[0], lon: r[1]), r[2]);
}

/// The phone's maps app (any that handles geo:), or the map page in a browser.
Future<void> openLocation(Location l) async {
  final page = locationText(l).substring(3);
  if (kIsWeb) return openUrl(page);
  try {
    await appChannel.invokeMethod<void>('open', 'geo:${l.lat},${l.lon}?q=${l.lat},${l.lon}');
  } on PlatformException {
    openUrl(page);
  }
}

class LocationMessage extends StatelessWidget {
  const LocationMessage(this.location, {super.key});
  final Location location;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final l = location;
    return InkWell(
      onTap: () => openLocation(l),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.location_on, size: 40),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.location, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('${l.lat.toStringAsFixed(5)}, ${l.lon.toStringAsFixed(5)}'),
                Text(t.openInMaps, style: const TextStyle(decoration: TextDecoration.underline)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
