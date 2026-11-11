import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'browser.dart' if (dart.library.js_interop) 'browser_web.dart' as browser;
import 'l10n/app_localizations.dart';
import 'links.dart';
import 'src/rust/api/core.dart';

/// A shared location travels as an ordinary text message with a map link, so older apps show a
/// link that opens a map. No map is drawn here: loading tiles would tell a map server where it is.
/// A live one carries `&live=<end, Unix seconds>` (OpenStreetMap ignores it) and is edited with
/// each new position until then.
typedef Location = ({double lat, double lon});

String locationText(Location l, {DateTime? until}) {
  final lat = l.lat.toStringAsFixed(5), lon = l.lon.toStringAsFixed(5);
  final live = until == null ? '' : '&live=${until.millisecondsSinceEpoch ~/ 1000}';
  return '📍 https://www.openstreetmap.org/?mlat=$lat&mlon=$lon$live#map=17/$lat/$lon';
}

final _shared = RegExp(
  r'^📍 https://www\.openstreetmap\.org/\?mlat=(-?\d{1,2}\.\d+)&mlon=(-?\d{1,3}\.\d+)(?:&live=(\d{1,12}))?#map=\S+$',
);

/// The location in a message that only shares one, else null.
Location? locationOf(String text) {
  final m = _shared.firstMatch(text);
  if (m == null) return null;
  final lat = double.parse(m[1]!), lon = double.parse(m[2]!);
  return lat.abs() <= 90 && lon.abs() <= 180 ? (lat: lat, lon: lon) : null;
}

/// When a live location stops updating; null for a one-off location.
DateTime? liveUntil(String text) {
  final s = _shared.firstMatch(text)?[3];
  return s == null ? null : DateTime.fromMillisecondsSinceEpoch(int.parse(s) * 1000);
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

/// Live locations this phone is sharing now, by message ID (base64).
final liveSharing = ValueNotifier<Set<String>>(const {});

class _Live {
  _Live(this.group, this.id, this.until, this.last);
  final Uint8List group, id;
  final DateTime until;
  Location last;
  Timer? timer;
  Future<void> pending = Future.value(); // one update at a time, so a stop can't be overtaken
}

final _live = <String, _Live>{};
const liveEvery = Duration(seconds: 30);

/// Sends [first] as a live location and edits it with a fresh position every 30 seconds until
/// [length] is up (at most 15 minutes: the edit window, MSG-09, so older apps follow it too).
/// An ongoing notification keeps the app running meanwhile.
Future<void> shareLive(
  Core core,
  Uint8List groupId,
  Location first,
  Duration length, {
  required String notice,
  required VoidCallback changed,
}) async {
  final until = DateTime.now().add(length);
  final m = await core.sendText(
    groupId: groupId,
    text: locationText(first, until: until),
    mentions: const [],
  );
  final key = base64Encode(m.messageId);
  final live = _live[key] = _Live(groupId, m.messageId, until, first);
  await appChannel.invokeMethod<void>('liveStart', notice);
  liveSharing.value = {...liveSharing.value, key};
  live.timer = Timer.periodic(liveEvery, (_) {
    if (!DateTime.now().isBefore(until.subtract(const Duration(seconds: 5)))) {
      unawaited(stopLive(core, m.messageId, changed: changed)); // its end time says it ended
      return;
    }
    live.pending = live.pending.then((_) async {
      final here = await currentLocation();
      if (here == null || _live[key] != live) return; // no fix this time, or stopped meanwhile
      live.last = here.$1;
      try {
        await core.edit(
          groupId: groupId,
          messageId: m.messageId,
          text: locationText(here.$1, until: until),
        );
        changed();
      } on CoreError catch (e) {
        debugPrint('live location: ${e.code}'); // the next update tries again
      }
    });
  });
}

/// Stops a live location. [early]: before its time, so it's edited to end now.
Future<void> stopLive(Core core, Uint8List messageId, {bool early = false, required VoidCallback changed}) async {
  final key = base64Encode(messageId);
  final live = _live.remove(key);
  if (live == null) return;
  live.timer?.cancel();
  liveSharing.value = {...liveSharing.value}..remove(key);
  if (_live.isEmpty) await appChannel.invokeMethod<void>('liveStop');
  await live.pending;
  if (early) {
    try {
      await core.edit(
        groupId: live.group,
        messageId: live.id,
        text: locationText(live.last, until: DateTime.now()),
      );
    } on CoreError catch (e) {
      debugPrint('live location stop: ${e.code}');
    }
  }
  changed();
}

class LocationMessage extends StatelessWidget {
  const LocationMessage(this.location, {super.key, this.until, this.onStop});
  final Location location;

  /// A live location's end.
  final DateTime? until;

  /// Ours, still being shared from this phone.
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final l = location;
    final end = until;
    final live = end != null && DateTime.now().isBefore(end);
    return InkWell(
      onTap: () => openLocation(l),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(end == null ? Icons.location_on : Icons.share_location, size: 40),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(end == null ? t.location : t.liveLocation, style: const TextStyle(fontWeight: FontWeight.bold)),
                if (end != null)
                  Text(
                    live
                        ? t.liveUntil(DateFormat.Hm(Localizations.localeOf(context).toString()).format(end))
                        : t.liveEnded,
                  ),
                Text('${l.lat.toStringAsFixed(5)}, ${l.lon.toStringAsFixed(5)}'),
                Text(t.openInMaps, style: const TextStyle(decoration: TextDecoration.underline)),
                if (live && onStop != null) TextButton(onPressed: onStop, child: Text(t.stopSharing)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
