import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'l10n/app_localizations.dart';
import 'onboarding.dart' show showError;
import 'avatar.dart';
import 'discovery.dart';
import 'format.dart';
import 'groups.dart';
import 'links.dart';
import 'media.dart';
import 'update.dart';
import 'profile.dart';
import 'push.dart' show appVisible, clearNotification;
import 'safety.dart';
import 'src/rust/api/core.dart';
import 'themes.dart';

/// Keeps the message stream connected (SRV-03) and tells screens when something arrived.
class ChatService extends ChangeNotifier {
  ChatService(this.core, {required this.onDeregistered, this.onMessage, this.onNumberRemoved});
  final Core core;
  final VoidCallback onDeregistered;

  /// Another account took our number (docs/change-number.md).
  final VoidCallback? onNumberRemoved;

  /// Every new incoming message, e.g. to notify while the app is in the background.
  final void Function(MessageView)? onMessage;
  bool _stopped = false;
  StreamSubscription<CoreEvent>? _sub;
  Completer<void>? _waiting; // the current connection, or the backoff before the next
  bool _woken = false;
  bool _paused = false;
  AppLifecycleListener? _lifecycle;
  final _typing = <String, Timer>{};
  final _typingWho = <String, List<int>>{};

  /// MSG-14: someone typed within the last few seconds.
  bool isTyping(Uint8List groupId) => _typing.containsKey(base64Encode(groupId));

  /// Who it was, for "Ana is typing…" in groups.
  List<int>? typingAccount(Uint8List groupId) => _typingWho[base64Encode(groupId)];

  void _setTyping(Uint8List groupId, bool on, [List<int>? who]) {
    final key = base64Encode(groupId);
    _typing.remove(key)?.cancel();
    if (who != null) _typingWho[key] = who;
    if (!on) return;
    // A little over the 3 s send interval.
    _typing[key] = Timer(const Duration(seconds: 5), () {
      _typing.remove(key);
      if (!_stopped) notifyListeners();
    });
  }

  void start() {
    // In the background the stream closes, so the server pushes at once (MSG-17). An open but
    // frozen connection looks online to it, and nothing arrives until its ping fails (~40 s).
    _lifecycle = AppLifecycleListener(onHide: pause, onShow: resume);
    unawaited(_loop());
  }

  void pause() {
    _paused = true;
    _drop();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    wake();
  }

  /// Our own actions change chats too (last message, ticks); screens rebuild on this.
  void refresh() => _stopped ? null : notifyListeners();

  DateTime _lastEvent = DateTime(0);

