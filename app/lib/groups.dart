import 'format.dart';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'avatar.dart';
import 'chats.dart';
import 'l10n/app_localizations.dart';
import 'links.dart';
import 'onboarding.dart' show showError;
import 'profile.dart';
import 'src/rust/api/core.dart';
import 'themes.dart';

/// A member's name for bubbles and system lines.
String memberName(AppLocalizations t, Core core, List<int> account, {List<int>? me}) {
  if (me != null && listEquals(account, me)) return t.you;
  if (account.isEmpty) return t.someone;
  return core.memberName(account: account) ?? t.newContact;
}

/// Our account in a group, if we're still in it.
List<int>? myAccount(Core core, List<int> groupId) {
  try {
    return core.groupInfo(groupId: groupId).members.firstWhere((m) => m.me).account;
  } on Object {
    return null;
  }
}

/// GRP-12: one system line as text.
String groupEventText(AppLocalizations t, Core core, GroupEventView e, List<int>? me) {
  final actor = memberName(t, core, e.actor, me: me);
  final targets = e.targets.map((a) => memberName(t, core, a, me: me)).join(', ');
  return switch (e.kind) {
    GroupEventKind.created => t.evCreated(actor),
    GroupEventKind.added => t.evAdded(actor, targets),
    GroupEventKind.removed => t.evRemoved(actor, targets),
    GroupEventKind.left => t.evLeft(actor),
    GroupEventKind.renamed => t.evRenamed(actor, e.name),
    GroupEventKind.adminAdded => t.evAdminAdded(actor, targets),
    GroupEventKind.adminRemoved => t.evAdminRemoved(actor, targets),
    GroupEventKind.settings => t.evSettings(actor),
    GroupEventKind.avatar => t.evAvatar(actor),
  };
}

/// Runs a core call; CoreErrors become snackbars. Returns whether it succeeded.
Future<bool> _try(BuildContext context, Future<void> Function() f) async {
  try {
    await f();
    return true;
  } on CoreError catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

String _clean(String u) => u.trim().replaceFirst(RegExp('^@'), '').toLowerCase();

/// GRP-01: name the group and pick people by @username.
class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key, required this.core, required this.service});
  final Core core;
  final ChatService service;

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _name = TextEditingController();
  final _person = TextEditingController();
  final _people = <String>[];
  bool _busy = false;

  void _add() {
    final u = _clean(_person.text);
    if (u.isEmpty || _people.contains(u)) return;
    setState(() => _people.add(u));
    _person.clear();
  }

  Future<void> _create() async {
    _add();
    setState(() => _busy = true);
    late List<int> id;
    final ok = await _try(context, () async {
      id = await widget.core.createGroup(name: _name.text.trim(), usernames: _people);
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    widget.service.refresh();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(core: widget.core, service: widget.service, groupId: Uint8List.fromList(id)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: SiegelBar(title: Text(t.newGroup)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 64,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: t.groupName),
            onChanged: (_) => setState(() {}),
          ),
          _AddPerson(controller: _person, onAdd: _add),
          Wrap(
            spacing: 8,
            children: [
              for (final p in _people)
                InputChip(label: Text('@$p'), onDeleted: () => setState(() => _people.remove(p))),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || _name.text.trim().isEmpty || (_people.isEmpty && _person.text.trim().isEmpty)
                ? null
                : _create,
            child: Text(t.create),
          ),
        ],
      ),
    );
  }
}

class _AddPerson extends StatelessWidget {
  const _AddPerson({required this.controller, required this.onAdd});
  final TextEditingController controller;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            autocorrect: false,
            decoration: InputDecoration(labelText: t.addPeople, hintText: t.addPeopleHint),
            onSubmitted: (_) => onAdd(),
          ),
        ),
        IconButton(tooltip: t.add, icon: const Icon(Icons.person_add_alt_1), onPressed: onAdd),
      ],
    );
  }
}

