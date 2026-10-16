import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'l10n/app_localizations.dart';
import 'src/rust/api/core.dart';

/// Talks to the Android side: the link the app was opened with, and the share sheet.
const appChannel = MethodChannel('siegel/app');

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
            child: ColoredBox(
              color: Colors.white, // scanners need dark on light, also in dark mode
              child: QrImageView(data: link, size: 220, semanticsLabel: title),
            ),
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

void shareText(String text) => appChannel.invokeMethod<void>('share', text);

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
