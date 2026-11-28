import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'l10n/app_localizations.dart';
import 'onboarding.dart' show showError;
import 'avatar.dart';
import 'browser.dart' if (dart.library.js_interop) 'browser_web.dart' as browser;
import 'backgrounds.dart';
import 'discovery.dart';
import 'format.dart';
import 'groups.dart';
import 'links.dart';
import 'location.dart';
import 'media.dart';
import 'preview.dart';
import 'update.dart';
import 'profile.dart';
import 'report.dart';
import 'stickers.dart';
import 'push.dart' show appVisible, clearNotification;
import 'safety.dart';
import 'search.dart';
import 'src/rust/api/core.dart';
import 'themes.dart';

/// Keeps the message stream connected (SRV-03) and tells screens when something arrived.
class ChatService extends ChangeNotifier {
  ChatService(
    this.core, {
    required this.onDeregistered,
    this.onMessage,
    this.onNumberRemoved,
    this.onEnforcement,
    this.onReportsReviewed,
  });
  final Core core;
  final VoidCallback onDeregistered;

  /// Another account took our number (docs/change-number.md).
  final VoidCallback? onNumberRemoved;

  /// M7: suspended, or our @username was removed (`core.notice()`).
  final VoidCallback? onEnforcement;

  /// M7: moderators reviewed this many of our reports.
  final void Function(int)? onReportsReviewed;

  /// Every new incoming message, e.g. to notify while the app is in the background.
  final void Function(MessageView)? onMessage;
  bool _stopped = false;

  // Counts changes per chat (events) and to all of them (our own actions), so an open chat only
  // re-reads its messages when they may have changed: not on typing, nor on other chats' events.
  final _changed = <String, int>{};
  int _changedAll = 0;
  int changes(Uint8List groupId) => _changedAll + (_changed[base64Encode(groupId)] ?? 0);

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
    // What the app was sending when it was last closed goes now; uploads carry on where they were.
    final t = lookupAppLocalizations(
      AppLocalizations.supportedLocales.firstWhere(
        (l) => l.languageCode == WidgetsBinding.instance.platformDispatcher.locale.languageCode,
        orElse: () => const Locale('en'),
      ),
    );
    unawaited(
      keepingAlive(t.sendingFiles, core.resumeSending).then((_) => refresh(), onError: (Object _) => refresh()),
    );
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
  void refresh() {
    _changedAll++;
    if (!_stopped) notifyListeners();
  }

  DateTime _lastEvent = DateTime(0);

  /// After a push (MSG-17): fetch what's waiting, so notifications show before Android freezes
  /// the app again. In the background, only that: a short drain (at most 20 s), without the
  /// upkeep a full connection does (keys, pictures, profiles), which would cost battery on every
  /// message. On screen: reconnect, then wait until messages stop (2 s quiet, 4 s to 15 s).
  Future<void> fetchNow() async {
    if (_paused) {
      try {
        await for (final e in core.drain()) {
          if (_onEvent(e)) return;
        }
      } on Object catch (e) {
        debugPrint('drain: ${e is CoreError ? e.code : e}');
      }
      return;
    }
    final start = DateTime.now();
    wake();
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final now = DateTime.now();
      final quiet = now.difference(_lastEvent) > const Duration(seconds: 2);
      if ((quiet && now.difference(start) > const Duration(seconds: 4)) ||
          now.difference(start) > const Duration(seconds: 15)) {
        if (_paused) _drop(); // hidden meanwhile: back to sleep, so the next message pushes again
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

  /// One event from the server; true once this device was deregistered.
  bool _onEvent(CoreEvent e) {
    _lastEvent = DateTime.now();
    if (e.kind == CoreEventKind.deregistered) {
      _stopped = true;
      onDeregistered(); // ID-12: the core already wiped local data
      return true;
    }
    if (e.kind == CoreEventKind.numberRemoved) onNumberRemoved?.call();
    if (e.kind == CoreEventKind.enforcement) onEnforcement?.call();
    if (e.kind == CoreEventKind.reportsReviewed) onReportsReviewed?.call(core.takeReportsReviewed());
    if (e.kind case CoreEventKind.typing || CoreEventKind.message) {
      _setTyping(e.groupId!, e.kind == CoreEventKind.typing, e.account);
    }
    if (e.kind == CoreEventKind.message && e.message != null) {
      onMessage?.call(e.message!);
      unawaited(autoDownload(core, e.message!)); // MED-12
    }
    if (e.kind != CoreEventKind.typing) {
      final g = e.groupId;
      g == null ? _changedAll++ : _changed.update(base64Encode(g), (n) => n + 1, ifAbsent: () => 1);
    }
    notifyListeners();
    return false;
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
          if (_onEvent(e)) finish();
        },
        onError: (Object e) {
          // Network error or server restart: reconnect below. The code says which (web console).
          debugPrint('stream: ${e is CoreError ? e.code : e}');
          finish();
        },
        onDone: finish,
      );
      await done.future;
      if (_stopped) return;
      // Suspended (M7): the server closes every stream, so wait for the end, not a backoff.
      final n = core.notice();
      if (n != null && n.suspended) {
        final left = DateTime.fromMillisecondsSinceEpoch(asInt(n.untilMs)).difference(DateTime.now());
        final sleep = _waiting = Completer<void>();
        final timer = Timer(left < const Duration(hours: 1) ? left : const Duration(hours: 1), () {
          if (!sleep.isCompleted) sleep.complete();
        });
        await sleep.future;
        timer.cancel();
        continue;
      }
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
        : Text(_time(context, asInt(c.last!.sentAt)), style: unread ? TextStyle(color: colors.primary) : null),
    onTap: () => openChat(context, core, service, c.groupId),
    onLongPress: c.request ? null : () => _chatActions(context, core, service, c),
  );
}

/// Archive or delete a chat from the list.
Future<void> _chatActions(BuildContext context, Core core, ChatService service, ChatSummary c) async {
  final t = AppLocalizations.of(context)!;
  final archived = isArchived(core, c.groupId);
  final pick = await showModalBottomSheet<String>(
    context: context,
    builder: (s) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(archived ? Icons.unarchive_outlined : Icons.archive_outlined),
            title: Text(archived ? t.unarchive : t.archive),
            onTap: () => Navigator.pop(s, 'archive'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(t.deleteChat),
            onTap: () => Navigator.pop(s, 'delete'),
          ),
        ],
      ),
    ),
  );
  if (pick == 'archive') {
    setArchived(core, c.groupId, !archived);
    service.refresh();
    if (!archived && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.archivedHint)));
    }
  } else if (pick == 'delete' && context.mounted) {
    await deleteChat(context, core, service, c);
  }
}

