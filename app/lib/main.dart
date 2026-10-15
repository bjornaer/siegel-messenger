import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'app_lock.dart';
import 'chats.dart';
import 'l10n/app_localizations.dart';
import 'onboarding.dart';
import 'push.dart';
import 'themes.dart';
import 'src/rust/api/core.dart';
import 'src/rust/frb_generated.dart';

const serverUrl = String.fromEnvironment('SIEGEL_SERVER', defaultValue: 'https://siegel.schlk.in');

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
  }

  ChatService? _chats;

  ChatService _service() => _chats ??= _startChats();

  ChatService _startChats() {
    final c = core;
    final service = ChatService(
      c,
      onDeregistered: _reset,
      // MSG-17: in the foreground the chat itself shows new messages.
      onMessage: (m) {
        if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) notifyMessage(c, m);
      },
    )..start();
    unawaited(startPush(c, service.wake));
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
      navigatorKey: _navigator,
      onGenerateTitle: (c) => AppLocalizations.of(c)!.appTitle,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: theme.data(Brightness.light),
      darkTheme: theme.data(Brightness.dark),
      home: ready
          ? AppLock(
              core: core,
              child: ChatListScreen(
                core: core,
                service: _service(),
                settings: (_) => SettingsScreen(core: core, onDeleted: _reset),
              ),
            )
          : Onboarding(core: core, onDone: () => setState(() {})),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.core, required this.onDeleted});
  final Core core;
  final Future<void> Function() onDeleted;

  Future<void> _delete(BuildContext context) async {
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

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(t.settings)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(t.homeRegistered(core.username()!), style: Theme.of(context).textTheme.titleLarge),
          if (core.displayName() case final name?) Text(name),
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
          AppLockSettings(core: core),
          _Toggle(core: core, setting: 'read_receipts', title: t.readReceipts, help: t.readReceiptsHelp),
          _Toggle(core: core, setting: 'typing_indicators', title: t.typingIndicators, help: t.typingIndicatorsHelp),
          ListTile(
            leading: const Icon(Icons.block),
            title: Text(t.blockedPeople),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BlockedScreen(core: core))),
          ),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: () => _delete(context), child: Text(t.deleteAccount)),
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
      appBar: AppBar(title: Text(t.blockedPeople)),
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
