import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'browser.dart' if (dart.library.js_interop) 'browser_web.dart' as browser;
import 'l10n/app_localizations.dart';
import 'src/rust/api/core.dart';

/// A QR code on a white quiet zone, its squares on whole screen pixels: blurred seams between
/// them are what a camera trips on, most of all reading a laptop screen.
class SharpQr extends StatelessWidget {
  const SharpQr({super.key, required this.data, required this.size, required this.label});
  final String data;
  final double size;
  final String label;

  @override
  Widget build(BuildContext context) {
    const quiet = 16.0; // 4 modules or more of white around it, as scanners expect
    final n = QrValidator.validate(data: data).qrCode?.moduleCount ?? 0;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final inner = size - 2 * quiet;
    final drawn = n == 0 ? inner : (inner * dpr / n).floorToDouble() / dpr * n;
    return ColoredBox(
      color: Colors.white, // dark on light, also in dark mode
      child: Padding(
        padding: EdgeInsets.all(quiet + (inner - drawn) / 2),
        child: QrImageView(data: data, size: drawn, padding: EdgeInsets.zero, semanticsLabel: label),
      ),
    );
  }
}

/// Talks to the Android side: the link the app was opened with, and the share sheet.
const appChannel = MethodChannel('siegel/app');

const serverUrl = String.fromEnvironment('SIEGEL_SERVER', defaultValue: 'https://siegel.schlk.in');
const sourceUrl = 'https://github.com/bjornaer/siegel-messenger';

/// The Android app (not the web app, M8): `dart:io`'s Platform throws in a browser.
bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// A web page, in the browser (Android's own, or a new tab of the web app's).
void openUrl(String url) => kIsWeb ? browser.openUrl(url) : appChannel.invokeMethod<void>('open', url);

/// Our public pages: /terms, /guidelines, /privacy.
void openPage(String path) => openUrl('$serverUrl$path');

/// DISC-08: is this one of our contact links?
bool isContactLink(String s) => s.contains('/u/') && s.contains('#');

/// GRP-16: a group invite link?
bool isGroupLink(String s) => s.contains('/g/') && s.contains('#');

/// A link as a QR code, with Copy and Share.
void showLinkDialog(BuildContext context, String title, String link, String help) {
  final t = AppLocalizations.of(context)!;
  showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A fixed size: dialogs measure their content, which the QR widget can't report.
          SizedBox.square(
            dimension: 220,
            child: SharpQr(data: link, size: 220, label: title),
          ),
          const SizedBox(height: 12),
          Text(help),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: link));
            Navigator.pop(d);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.copied)));
          },
          child: Text(t.copy),
        ),
        FilledButton(onPressed: () => shareText(link), child: Text(t.share)),
      ],
    ),
  );
}

/// GRP-16: shows the group behind a link and joins it on confirmation. Returns the chat ID.
Future<Uint8List?> joinGroupByLink(BuildContext context, Core core, String link) async {
  final t = AppLocalizations.of(context)!;
  final preview = await core.previewGroupLink(link: link);
  if (!context.mounted) return null;
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(t.joinGroupTitle(preview.name)),
      content: Text(t.membersCount(preview.members)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.cancel)),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(t.join)),
      ],
    ),
  );
  if (ok != true) return null;
  return core.joinGroupLink(link: link);
}

/// The share sheet; a browser has none, so there the text is copied instead.
void shareText(String text) =>
    kIsWeb ? Clipboard.setData(ClipboardData(text: text)) : appChannel.invokeMethod<void>('share', text);

/// DISC-08, DISC-02: our own link as a QR code, to share, copy, reset or turn off. Shown in
/// the profile area of Settings.
class MyLinkTile extends StatefulWidget {
  const MyLinkTile({super.key, required this.core});
  final Core core;

  @override
  State<MyLinkTile> createState() => _MyLinkTileState();
}

class _MyLinkTileState extends State<MyLinkTile> {
  void _show(String link) {
    final t = AppLocalizations.of(context)!;
    showLinkDialog(context, t.myLink, link, t.myLinkHelp);
  }

  Future<void> _reset() async {
    final t = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t.resetLink),
        content: Text(t.resetLinkBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(t.resetLink)),
        ],
      ),
    );
    if (ok == true) setState(() => widget.core.resetContactLink());
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final link = widget.core.contactLink();
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.qr_code_2),
          title: Text(t.myLink),
          subtitle: Text(t.myLinkSubtitle),
          value: link != null,
          onChanged: (on) => setState(() => widget.core.setContactLink(enabled: on)),
        ),
        if (link != null)
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                icon: const Icon(Icons.qr_code),
                label: Text(t.showLink),
                onPressed: () => _show(link),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.share_outlined),
                label: Text(t.share),
                onPressed: () => shareText(link),
              ),
              TextButton(onPressed: _reset, child: Text(t.resetLink)),
            ],
          ),
      ],
    );
  }
}
