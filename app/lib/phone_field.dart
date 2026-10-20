import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:phone_numbers_parser/metadata.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import 'l10n/app_localizations.dart';
import 'links.dart' show appChannel;

/// Country names in the phone's language and the SIM's country, from Android (null elsewhere).
class _Countries {
  _Countries(this.sim, this.names);
  final IsoCode? sim;
  final Map<String, String> names;

  static Future<_Countries>? _loading;

  static Future<_Countries> load() => _loading ??= () async {
    try {
      final r = await appChannel.invokeMapMethod<String, Object?>('countries');
      final sim = r?['sim'] as String? ?? '';
      return _Countries(
        IsoCode.values.where((c) => c.name == sim).firstOrNull,
        (r?['names'] as Map?)?.cast<String, String>() ?? const {},
      );
    } on Object {
      return _Countries(null, const {});
    }
  }();
}

String flagOf(IsoCode c) =>
    String.fromCharCodes(c.name.toUpperCase().codeUnits.map((u) => 0x1F1E6 + u - 0x41)); // regional indicators

String callingCode(IsoCode c) => '+${metadataByIsoCode[c]?.countryCode ?? ''}';

/// A phone number with its country: a flag button (the SIM's country by default) and the number.
/// Typed with a leading + the country follows the number; otherwise it's read as a national
/// number of the chosen country, trunk prefix included (Brazil's 0 19 …, Spain's none).
/// [onChanged] gets the valid number, or null.
class PhoneNumberField extends StatefulWidget {
  const PhoneNumberField({super.key, required this.onChanged, this.label, this.initialCountry, this.enabled = true});
  final ValueChanged<PhoneNumber?> onChanged;
  final String? label;
  final IsoCode? initialCountry;
  final bool enabled;

  @override
  State<PhoneNumberField> createState() => _PhoneNumberFieldState();
}

class _PhoneNumberFieldState extends State<PhoneNumberField> {
  final _text = TextEditingController();
  IsoCode? _country;
  Map<String, String> _names = const {};
  PhoneNumber? _parsed;

  @override
  void initState() {
    super.initState();
    final region = PlatformDispatcher.instance.locale.countryCode;
    _country = widget.initialCountry ?? IsoCode.values.where((c) => c.name == region).firstOrNull;
    _Countries.load().then((c) {
      if (!mounted) return;
      setState(() {
        _names = c.names;
        if (widget.initialCountry == null && c.sim != null) _country = c.sim; // the SIM knows best
      });
      _parse();
    });
  }

  void _parse() {
    final v = _text.text.trim();
    PhoneNumber? p;
    try {
      final n = PhoneNumber.parse(v, callerCountry: _country, destinationCountry: v.startsWith('+') ? null : _country);
      if (n.isValid(type: PhoneNumberType.mobile) || n.isValid()) p = n;
    } on PhoneNumberException {
      p = null;
    }
    setState(() {
      _parsed = p;
      if (p != null && v.startsWith('+')) _country = p.isoCode; // the flag follows a typed +code
    });
    widget.onChanged(p);
  }

  String _name(IsoCode c) => _names[c.name] ?? c.name;

  Future<void> _pick() async {
    final t = AppLocalizations.of(context)!;
    final picked = await showModalBottomSheet<IsoCode>(
      context: context,
      isScrollControlled: true,
      builder: (s) => _CountryPicker(name: _name, current: _country, searchHint: t.searchCountry),
    );
    if (picked == null) return;
    setState(() => _country = picked);
    _parse();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final c = _country;
    final p = _parsed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 56,
              child: OutlinedButton(
                onPressed: widget.enabled ? _pick : null,
                child: Text(
                  c == null ? '🌐' : '${flagOf(c)} ${callingCode(c)}',
                  semanticsLabel: c == null ? t.chooseCountry : '${_name(c)} ${callingCode(c)}',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _text,
                enabled: widget.enabled,
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumber],
                decoration: InputDecoration(labelText: widget.label ?? t.phoneTitle, hintText: t.phoneHintNational),
                onChanged: (_) => _parse(),
              ),
            ),
          ],
        ),
        if (p != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              t.smsGoesTo('+${p.countryCode} ${p.formatNsn()}', _name(p.isoCode)),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _CountryPicker extends StatefulWidget {
  const _CountryPicker({required this.name, required this.current, required this.searchHint});
  final String Function(IsoCode) name;
  final IsoCode? current;
  final String searchHint;

  @override
  State<_CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<_CountryPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase().replaceAll('+', '');
    final all = IsoCode.values.where((c) => metadataByIsoCode[c] != null).toList()
      ..sort((a, b) => widget.name(a).compareTo(widget.name(b)));
    final shown = all
        .where(
          (c) =>
              q.isEmpty ||
              widget.name(c).toLowerCase().contains(q) ||
              c.name.toLowerCase() == q ||
              callingCode(c).substring(1).startsWith(q),
        )
        .toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: widget.searchHint),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (_, i) {
                  final c = shown[i];
                  return ListTile(
                    leading: Text(flagOf(c), style: const TextStyle(fontSize: 24)),
                    title: Text(widget.name(c)),
                    trailing: Text(callingCode(c)),
                    selected: c == widget.current,
                    onTap: () => Navigator.pop(context, c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
