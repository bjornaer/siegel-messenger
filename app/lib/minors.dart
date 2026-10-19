import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import 'l10n/app_localizations.dart';
import 'src/rust/api/core.dart';
import 'themes.dart';

/// M7 part 2: the birth month and year stay on this phone (encrypted settings, "YYYY-MM").
/// The server only learns "under 18", and only while it's true.
const birthKey = 'birth';

/// CMP-02: the minimum age by calling code; elsewhere 16.
const minAgeByCallingCode = {'34': 14};
const defaultMinAge = 16;

int minAgeFor(String? callingCode) => minAgeByCallingCode[callingCode] ?? defaultMinAge;

int minAgeOf(Core core) {
  final phone = core.myPhone();
  if (phone == null || phone.isEmpty) return defaultMinAge;
  try {
    return minAgeFor(PhoneNumber.parse(phone).countryCode);
  } on PhoneNumberException {
    return defaultMinAge;
  }
}

/// Whole years at [now]. Without the day, a birthday in the current month counts as not yet
/// reached: never older than the person is.
int ageAt(DateTime now, int year, int month) => now.year - year - (month >= now.month ? 1 : 0);

(int, int)? birthOf(Core core) {
  final parts = (core.setting(key: birthKey) ?? '').split('-');
  if (parts.length != 2) return null;
  final (y, m) = (int.tryParse(parts[0]), int.tryParse(parts[1]));
  return y == null || m == null ? null : (y, m);
}

int? ageOf(Core core, [DateTime? now]) {
  final b = birthOf(core);
  return b == null ? null : ageAt(now ?? DateTime.now(), b.$1, b.$2);
}

void setBirth(Core core, int year, int month) =>
    core.setSetting(key: birthKey, value: '$year-${month.toString().padLeft(2, '0')}');

/// Tells the server when the account turns (or stops being) under 18. Under 18, group adds
/// are locked to contacts.
Future<void> syncMinor(Core core) async {
  final age = ageOf(core);
  if (age == null) return;
  final minor = age < 18;
  if (minor) core.setSetting(key: 'group_adds', value: 'contacts');
  if (core.minor() == minor) return;
  try {
    await core.setMinor(minor: minor);
  } on CoreError {
    // Offline: tried again at the next start.
  }
}

/// Month and year pickers for the birth date.
class BirthDateFields extends StatelessWidget {
  const BirthDateFields({super.key, required this.year, required this.month, required this.onChanged});
  final int? year;
  final int? month;
  final void Function(int? year, int? month) onChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final now = DateTime.now().year;
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<int>(
            initialValue: month,
            decoration: InputDecoration(labelText: t.birthMonth),
            items: [
              for (var i = 1; i <= 12; i++)
                DropdownMenuItem(value: i, child: Text(DateFormat.MMMM(t.localeName).format(DateTime(2000, i)))),
            ],
            onChanged: (v) => onChanged(year, v),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<int>(
            initialValue: year,
            decoration: InputDecoration(labelText: t.birthYear),
            items: [for (var y = now; y >= now - 100; y--) DropdownMenuItem(value: y, child: Text('$y'))],
            onChanged: (v) => onChanged(v, month),
          ),
        ),
      ],
    );
  }
}

/// Accounts from before birth dates were asked: ask once, then keep the "under 18" flag current.
class BirthDateGate extends StatefulWidget {
  const BirthDateGate({super.key, required this.core, required this.child, required this.onDelete});
  final Core core;
  final Widget child;
  final Future<void> Function(BuildContext) onDelete;

  @override
  State<BirthDateGate> createState() => _BirthDateGateState();
}

class _BirthDateGateState extends State<BirthDateGate> {
  int? _year;
  int? _month;

  @override
  void initState() {
    super.initState();
    unawaited(syncMinor(widget.core));
  }

  @override
  Widget build(BuildContext context) {
    final age = ageOf(widget.core);
    final min = minAgeOf(widget.core);
    if (age != null && age >= min) return widget.child;
    final t = AppLocalizations.of(context)!;
    final tooYoung = age != null;
    return Scaffold(
      appBar: SiegelBar(title: Text(t.birthTitle)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (tooYoung) ...[
            Text(t.tooYoung(min)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: () => widget.onDelete(context), child: Text(t.deleteAccount)),
          ] else ...[
            Text(t.birthWhy),
            const SizedBox(height: 16),
            BirthDateFields(
              year: _year,
              month: _month,
              onChanged: (y, m) => setState(() {
                _year = y;
                _month = m;
              }),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _year == null || _month == null
                  ? null
                  : () {
                      setBirth(widget.core, _year!, _month!);
                      unawaited(syncMinor(widget.core));
                      setState(() {});
                    },
              child: Text(t.save),
            ),
          ],
        ],
      ),
    );
  }
}