  /// After a push (MSG-17): reconnect, then wait until messages stop arriving (2 s quiet, at least
  /// 4 s, at most 15 s), so notifications are shown before Android freezes the app again.
  Future<void> fetchNow() async {
    final start = DateTime.now();
    wake();
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final now = DateTime.now();
      final quiet = now.difference(_lastEvent) > const Duration(seconds: 2);
      if ((quiet && now.difference(start) > const Duration(seconds: 4)) ||
          now.difference(start) > const Duration(seconds: 15)) {
        if (_paused) _drop(); // back to sleep, so the next message pushes again
        return;
      }
    }
  }

  /// A push arrived (MSG-17): the server thinks we're offline, so reconnect now, even if this
  /// connection still looks open (a sleeping phone can leave it half-dead).
  void wake() {
    _woken = true;
    _drop();
  }

  void _drop() {
    _sub?.cancel();
    _sub = null;
    if (_waiting?.isCompleted == false) _waiting!.complete();
  }

  Future<void> _loop() async {
    var backoff = const Duration(seconds: 1);
    while (!_stopped) {
      if (_paused && !_woken) {
        await (_waiting = Completer<void>()).future; // until a push or the app is shown
        continue;
      }
      _woken = false;
      final done = _waiting = Completer<void>();
      void finish([Object? _]) => done.isCompleted ? null : done.complete();
      _sub = core.runStream().listen(
        (e) {
          backoff = const Duration(seconds: 1);
          _lastEvent = DateTime.now();
          if (e.kind == CoreEventKind.deregistered) {
            _stopped = true;
            finish();
            onDeregistered(); // ID-12: the core already wiped local data
            return;
          }
          if (e.kind == CoreEventKind.numberRemoved) onNumberRemoved?.call();
          if (e.kind case CoreEventKind.typing || CoreEventKind.message) {
            _setTyping(e.groupId!, e.kind == CoreEventKind.typing, e.account);
          }
          if (e.kind == CoreEventKind.message && e.message != null) {
            onMessage?.call(e.message!);
            unawaited(autoDownload(core, e.message!)); // MED-12
          }
          notifyListeners();
        },
        onError: finish, // network error or server restart: reconnect below
        onDone: finish,
      );
      await done.future;
      if (_stopped) return;
      if (_woken || _paused) continue; // reconnect without backoff, or sleep until woken
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
    _lifecycle?.dispose();
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
String chatTitle(AppLocalizations t, ChatSummary c) => c.isGroup
    ? c.groupName ?? t.group
    : c.peerDisplayName ?? (c.peerUsername == null ? t.newContact : '@${c.peerUsername}');

/// The chat list's one-line preview: system lines as text, group messages with their sender.
String _preview(AppLocalizations t, Core core, ChatSummary c) {
  final m = c.last!;
  if (m.event != null) return groupEventText(t, core, m.event!, myAccount(core, c.groupId));
  final text = m.deleted ? t.messageDeleted : messageText(t, m);
  if (!c.isGroup || m.outgoing) return text;
  return '${memberName(t, core, m.senderAccount)}: $text';
}

Widget _chatTile(BuildContext context, Core core, ChatService service, ChatSummary c) {
  final t = AppLocalizations.of(context)!;
  final colors = Theme.of(context).colorScheme;
  // Unread chats stand out: bold text, a count, and the time in the theme colour.
  final unread = c.unread > 0;
  final bold = unread ? const TextStyle(fontWeight: FontWeight.bold) : null;
  return ListTile(
    leading: c.isGroup ? Avatar(core: core, groupId: c.groupId) : Avatar(core: core, account: c.peerAccount),
    title: Text(chatTitle(t, c), style: bold),
    // The count sits on the preview's line, so the row still fits at 200% text (CMP-05).
    subtitle: c.last == null
        ? null
        : Row(
            children: [
              Expanded(
                child: Text(_preview(t, core, c), maxLines: 1, overflow: TextOverflow.ellipsis, style: bold),
              ),
              if (unread) ...[
                const SizedBox(width: 8),
                // Muted chats count quietly, in grey.
                Badge(
                  label: Semantics(
                    label: t.unreadCount(c.unread),
                    child: ExcludeSemantics(child: Text(c.unread > 99 ? '99+' : '${c.unread}')),
                  ),
                  backgroundColor: isMuted(core, c.groupId) ? colors.outline : colors.primary,
                  textColor: isMuted(core, c.groupId) ? colors.surface : colors.onPrimary,
                ),
              ],
            ],
          ),
    trailing: c.last == null
        ? null
        : Text(_time(context, c.last!.sentAt), style: unread ? TextStyle(color: colors.primary) : null),
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
      appBar: SiegelBar(
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
          // Pull down to reconnect at once and fetch anything waiting.
          return RefreshIndicator(
            onRefresh: () async {
              service.wake();
              await Future<void>.delayed(const Duration(seconds: 1));
              service.refresh();
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                UpdateBanner(core: core),
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
            ),
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
      appBar: SiegelBar(title: Text(t.messageRequests)),
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

  /// DISC-02, DISC-08: someone's contact QR code opens the chat with them.
  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (code == null || !mounted) return;
    if (!isContactLink(code) && !isGroupLink(code)) {
      showError(context, CoreError(code: 'link_invalid'));
      return;
    }
    setState(() => _busy = true);
    try {
      final id = isGroupLink(code)
          ? await joinGroupByLink(context, widget.core, code)
          : await widget.core.openContactLink(link: code);
      if (id == null || !mounted) return;
      widget.service.refresh();
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
      appBar: SiegelBar(title: Text(t.newChat)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.tonalIcon(
            icon: const Icon(Icons.group_add_outlined),
            label: Text(t.newGroup),
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => NewGroupScreen(core: widget.core, service: widget.service),
              ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(t.scanQr),
            onPressed: _busy ? null : _scan,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.contacts_outlined),
            label: Text(t.findContacts),
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => FindContactsScreen(core: widget.core, service: widget.service),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),
          Text(t.orStartChat, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
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
  late final List<int>? _me = myAccount(core, _group);

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_markRead);
    _lifecycle = AppLifecycleListener(onShow: _markRead);
    _markRead();
  }

  @override
  void dispose() {
    widget.service.removeListener(_markRead);
    _lifecycle.dispose();
    // The chat list redraws without this chat's unread count (after the tree is unlocked).
    final service = widget.service;
    Future.microtask(service.refresh);
    _recTimer?.cancel();
    _recorder?.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// MSG-13: what arrives in an open chat counts as read.
  late final AppLifecycleListener _lifecycle;

  /// What arrives while the app is hidden stays unread and gets a notification; once the chat
  /// is on screen again, both go.
  void _markRead() {
    if (!appVisible()) return;
    unawaited(clearNotification(_group).catchError((Object _) {}));
    unawaited(core.markRead(groupId: _group).catchError((Object _) {}));
  }

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
  /// GRP-15: "@query" right before the cursor, in a group: offer members to mention.
  String? _mentionQuery;
  final _mentioned = <String, List<int>>{}; // inserted "@Name" -> account

  void _updateMentionQuery() {
    final sel = _text.selection;
    final before = sel.isValid ? _text.text.substring(0, sel.baseOffset) : _text.text;
    final m = RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(before);
    final q = m?.group(1);
    if (q != _mentionQuery) setState(() => _mentionQuery = q);
  }

  void _mention(String name, List<int> account) {
    final sel = _text.selection;
    final end = sel.isValid ? sel.baseOffset : _text.text.length;
    final start = _text.text.lastIndexOf('@', end - 1);
    final insert = '@$name ';
    _text.value = TextEditingValue(
      text: _text.text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    _mentioned[name] = account;
    setState(() => _mentionQuery = null);
  }

  Widget _mentionSuggestions(AppLocalizations t) {
    final q = _mentionQuery!.toLowerCase();
    List<GroupMemberView> members;
    try {
      members = core.groupInfo(groupId: _group).members.where((m) => !m.me).toList();
    } on Object {
      return const SizedBox.shrink();
    }
    final matches = members
        .where((m) => (m.displayName ?? '').toLowerCase().contains(q) || (m.username ?? '').toLowerCase().startsWith(q))
        .take(5)
        .toList();
    if (matches.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final m in matches)
          ListTile(
            dense: true,
            leading: Avatar(core: core, account: m.account, radius: 14),
            title: Text(m.displayName ?? '@${m.username}'),
            subtitle: m.displayName != null && m.username != null ? Text('@${m.username}') : null,
            onTap: () => _mention(m.displayName ?? m.username ?? t.someone, m.account),
          ),
      ],
    );
  }

  void _onChanged(String v) {
    _updateMentionQuery();
    final now = DateTime.now();
    if (v.isEmpty || _editing != null || now.difference(_lastTyping) < const Duration(seconds: 3)) {
      return;
    }
    _lastTyping = now;
    unawaited(core.sendTyping(groupId: _group).catchError((Object _) {}));
  }

  // MED-09: a voice note being recorded; the timer redraws the elapsed time.
  VoiceRecorder? _recorder;
  Timer? _recTimer;

  Future<void> _startRecording() async {
    final r = VoiceRecorder();
    if (!await r.start()) {
      r.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.micDenied)));
      }
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _recorder = r);
    _recTimer = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  Future<void> _stopRecording({required bool send}) async {
    final r = _recorder!;
    _recTimer?.cancel();
    setState(() => _recorder = null);
    final rec = await r.stop(keep: send);
    r.dispose();
    if (rec == null || rec.ms < 500) return; // a slip of the finger, not a message
    await _sendAttachment(outgoing(rec.data, 'audio/mp4', ms: rec.ms, voice: true, waveform: rec.waveform));
  }

  /// MED-07..10: what to attach.
  Future<void> _attach() async {
    final t = AppLocalizations.of(context)!;
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, icon, label) in [
              (0, Icons.photo_outlined, t.photo),
              (1, Icons.videocam_outlined, t.video),
              (2, Icons.insert_drive_file_outlined, t.file),
              (3, Icons.audio_file_outlined, t.attachAudio),
            ])
              ListTile(leading: Icon(icon), title: Text(label), onTap: () => Navigator.pop(c, i)),
          ],
        ),
      ),
    );
    if (choice == null) return;
    try {
      final o = await switch (choice) {
        0 => pickPhoto(),
        1 => pickVideo(_askCompress),
        2 => pickFile(),
        _ => pickFile(audio: true),
      };
      if (o != null) await _sendAttachment(o);
    } on TooLarge {
      if (mounted) showError(context, const CoreError(code: 'attachment_too_large')); // MED-06
    }
  }

  /// MED-08: compression is offered; over 100 MB it is the only way.
  Future<bool?> _askCompress(bool must) {
    final t = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t.compressVideo),
        content: Text(must ? t.compressVideoMust : t.compressVideoBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(t.cancel)),
          if (!must) TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.sendOriginal)),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(t.compress)),
        ],
      ),
    );
  }

  Future<void> _sendAttachment(Outgoing o) async {
    if (o.data.length > maxAttachment) {
      return showError(context, const CoreError(code: 'attachment_too_large')); // MED-06
    }
    final reply = _replyTo;
    setState(() => _replyTo = null);
    await _run(
      () => core.sendAttachment(
        groupId: _group,
        data: o.data,
        mimeType: o.mime,
        fileName: o.name,
        durationMs: o.ms,
        voiceNote: o.voice,
        waveform: o.waveform,
        width: o.width,
        height: o.height,
        thumbnail: o.thumbnail,
        replyTo: reply?.messageId,
      ),
    );
  }

  /// MED-14: sends the message on to a chat the user picks.
  Future<void> _forward(MessageView m) async {
    final t = AppLocalizations.of(context)!;
    final chats = core.chats().where((c) => !c.request && !c.left).toList();
    final to = await showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(t.forwardTo, style: Theme.of(c).textTheme.titleMedium)),
              for (final chat in chats)
                ListTile(
                  leading: chat.isGroup
                      ? Avatar(core: core, groupId: chat.groupId)
                      : Avatar(core: core, account: chat.peerAccount),
                  title: Text(chatTitle(t, chat)),
                  onTap: () => Navigator.pop(c, chat.groupId),
                ),
            ],
          ),
        ),
      ),
    );
    if (to == null) return;
    await _run(() => core.forward(messageId: m.messageId, to: to));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.forwarded)));
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
    final mentions = [
      for (final e in _mentioned.entries)
        if (text.contains('@${e.key}')) Uint8List.fromList(e.value),
    ];
    _text.clear();
    _mentioned.clear();
    setState(() => _replyTo = null);
    await _run(() => core.sendText(groupId: _group, text: text, replyTo: reply?.messageId, mentions: mentions));
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
    final me = c.isGroup ? myAccount(core, _group) : null;
    final mine = m.reactions
        .where((r) => c.isGroup ? listEquals(r.account, me) : !listEquals(r.account, c.peerAccount))
        .firstOrNull
        ?.emoji;
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
                ListTile(leading: const Icon(Icons.reply), title: Text(t.reply), onTap: () => act(() => _reply(m))),
              if (!m.deleted && m.event == null && !m.keyChange)
                ListTile(
                  leading: const Icon(Icons.shortcut),
                  title: Text(t.forward),
                  onTap: () => act(() => _forward(m)),
                ),
              if (!m.deleted && m.attachment != null && !m.attachment!.voiceNote)
                ListTile(
                  leading: const Icon(Icons.download),
                  title: Text(t.saveToDevice),
                  onTap: () => act(() => saveToDevice(context, core, m)),
                ),
              if (!m.deleted && m.attachment == null)
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: Text(t.copy),
                  onTap: () => act(() {
                    Clipboard.setData(ClipboardData(text: m.text));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.copied)));
                  }),
                ),
              if (m.outgoing &&
                  !m.deleted &&
                  m.attachment == null &&
                  age < _editWindow &&
                  m.status != MessageStatus.failed)
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
                  onTap: () => act(
                    () => c.isGroup
                        ? showGroupMessageInfo(context, core, m)
                        : showMessageInfo(context, m, chatTitle(t, c)),
                  ),
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
        if (c == null) return Scaffold(appBar: SiegelBar());
        return Scaffold(
          appBar: SiegelBar(
            title: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => c.isGroup
                      ? GroupInfoScreen(core: core, service: widget.service, groupId: _group)
                      : ContactProfileScreen(
                          core: core,
                          groupId: _group,
                          onBlock: () {
                            Navigator.of(context).pop(); // back to the chat, which closes once blocked
                            _block(c);
                          },
                        ),
                ),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48), // CMP-05: tap target
                child: Row(
                  children: [
                    Avatar(
                      core: core,
                      account: c.isGroup ? null : c.peerAccount,
                      groupId: c.isGroup ? c.groupId : null,
                      radius: 18,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
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
                          if (widget.service.isTyping(_group))
                            Text(
                              c.isGroup
                                  ? t.isTyping(memberName(t, core, widget.service.typingAccount(_group) ?? const []))
                                  : t.typing,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              if (!c.request && !c.isGroup)
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
              SafeArea(
                top: false,
                child: c.left
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(t.leftGroup, textAlign: TextAlign.center),
                      )
                    : c.request
                    ? (c.isGroup ? _inviteBar(t) : _requestBar(t, c))
                    : _composer(t, c),
              ),
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
            if (m.event != null)
              _systemLine(context, m)
            else if (m.keyChange)
              _keyChange(context, m, c)
            else
              _bubble(context, m, byId, c),
        ],
      ),
    );
  }

  void _reply(MessageView m) => setState(() {
    _replyTo = m;
    _editing = null;
    _focus.requestFocus();
  });

  Widget _bubble(BuildContext context, MessageView m, Map<String, MessageView> byId, ChatSummary c) {
    final t = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final grad = m.outgoing ? Theme.of(context).extension<SiegelGradient>() : null; // gradient themes
    final small = Theme.of(context).textTheme.labelSmall?.copyWith(color: grad?.on);
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
      // CMP-05: read as one message with its sender; Reply stands in for the swipe.
      child: Semantics(
        container: true,
        label: m.outgoing ? t.you : (c.isGroup ? memberName(t, core, m.senderAccount) : chatTitle(t, c)),
        onLongPressHint: t.messageOptions,
        customSemanticsActions: m.deleted || c.request
            ? null
            : {CustomSemanticsAction(label: t.reply): () => _reply(m)},
        child: _SwipeToReply(
          onReply: m.deleted || c.request ? null : () => _reply(m),
          child: GestureDetector(
            onLongPress: () => _actions(m, c),
            onTap: failed ? () => _run(() => core.retry(messageId: m.messageId)) : null,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
              decoration: BoxDecoration(
                color: grad != null ? null : (m.outgoing ? colors.primaryContainer : colors.surfaceContainerHighest),
                gradient: grad?.linear,
                borderRadius: BorderRadius.circular(16),
                // GRP-15: messages that @mention us stand out.
                border: !m.outgoing && m.mentions.any((a) => listEquals(a, _me))
                    ? Border.all(color: colors.primary, width: 2)
                    : null,
              ),
              // As wide as its widest line; text starts left, time and ticks end right.
              child: onGradient(
                context,
                grad,
                IntrinsicWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (c.isGroup && !m.outgoing)
                        ExcludeSemantics(
                          // the bubble already says who sent it
                          child: Text(
                            memberName(t, core, m.senderAccount),
                            style: small?.copyWith(color: colors.primary, fontWeight: FontWeight.bold),
                          ),
                        ),
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
                                if (quoted != null)
                                  Text(
                                    quoted.outgoing
                                        ? t.you
                                        : c.isGroup
                                        ? memberName(t, core, quoted.senderAccount)
                                        : chatTitle(t, c),
                                    style: small,
                                  ),
                                Text(
                                  quoted == null
                                      ? t.originalMissing
                                      : quoted.deleted
                                      ? t.messageDeleted
                                      : messageText(t, quoted),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (m.deleted)
                        Text(t.messageDeleted, style: const TextStyle(fontStyle: FontStyle.italic))
                      else if (m.attachment != null)
                        attachmentView(core, m)
                      else
                        Text.rich(formatText(m.text)),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (m.edited && !m.deleted)
                            GestureDetector(
                              onTap: () => _history(m),
                              child: Text('${t.edited} ', style: small),
                            ),
                          Text(_time(context, m.sentAt), style: small),
                          if (m.outgoing) ...[
                            const SizedBox(width: 4),
                            _status(
                              t,
                              m.status,
                              colors,
                              read: readTickColor(Theme.of(context)),
                              muted: grad?.on.withValues(alpha: 0.75) ?? colors.onSurfaceVariant,
                            ),
                          ],
                        ],
                      ),
                      if (failed)
                        Text(
                          t.notSentRetry,
                          textAlign: TextAlign.end,
                          style: small?.copyWith(color: colors.error),
                        ),
                      if (counts.isNotEmpty)
                        Text(
                          [for (final e in counts.entries) e.value > 1 ? '${e.key} ${e.value}' : e.key].join('  '),
                          textAlign: TextAlign.end,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// GRP-12: membership and settings changes, centred.
  Widget _systemLine(BuildContext context, MessageView m) {
    final t = AppLocalizations.of(context)!;
    return Padding(
      key: ValueKey(base64Encode(m.messageId)),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        groupEventText(t, core, m.event!, myAccount(core, _group)),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  /// GRP-11: an invite from a non-contact; members don't see our name until we accept.
  Widget _inviteBar(AppLocalizations t) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(t.inviteBanner, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await core.leaveGroup(groupId: _group);
                      core.deleteChat(groupId: _group);
                      if (mounted) Navigator.of(context).pop();
                    }),
              child: Text(t.decline),
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
  /// Sent and delivered are muted like the time; read is the theme's read colour.
  Widget _status(AppLocalizations t, MessageStatus s, ColorScheme colors, {required Color read, Color? muted}) =>
      switch (s) {
        MessageStatus.failed => Icon(Icons.error_outline, size: 14, color: colors.error, semanticLabel: t.notSentRetry),
        MessageStatus.sending => Icon(Icons.schedule, size: 14, color: muted, semanticLabel: t.statusSending),
        MessageStatus.sent => Icon(Icons.check, size: 14, color: muted, semanticLabel: t.statusSent),
        MessageStatus.delivered => Icon(Icons.done_all, size: 14, color: muted, semanticLabel: t.statusDelivered),
        MessageStatus.read => Icon(Icons.done_all, size: 16, color: read, semanticLabel: t.statusRead),
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
          if (c.isGroup && _mentionQuery != null) _mentionSuggestions(t),
          if (target != null)
            Row(
              children: [
                Icon(_editing != null ? Icons.edit_outlined : Icons.reply, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _editing != null ? t.editing : messageText(t, target),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
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
          if (_recorder != null)
            Row(
              children: [
                IconButton(
                  tooltip: t.cancel,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _stopRecording(send: false),
                ),
                Icon(Icons.fiber_manual_record, color: Theme.of(context).colorScheme.error, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text('${t.recording} ${formatDuration(_recorder!.elapsed.inMilliseconds)}')),
                IconButton(tooltip: t.send, icon: const Icon(Icons.send), onPressed: () => _stopRecording(send: true)),
              ],
            )
          else
            Row(
              children: [
                if (_editing == null)
                  IconButton(tooltip: t.attach, icon: const Icon(Icons.attach_file), onPressed: _busy ? null : _attach),
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
                ValueListenableBuilder(
                  valueListenable: _text,
                  builder: (context, v, _) => v.text.trim().isEmpty && _editing == null
                      ? IconButton(
                          tooltip: t.recordVoice,
                          icon: const Icon(Icons.mic_none),
                          onPressed: _busy ? null : _startRecording,
                        )
                      : IconButton(
                          tooltip: t.send,
                          icon: Icon(_editing != null ? Icons.check : Icons.send),
                          onPressed: _busy ? null : _send,
                        ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// MSG-18: drag a bubble right to reply; a haptic tick says the drag went far enough.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({required this.onReply, required this.child});

  final VoidCallback? onReply;
  final Widget child;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _threshold = 64.0;
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.onReply == null) return widget.child;
    final armed = _dx >= _threshold;
    return GestureDetector(
      excludeFromSemantics: true, // screen readers get a Reply action on the bubble instead
      onHorizontalDragUpdate: (d) {
        final dx = (_dx + d.delta.dx).clamp(0.0, _threshold * 1.4);
        if (dx >= _threshold && _dx < _threshold) HapticFeedback.mediumImpact();
        setState(() => _dx = dx);
      },
      onHorizontalDragEnd: (_) {
        if (_dx >= _threshold) widget.onReply!();
        setState(() => _dx = 0);
      },
      onHorizontalDragCancel: () => setState(() => _dx = 0),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Opacity(
            opacity: (_dx / _threshold).clamp(0.0, 1.0),
            child: Icon(Icons.reply, size: armed ? 26 : 22),
          ),
          Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ],
      ),
    );
  }
}
