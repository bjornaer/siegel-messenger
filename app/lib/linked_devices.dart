import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'l10n/app_localizations.dart';
import 'onboarding.dart' show showError;
import 'safety.dart' show ScanScreen;
import 'src/rust/api/core.dart';
import 'themes.dart';

/// M8: the name a link QR code carries (`siegel-link:<id>.<recipient>.<name>`), or null.
String? linkName(String qr) {
  if (!qr.startsWith('siegel-link:')) return null;
  final parts = qr.substring('siegel-link:'.length).split('.');
  if (parts.length != 3) return null;
  try {
    return utf8.decode(base64Url.decode(base64Url.normalize(parts[2])));
  } on FormatException {
    return null;
  }
}

const maxLinked = 4;

/// M8: Settings → Linked devices. The phone links up to 4 (W2) and unlinks them.
class LinkedDevicesScreen extends StatefulWidget {
  const LinkedDevicesScreen({super.key, required this.core});
  final Core core;

  @override
  State<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends State<LinkedDevicesScreen> {
  late Future<List<DeviceView>> _devices = widget.core.devices();
  bool _busy = false;

  void _reload() => setState(() {
    _devices = widget.core.devices();
  });

  Future<void> _link() async {
    final t = AppLocalizations.of(context)!;
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (code == null || !mounted) return;
    final name = linkName(code);
    if (name == null) return showError(context, const CoreError(code: 'link_invalid'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t.linkDeviceTitle(name)),
        content: Text(t.linkDeviceBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(t.linkDevice)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.core.linkDevice(qr: code);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.deviceLinked(name))));
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
      _reload();
    }
  }

  Future<void> _unlink(DeviceView d) async {
    final t = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t.unlinkTitle(d.name)),
        content: Text(t.unlinkBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t.unlink)),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await widget.core.unlinkDevice(deviceId: d.id);
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final primary = !widget.core.isLinkedDevice();
    return Scaffold(
      appBar: SiegelBar(title: Text(t.linkedDevices)),
      body: FutureBuilder(
        future: _devices,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text(t.errNetwork));
          final devices = snap.data;
          if (devices == null) return const Center(child: CircularProgressIndicator());
          final linked = devices.where((d) => d.linked).toList();
          String seen(DeviceView d) => d.lastSeenDay.isEmpty
              ? ''
              : t.lastActive(DateFormat.yMMMd(t.localeName).format(DateTime.parse(d.lastSeenDay)));
          return ListView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
            children: [
              Text(primary ? t.linkedDevicesHelp : t.thisIsLinked),
              const SizedBox(height: 8),
              for (final d in devices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(d.linked ? Icons.laptop_outlined : Icons.smartphone),
                  title: Text(d.linked ? d.name : t.mainPhone),
                  subtitle: Text([if (d.thisDevice) t.thisDevice, seen(d)].where((s) => s.isNotEmpty).join(' · ')),
                  trailing: primary && d.linked
                      ? TextButton(onPressed: _busy ? null : () => _unlink(d), child: Text(t.unlink))
                      : null,
                ),
              if (primary) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy || linked.length >= maxLinked ? null : _link,
                  icon: _busy
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.qr_code_scanner),
                  label: Text(t.linkDevice),
                ),
                if (linked.length >= maxLinked) Text(t.tooManyDevices, textAlign: TextAlign.center),
              ],
            ],
          );
        },
      ),
    );
  }
}
