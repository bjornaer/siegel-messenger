import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'app_lock.dart';
import 'backgrounds.dart';
import 'avatar.dart';
import 'chats.dart';
import 'discovery.dart';
import 'l10n/app_localizations.dart';
import 'links.dart';
import 'minors.dart';
import 'media.dart';
import 'number.dart';
import 'onboarding.dart';
import 'push.dart';
import 'stickers.dart' show importStickerFiles;
import 'suspended.dart';
import 'server_data.dart';
import 'themes.dart';
import 'src/rust/api/core.dart';
import 'src/rust/frb_generated.dart';

// CRY-15: the DB key lives only in the Keychain / Keystore, never in backups or other devices.
// resetOnError stays false: a silent reset would destroy the key and with it the whole history.
const _secure = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  aOptions: AndroidOptions(resetOnError: false),
);

Future<Core> openCore() async {
  var key = await _secure.read(key: 'db_key');
  if (key == null) {
    final rng = Random.secure(); // OS CSPRNG (CRY-16)
    key = base64Encode(List.generate(32, (_) => rng.nextInt(256)));
    await _secure.write(key: 'db_key', value: key);
  }
  final dir = await getApplicationSupportDirectory();
  return Core.open(dbPath: '${dir.path}/siegel.db', dbKey: base64Decode(key), serverUrl: serverUrl);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(SiegelApp(core: await openCore()));
}

class SiegelApp extends StatefulWidget {
  const SiegelApp({super.key, required this.core});
  final Core core;

  @override
  State<SiegelApp> createState() => _SiegelAppState();
}

class _SiegelAppState extends State<SiegelApp> {
  final _navigator = GlobalKey<NavigatorState>();
  late Core core = widget.core;

  @override
  void initState() {
    super.initState();
    themeChoice.value = themeById(core.setting(key: 'theme'));
    // DISC-08: links opened while the app runs, and the one it was started with.
    appChannel.setMethodCallHandler((call) async {
      if (call.method == 'link') _openLink(call.arguments as String);
      if (call.method == 'shared') _importShared(call.arguments as List<Object?>);
    });
    appChannel.invokeMethod<String>('takeLink').then((l) {
      if (l != null) _openLink(l);
    }, onError: (Object _) {});
    appChannel.invokeMethod<List<Object?>>('takeShared').then((f) {
      if (f != null) _importShared(f);
    }, onError: (Object _) {});
  }

  /// Stickers or packs shared to Siegel by another app: straight into my stickers.
  void _importShared(List<Object?> files) {
    final added = importStickerFiles(core, [
      for (final f in files.cast<List<Object?>>()) (f[0] as String, f[1] as Uint8List),
    ]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _navigator.currentContext;
      if (ctx == null || !ctx.mounted) return;
      ScaffoldMessenger.maybeOf(ctx)
          ?.showSnackBar(SnackBar(content: Text(AppLocalizations.of(ctx)!.stickersAdded(added))));
    });
  }

  String? _pendingLink; // opened before onboarding finished

  Future<void> _openLink(String link) async {
    if (!isContactLink(link) && !isGroupLink(link)) return;
    if (!(core.isRegistered() && core.username() != null)) {
      _pendingLink = link;
      return;
    }
    final service = _service();
    try {
      final ctx = _navigator.currentContext;
      final chat = isGroupLink(link)
          ? (ctx == null ? null : await joinGroupByLink(ctx, core, link))
          : await core.openContactLink(link: link);
      if (chat == null) return;
      service.refresh();
      _navigator.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(core: core, service: service, groupId: chat),
        ),
      );
    } on CoreError catch (e) {
      final ctx = _navigator.currentContext;
      if (ctx != null && ctx.mounted) showError(ctx, e);
    }
  }

  ChatService? _chats;

  ChatService _service() => _chats ??= _startChats();

  ChatService _startChats() {
    final c = core;
    final service = ChatService(
      c,
      onDeregistered: _reset,
      onNumberRemoved: () {
        final ctx = _navigator.currentContext;
        if (ctx != null && ctx.mounted) showNumberRemoved(ctx, c);
      },
      // M7: suspended or username removed; the home below shows which.
      onEnforcement: () {
        _navigator.currentState?.popUntil((r) => r.isFirst);
        if (mounted) setState(() {});
      },
      // MSG-17: in the foreground the chat itself shows new messages.
      onMessage: (m) {
        if (!appVisible()) notifyMessage(c, m);
      },
    )..start();
    unawaited(startPush(c, service.fetchNow));
    return service;
  }

  /// Back to onboarding with a fresh, empty database (account deleted or device deregistered).
  Future<void> _reset() async {
    _navigator.currentState?.popUntil((r) => r.isFirst);
    _chats?.dispose();
    _chats = null;
    final fresh = await openCore();
    themeChoice.value = siegelThemes.first;
    setState(() => core = fresh);
  }

  @override
  void dispose() {
    _chats?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = core.isRegistered() && core.username() != null;
    return ValueListenableBuilder(valueListenable: themeChoice, builder: (context, theme, _) => _app(ready, theme));
  }

  Widget _app(bool ready, SiegelTheme theme) {
    return MaterialApp(
      debugShowCheckedModeBanner: false, // also keeps it out of store screenshots
      navigatorKey: _navigator,
      onGenerateTitle: (c) => AppLocalizations.of(c)!.appTitle,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Flutter falls back to the first entry for languages we don't have: make that English.
      supportedLocales: [const Locale('en'), ...AppLocalizations.supportedLocales.where((l) => l.languageCode != 'en')],
      theme: theme.data(Brightness.light),
      darkTheme: theme.data(Brightness.dark),
      themeMode: theme.lightOnly ? ThemeMode.light : ThemeMode.system,
      home: ready
          ? AppLock(
              core: core,
              child: switch (core.notice()) {
                final n? when n.suspended => SuspendedScreen(
                  notice: n,
                  onDelete: (ctx) => confirmDeleteAccount(ctx, core, _reset),
                ),
                _ => BirthDateGate(
                  core: core,
                  onDelete: (ctx) => confirmDeleteAccount(ctx, core, _reset),
                  child: ChatListScreen(
                    core: core,
                    service: _service(),
                    settings: (_) => SettingsScreen(core: core, onDeleted: _reset),
                  ),
                ),
              },
            )
          : Onboarding(
              core: core,
              onDone: () {
                setState(() {});
                final link = _pendingLink;
                _pendingLink = null;
                if (link != null) WidgetsBinding.instance.addPostFrameCallback((_) => _openLink(link));
              },
            ),
    );
  }
}

