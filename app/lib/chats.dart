import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'l10n/app_localizations.dart';
import 'onboarding.dart' show showError;
import 'profile.dart';
import 'safety.dart';
import 'src/rust/api/core.dart';

/// Keeps the message stream connected (SRV-03) and tells screens when something arrived.
class ChatService extends ChangeNotifier {
  ChatService(this.core, {required this.onDeregistered, this.onMessage});
  final Core core;
  final VoidCallback onDeregistered;

  /// Every new incoming message, e.g. to notify while the app is in the background.
  final void Function(MessageView)? onMessage;
  bool _stopped = false;
  StreamSubscription<CoreEvent>? _sub;
  Completer<void>? _waiting; // the current connection, or the backoff before the next
  bool _woken = false;
  final _typing = <String, Timer>{};

  /// MSG-14: the peer typed within the last few seconds.
  bool isTyping(Uint8List groupId) => _typing.containsKey(base64Encode(groupId));

  void _setTyping(Uint8List groupId, bool on) {
    final key = base64Encode(groupId);
    _typing.remove(key)?.cancel();
    if (!on) return;
    // A little over the 3 s send interval.
    _typing[key] = Timer(const Duration(seconds: 5), () {
      _typing.remove(key);
      if (!_stopped) notifyListeners();
    });
  }

  void start() => unawaited(_loop());

  /// Our own actions change chats too (last message, ticks); screens rebuild on this.
  void refresh() => notifyListeners();

  /// A push arrived (MSG-17): the server thinks we're offline, so reconnect now, even if this
  /// connection still looks open (a sleeping phone can leave it half-dead).
  void wake() {
    _woken = true;
    _sub?.cancel();
    _sub = null;
    if (_waiting?.isCompleted == false) _waiting!.complete();
  }

  Future<void> _loop() async {
    var backoff = const Duration(seconds: 1);
    while (!_stopped) {
      final done = _waiting = Completer<void>();
      void finish([Object? _]) => done.isCompleted ? null : done.complete();
      _sub = core.runStream().listen(
        (e) {
          backoff = const Duration(seconds: 1);
          if (e.kind == CoreEventKind.deregistered) {
            _stopped = true;
            finish();
            onDeregistered(); // ID-12: the core already wiped local data
            return;
          }
          if (e.kind case CoreEventKind.typing || CoreEventKind.message) {
            _setTyping(e.groupId!, e.kind == CoreEventKind.typing);
          }
          if (e.kind == CoreEventKind.message && e.message != null) onMessage?.call(e.message!);
          notifyListeners();
        },
        onError: finish, // network error or server restart: reconnect below
        onDone: finish,
      );
      await done.future;
      if (_stopped) return;
      if (_woken) {
        _woken = false;
        continue; // reconnect without backoff
      }
      final sleep = _waiting = Completer<void>();
      final timer = Timer(backoff, () => sleep.isCompleted ? null : sleep.complete());
      await sleep.future;
      timer.cancel();
      backoff = Duration(seconds: min(backoff.inSeconds * 2, 60));
    }
  }