/// Section 8: name, members and roles, admin settings, mute and leave.
class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({super.key, required this.core, required this.service, required this.groupId});
  final Core core;
  final ChatService service;
  final Uint8List groupId;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  bool _busy = false;
  Core get core => widget.core;

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    await _try(context, f);
    if (!mounted) return;
    setState(() => _busy = false);
    widget.service.refresh();
  }

  Future<String?> _ask(String title, String label, {String initial = ''}) {
    final t = AppLocalizations.of(context)!;
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(d, c.text), child: Text(t.save)),
        ],
      ),
    );
  }

  void _memberActions(GroupInfoView g, GroupMemberView m) {
    final t = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      builder: (s) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(m.admin ? Icons.remove_moderator_outlined : Icons.add_moderator_outlined),
              title: Text(m.admin ? t.removeAdmin : t.makeAdmin),
              onTap: () {
                Navigator.pop(s);
                _run(() => core.setAdmin(groupId: widget.groupId, account: m.account, admin: !m.admin));
              },
            ),
            ListTile(
              leading: Icon(Icons.person_remove_outlined, color: Theme.of(context).colorScheme.error),
              title: Text(t.removeFromGroup),
              onTap: () {
                Navigator.pop(s);
                _run(() => core.removeMember(groupId: widget.groupId, account: m.account));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// GRP-16: admins create, show and revoke invite links.
  List<Widget> _inviteLinks(AppLocalizations t) {
    List<GroupLinkView> links;
    try {
      links = core.groupLinks(groupId: widget.groupId);
    } on Object {
      links = [];
    }
    final date = DateFormat.yMMMd(Localizations.localeOf(context).toString());
    return [
      const Divider(),
      ListTile(title: Text(t.inviteLinks, style: Theme.of(context).textTheme.titleSmall)),
      for (final l in links)
        ListTile(
          leading: const Icon(Icons.link),
          title: Text(t.expiresOn(date.format(DateTime.fromMillisecondsSinceEpoch(asInt(l.expires) * 1000)))),
          onTap: () => showLinkDialog(context, t.inviteLinks, l.link, t.inviteLinkHelp),
          trailing: TextButton(
            onPressed: _busy ? null : () => _run(() => core.revokeGroupLink(groupId: widget.groupId, id: l.id)),
            child: Text(t.revoke),
          ),
        ),
      ListTile(
        leading: const Icon(Icons.add_link),
        title: Text(t.newInviteLink),
        enabled: !_busy,
        onTap: () async {
          String? link;
          await _run(() async => link = await core.createGroupLink(groupId: widget.groupId));
          if (link != null && mounted) showLinkDialog(context, t.inviteLinks, link!, t.inviteLinkHelp);
        },
      ),
    ];
  }

  Future<void> _leave() async {
    final t = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t.leaveGroup),
        content: Text(t.leaveGroupBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(t.leaveGroup)),
        ],
      ),
    );
    if (ok == true && mounted) await _run(() => core.leaveGroup(groupId: widget.groupId));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final chat = core.chats().where((c) => listEquals(c.groupId, widget.groupId)).firstOrNull;
        GroupInfoView? g;
        try {
          if (chat != null && !chat.left) g = core.groupInfo(groupId: widget.groupId);
        } on CoreError {
          g = null;
        }
        final canEdit = g != null && (g.meAdmin || !g.adminsOnlyInfo);
        final canAdd = g != null && (g.meAdmin || !g.adminsOnlyAdd);
        return Scaffold(
          appBar: SiegelBar(title: Text(t.groupInfo)),
          body: ListView(
            children: [
              const SizedBox(height: 16),
              Center(
                child: canEdit
                    ? AvatarEditor(core: core, groupId: widget.groupId, onChanged: widget.service.refresh)
                    : Avatar(core: core, groupId: widget.groupId, radius: 40),
              ),
              const SizedBox(height: 12),
              Text(
                g?.name ?? chat?.groupName ?? t.group,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (g != null) Text(t.membersCount(g.members.length), textAlign: TextAlign.center),
              if (chat?.left ?? false)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(t.leftGroup, textAlign: TextAlign.center),
                ),
              if (canEdit)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(t.rename),
                  enabled: !_busy,
                  onTap: () async {
                    final name = await _ask(t.rename, t.groupName, initial: g!.name);
                    if (name != null && name.trim().isNotEmpty) {
                      await _run(() => core.renameGroup(groupId: widget.groupId, name: name));
                    }
                  },
                ),
              if (canAdd)
                ListTile(
                  leading: const Icon(Icons.person_add_alt_1),
                  title: Text(t.addPeople),
                  enabled: !_busy,
                  onTap: () async {
                    final u = await _ask(t.addPeople, t.usernameLabel);
                    if (u != null && _clean(u).isNotEmpty) {
                      await _run(() => core.addMembers(groupId: widget.groupId, usernames: [_clean(u)]));
                    }
                  },
                ),
              if (g != null)
                for (final m in g.members)
                  ListTile(
                    leading: Avatar(core: widget.core, account: m.me ? null : m.account),
                    title: Text(m.me ? t.you : m.displayName ?? (m.username == null ? t.newContact : '@${m.username}')),
                    subtitle: m.displayName != null && m.username != null ? Text('@${m.username}') : null,
                    trailing: m.admin ? Text(t.admin) : null,
                    onTap: g.meAdmin && !m.me && !_busy ? () => _memberActions(g!, m) : null,
                  ),
              if (g != null && g.meAdmin) ...[
                const Divider(),
                SwitchListTile(
                  title: Text(t.onlyAdminsEditInfo),
                  value: g.adminsOnlyInfo,
                  onChanged: _busy
                      ? null
                      : (v) => _run(
                          () => core.setGroupSettings(
                            groupId: widget.groupId,
                            adminsOnlyInfo: v,
                            adminsOnlyAdd: g!.adminsOnlyAdd,
                          ),
                        ),
                ),
                SwitchListTile(
                  title: Text(t.onlyAdminsAdd),
                  value: g.adminsOnlyAdd,
                  onChanged: _busy
                      ? null
                      : (v) => _run(
                          () => core.setGroupSettings(
                            groupId: widget.groupId,
                            adminsOnlyInfo: g!.adminsOnlyInfo,
                            adminsOnlyAdd: v,
                          ),
                        ),
                ),
              ],
              if (g != null && g.meAdmin) ..._inviteLinks(t),
              const Divider(),
              MuteTile(core: core, groupId: widget.groupId),
              if (g != null)
                ListTile(
                  leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
                  title: Text(t.leaveGroup, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  enabled: !_busy,
                  onTap: _leave,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// GRP-13: delivered and read per member, for one of our messages.
void showGroupMessageInfo(BuildContext context, Core core, MessageView m) {
  final t = AppLocalizations.of(context)!;
  final me = myAccount(core, m.groupId);
  final receipts = core.messageReceipts(messageId: m.messageId);
  List<GroupMemberView> members;
  try {
    members = core.groupInfo(groupId: m.groupId).members.where((x) => !x.me).toList();
  } on Object {
    members = [];
  }
  String state(List<int> account) {
    final r = receipts.where((x) => listEquals(x.account, account)).firstOrNull;
    return switch (r?.status) {
      MessageStatus.read => t.statusRead,
      MessageStatus.delivered => t.statusDelivered,
      _ => t.statusSent,
    };
  }

  showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(t.messageInfo),
      content: SingleChildScrollView(
        child: ListBody(
          children: [for (final x in members) Text('${memberName(t, core, x.account, me: me)}: ${state(x.account)}')],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(t.close))],
    ),
  );
}
