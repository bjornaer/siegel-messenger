import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'l10n/app_localizations.dart';
import 'onboarding.dart' show showError;
import 'src/rust/api/core.dart';

/// Keeps the message stream connected (SRV-03) and tells screens when something arrived.
class ChatService extends ChangeNotifier {
  ChatService(this.core, {required this.onDeregistered});
  final Core core;
  final VoidCallback onDeregistered;
  bool _stopped = false;

  void start() => unawaited(_loop());

  Future<void> _loop() async {
    var backoff = const Duration(seconds: 1);
    while (!_stopped) {
      try {
        await for (final e in core.runStream()) {
          backoff = const Duration(seconds: 1);
          if (e.kind == CoreEventKind.deregistered) {
            _stopped = true;
            onDeregistered(); // ID-12: the core already wiped local data
            return;
          }
          notifyListeners();
        }
      } on Object {
        // network error or server restart: reconnect below
      }
      if (_stopped) return;
      await Future<void>.delayed(backoff);
      backoff = Duration(seconds: min(backoff.inSeconds * 2, 60));
    }
  }

  @override
  void dispose() {
    _stopped = true;
    super.dispose();
  }
}

String _time(BuildContext context, int ms) =>
    DateFormat.Hm(Localizations.localeOf(context).toString()).format(DateTime.fromMillisecondsSinceEpoch(ms));

/// Display name, else @username, else a placeholder until their profile arrives.
String chatTitle(AppLocalizations t, ChatSummary c) =>
    c.peerDisplayName ?? (c.peerUsername == null ? t.newContact : '@${c.peerUsername}');

Widget _chatTile(BuildContext context, Core core, ChatService service, ChatSummary c) {
  final t = AppLocalizations.of(context)!;
  return ListTile(
    leading: const CircleAvatar(child: Icon(Icons.person_outline)),
    title: Text(chatTitle(t, c)),
    subtitle: c.last == null ? null : Text(c.last!.text, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: c.last == null ? null : Text(_time(context, c.last!.sentAt)),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(core: core, service: service, groupId: c.groupId),
      ),
    ),
  );
}

class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key, required this.core, required this.service, required this.settings});
  final Core core;
  final ChatService service;
  final WidgetBuilder settings;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.chatsTitle),
        actions: [
          IconButton(
            tooltip: t.settings,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: settings)),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final all = core.chats();
          final chats = all.where((c) => !c.request).toList();
          final requests = all.length - chats.length;
          return ListView(
            children: [
              if (requests > 0)
                ListTile(
                  leading: const Icon(Icons.mark_email_unread_outlined),
                  title: Text(t.messageRequestsCount(requests)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MessageRequestsScreen(core: core, service: service),
                    ),
                  ),
                ),
              if (chats.isEmpty && requests == 0)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(t.noChats, textAlign: TextAlign.center),
                ),
              for (final c in chats) _chatTile(context, core, service, c),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.edit_outlined),
        label: Text(t.newChat),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => NewChatScreen(core: core, service: service),
          ),
        ),
      ),
    );
  }
}

/// MSG-15: chats from people who aren't contacts yet.
class MessageRequestsScreen extends StatelessWidget {
  const MessageRequestsScreen({super.key, required this.core, required this.service});
  final Core core;
  final ChatService service;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(t.messageRequests)),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final requests = core.chats().where((c) => c.request).toList();
          if (requests.isEmpty) return Center(child: Text(t.noRequests));
          return ListView(children: [for (final c in requests) _chatTile(context, core, service, c)]);
        },
      ),
    );
  }
}

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key, required this.core, required this.service});
  final Core core;
  final ChatService service;

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final _username = TextEditingController();
  bool _busy = false;

  Future<void> _start() async {
    final name = _username.text.trim().replaceFirst(RegExp('^@'), '').toLowerCase();
    setState(() => _busy = true);
    try {
      final id = await widget.core.startChat(username: name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar(); // an earlier error would cover the composer
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
    return Scaffold(
      appBar: AppBar(title: Text(t.newChat)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _username,
            autofocus: true,
            autocorrect: false,
            decoration: InputDecoration(labelText: t.usernameLabel),
            onSubmitted: (_) => _busy ? null : _start(),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _start, child: Text(t.startChat)),
        ],
      ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.core, required this.service, required this.groupId});
  final Core core;
  final ChatService service;
  final Uint8List groupId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  bool _busy = false;

  Core get core => widget.core;

  ChatSummary? _summary() {
    for (final c in core.chats()) {
      if (listEquals(c.groupId, widget.groupId)) return c;
    }
    return null; // deleted or blocked
  }

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

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    await _run(() async {
      await core.sendText(groupId: widget.groupId, text: text);
      _text.clear();
    });
  }

  Future<void> _block(ChatSummary c) async {
    final t = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t.blockConfirmTitle(chatTitle(t, c))),
        content: Text(t.blockConfirmBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(t.block)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      await core.block(account: c.peerAccount);
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final c = _summary();
        if (c == null) return Scaffold(appBar: AppBar());
        return Scaffold(
          appBar: AppBar(
            title: Text(chatTitle(t, c)),
            actions: [
              if (!c.request)
                PopupMenuButton<void>(
                  itemBuilder: (_) => [PopupMenuItem(onTap: () => _block(c), child: Text(t.block))],
                ),
            ],
          ),
          body: Column(
            children: [
              Expanded(child: _messages(context, colors)),
              SafeArea(top: false, child: c.request ? _requestBar(t, c) : _composer(t)),
            ],
          ),
        );
      },
    );
  }

  Widget _messages(BuildContext context, ColorScheme colors) {
    final messages = core.messages(groupId: widget.groupId, limit: 500).reversed.toList();
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.all(12),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final m = messages[i];
        return Align(
          key: ValueKey(base64Encode(m.messageId)),
          alignment: m.outgoing ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
            decoration: BoxDecoration(
              color: m.outgoing ? colors.primaryContainer : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(m.text),
                Text(_time(context, m.sentAt), style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        );
      },
    );
  }

  /// MSG-15: accept, delete or block before anything goes back to the requester.
  Widget _requestBar(AppLocalizations t, ChatSummary c) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(t.requestBanner(chatTitle(t, c)), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [
            OutlinedButton(onPressed: _busy ? null : () => _block(c), child: Text(t.block)),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () {
                      core.deleteChat(groupId: widget.groupId);
                      Navigator.of(context).pop();
                    },
              child: Text(t.delete),
            ),
            FilledButton(
              onPressed: _busy ? null : () => _run(() => core.accept(groupId: widget.groupId)),
              child: Text(t.accept),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _composer(AppLocalizations t) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _text,
            minLines: 1,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(hintText: t.messageHint, border: const OutlineInputBorder()),
          ),
        ),
        IconButton(tooltip: t.send, icon: const Icon(Icons.send), onPressed: _busy ? null : _send),
      ],
    ),
  );
}
