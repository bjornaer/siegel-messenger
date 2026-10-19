import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'avatar.dart';
import 'chats.dart';
import 'l10n/app_localizations.dart';
import 'safety.dart';
import 'src/rust/api/core.dart';
import 'themes.dart';

/// Setting key for a muted chat: no notifications from it.
String muteKey(List<int> groupId) => 'mute.${base64Encode(groupId)}';

/// GRP-14: muted always, or until a time (`until:<ms>`). `on` is the old always.
bool isMuted(Core core, List<int> groupId) {
  final v = core.setting(key: muteKey(groupId));
  if (v == 'on' || v == 'always') return true;
  final until = int.tryParse(v?.replaceFirst('until:', '') ?? '');
  return until != null && DateTime.now().millisecondsSinceEpoch < until;
}

/// Archived chats leave the list and stay silent, even when new messages arrive.
String archiveKey(List<int> groupId) => 'archive.${base64Encode(groupId)}';
bool isArchived(Core core, List<int> groupId) => core.setting(key: archiveKey(groupId)) == '1';
void setArchived(Core core, List<int> groupId, bool on) =>
    core.setSetting(key: archiveKey(groupId), value: on ? '1' : '');

/// A deleted 1:1 chat stays hidden until its next message.
String hiddenKey(List<int> groupId) => 'hidden.${base64Encode(groupId)}';

/// Muted "always": not even @mentions get through (GRP-15).
bool isMutedAlways(Core core, List<int> groupId) =>
    const {'on', 'always'}.contains(core.setting(key: muteKey(groupId)));

/// Mute for 8 hours, a week or always (GRP-14), or unmute.
class MuteTile extends StatefulWidget {
  const MuteTile({super.key, required this.core, required this.groupId});
  final Core core;
  final List<int> groupId;

  @override
  State<MuteTile> createState() => _MuteTileState();
}

class _MuteTileState extends State<MuteTile> {
  void _set(String value) => setState(() => widget.core.setSetting(key: muteKey(widget.groupId), value: value));

  String _until(int ms) =>
      DateFormat.yMMMd(Localizations.localeOf(context).toString())
          .add_Hm()
          .format(DateTime.fromMillisecondsSinceEpoch(ms));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final muted = isMuted(widget.core, widget.groupId);
    final v = widget.core.setting(key: muteKey(widget.groupId)) ?? '';
    final until = int.tryParse(v.replaceFirst('until:', ''));
    final now = DateTime.now();
    return ListTile(
      leading: Icon(muted ? Icons.notifications_off_outlined : Icons.notifications_outlined),
      title: Text(t.mute),
      subtitle: muted ? Text(until != null ? t.mutedUntil(_until(until)) : t.muted) : null,
      onTap: () => showModalBottomSheet<void>(
        context: context,
        builder: (s) => SafeArea(
          child: Wrap(
            children: [
              for (final (label, value) in [
                (t.muteFor8h, 'until:${now.add(const Duration(hours: 8)).millisecondsSinceEpoch}'),
                (t.muteFor1w, 'until:${now.add(const Duration(days: 7)).millisecondsSinceEpoch}'),
                (t.muteAlways, 'always'),
                if (muted) (t.unmute, 'off'),
              ])
                ListTile(
                  title: Text(label),
                  onTap: () {
                    Navigator.pop(s);
                    _set(value);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

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
    if (c == null) return Scaffold(appBar: SiegelBar());
    final name = chatTitle(t, c);
    return Scaffold(
      appBar: SiegelBar(),
      body: ListView(
        children: [
          const SizedBox(height: 16),
          Center(
            child: Avatar(core: widget.core, account: c.peerAccount, radius: 40),
          ),
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
          MuteTile(core: widget.core, groupId: widget.groupId),
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
