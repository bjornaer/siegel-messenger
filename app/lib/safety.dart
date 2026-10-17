import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Uint8List;
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'l10n/app_localizations.dart';
import 'src/rust/api/core.dart';
import 'themes.dart';

/// CRY-12: the chat's safety number as digits and as a QR code; scanning theirs verifies.
class SafetyNumberScreen extends StatefulWidget {
  const SafetyNumberScreen({super.key, required this.core, required this.groupId, required this.name});
  final Core core;
  final Uint8List groupId;
  final String name;

  @override
  State<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends State<SafetyNumberScreen> {
  Future<void> _scan() async {
    final t = AppLocalizations.of(context)!;
    final scanned = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (scanned == null || !mounted) return;
    final ok = widget.core.verifySafetyNumber(groupId: widget.groupId, scanned: scanned);
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(ok ? t.verifiedDone : t.verifyMismatch(widget.name))));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final number = widget.core.safetyNumber(groupId: widget.groupId);
    final verified = widget.core.chats().any((c) => c.peerVerified && listEquals(c.groupId, widget.groupId));
    return Scaffold(
      appBar: SiegelBar(title: Text(t.safetyNumber)),
      body: number == null
          ? Center(child: Text(t.safetyNumberUnavailable))
          : ListView(
              padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + MediaQuery.paddingOf(context).bottom),
              children: [
                Center(
                  child: ColoredBox(
                    color: Colors.white, // scanners need dark-on-light, also in dark mode
                    child: QrImageView(data: number, size: 220, semanticsLabel: t.safetyNumber),
                  ),
                ),
                const SizedBox(height: 24),
                // 12 groups of 5 digits, the way people read them out to each other.
                Text(
                  [for (var i = 0; i < 60; i += 5) number.substring(i, i + 5)].join('  '),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontFamily: 'monospace', height: 1.8),
                ),
                const SizedBox(height: 16),
                if (verified)
                  ListTile(leading: const Icon(Icons.verified_user), title: Text(t.verified))
                else
                  Text(t.safetyNumberHelp(widget.name)),
                const SizedBox(height: 16),
                FilledButton.icon(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), label: Text(t.scanCode)),
              ],
            ),
    );
  }
}

/// Camera QR reader (zxing-cpp, on device). Pops with the first code read.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: SiegelBar(title: Text(AppLocalizations.of(context)!.scanCode)),
    body: ReaderWidget(
      codeFormat: Format.qrCode,
      showGallery: false,
      showToggleCamera: false,
      onScan: (code) {
        if (_done || !code.isValid || code.text == null) return;
        _done = true;
        Navigator.of(context).pop(code.text);
      },
    ),
  );
}