/// ID-16, after a confirmation.
Future<void> confirmDeleteAccount(BuildContext context, Core core, Future<void> Function() onDeleted) async {
  final t = AppLocalizations.of(context)!;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(t.deleteConfirmTitle),
      content: Text(t.deleteConfirmBody),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.cancel)),
        TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t.delete)),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await core.deleteAccount();
    await onDeleted();
  } on CoreError catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.core, required this.onDeleted});
  final Core core;
  final Future<void> Function() onDeleted;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: SiegelBar(title: Text(t.settings)),
      body: ListView(
        // Clear of the system navigation bar, or the last row (Delete account) can't be reached.
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          _Profile(core: core),
          MyLinkTile(core: core),
          DiscoverableTile(core: core),
          ChangeNumberTile(core: core),
          const SizedBox(height: 24),
          Text(t.historyNotice), // ID-14: also stated in Settings
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(t.theme),
            subtitle: ValueListenableBuilder(valueListenable: themeChoice, builder: (_, th, _) => Text(th.name)),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ThemePicker(
                  onPick: (th) {
                    core.setSetting(key: 'theme', value: th.id);
                    themeChoice.value = th;
                  },
                ),
              ),
            ),
          ),
          ChatBackgroundTile(core: core),
          AppLockSettings(core: core),
          AutoDownloadTile(core: core),
          _Toggle(core: core, setting: 'read_receipts', title: t.readReceipts, help: t.readReceiptsHelp),
          _Toggle(core: core, setting: 'typing_indicators', title: t.typingIndicators, help: t.typingIndicatorsHelp),
          _GroupAdds(core: core),
          ListTile(
            leading: const Icon(Icons.block),
            title: Text(t.blockedPeople),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BlockedScreen(core: core))),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(t.skTitle),
            subtitle: Text(t.skHelp),
            onTap: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ServerDataScreen(core: core))),
          ),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: Text(t.termsAndGuidelines),
            onTap: () => openPage('/terms'),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(t.privacyPolicy),
            onTap: () => openPage('/privacy'),
          ),
          // AGPL-3.0 section 13: people using the service can get its source.
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(t.sourceCode),
            subtitle: Text(t.sourceCodeHelp),
            onTap: () => appChannel.invokeMethod<void>('open', sourceUrl),
          ),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: () => confirmDeleteAccount(context, core, onDeleted), child: Text(t.deleteAccount)),
        ],
      ),
    );
  }
}

