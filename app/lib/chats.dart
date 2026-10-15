import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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

class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key, required this.core, required this.service, required this.settings});
  final Core core;
  final ChatService service;
  final WidgetBuilder settings;

  void _open(BuildContext context, Uint8List groupId, String title) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(core: core, service: service, groupId: groupId, title: title),
    ),
  );

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
          final chats = core.chats();
          if (chats.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(t.noChats, textAlign: TextAlign.center),
              ),
            );
          }
          return ListView(
            children: [
              for (final c in chats)
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                  title: Text(c.peerUsername == null ? t.newContact : '@${c.peerUsername}'),
                  subtitle: c.last == null ? null : Text(c.last!.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: c.last == null ? null : Text(_time(context, c.last!.sentAt)),
                  onTap: () => _open(context, c.groupId, c.peerUsername == null ? t.newContact : '@${c.peerUsername}'),
                ),
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
          builder: (_) => ChatScreen(core: widget.core, service: widget.service, groupId: id, title: '@$name'),
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
  const ChatScreen({super.key, required this.core, required this.service, required this.groupId, required this.title});
  final Core core;
  final ChatService service;
  final Uint8List groupId;
  final String title;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  bool _sending = false;

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await widget.core.sendText(groupId: widget.groupId, text: text);
      _text.clear();
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: widget.service,
              builder: (context, _) {
                final messages = widget.core.messages(groupId: widget.groupId, limit: 500).reversed.toList();
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
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
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
                  IconButton(tooltip: t.send, icon: const Icon(Icons.send), onPressed: _sending ? null : _send),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
