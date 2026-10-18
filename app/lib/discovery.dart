import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import 'chats.dart' show ChatScreen, ChatService;
import 'l10n/app_localizations.dart';
import 'links.dart' show appChannel;
import 'onboarding.dart' show showError;
import 'src/rust/api/core.dart';
import 'themes.dart';

/// The country numbers without a +prefix belong to: our own number's, else the phone's region.
IsoCode? phoneRegion(Core core) {
  final mine = core.myPhone();
  if (mine != null && mine.isNotEmpty) {
    try {
      return PhoneNumber.parse(mine).isoCode;
    } on PhoneNumberException {
      // fall through
    }
  }
  final region = PlatformDispatcher.instance.locale.countryCode;
  return IsoCode.values.where((c) => c.name == region).firstOrNull;
}

/// E.164 for a number as typed in the address book, or null if it isn't a valid number.
String? toE164(String raw, IsoCode? region) {
  try {
    final p = PhoneNumber.parse(raw, callerCountry: region);
    return p.isValid() ? p.international : null;
  } on PhoneNumberException {
    return null;
  }
}

/// DISC-03: "Let people who have my number find me". Off by default.
class DiscoverableTile extends StatefulWidget {
  const DiscoverableTile({super.key, required this.core});
  final Core core;

  @override
  State<DiscoverableTile> createState() => _DiscoverableTileState();
}

class _DiscoverableTileState extends State<DiscoverableTile> {
  bool? _on;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.core.discoverable().then((on) {
      if (mounted) setState(() => _on = on);
    }, onError: (Object _) {});
  }

  /// Accounts from before the number was kept on the phone: ask for it. The server checks it.
  Future<bool> _ensurePhone(AppLocalizations t) async {
    final mine = widget.core.myPhone();
    if (mine != null && mine.isNotEmpty) return true;
    final field = TextEditingController();
    final number = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t.myNumberTitle),
        content: TextField(
          controller: field,
          autofocus: true,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(hintText: t.phoneHint, helperText: t.myNumberHelp),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(d, field.text), child: Text(t.save)),
        ],
      ),
    );
    if (number == null || !mounted) return false;
    final e164 = toE164(number, phoneRegion(widget.core));
    if (e164 == null) {
      showError(context, CoreError(code: 'phone_invalid'));
      return false;
    }
    widget.core.setMyPhone(phone: e164);
    return true;
  }

  Future<void> _set(bool on) async {
    final t = AppLocalizations.of(context)!;
    if (on && !await _ensurePhone(t)) return;
    setState(() => _busy = true);
    try {
      await widget.core.setDiscoverable(enabled: on);
      if (mounted) setState(() => _on = on);
    } on CoreError catch (e) {
      if (e.code == 'phone_mismatch') widget.core.setMyPhone(phone: ''); // ask again next time
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: const Icon(Icons.contact_phone_outlined),
      title: Text(t.discoverable),
      subtitle: Text(t.discoverableHelp),
      value: _on ?? false,
      onChanged: _on == null || _busy ? null : _set,
    );
  }
}

/// DISC-04..07: which of the phone's contacts use Siegel and can be found by number.
class FindContactsScreen extends StatefulWidget {
  const FindContactsScreen({super.key, required this.core, required this.service});
  final Core core;
  final ChatService service;

  @override
  State<FindContactsScreen> createState() => _FindContactsScreenState();
}

class _FindContactsScreenState extends State<FindContactsScreen> {
  bool _busy = false;
  bool _denied = false;

  /// (name from the address book, @username), once checked.
  List<(String, String)>? _found;

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _denied = false;
    });
    try {
      final rows = await appChannel.invokeListMethod<List<Object?>>('contacts');
      if (rows == null) {
        setState(() => _denied = true);
        return;
      }
      final region = phoneRegion(widget.core);
      final names = <String, String>{};
      for (final r in rows) {
        final e164 = toE164(r[1] as String, region);
        if (e164 != null) names.putIfAbsent(e164, () => r[0] as String);
      }
      final found = await widget.core.findContacts(numbers: names.keys.toList());
      final list = [for (final f in found) (names[f.phone] ?? f.phone, f.username)]
        ..sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
      if (mounted) setState(() => _found = list);
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chat(String username) async {
    setState(() => _busy = true);
    try {
      final id = await widget.core.startChat(username: username);
      widget.service.refresh();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(core: widget.core, service: widget.service, groupId: id),
        ),
      );
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final found = _found;
    return Scaffold(
      appBar: SiegelBar(title: Text(t.findContacts)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (found == null) ...[
            Text(t.findContactsIntro),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.contacts_outlined),
              label: Text(t.checkContacts),
              onPressed: _busy ? null : _check,
            ),
            if (_denied) ...[const SizedBox(height: 16), Text(t.contactsDenied)],
          ] else if (found.isEmpty)
            Text(t.noContactsFound)
          else
            for (final (name, username) in found)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase())),
                title: Text(name),
                subtitle: Text('@$username'),
                trailing: FilledButton.tonal(onPressed: _busy ? null : () => _chat(username), child: Text(t.startChat)),
              ),
        ],
      ),
    );
  }
}