/// MSG-13, MSG-14: on by default; the core reads the same setting keys.
class _Toggle extends StatefulWidget {
  const _Toggle({required this.core, required this.setting, required this.title, required this.help});
  final Core core;
  final String setting;
  final String title;
  final String help;

  @override
  State<_Toggle> createState() => _ToggleState();
}

class _ToggleState extends State<_Toggle> {
  @override
  Widget build(BuildContext context) => SwitchListTile(
    title: Text(widget.title),
    subtitle: Text(widget.help),
    value: widget.core.setting(key: widget.setting) != 'off',
    onChanged: (on) => setState(() => widget.core.setSetting(key: widget.setting, value: on ? 'on' : 'off')),
  );
}

/// MSG-16: who is blocked, with unblock.
class BlockedScreen extends StatefulWidget {
  const BlockedScreen({super.key, required this.core});
  final Core core;

  @override
  State<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends State<BlockedScreen> {
  bool _busy = false;

  Future<void> _unblock(BlockedContact c) async {
    setState(() => _busy = true);
    try {
      await widget.core.unblock(account: c.account);
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final blocked = widget.core.blocked();
    return Scaffold(
      appBar: SiegelBar(title: Text(t.blockedPeople)),
      body: blocked.isEmpty
          ? Center(child: Text(t.noBlocked))
          : ListView(
              children: [
                for (final c in blocked)
                  ListTile(
                    title: Text(c.displayName ?? (c.username == null ? t.newContact : '@${c.username}')),
                    trailing: TextButton(onPressed: _busy ? null : () => _unblock(c), child: Text(t.unblock)),
                  ),
              ],
            ),
    );
  }
}

/// GRP-11: who can add me to groups; anyone else sends an invite.
class _GroupAdds extends StatefulWidget {
  const _GroupAdds({required this.core});
  final Core core;

  @override
  State<_GroupAdds> createState() => _GroupAddsState();
}

class _GroupAddsState extends State<_GroupAdds> {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final everyone = widget.core.setting(key: 'group_adds') == 'everyone';
    final minor = widget.core.minor(); // M7: locked to contacts
    return ListTile(
      leading: const Icon(Icons.group_add_outlined),
      title: Text(t.groupAdds),
      subtitle: Text(
        minor ? t.groupAddsMinor : '${everyone ? t.groupAddsEveryone : t.groupAddsContacts}. ${t.groupAddsHelp}',
      ),
      onTap: minor
          ? null
          : () => showModalBottomSheet<void>(
              context: context,
              builder: (s) => SafeArea(
                child: Wrap(
                  children: [
                    for (final (label, value) in [(t.groupAddsContacts, 'contacts'), (t.groupAddsEveryone, 'everyone')])
                      ListTile(
                        title: Text(label),
                        trailing: (value == 'everyone') == everyone ? const Icon(Icons.check) : null,
                        onTap: () {
                          Navigator.pop(s);
                          setState(() => widget.core.setSetting(key: 'group_adds', value: value));
                        },
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Name and @username, editable (the server allows a new @username every 30 days, ID-07).
class _Profile extends StatefulWidget {
  const _Profile({required this.core});
  final Core core;

  @override
  State<_Profile> createState() => _ProfileState();
}

class _ProfileState extends State<_Profile> {
  Future<void> _edit() async {
    final t = AppLocalizations.of(context)!;
    final name = TextEditingController(text: widget.core.displayName() ?? '');
    final user = TextEditingController(text: widget.core.username() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t.editProfile),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              maxLength: 64,
              decoration: InputDecoration(labelText: t.displayNameLabel),
            ),
            TextField(
              controller: user,
              autocorrect: false,
              decoration: InputDecoration(labelText: t.usernameLabel, helperText: t.usernameHelp, helperMaxLines: 3),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(t.save)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      widget.core.setDisplayName(name: name.text);
      final u = user.text.trim().replaceFirst(RegExp('^@'), '').toLowerCase();
      if (u.isNotEmpty && u != widget.core.username()) await widget.core.setUsername(username: u);
      await widget.core.announceProfile(); // contacts see the new name
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: AvatarEditor(core: widget.core, radius: 28),
      title: Text(t.homeRegistered(widget.core.username() ?? ''), style: Theme.of(context).textTheme.titleLarge),
      subtitle: widget.core.displayName() == null ? null : Text(widget.core.displayName()!),
      trailing: IconButton(tooltip: t.editProfile, icon: const Icon(Icons.edit_outlined), onPressed: _edit),
    );
  }
}
