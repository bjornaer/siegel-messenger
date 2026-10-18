import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'discovery.dart' show phoneRegion, toE164;
import 'l10n/app_localizations.dart';
import 'onboarding.dart' show attestationToken, showError;
import 'src/rust/api/core.dart';
import 'themes.dart';

/// Settings row: change number, or add one after another account took ours.
class ChangeNumberTile extends StatefulWidget {
  const ChangeNumberTile({super.key, required this.core});
  final Core core;

  @override
  State<ChangeNumberTile> createState() => _ChangeNumberTileState();
}

class _ChangeNumberTileState extends State<ChangeNumberTile> {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final removed = widget.core.numberRemoved();
    final phone = widget.core.myPhone();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(removed ? Icons.warning_amber : Icons.phone_outlined),
      title: Text(t.changeNumber),
      subtitle: Text(removed ? t.noNumber : (phone == null || phone.isEmpty ? t.changeNumberHelp : phone)),
      onTap: () async {
        await Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => ChangeNumberScreen(core: widget.core)));
        if (mounted) setState(() {});
      },
    );
  }
}

/// Shown once when another account proved our number (docs/change-number.md).
Future<void> showNumberRemoved(BuildContext context, Core core) {
  final t = AppLocalizations.of(context)!;
  return showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(t.numberRemovedTitle),
      content: Text(t.numberRemovedBody),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(t.later)),
        TextButton(
          onPressed: () {
            Navigator.pop(d);
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChangeNumberScreen(core: core)));
          },
          child: Text(t.changeNumber),
        ),
      ],
    ),
  );
}

/// The new number, then the SMS code (and the Registration Lock PIN if set). Same account.
class ChangeNumberScreen extends StatefulWidget {
  const ChangeNumberScreen({super.key, required this.core});
  final Core core;

  @override
  State<ChangeNumberScreen> createState() => _ChangeNumberScreenState();
}

class _ChangeNumberScreenState extends State<ChangeNumberScreen> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _pin = TextEditingController();
  String? _e164; // set once the code was sent
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run(() async {
    final e164 = toE164(_phone.text, phoneRegion(widget.core));
    if (e164 == null) throw CoreError(code: 'phone_invalid');
    await widget.core.requestOtp(
      phoneE164: e164,
      attestationToken: await attestationToken(e164),
      platform: Platform.isIOS ? DevicePlatform.ios : DevicePlatform.android,
    );
    setState(() => _e164 = e164);
  });

  Future<void> _change() => _run(() async {
    await widget.core.changeNumber(phoneE164: _e164!, otp: _code.text.trim(), pin: _pin.text.trim());
    if (!mounted) return;
    final t = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.numberChanged(_e164!))));
    Navigator.of(context).pop();
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final sent = _e164 != null;
    return Scaffold(
      appBar: SiegelBar(title: Text(t.changeNumber)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          Text(t.changeNumberHelp),
          const SizedBox(height: 16),
          TextField(
            controller: _phone,
            enabled: !sent,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: t.newNumber, hintText: t.phoneHint),
          ),
          if (!sent) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _send, child: Text(t.sendCode)),
          ] else ...[
            const SizedBox(height: 16),
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: t.codeLabel),
            ),
            if (widget.core.hasRegistrationLock()) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                decoration: InputDecoration(labelText: t.pinLabel),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _change, child: Text(t.changeNumber)),
          ],
        ],
      ),
    );
  }
}