  @override
  void dispose() {
    _stopped = true;
    wake();
    for (final t in _typing.values) {
      t.cancel();
    }
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
    subtitle: c.last == null
        ? null
        : Text(c.last!.deleted ? t.messageDeleted : c.last!.text, maxLines: 1, overflow: TextOverflow.ellipsis),
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

/// MSG-09, MSG-11 windows; the core enforces the same ones.
const _editWindow = Duration(minutes: 15);
const _deleteWindow = Duration(hours: 48);
const _emojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _keys = <String, GlobalKey>{};
  bool _busy = false;
  MessageView? _replyTo;
  MessageView? _editing;
  DateTime _lastTyping = DateTime(0);

  Core get core => widget.core;
  Uint8List get _group => widget.groupId;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_markRead);
    _markRead();
  }

  @override
  void dispose() {
    widget.service.removeListener(_markRead);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// MSG-13: what arrives in an open chat counts as read.
  void _markRead() => unawaited(core.markRead(groupId: _group).catchError((Object _) {}));

  ChatSummary? _summary() {
    for (final c in core.chats()) {
      if (listEquals(c.groupId, _group)) return c;
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
      widget.service.refresh();
    }
  }

  /// MSG-14: at most one typing event every 3 seconds.
  void _onChanged(String v) {
    final now = DateTime.now();
    if (v.isEmpty || _editing != null || now.difference(_lastTyping) < const Duration(seconds: 3)) {
      return;
    }
    _lastTyping = now;
    unawaited(core.sendTyping(groupId: _group).catchError((Object _) {}));
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final editing = _editing;
    if (editing != null) {
      if (text == editing.text) {
        _text.clear();
        return setState(() => _editing = null); // nothing changed: no edit to send
      }
      await _run(() async {
        await core.edit(groupId: _group, messageId: editing.messageId, text: text);
        _text.clear();
        setState(() => _editing = null);
      });
      return;
    }
    // Cleared up front: a failed send stays in the chat with a retry (MSG-04), not in the composer.
    final reply = _replyTo;
    _text.clear();
    setState(() => _replyTo = null);
    await _run(() => core.sendText(groupId: _group, text: text, replyTo: reply?.messageId));
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

  Future<void> _deleteForEveryone(MessageView m) async {
    final t = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t.deleteForEveryone),
        content: Text(t.deleteForEveryoneBody), // MSG-11: promise no more than this
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(t.delete)),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _run(() => core.deleteForEveryone(groupId: _group, messageId: m.messageId));
    }
  }

  void _history(MessageView m) {
    final t = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t.editHistory),
        content: SingleChildScrollView(
          child: ListBody(
            children: [
              for (final v in core.versions(messageId: m.messageId))
                Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(v)),
              Text(m.text, style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(t.close))],
      ),
    );
  }

  /// Long-press actions. Edit and delete-for-everyone only show inside their windows;
  /// the core checks the same rules (MSG-09, MSG-11).
  void _actions(MessageView m, ChatSummary c) {
    final t = AppLocalizations.of(context)!;
    final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(m.sentAt));
    // ponytail: in 1:1 any reaction not from the peer is ours; groups (M3) need our account ID.
    final mine = m.reactions.where((r) => !listEquals(r.account, c.peerAccount)).firstOrNull?.emoji;
    void act(VoidCallback f) {
      Navigator.pop(context);
      f();
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true, // all actions fit on small screens too
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Wrap(
            children: [
              if (!m.deleted && !c.request)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final e in _emojis)
                      IconButton(
                        isSelected: e == mine,
                        icon: Text(e, style: const TextStyle(fontSize: 24)),
                        onPressed: () => act(
                          () => _run(
                            () => core.react(groupId: _group, messageId: m.messageId, emoji: e == mine ? '' : e),
                          ),
                        ),
                      ),
                  ],
                ),
              if (!m.deleted && !c.request)
                ListTile(
                  leading: const Icon(Icons.reply),
                  title: Text(t.reply),
                  onTap: () => act(
                    () => setState(() {
                      _replyTo = m;
                      _editing = null;
                      _focus.requestFocus();
                    }),
                  ),
                ),
              if (!m.deleted)
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: Text(t.copy),
                  onTap: () => act(() {
                    Clipboard.setData(ClipboardData(text: m.text));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.copied)));
                  }),
                ),
              if (m.outgoing && !m.deleted && age < _editWindow && m.status != MessageStatus.failed)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(t.edit),
                  onTap: () => act(() {
                    _text.text = m.text;
                    setState(() {
                      _editing = m;
                      _replyTo = null;
                      _focus.requestFocus();
                    });
                  }),
                ),
              if (m.outgoing && !m.deleted)
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(t.messageInfo),
                  onTap: () => act(() => showMessageInfo(context, m, chatTitle(t, c))),
                ),
              if (m.edited && !m.deleted)
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(t.editHistory),
                  onTap: () => act(() => _history(m)),
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(t.deleteForMe),
                onTap: () => act(() {
                  core.deleteForMe(messageId: m.messageId);
                  widget.service.refresh();
                }),
              ),
              if (m.outgoing && !m.deleted && age < _deleteWindow && m.status != MessageStatus.failed)
                ListTile(
                  leading: const Icon(Icons.delete_forever_outlined),
                  title: Text(t.deleteForEveryone),
                  onTap: () => act(() => _deleteForEveryone(m)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final c = _summary();
        if (c == null) return Scaffold(appBar: AppBar());
        return Scaffold(
          appBar: AppBar(
            title: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ContactProfileScreen(
                    core: core,
                    groupId: _group,
                    onBlock: () {
                      Navigator.of(context).pop(); // back to the chat, which closes once blocked
                      _block(c);
                    },
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text(chatTitle(t, c), overflow: TextOverflow.ellipsis)),
                      if (c.peerVerified) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.verified_user, size: 18, semanticLabel: t.verified),
                      ],
                    ],
                  ),
                  if (widget.service.isTyping(_group)) Text(t.typing, style: Theme.of(context).textTheme.labelMedium),
                ],
              ),
            ),
            actions: [
              if (!c.request)
                PopupMenuButton<void>(
                  itemBuilder: (_) => [
                    PopupMenuItem(onTap: () => _safety(c), child: Text(t.safetyNumber)),
                    PopupMenuItem(onTap: () => _block(c), child: Text(t.block)),
                  ],
                ),
            ],
          ),
          body: Column(
            children: [
              Expanded(child: _messages(context, c)),
              SafeArea(top: false, child: c.request ? _requestBar(t, c) : _composer(t, c)),
            ],
          ),
        );
      },
    );
  }

  void _safety(ChatSummary c) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          SafetyNumberScreen(core: core, groupId: _group, name: chatTitle(AppLocalizations.of(context)!, c)),
    ),
  );

  void _jumpTo(Uint8List messageId) {
    final ctx = _keys[base64Encode(messageId)]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.5);
    }
  }

  // ponytail: builds all (up to 500) bubbles so replies can jump to any of them; paginate if chats get long.
  Widget _messages(BuildContext context, ChatSummary c) {
    final messages = core.messages(groupId: _group, limit: 500);
    final byId = {for (final m in messages) base64Encode(m.messageId): m};
    return SingleChildScrollView(
      reverse: true,
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          for (final m in messages)
            if (m.keyChange) _keyChange(context, m, c) else _bubble(context, m, byId, c),
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, MessageView m, Map<String, MessageView> byId, ChatSummary c) {
    final t = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.labelSmall;
    final id = base64Encode(m.messageId);
    final quoted = m.replyTo == null ? null : byId[base64Encode(m.replyTo!)];
    final failed = m.status == MessageStatus.failed;
    final counts = <String, int>{};
    for (final r in m.reactions) {
      counts[r.emoji] = (counts[r.emoji] ?? 0) + 1;
    }
    return Align(
      key: _keys.putIfAbsent(id, GlobalKey.new),
      alignment: m.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _actions(m, c),
        onTap: failed ? () => _run(() => core.retry(messageId: m.messageId)) : null,
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
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.replyTo != null && !m.deleted)
                GestureDetector(
                  onTap: () => _jumpTo(m.replyTo!),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.only(left: 8),
                    decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: colors.primary, width: 3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (quoted != null) Text(quoted.outgoing ? t.you : chatTitle(t, c), style: small),
                        Text(
                          quoted == null
                              ? t.originalMissing
                              : quoted.deleted
                              ? t.messageDeleted
                              : quoted.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              if (m.deleted)
                Text(t.messageDeleted, style: const TextStyle(fontStyle: FontStyle.italic))
              else
                Text(m.text),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (m.edited && !m.deleted)
                    GestureDetector(
                      onTap: () => _history(m),
                      child: Text('${t.edited} ', style: small),
                    ),
                  Text(_time(context, m.sentAt), style: small),
                  if (m.outgoing) ...[const SizedBox(width: 4), _status(t, m.status, colors)],
                ],
              ),
              if (failed) Text(t.notSentRetry, style: small?.copyWith(color: colors.error)),
              if (counts.isNotEmpty)
                Text([for (final e in counts.entries) e.value > 1 ? '${e.key} ${e.value}' : e.key].join('  ')),
            ],
          ),
        ),
      ),
    );
  }

  /// CRY-13: stays in the chat; no actions besides comparing the new number.
  Widget _keyChange(BuildContext context, MessageView m, ChatSummary c) {
    final t = AppLocalizations.of(context)!;
    return Padding(
      key: ValueKey(base64Encode(m.messageId)),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Card.outlined(
        child: ListTile(
          leading: const Icon(Icons.gpp_maybe_outlined),
          title: Text(t.keyChanged(chatTitle(t, c)), style: Theme.of(context).textTheme.bodySmall),
          onTap: () => _safety(c),
        ),
      ),
    );
  }

  /// MSG-04 ticks, with labels for screen readers.
  Widget _status(AppLocalizations t, MessageStatus s, ColorScheme colors) => switch (s) {
    MessageStatus.failed => Icon(Icons.error_outline, size: 14, color: colors.error, semanticLabel: t.notSentRetry),
    MessageStatus.sending => Icon(Icons.schedule, size: 14, semanticLabel: t.statusSending),
    MessageStatus.sent => Icon(Icons.check, size: 14, semanticLabel: t.statusSent),
    MessageStatus.delivered => Icon(Icons.done_all, size: 14, semanticLabel: t.statusDelivered),
    MessageStatus.read => Icon(Icons.done_all, size: 14, color: colors.primary, semanticLabel: t.statusRead),
  };

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
                      core.deleteChat(groupId: _group);
                      Navigator.of(context).pop();
                    },
              child: Text(t.delete),
            ),
            FilledButton(
              onPressed: _busy ? null : () => _run(() => core.accept(groupId: _group)),
              child: Text(t.accept),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _composer(AppLocalizations t, ChatSummary c) {
    final target = _editing ?? _replyTo;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (target != null)
            Row(
              children: [
                Icon(_editing != null ? Icons.edit_outlined : Icons.reply, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_editing != null ? t.editing : target.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  tooltip: t.cancel,
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    if (_editing != null) _text.clear();
                    _editing = null;
                    _replyTo = null;
                  }),
                ),
              ],
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: _onChanged,
                  decoration: InputDecoration(hintText: t.messageHint, border: const OutlineInputBorder()),
                ),
              ),
              IconButton(
                tooltip: t.send,
                icon: Icon(_editing != null ? Icons.check : Icons.send),
                onPressed: _busy ? null : _send,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