/// A 1:1 chat loses its messages here and comes back with the next one; a group is left and
/// deleted in one step.
Future<bool> deleteChat(BuildContext context, Core core, ChatService service, ChatSummary c) async {
  final t = AppLocalizations.of(context)!;
  final name = chatTitle(t, c);
  final leave = c.isGroup && !c.left;
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(leave ? t.leaveAndDeleteTitle(name) : t.deleteChatTitle(name)),
      content: Text(leave ? t.leaveAndDeleteBody : t.deleteChatBody),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.cancel)),
        TextButton(onPressed: () => Navigator.pop(d, true), child: Text(t.delete)),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    if (c.isGroup) {
      if (leave) await core.leaveGroup(groupId: c.groupId);
      core.deleteChat(groupId: c.groupId);
    } else {
      core.clearChat(groupId: c.groupId);
      core.setSetting(key: hiddenKey(c.groupId), value: '1');
      shareChatSetting(core, c.groupId, 'hidden', '1'); // M8: deleted on our other devices too
    }
    setArchived(core, c.groupId, false);
  } on CoreError catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  service.refresh();
  return true;
}

/// Chats in the main list (or the archive): no requests, no deleted 1:1 chats still empty.
List<ChatSummary> listedChats(Core core, {required bool archived, List<ChatSummary>? from}) => [
  for (final c in from ?? core.chats())
    if (!c.request &&
        isArchived(core, c.groupId) == archived &&
        !(c.last == null && core.setting(key: hiddenKey(c.groupId)) == '1'))
      c,
];

typedef SharedFile = ({String name, String path, String mime});

/// What another app shared to Siegel: text (a link, say) and copies of its files in our cache.
typedef Shared = ({String text, List<SharedFile> files});

/// Shared to Siegel: which chat it goes to. WebP images can go to my stickers instead.
class ShareScreen extends StatelessWidget {
  const ShareScreen({super.key, required this.core, required this.service, required this.shared});
  final Core core;
  final ChatService service;
  final Shared shared;

  /// Backing out: our copies of the files go.
  static void discard(Shared s) {
    for (final f in s.files) {
      File(f.path).delete().ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final stickers = shared.files.isNotEmpty && shared.files.every((f) => f.mime == 'image/webp');
    final chats = listedChats(core, archived: false).where((c) => !c.request && !c.left).toList();
    return PopScope(
      onPopInvokedWithResult: (popped, sent) {
        if (popped && sent != true) discard(shared);
      },
      child: Scaffold(
        appBar: SiegelBar(title: Text(t.sendTo)),
        body: ListView(
          children: [
            if (stickers)
              ListTile(
                leading: const Icon(Icons.emoji_emotions_outlined),
                title: Text(t.addToStickers),
                onTap: () {
                  final added = importStickerFiles(core, [
                    for (final f in shared.files) (f.name, File(f.path).readAsBytesSync()),
                  ]);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.stickersAdded(added))));
                  Navigator.pop(context);
                },
              ),
            for (final c in chats)
              ListTile(
                leading: c.isGroup
                    ? Avatar(core: core, groupId: c.groupId)
                    : Avatar(core: core, account: c.peerAccount),
                title: Text(chatTitle(t, c)),
                onTap: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => ChatScreen(core: core, service: service, groupId: c.groupId, shared: shared),
                  ),
                  result: true, // handed on: the chat sends or deletes the copies
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ArchivedScreen extends StatelessWidget {
  const ArchivedScreen({super.key, required this.core, required this.service});
  final Core core;
  final ChatService service;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: SiegelBar(title: Text(t.archived)),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final chats = listedChats(core, archived: true);
          if (chats.isEmpty) return Center(child: Text(t.noArchived));
          return ListView(children: [for (final c in chats) _chatTile(context, core, service, c)]);
        },
      ),
    );
  }
}

/// Opens a chat: beside the list on a wide window, over it otherwise.
/// [jumpTo]: a message to scroll to once the chat is open (a search result).
void openChat(BuildContext context, Core core, ChatService service, Uint8List groupId, {Uint8List? jumpTo}) {
  final wide = context.getInheritedWidgetOfExactType<_WideChats>();
  final route = MaterialPageRoute<void>(
    builder: (_) => ChatScreen(core: core, service: service, groupId: groupId, jumpTo: jumpTo),
  );
  if (wide == null) {
    Navigator.of(context).push(route);
  } else {
    wide.pane.currentState?.pushAndRemoveUntil(route, (r) => r.isFirst);
  }
}

class _WideChats extends InheritedWidget {
  const _WideChats({required this.pane, required super.child});
  final GlobalKey<NavigatorState> pane;

  @override
  bool updateShouldNotify(_WideChats old) => false;
}

/// M8 part 6: the home screen. On a wide window (a browser, a tablet) the open chat sits
/// beside the list, in its own navigator: a chat that closes itself leaves the placeholder.
const _savedKey = 'saved_messages';
bool _savingMessages = false;

/// A "Saved messages" chat: a group of just us, made once by the phone. Linked devices get it
/// like any other chat. Deleted, it stays deleted.
Future<void> ensureSavedMessages(Core core, String name) async {
  if (_savingMessages || core.isLinkedDevice() || core.setting(key: _savedKey) != null) return;
  _savingMessages = true;
  try {
    await core.createGroup(name: name, usernames: const []);
    core.setSetting(key: _savedKey, value: '1');
  } on Object {
    // Offline, say: tried again next time the app opens.
  } finally {
    _savingMessages = false;
  }
}

class ChatsHome extends StatefulWidget {
  const ChatsHome({super.key, required this.core, required this.service, required this.settings});
  final Core core;
  final ChatService service;
  final WidgetBuilder settings;

  static const wideFrom = 840.0;

  @override
  State<ChatsHome> createState() => _ChatsHomeState();
}

