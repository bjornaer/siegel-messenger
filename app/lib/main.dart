import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n/app_localizations.dart';
import 'onboarding.dart';
import 'src/rust/api/core.dart';
import 'src/rust/frb_generated.dart';

const serverUrl = String.fromEnvironment('SIEGEL_SERVER', defaultValue: 'https://siegel.schlk.in');

// CRY-15: the DB key lives only in the Keychain / Keystore, never in backups or other devices.
// resetOnError stays false: a silent reset would destroy the key and with it the whole history.
const _secure = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  aOptions: AndroidOptions(resetOnError: false, keyCipherAlgorithm: KeyCipherAlgorithm.AES_GCM_NoPadding),
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
  late Core core = widget.core;

  @override
  Widget build(BuildContext context) {
    final ready = core.isRegistered() && core.username() != null;
    return MaterialApp(
      onGenerateTitle: (c) => AppLocalizations.of(c)!.appTitle,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
      home: ready
          ? Home(core: core, onDeleted: () async {
              final fresh = await openCore();
              setState(() => core = fresh);
            })
          : Onboarding(core: core, onDone: () => setState(() {})),
    );
  }
}

/// Placeholder until chats land in M2.
class Home extends StatelessWidget {
  const Home({super.key, required this.core, required this.onDeleted});
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
      appBar: AppBar(title: Text(t.appTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(t.homeRegistered(core.username()!), style: Theme.of(context).textTheme.titleLarge),
          if (core.displayName() case final name?) Text(name),
          const SizedBox(height: 24),
          Text(t.settings, style: Theme.of(context).textTheme.titleMedium),
          Text(t.historyNotice), // ID-14: also stated in Settings
          const SizedBox(height: 16),
          OutlinedButton(onPressed: () => _delete(context), child: Text(t.deleteAccount)),
        ],
      ),
    );
  }
}
