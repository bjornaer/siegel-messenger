import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'l10n/app_localizations.dart';
import 'onboarding.dart' show showError;
import 'src/rust/api/core.dart';
import 'themes.dart';

/// RM-01: everything the server holds about this account (CMP-06), fetched live, in plain words.
class ServerDataScreen extends StatefulWidget {
  const ServerDataScreen({super.key, required this.core});
  final Core core;

  @override
  State<ServerDataScreen> createState() => _ServerDataScreenState();
}

class _ServerDataScreenState extends State<ServerDataScreen> {
  ServerData? _data;

  @override
  void initState() {
    super.initState();
    widget.core.serverData().then(
      (d) {
        if (mounted) setState(() => _data = d);
      },
      onError: (Object e) {
        if (!mounted) return;
        if (e is CoreError) showError(context, e);
        Navigator.of(context).pop();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final d = _data;
    String day(String s) => s.isEmpty ? t.none : DateFormat.yMMMd(t.localeName).format(DateTime.parse(s));
    String short(String hex) => hex.length > 16 ? '${hex.substring(0, 16)}…' : hex;
    Widget row(String title, String value) =>
        ListTile(contentPadding: EdgeInsets.zero, title: Text(title), subtitle: Text(value));
    Widget heading(String s) => Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 4),
      child: Text(s, style: Theme.of(context).textTheme.titleMedium),
    );
    return Scaffold(
      appBar: SiegelBar(title: Text(t.skTitle)),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
              children: [
                Text(t.skIntro),
                heading(t.skAccount),
                row(t.skCreated, day(d.createdDay)),
                row(t.skPhone, d.phoneHash.isEmpty ? t.none : t.skPhoneHash(short(d.phoneHash))),
                if (d.numberChangedDay.isNotEmpty) row(t.skNumberChanged, day(d.numberChangedDay)),
                row(
                  t.skUsername,
                  d.username.isEmpty ? t.none : t.skUsernameSince(d.username, day(d.usernameClaimedDay)),
                ),
                if (d.releasedUsernames.isNotEmpty) row(t.skReleased, d.releasedUsernames.map((u) => '@$u').join(', ')),
                row(t.skIdentityKey, t.skIdentityKeyHelp(short(d.identityKey))),
                row(t.pinTitle, d.registrationLock ? t.skOn : t.skOff),
                heading(t.skProfile),
                row(t.skProfile, d.profile ? t.skProfileStored : t.none),
                row(t.skProfilePicture, d.profilePicture ? t.skPictureStored : t.none),
                heading(t.findContacts),
                row(t.discoverable, d.discoverable ? t.skOn : t.skOff),
                row(t.skChecked, t.skCheckedCount(d.numbersChecked)),
                heading(t.skDevices),
                for (final v in d.devices)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(v.thisDevice ? Icons.smartphone : Icons.devices_other),
                    title: Text(v.thisDevice ? t.skThisDevice : t.skOtherDevice),
                    subtitle: Text(
                      [
                        t.skLastSeen(v.ios ? 'iOS' : 'Android', day(v.lastSeenDay)),
                        t.skQueued(v.queued),
                        t.skKeys(v.keyPackages),
                        v.pushToken ? t.skPushYes : t.skPushNo,
                      ].join('\n'),
                    ),
                  ),
              ],
            ),
    );
  }
}