class _ChatsHomeState extends State<ChatsHome> {
  final _pane = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ensureSavedMessages(widget.core, AppLocalizations.of(context)!.savedMessages);
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = ChatListScreen(core: widget.core, service: widget.service, settings: widget.settings);
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth < ChatsHome.wideFrom
          ? list
          : _WideChats(
              pane: _pane,
              child: Row(
                children: [
                  SizedBox(width: 360, child: list),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Navigator(
                      key: _pane,
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (context) =>
                            Scaffold(body: Center(child: Text(AppLocalizations.of(context)!.noChatOpen))),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key, required this.core, required this.service, required this.settings});
  final Core core;
  final ChatService service;
  final WidgetBuilder settings;

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  Core get core => widget.core;
  ChatService get service => widget.service;
  WidgetBuilder get settings => widget.settings;

  /// The archived row stays out of sight until the list is pulled down, as on WhatsApp.
  bool _archivedShown = false;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: SiegelBar(
        title: Text(t.chatsTitle),
        actions: [
          IconButton(
            tooltip: t.searchMessages,
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SearchScreen(core: core, service: service),
              ),
            ),
          ),
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
          final all = core.chats(); // once per rebuild: each call crosses into the core
          final chats = listedChats(core, archived: false, from: all);
          final requests = all.where((c) => c.request).length;
          final archived = listedChats(core, archived: true, from: all);
          final archivedUnread = archived.where((c) => c.unread > 0).length;
          final head = <Widget>[
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
            if (archived.isNotEmpty && (_archivedShown || chats.isEmpty))
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: Text(t.archived),
                trailing: archivedUnread == 0
                    ? null
                    : Text('$archivedUnread', semanticsLabel: t.unreadChats(archivedUnread)),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ArchivedScreen(core: core, service: service),
                  ),
                ),
              ),
            if (chats.isEmpty && requests == 0 && archived.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(t.noChats, textAlign: TextAlign.center),
              ),
          ];
          // Pull down to reconnect at once and fetch anything waiting, and to show the archived row.
          return RefreshIndicator(
            onRefresh: () async {
              setState(() => _archivedShown = true);
              service.wake();
              await Future<void>.delayed(const Duration(seconds: 1));
              service.refresh();
            },
            // Built lazily: only the rows on screen.
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: head.length + chats.length,
              itemBuilder: (context, i) =>
                  i < head.length ? head[i] : _chatTile(context, core, service, chats[i - head.length]),
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
          // M8: the browser has neither the camera scanner nor the phone's contacts.
          if (!kIsWeb) ...[
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
          ],
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

/// Siegel Web's keyboard and mouse: Enter sends (Shift+Enter is a new line), a reply button
/// shows beside the bubble under the pointer, and files dropped on the page go to the open chat.
@visibleForTesting
bool webUi = kIsWeb;

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.core,
    required this.service,
    required this.groupId,
    this.jumpTo,
    this.shared,
  });
  final Core core;
  final ChatService service;
  final Uint8List groupId;
  final Uint8List? jumpTo;

  /// Shared in from another app: photos go through the usual look before sending, text waits in
  /// the composer, videos ask their quality, other files go as they are.
  final Shared? shared;

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
  List<MessageView> _cached = const [];
  (String, int)? _cachedAt; // which chat, at which change
  final _scroll = ScrollController();
  final _away = ValueNotifier(false); // scrolled up from the newest message
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
    if (webUi) browser.onDrop = _dropped;
    _scroll.addListener(() => _away.value = _scroll.offset > 400);
    final to = widget.jumpTo;
    if (to != null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _jumpTo(to) : null);
    final shared = widget.shared;
    if (shared != null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _takeShared(shared) : null);
  }

  Future<void> _takeShared(Shared s) async {
    if (s.text.isNotEmpty) _text.text = s.text;
    bool photo(SharedFile f) => f.mime.startsWith('image/') && f.mime != 'image/svg+xml';
    try {
      final photos = <Outgoing>[];
      for (final f in s.files.where(photo)) {
        try {
          photos.add(await photoOf(await File(f.path).readAsBytes(), gif: f.mime == 'image/gif'));
        } finally {
          File(f.path).delete().ignore(); // our copy; the photo is re-encoded in memory
        }
      }
      if (photos.isNotEmpty) {
        for (final o in await _photos(() async => photos)) {
          await _sendAttachment(o);
        }
      }
      for (final f in s.files.where((f) => !photo(f))) {
        if (!mounted) return;
        final o = f.mime.startsWith('video/')
            ? await videoFrom(f.path, (size) async {
                final q = await _askQuality(size);
                if (q != null && q != VideoQuality.original && mounted) setState(() => _busy = true);
                return q;
              }, copy: true)
            : outgoing(Uint8List(0), f.mime, name: f.name, path: f.path, temp: true);
        if (mounted) setState(() => _busy = false);
        if (o != null) await _sendAttachment(o);
      }
    } on TooLarge {
      if (mounted) showError(context, const CoreError(code: 'attachment_too_large'));
    } on CompressFailed {
      if (mounted) showError(context, const CoreError(code: 'video_compress_failed'));
    } on Exception catch (e) {
      debugPrint('share: $e');
      if (mounted) showError(context, const CoreError(code: 'attachment_invalid'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    if (webUi && browser.onDrop == _dropped) browser.onDrop = null;
    widget.service.removeListener(_markRead);
    _lifecycle.dispose();
    // The chat list redraws without this chat's unread count (after the tree is unlocked).
    final service = widget.service;
    Future.microtask(service.refresh);
    _recTimer?.cancel();
    _voice?.dispose();
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    _away.dispose();
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
  // The bar shows at the tap; the red dot once the microphone is live. One recorder per chat:
  // a fresh one takes a noticeable moment to start each time.
  VoiceRecorder? _recorder, _voice;
  Future<bool>? _starting;
  Timer? _recTimer;

  Future<void> _startRecording() async {
    final r = _voice ??= VoiceRecorder();
    HapticFeedback.mediumImpact();
    setState(() => _recorder = r);
    _recTimer = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
    final ok = await (_starting = r.start());
    _starting = null;
    if (ok || !mounted) return;
    _recTimer?.cancel();
    setState(() => _recorder = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.micDenied)));
  }

  Future<void> _stopRecording({required bool send}) async {
    final r = _recorder!;
    _recTimer?.cancel();
    setState(() => _recorder = null);
    if (!await (_starting ?? Future.value(true))) return; // tapped again before it began
    final rec = await r.stop(keep: send);
    if (rec == null) return;
    if (rec.ms < 500) {
      if (rec.path.isNotEmpty) File(rec.path).delete().ignore();
      return; // a slip of the finger, not a message
    }
    await _sendAttachment(
      outgoing(rec.data, r.mime, ms: rec.ms, voice: true, waveform: rec.waveform, path: rec.path, temp: true),
    );
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
              (4, Icons.photo_camera_outlined, t.camera),
              (0, Icons.photo_outlined, t.photo),
              (1, Icons.videocam_outlined, t.video),
              (2, Icons.insert_drive_file_outlined, t.file),
              (3, Icons.audio_file_outlined, t.attachAudio),
              (5, Icons.location_on_outlined, t.location),
            ])
              ListTile(leading: Icon(icon), title: Text(label), onTap: () => Navigator.pop(c, i)),
          ],
        ),
      ),
    );
    if (choice == null) return;
    if (choice == 5) return _shareLocation();
    try {
      if (choice == 2 || choice == 3) {
        await for (final o in pickFiles(audio: choice == 3)) {
          await _sendAttachment(o);
        }
        return;
      }
      if (choice == 0 || choice == 4) {
        for (final o in await _photos(choice == 4 ? _shot : pickPhotos)) {
          await _sendAttachment(o); // one by one, in order; they show as an album
        }
        return;
      }
      final o = await pickVideo((size) async {
        final q = await _askQuality(size);
        if (q != null && q != VideoQuality.original && mounted) setState(() => _busy = true); // a while
        return q;
      });
      if (mounted) setState(() => _busy = false);
      if (o != null) await _sendAttachment(o);
    } on TooLarge {
      if (mounted) showError(context, const CoreError(code: 'attachment_too_large')); // MED-06
    } on CompressFailed {
      if (mounted) showError(context, const CoreError(code: 'video_compress_failed'));
    } on Exception catch (e) {
      debugPrint('attach: $e'); // a picker or codec failure: say so rather than nothing
      if (mounted) showError(context, const CoreError(code: 'attachment_invalid'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks before sending: where we are is sensitive, and a fix can be off.
  Future<void> _shareLocation() async {
    final t = AppLocalizations.of(context)!;
    setState(() => _busy = true); // a fix can take a few seconds
    final (Location, double)? here;
    try {
      here = await currentLocation();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (here == null) return showError(context, const CoreError(code: 'location_unavailable'));
    final (l, accuracy) = here;
    var minutes = 0; // 0: where we are now; else live for that long
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: Text(t.sendLocationTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LocationMessage(l),
              const SizedBox(height: 12),
              Text(t.sendLocationBody(accuracy.round())),
              // A browser tab can't keep sending its position, so live is phone only.
              if (!kIsWeb) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in const [0, 5, 10, 15])
                      ChoiceChip(
                        label: Text(m == 0 ? t.currentLocation : t.liveFor(m)),
                        selected: minutes == m,
                        onSelected: (_) => set(() => minutes = m),
                      ),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.cancel)),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(t.send)),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if (minutes > 0) {
      return _run(
        () => shareLive(
          core,
          _group,
          l,
          Duration(minutes: minutes),
          notice: t.sharingLiveLocation,
          changed: widget.service.refresh,
        ),
      );
    }
    final reply = _replyTo;
    setState(() => _replyTo = null);
    await _run(() => core.sendText(groupId: _group, text: locationText(l), replyTo: reply?.messageId, mentions: []));
  }

  /// Siegel Web: files dropped or pasted on the page are sent here, photos made smaller like
  /// picked ones; big files go a piece at a time.
  Future<void> _dropped(List<browser.Dropped> files) async {
    final c = _summary();
    if (_editing != null || c == null || c.left || c.request) {
      for (final f in files) {
        if (f.url.isNotEmpty) browser.revokeUrl(f.url);
      }
      return; // only where the composer is
    }
    for (final f in files) {
      final mime = f.type.isNotEmpty ? f.type : mimeFor(f.name);
      try {
        if (f.size > maxFile) throw TooLarge();
        if (f.url.isNotEmpty) {
          await _sendAttachment(outgoing(Uint8List(0), mime, name: f.name, path: f.url, size: f.size));
          continue;
        }
        final photo = mime.startsWith('image/') && mime != 'image/svg+xml';
        await _sendAttachment(
          photo ? await photoOf(f.data, gif: mime == 'image/gif') : outgoing(f.data, mime, name: f.name),
        );
      } on TooLarge {
        if (f.url.isNotEmpty) browser.revokeUrl(f.url);
        if (mounted) showError(context, const CoreError(code: 'attachment_too_large'));
      } on Object catch (e) {
        debugPrint('drop: $e');
        if (mounted) showError(context, const CoreError(code: 'attachment_invalid'));
      }
      if (!mounted) return;
    }
  }

  /// M9: photos (camera or gallery) go through a look before sending, where one alone can be
  /// made view once.
  Future<List<Outgoing>> _photos(Future<List<Outgoing>> Function() pick) async {
    final ps = await pick();
    if (ps.isEmpty || !mounted) return const [];
    setState(() => _busy = false);
    return await Navigator.of(context)
            .push<List<Outgoing>>(MaterialPageRoute(builder: (_) => PhotoSendScreen(photos: ps))) ??
        const [];
  }

  static Future<List<Outgoing>> _shot() async => [?await takePhoto()];

  /// M9: the composer's camera button.
  Future<void> _camera() async {
    try {
      for (final o in await _photos(_shot)) {
        await _sendAttachment(o);
      }
    } on Exception catch (e) {
      debugPrint('camera: $e');
      if (mounted) showError(context, const CoreError(code: 'attachment_invalid'));
    }
  }

  /// MED-08: Standard (720p, quick to send), HD (1080p) or the original; over 1 GB the
  /// original can't go.
  Future<VideoQuality?> _askQuality(int size) {
    final t = AppLocalizations.of(context)!;
    final big = size > maxFile;
    Widget option(BuildContext d, VideoQuality q, String title, String help) => ListTile(
      enabled: q != VideoQuality.original || !big,
      title: Text(title),
      subtitle: Text(help),
      onTap: () => Navigator.pop(d, q),
    );
    return showDialog<VideoQuality>(
      context: context,
      builder: (d) => SimpleDialog(
        title: Text(t.videoQuality),
        children: [
          if (big) Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Text(t.compressVideoMust)),
          option(d, VideoQuality.standard, t.qualityStandard, t.qualityStandardHelp),
          option(d, VideoQuality.hd, t.qualityHd, t.qualityHdHelp),
          option(d, VideoQuality.original, t.qualityOriginal, t.qualityOriginalHelp(formatSize(size))),
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
    if (kIsWeb && o.path.isNotEmpty) return _streamUp(o, reply);
    if (o.viewOnce) {
      // M9: no copy is kept to queue; it goes in one go.
      return _run(
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
          sticker: o.sticker,
          viewOnce: true,
          replyTo: reply?.messageId,
        ),
      );
    }
    // Shown at once as sending, uploaded behind it, resumable. From disk (phones: videos,
    // files, voice notes) the app stays up until it's uploaded: Android only lets the app start
    // that while it's in front.
    final done = Completer<void>();
    if (o.path.isNotEmpty) unawaited(keepingAlive(AppLocalizations.of(context)!.sendingFiles, () => done.future));
    final MessageView m;
    try {
      m = o.path.isNotEmpty
          ? await core.queueAttachmentFile(
              groupId: _group,
              path: o.path,
              mimeType: o.mime,
              fileName: o.name,
              durationMs: o.ms,
              width: o.width,
              height: o.height,
              thumbnail: o.thumbnail,
              voiceNote: o.voice,
              waveform: o.waveform,
              replyTo: reply?.messageId,
            )
          : await core.queueAttachment(
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
              sticker: o.sticker,
              replyTo: reply?.messageId,
            );
    } on CoreError catch (e) {
      done.complete();
      if (mounted) showError(context, e);
      return;
    } catch (_) {
      done.complete(); // never leave the notification up
      rethrow;
    } finally {
      if (o.temp) File(o.path).delete().ignore(); // encrypted into the chat's own copy
    }
    final service = widget.service..refresh();
    _uploads = _uploads.then((_) async {
      try {
        await core.retry(messageId: m.messageId);
      } on CoreError {
        // Marked failed, with a retry that carries on where it stopped (MSG-04).
      } finally {
        done.complete();
      }
      service.refresh();
    });
  }

  /// Siegel Web: a big file read from its blob: URL and sent a piece at a time, never whole in
  /// memory. Nothing is kept to resume from, so the page asks before it's left meanwhile.
  Future<void> _streamUp(Outgoing o, MessageView? reply) async {
    final MessageView m;
    try {
      m = await core.queueAttachmentStream(
        groupId: _group,
        size: BigInt.from(o.size),
        mimeType: o.mime,
        fileName: o.name,
        durationMs: o.ms,
        width: o.width,
        height: o.height,
        thumbnail: o.thumbnail,
        replyTo: reply?.messageId,
      );
    } on CoreError catch (e) {
      browser.revokeUrl(o.path);
      if (mounted) showError(context, e);
      return;
    }
    browser.holdPage(true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.keepTabOpen)));
    }
    final service = widget.service..refresh();
    // A network error: the same piece again, a few times, waiting longer each time.
    Future<bool> push(Uint8List piece) async {
      for (var tries = 0; ; tries++) {
        try {
          return await core.pushAttachmentStream(messageId: m.messageId, piece: tries == 0 ? piece : Uint8List(0));
        } on CoreError catch (e) {
          if (e.code == 'attachment_invalid' || tries == 5) rethrow;
          await Future<void>.delayed(Duration(seconds: 2 << tries));
        }
      }
    }

    _uploads = _uploads.then((_) async {
      try {
        const piece = 8 << 20; // whole 64 KB chunks
        final pending = BytesBuilder(copy: false);
        await for (final bytes in browser.readUrl(o.path)) {
          pending.add(bytes);
          while (pending.length >= piece) {
            final all = pending.takeBytes();
            await push(Uint8List.sublistView(all, 0, piece));
            pending.add(Uint8List.sublistView(all, piece));
          }
        }
        if (pending.isNotEmpty) await push(pending.takeBytes());
      } on Object catch (e) {
        debugPrint('stream up: $e'); // marked failed below: it has to be sent again
      } finally {
        browser.revokeUrl(o.path);
      }
      try {
        await core.retry(messageId: m.messageId);
      } on CoreError {
        // Failed, with a retry
      } finally {
        browser.holdPage(false);
      }
      service.refresh();
    });
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
    final MessageView m;
    try {
      // Shown at once with a clock; delivered behind it, in the order they were written.
      m = core.queueText(groupId: _group, text: text, replyTo: reply?.messageId, mentions: mentions);
    } on CoreError catch (e) {
      return showError(context, e);
    }
    final service = widget.service..refresh();
    final card = core.setting(key: previewsSetting) == 'off' ? null : fetchPreview(text);
    _sending = _sending.then((_) async {
      if (await card case final p?) {
        try {
          core.setLinkPreview(messageId: m.messageId, preview: p);
        } on CoreError {
          // sent without it
        }
      }
      try {
        await core.retry(messageId: m.messageId);
      } on CoreError {
        // Marked failed in the chat, with a retry (MSG-04).
      }
      service.refresh();
    });
  }

  Future<void> _sending = Future.value();

  /// Files go one after another, apart from texts, so a long upload doesn't hold them up.
  Future<void> _uploads = Future.value();

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

  /// CMP-03: the report screen; a blocked 1:1 chat closes, like blocking does.
  Future<void> _report(ChatSummary c, {MessageView? around, bool block = false}) async {
    final sent = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReportScreen(core: core, chat: c, around: around, block: block),
      ),
    );
    widget.service.refresh();
    if (sent == true && block && mounted) Navigator.of(context).pop();
  }

  Future<void> _saveSticker(MessageView m) => _run(() async {
    final data = await core.attachmentData(messageId: m.messageId);
    core.addSticker(data: data, mimeType: m.attachment!.mimeType, pack: '');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.stickerAdded)));
    }
  });

  Future<void> _sticker() async {
    final s = await pickSticker(context, core, _text);
    if (s == null) return;
    if (s.mime == 'image/gif') {
      // A GIF from GIPHY goes as a photo, animated.
      final (w, h) = await sizeOf(s.data);
      await _sendAttachment(outgoing(s.data, s.mime, width: w, height: h, thumbnail: await thumbnailOf(s.data)));
    } else {
      await _sendAttachment(outgoing(s.data, s.mime, width: 512, height: 512, sticker: true));
    }
  }

  /// Any emoji as a reaction.
  Future<void> _pickReaction(MessageView m) async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (s) => SafeArea(
        child: SizedBox(
          height: 360,
          child: EmojiPicker(onEmojiSelected: (_, e) => Navigator.pop(s, e.emoji), config: emojiConfig(context)),
        ),
      ),
    );
    if (emoji != null) await _run(() => core.react(groupId: _group, messageId: m.messageId, emoji: emoji));
  }

  /// Long-press actions. Edit and delete-for-everyone only show inside their windows;
  /// the core checks the same rules (MSG-09, MSG-11).
  void _actions(MessageView m, ChatSummary c) {
    final t = AppLocalizations.of(context)!;
    final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(asInt(m.sentAt)));
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
                    // A reaction from the full picker takes the last quick slot, selected.
                    for (final e in mine == null || _emojis.contains(mine) ? _emojis : [..._emojis.take(5), mine])
                      IconButton(
                        isSelected: e == mine,
                        icon: Text(e, style: const TextStyle(fontSize: 24)),
                        onPressed: () => act(
                          () => _run(
                            () => core.react(groupId: _group, messageId: m.messageId, emoji: e == mine ? '' : e),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: t.moreReactions,
                      icon: const Icon(Icons.add_reaction_outlined),
                      onPressed: () => act(() => _pickReaction(m)),
                    ),
                  ],
                ),
              if (!m.deleted && !c.request)
                ListTile(leading: const Icon(Icons.reply), title: Text(t.reply), onTap: () => act(() => _reply(m))),
              if (!m.deleted && m.event == null && !m.keyChange && m.attachment?.viewOnce != true)
                ListTile(
                  leading: const Icon(Icons.shortcut),
                  title: Text(t.forward),
                  onTap: () => act(() => _forward(m)),
                ),
              if (!m.outgoing && !m.deleted && m.event == null && !m.keyChange)
                ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: Text(t.report),
                  onTap: () => act(() => _report(c, around: m)),
                ),
              if (!m.deleted && m.attachment?.sticker == true)
                ListTile(
                  leading: const Icon(Icons.bookmark_add_outlined),
                  title: Text(t.addToMyStickers),
                  onTap: () => act(() => _saveSticker(m)),
                ),
              if (!m.deleted &&
                  m.attachment != null &&
                  !m.attachment!.voiceNote &&
                  !m.attachment!.sticker &&
                  !m.attachment!.viewOnce)
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
                  locationOf(m.text) == null &&
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
              if (m.edited && !m.deleted && locationOf(m.text) == null) // live locations update by editing
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
              if (!c.request) IconButton(tooltip: t.searchInChat, icon: const Icon(Icons.search), onPressed: _search),
              if (!c.request && !c.isGroup)
                PopupMenuButton<void>(
                  itemBuilder: (_) => [
                    PopupMenuItem(onTap: () => _safety(c), child: Text(t.safetyNumber)),
                    if (!c.left) PopupMenuItem(onTap: _repair, child: Text(t.repairChat)),
                    PopupMenuItem(onTap: () => _report(c), child: Text(t.report)),
                    PopupMenuItem(onTap: () => _block(c), child: Text(t.block)),
                  ],
                ),
              if (!c.request && c.isGroup)
                PopupMenuButton<void>(
                  itemBuilder: (_) => [PopupMenuItem(onTap: () => _report(c), child: Text(t.reportGroup))],
                ),
            ],
          ),
          // The background runs behind the composer too; the message box is filled over it.
          body: ChatBackground(
            core: core,
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      _messages(context, c),
                      PositionedDirectional(
                        end: 12,
                        bottom: 12,
                        child: ValueListenableBuilder(
                          valueListenable: _away,
                          builder: (_, away, _) => away
                              ? IconButton.filledTonal(
                                  tooltip: t.scrollToBottom,
                                  icon: const Icon(Icons.keyboard_arrow_down),
                                  onPressed: () => _scroll.animateTo(
                                    0,
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeOut,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ],
                  ),
                ),
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

  /// Older bubbles aren't built until scrolled to: page up until the quoted one is.
  /// Search this chat only; the message found is scrolled to and tinted.
  Future<void> _search() async {
    final found = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => SearchScreen(core: core, service: widget.service, groupId: _group),
      ),
    );
    if (found != null && mounted) await _jumpTo(found);
  }

  /// Our messages stopped reaching them (their app fell out of step with this chat's keys): a
  /// fresh session, and what they never confirmed goes again.
  Future<void> _repair() async {
    final t = AppLocalizations.of(context)!;
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t.repairChat),
        content: Text(t.repairChatHelp),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(t.repairChat)),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final n = await core.repairChat(groupId: _group);
      widget.service.refresh();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.chatRepaired(n))));
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Who reacted with what; our own reaction can be taken back from here.
  void _whoReacted(List<MessageView> ms, ChatSummary c) {
    final me = c.isGroup ? myAccount(core, _group) : null;
    bool mine(Reaction r) => c.isGroup ? listEquals(r.account, me) : !listEquals(r.account, c.peerAccount);
    showModalBottomSheet<void>(
      context: context,
      builder: (d) {
        final t = AppLocalizations.of(d)!;
        final all = [
          for (final m in ms)
            for (final r in m.reactions) (m, r),
        ]..sort((a, b) => a.$2.emoji.compareTo(b.$2.emoji));
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(t.reactions, style: Theme.of(d).textTheme.titleMedium)),
              for (final (m, r) in all)
                if (mine(r))
                  ListTile(
                    leading: Avatar(core: core),
                    title: Text(t.you),
                    subtitle: Text(t.tapToRemove),
                    trailing: Text(r.emoji, style: const TextStyle(fontSize: 22)),
                    onTap: () {
                      Navigator.pop(d);
                      _run(() => core.react(groupId: _group, messageId: m.messageId, emoji: ''));
                    },
                  )
                else
                  ListTile(
                    leading: Avatar(core: core, account: r.account),
                    title: Text(memberName(t, core, r.account)),
                    trailing: Text(r.emoji, style: const TextStyle(fontSize: 22)),
                  ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _jumpTo(Uint8List messageId) async {
    final key = base64Encode(messageId);
    for (var i = 0; i < 100 && mounted && _keys[key]?.currentContext == null; i++) {
      final p = _scroll.position;
      if (p.pixels >= p.maxScrollExtent) return; // not among the loaded messages
      _scroll.jumpTo(min(p.pixels + p.viewportDimension, p.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
    }
    final ctx = _keys[key]?.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.5);
      // A moment's tint says which bubble it is (an album's photo: the album).
      final shown = _inAlbum[key] ?? key;
      if (!mounted) return;
      setState(() => _flash = shown);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted && _flash == shown) setState(() => _flash = null);
    }
  }

  String? _flash;

  /// Each album photo's ID → the album's newest, where the album shows.
  final _inAlbum = <String, String>{};

  /// Four or more photos in a row from one sender, each within a minute of the last, show as one
  /// album, as on WhatsApp. Keyed by the newest; the photos oldest first.
  Map<String, List<MessageView>> _albums(List<MessageView> messages) {
    final albums = <String, List<MessageView>>{};
    _inAlbum.clear();
    var run = <MessageView>[];
    void close() {
      if (run.length >= 4) {
        final head = base64Encode(run.last.messageId);
        albums[head] = run;
        for (final p in run) {
          _inAlbum[base64Encode(p.messageId)] = head;
        }
      }
      run = [];
    }

    for (final m in messages) {
      final joins =
          run.isNotEmpty &&
          isPhoto(m) &&
          m.replyTo == null &&
          m.outgoing == run.last.outgoing &&
          listEquals(m.senderAccount, run.last.senderAccount) &&
          asInt(m.sentAt) - asInt(run.last.sentAt) <= 60000;
      if (joins) {
        run.add(m);
      } else {
        close();
        if (isPhoto(m)) run = [m];
      }
    }
    close();
    return albums;
  }

  /// An album: a 2×2 grid; the last square says how many more and opens them all.
  Widget _album(List<MessageView> photos, ChatSummary c) {
    final more = photos.length - 4;
    // Two squares a row, inside the bubble's padding on narrow phones.
    final side = min(118.0, (MediaQuery.sizeOf(context).width * 0.78 - 24 - 4) / 2);
    return SizedBox(
      width: side * 2 + 4,
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final (i, p) in photos.take(4).indexed)
            SizedBox.square(
              dimension: side,
              child: GestureDetector(
                onLongPress: () => _actions(p, c),
                child: i < 3 || more <= 0
                    ? ImageMessage(core: core, message: p, tile: true)
                    : GestureDetector(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => AlbumScreen(core: core, photos: photos),
                          ),
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            AbsorbPointer(
                              child: ImageMessage(core: core, message: p, tile: true),
                            ),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: ColoredBox(
                                color: Colors.black54,
                                child: Center(
                                  child: Text('+$more', style: const TextStyle(color: Colors.white, fontSize: 24)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }

  /// MSG-07: the quoted message, in a bubble or above the composer: who, what, and its picture.
  Widget _quoteOf(AppLocalizations t, ChatSummary c, MessageView? q) {
    final colors = Theme.of(context).colorScheme;
    final a = q?.attachment;
    return _Quote(
      who: q == null
          ? null
          : q.outgoing
          ? t.you
          : c.isGroup
          ? memberName(t, core, q.senderAccount)
          : chatTitle(t, c),
      text: q == null
          ? t.originalMissing
          : q.deleted
          ? t.messageDeleted
          : messageText(t, q),
      thumb: q == null || q.deleted || a == null || a.viewOnce || a.thumbnail.isEmpty ? null : a.thumbnail,
      accent: q == null || q.outgoing || !c.isGroup
          ? colors.primary
          : memberColor(q.senderAccount, colors.surfaceContainerHighest),
    );
  }

  // ponytail: the newest 500 messages; paginate if chats get long.
  Widget _messages(BuildContext context, ChatSummary c) {
    final at = (base64Encode(_group), widget.service.changes(_group));
    if (at != _cachedAt) {
      _cachedAt = at;
      _cached = core.messages(groupId: _group, limit: 500);
    }
    final messages = _cached;
    final byId = {for (final m in messages) base64Encode(m.messageId): m};
    final index = <Key?, int>{
      for (final (i, m) in messages.reversed.indexed) ...{
        _keys[base64Encode(m.messageId)]: i,
        ValueKey('day ${base64Encode(m.messageId)}'): i,
      },
    };
    final albums = c.request ? const <String, List<MessageView>>{} : _albums(messages);
    // Built lazily, newest at the bottom: only what's on screen is laid out.
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.all(12),
      itemCount: messages.length,
      findChildIndexCallback: (key) => index[key], // a new message keeps the others' state
      itemBuilder: (context, i) {
        final m = messages[messages.length - 1 - i];
        final id = base64Encode(m.messageId);
        if (_inAlbum[id] case final head? when head != id) {
          return SizedBox.shrink(key: _keys.putIfAbsent(id, GlobalKey.new)); // shown in its album
        }
        final item = m.event != null
            ? _systemLine(context, m)
            : m.keyChange
            ? _keyChange(context, m, c)
            : _bubble(context, m, byId, c, album: albums[id]);
        // The first message of each day carries the day above it, as on WhatsApp.
        final older = i + 1 < messages.length ? messages[messages.length - 2 - i] : null;
        if (older != null && _day(older.sentAt) == _day(m.sentAt)) return item;
        return Column(
          key: ValueKey('day $id'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [_DayChip(_day(m.sentAt)), item],
        );
      },
    );
  }

  static DateTime _day(Object sentAt) {
    final d = DateTime.fromMillisecondsSinceEpoch(asInt(sentAt));
    return DateTime(d.year, d.month, d.day);
  }

  void _reply(MessageView m) => setState(() {
    _replyTo = m;
    _editing = null;
    _focus.requestFocus();
  });

  Widget _bubble(
    BuildContext context,
    MessageView m,
    Map<String, MessageView> byId,
    ChatSummary c, {
    List<MessageView>? album,
  }) {
    final t = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final sticker = m.attachment?.sticker == true && !m.deleted; // large, no bubble
    final grad = m.outgoing && !sticker ? Theme.of(context).extension<SiegelGradient>() : null; // gradient themes
    final small = Theme.of(context).textTheme.labelSmall?.copyWith(color: grad?.on);
    final id = base64Encode(m.messageId);
    final first = album?.first ?? m; // an album's quote is on its first photo
    final quoted = first.replyTo == null ? null : byId[base64Encode(first.replyTo!)];
    final failed = m.status == MessageStatus.failed;

    final counts = <String, int>{};
    for (final r in [
      for (final p in album ?? [m]) ...p.reactions,
    ]) {
      counts[r.emoji] = (counts[r.emoji] ?? 0) + 1;
    }
    return AnimatedContainer(
      key: _keys.putIfAbsent(id, GlobalKey.new),
      duration: const Duration(milliseconds: 400),
      color: colors.primary.withValues(alpha: _flash == id ? 0.2 : 0),
      child: Align(
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
            outgoing: m.outgoing,
            child: GestureDetector(
              onLongPress: () => _actions(m, c),
              onSecondaryTap: webUi ? () => _actions(m, c) : null, // a right click, in the browser

              onTap: failed ? () => _run(() => core.retry(messageId: m.messageId)) : null,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
                decoration: BoxDecoration(
                  color: grad != null || sticker
                      ? null
                      : (m.outgoing ? colors.primaryContainer : colors.surfaceContainerHighest),
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
                              style: small?.copyWith(
                                color: memberColor(m.senderAccount, colors.surfaceContainerHighest),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        if (m.forwarded && !m.deleted)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.shortcut, size: 14, color: small?.color),
                              const SizedBox(width: 4),
                              Text(t.forwarded, style: small?.copyWith(fontStyle: FontStyle.italic)),
                            ],
                          ),
                        if (first.replyTo != null && !m.deleted)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: GestureDetector(onTap: () => _jumpTo(first.replyTo!), child: _quoteOf(t, c, quoted)),
                          ),
                        if (m.deleted)
                          Text(t.messageDeleted, style: const TextStyle(fontStyle: FontStyle.italic))
                        else if (album != null)
                          _album(album, c)
                        else if (m.attachment != null)
                          attachmentView(core, m, held: c.request)
                        else if (locationOf(m.text) case final l?)
                          ValueListenableBuilder(
                            valueListenable: liveSharing,
                            builder: (_, sharing, _) => LocationMessage(
                              l,
                              until: liveUntil(m.text),
                              onStop: sharing.contains(id)
                                  ? () => stopLive(core, m.messageId, early: true, changed: widget.service.refresh)
                                  : null,
                            ),
                          )
                        else ...[
                          if (m.preview case final p?) LinkPreviewCard(p),
                          Text.rich(formatText(m.text, onLink: openUrl)),
                        ],
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (m.edited &&
                                !m.deleted &&
                                locationOf(m.text) == null) // live locations update by editing
                              GestureDetector(
                                onTap: () => _history(m),
                                child: Text('${t.edited} ', style: small),
                              ),
                            Text(_time(context, asInt(m.sentAt)), style: small),
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
                          Semantics(
                            button: true,
                            onTapHint: t.reactions,
                            child: InkWell(
                              onTap: () => _whoReacted(album ?? [m], c),
                              child: Text(
                                [for (final e in counts.entries) e.value > 1 ? '${e.key} ${e.value}' : e.key]
                                    .join('  '),
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ),
                      ],
                    ),
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
        MessageStatus.opened => Icon(Icons.done_all, size: 16, color: read, semanticLabel: t.viewOnceOpened),
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
            OutlinedButton(onPressed: _busy ? null : () => _report(c, block: true), child: Text(t.reportAndBlock)),
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
                Expanded(child: _editing != null ? Text(t.editing) : _quoteOf(t, c, target)),
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
          if (_busy) const LinearProgressIndicator(minHeight: 2), // compressing or sending
          if (_recorder != null)
            Row(
              children: [
                IconButton(
                  tooltip: t.cancel,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _stopRecording(send: false),
                ),
                Icon(
                  Icons.fiber_manual_record,
                  color: _recorder!.live ? Theme.of(context).colorScheme.error : Theme.of(context).disabledColor,
                  size: 16,
                ),
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
                if (_editing == null)
                  IconButton(
                    tooltip: t.stickers,
                    icon: const Icon(Icons.emoji_emotions_outlined),
                    onPressed: _busy ? null : _sticker,
                  ),
                Expanded(
                  // Siegel Web: Enter sends, Shift+Enter starts a new line (not while an IME is composing).
                  child: CallbackShortcuts(
                    bindings: {
                      if (webUi)
                        const SingleActivator(LogicalKeyboardKey.enter): () {
                          if (!_text.value.composing.isValid && !_busy) _send();
                        },
                    },
                    child: TextField(
                      controller: _text,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: _onChanged,
                      decoration: InputDecoration(
                        hintText: t.messageHint,
                        border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                        // Over the chat background: a light veil so the pattern or photo shows only faintly.
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ),
                ValueListenableBuilder(
                  valueListenable: _text,
                  builder: (context, v, _) => v.text.trim().isEmpty && _editing == null
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: t.camera,
                              icon: const Icon(Icons.photo_camera_outlined),
                              onPressed: _busy ? null : _camera,
                            ),
                            IconButton(
                              tooltip: t.recordVoice,
                              icon: const Icon(Icons.mic_none),
                              onPressed: _busy ? null : _startRecording,
                            ),
                          ],
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

/// MSG-18: drag a bubble right to reply; a haptic tick says the drag went far enough. With a
/// mouse (Siegel Web), a reply button shows beside the bubble under the pointer.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({required this.onReply, required this.outgoing, required this.child});

  final VoidCallback? onReply;
  final bool outgoing;
  final Widget child;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _threshold = 64.0;
  double _dx = 0;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (widget.onReply == null) return widget.child;
    if (webUi) {
      final button = Visibility.maintain(
        visible: _hover,
        child: IconButton(
          tooltip: AppLocalizations.of(context)!.reply,
          icon: const Icon(Icons.reply, size: 20),
          onPressed: widget.onReply,
        ),
      );
      return MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: widget.outgoing ? [button, Flexible(child: widget.child)] : [Flexible(child: widget.child), button],
        ),
      );
    }
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

/// A quoted message: a bar in the sender's colour, who and what, and a thumbnail for a picture.
/// Tinted from the text colour, so it reads in any bubble or theme.
class _Quote extends StatelessWidget {
  const _Quote({required this.who, required this.text, required this.thumb, required this.accent});
  final String? who;
  final String text;
  final Uint8List? thumb;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final ink = DefaultTextStyle.of(context).style.color ?? Theme.of(context).colorScheme.onSurface;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: ink.withValues(alpha: 0.08),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (who != null)
                        Text(
                          who!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: accent, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              ),
              if (thumb != null) Image.memory(thumb!, width: 48, fit: BoxFit.cover, excludeFromSemantics: true),
            ],
          ),
        ),
      ),
    );
  }
}

/// A day above its first message: Today, Yesterday, the weekday within a week, else the date.
class _DayChip extends StatelessWidget {
  const _DayChip(this.day);
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).toString();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final ago = today.difference(day).inDays;
    final label = switch (ago) {
      0 => t.today,
      1 => t.yesterday,
      > 1 && < 7 => DateFormat.EEEE(locale).format(day),
      _ when day.year == now.year => DateFormat.MMMMd(locale).format(day),
      _ => DateFormat.yMMMMd(locale).format(day),
    };
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: colors.surfaceContainerHigh, borderRadius: BorderRadius.circular(8)),
        child: Text(label, style: Theme.of(context).textTheme.labelMedium),
      ),
    );
  }
}
