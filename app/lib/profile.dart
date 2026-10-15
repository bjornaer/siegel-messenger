import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'chats.dart';
import 'l10n/app_localizations.dart';
import 'safety.dart';
import 'src/rust/api/core.dart';

/// Setting key for a muted chat: no notifications from it.
String muteKey(List<int> groupId) => 'mute.${base64Encode(groupId)}';

bool isMuted(Core core, List<int> groupId) => core.setting(key: muteKey(groupId)) == 'on';

/// Contact profile (section 11): name, @username, safety number, mute, block.
/// ponytail: photo comes with M4 media, report with CMP-03 (M6).
class ContactProfileScreen extends StatefulWidget {
  const ContactProfileScreen({super.key, required this.core, required this.groupId, required this.onBlock});
  final Core core;
  final Uint8List groupId;
  final VoidCallback onBlock;

  @override
  State<ContactProfileScreen> createState() => _ContactProfileScreenState();
}

class _ContactProfileScreenState extends State<ContactProfileScreen> {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final c = widget.core.chats().where((c) => listEquals(c.groupId, widget.groupId)).firstOrNull;
    if (c == null) return Scaffold(appBar: AppBar());
    final name = chatTitle(t, c);
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        children: [
          const SizedBox(height: 16),
          const Center(child: CircleAvatar(radius: 40, child: Icon(Icons.person_outline, size: 40))),
          const SizedBox(height: 12),
          Text(name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
          if (c.peerUsername != null && c.peerDisplayName != null)
            Text('@${c.peerUsername}', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ListTile(
            leading: Icon(c.peerVerified ? Icons.verified_user : Icons.shield_outlined),
            title: Text(t.safetyNumber),
            subtitle: c.peerVerified ? Text(t.verified) : null,
            onTap: () => Navigator.of(context)
                .push(
                  MaterialPageRoute<void>(
                    builder: (_) => SafetyNumberScreen(core: widget.core, groupId: widget.groupId, name: name),
                  ),
                )
                .then((_) => setState(() {})),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_off_outlined),
            title: Text(t.mute),
            value: isMuted(widget.core, widget.groupId),
            onChanged: (on) =>
                setState(() => widget.core.setSetting(key: muteKey(widget.groupId), value: on ? 'on' : 'off')),
          ),
          if (!c.request)
            ListTile(
              leading: Icon(Icons.block, color: Theme.of(context).colorScheme.error),
              title: Text(t.block, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: widget.onBlock,
            ),
        ],
      ),
    );
  }
}

/// Message info (section 11): when it was sent and how far it got. In 1:1 the peer is the only
/// recipient. ponytail: per-member states for groups come with GRP-13 (M3).
void showMessageInfo(BuildContext context, MessageView m, String peer) {
  final t = AppLocalizations.of(context)!;
  final when = DateFormat.yMMMd(Localizations.localeOf(context).toString())
      .add_Hm()
      .format(DateTime.fromMillisecondsSinceEpoch(m.sentAt));
  final state = switch (m.status) {
    MessageStatus.failed => t.notSentRetry,
    MessageStatus.sending => t.statusSending,
    MessageStatus.sent => t.statusSent,
    MessageStatus.delivered => t.statusDelivered,
    MessageStatus.read => t.statusRead,
  };
  showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(t.messageInfo),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.sentAt(when)),
          if (m.edited) Text(t.edited),
          const SizedBox(height: 12),
          Text('$peer: $state'),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(t.close))],
    ),
  );
}
