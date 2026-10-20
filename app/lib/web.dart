import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'browser.dart' if (dart.library.js_interop) 'browser_web.dart' as browser;
import 'l10n/app_localizations.dart';
import 'links.dart' show serverUrl;
import 'main.dart' show SiegelApp;
import 'onboarding.dart' show showError;
import 'src/rust/api/core.dart';
import 'themes.dart';

/// M8: Siegel in a browser (web.siegel.schlk.in). There is no Keystore here, so the database
/// key is kept wrapped by a PIN chosen in this browser and asked each time it opens (W3). The
/// browser is never registered itself: the phone links it (W1, W2).
const _dbPath = 'siegel.db';
const _wrappedKey = 'siegel_db_key';
const _failures = 'siegel_pin_failures';
const _lastUsed = 'siegel_last_used';
const _maxTries = 10;
const _unused = Duration(days: 14); // W3; the server unlinks it too

/// Forgets this browser: its database, its wrapped key; then starts over at the link screen.
void forgetBrowser() {
  forgetStorage(dbPath: _dbPath);
  for (final k in [_wrappedKey, _failures, _lastUsed]) {
    browser.save(k, null);
  }
  browser.reload();
}

void _touch() => browser.save(_lastUsed, '${DateTime.now().millisecondsSinceEpoch}');

class WebStart extends StatefulWidget {
  const WebStart({super.key});

  @override
  State<WebStart> createState() => _WebStartState();
}

class _WebStartState extends State<WebStart> {
  Core? _core;
  bool _expired = false;
  Timer? _keepAlive;

  @override
  void initState() {
    super.initState();
    final last = int.tryParse(browser.load(_lastUsed) ?? '');
    if (last != null && DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(last)) > _unused) {
      forgetStorage(dbPath: _dbPath);
      for (final k in [_wrappedKey, _failures, _lastUsed]) {
        browser.save(k, null);
      }
      _expired = true;
    }
  }

  @override
  void dispose() {
    _keepAlive?.cancel();
    super.dispose();
  }

  void _opened(Core core) {
    _touch();
    _keepAlive = Timer.periodic(const Duration(hours: 1), (_) => _touch());
    setState(() => _core = core);
  }

  /// A new PIN: a fresh key and a fresh, empty database.
  Future<void> _create(String pin) async {
    forgetStorage(dbPath: _dbPath);
    final rng = Random.secure();
    final key = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    browser.save(_wrappedKey, base64Encode(await wrapDbKey(pin: pin, key: key)));
    _opened(Core.open(dbPath: _dbPath, dbKey: key, serverUrl: serverUrl));
  }

  /// False for a wrong PIN; the tenth wrong one forgets the browser.
  Future<bool> _unlock(String pin) async {
    final key = await unwrapDbKey(pin: pin, wrapped: base64Decode(browser.load(_wrappedKey)!));
    if (key == null) {
      final n = (int.tryParse(browser.load(_failures) ?? '') ?? 0) + 1;
      browser.save(_failures, '$n');
      if (n >= _maxTries) forgetBrowser();
      return false;
    }
    browser.save(_failures, null);
    _opened(Core.open(dbPath: _dbPath, dbKey: key, serverUrl: serverUrl));
    return true;
  }

  int get _triesLeft => _maxTries - (int.tryParse(browser.load(_failures) ?? '') ?? 0);

  @override
  Widget build(BuildContext context) {
    final core = _core;
    if (core != null && core.isRegistered()) return SiegelApp(core: core);
    final theme = siegelThemes.first;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (c) => AppLocalizations.of(c)!.appTitle,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: [const Locale('en'), ...AppLocalizations.supportedLocales.where((l) => l.languageCode != 'en')],
      theme: theme.data(Brightness.light),
      darkTheme: theme.data(Brightness.dark),
      home: core != null
          ? LinkScreen(core: core, onLinked: () => setState(() {}))
          : browser.load(_wrappedKey) == null
          ? PinScreen.create(
              expired: _expired,
              onPin: (pin) async {
                await _create(pin);
                return true;
              },
            )
          : PinScreen.unlock(onPin: _unlock, triesLeft: () => _triesLeft, onForgot: forgetBrowser),
    );
  }
}

/// Choose a PIN (twice), or enter it to unlock.
class PinScreen extends StatefulWidget {
  const PinScreen.create({super.key, required this.onPin, this.expired = false})
    : creating = true,
      triesLeft = null,
      onForgot = null;
  const PinScreen.unlock({super.key, required this.onPin, required this.triesLeft, required this.onForgot})
    : creating = false,
      expired = false;

  final bool creating;
  final bool expired;
  final Future<bool> Function(String pin) onPin;
  final int Function()? triesLeft;
  final VoidCallback? onForgot;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  final _pin = TextEditingController();
  final _again = TextEditingController();
  String? _error;
  bool _busy = false;

  bool get _valid => RegExp(r'^\d{4,6}$').hasMatch(_pin.text) && (!widget.creating || _again.text.length >= 4);

  Future<void> _submit() async {
    final t = AppLocalizations.of(context)!;
    if (widget.creating && _pin.text != _again.text) return setState(() => _error = t.webPinMismatch);
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.onPin(_pin.text); // about a second: argon2id
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) {
        _error = t.webPinWrong(widget.triesLeft!());
        _pin.clear();
      }
    });
  }

  Widget _field(TextEditingController c, String label, {bool autofocus = false}) => TextField(
    controller: c,
    autofocus: autofocus,
    obscureText: true,
    enabled: !_busy,
    keyboardType: TextInputType.number,
    maxLength: 6,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(labelText: label),
    onChanged: (_) => setState(() {}),
    onSubmitted: (_) => _valid && !_busy ? _submit() : null,
  );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.creating ? t.webPinCreateTitle : t.webPinEnterTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                if (widget.expired) ...[const SizedBox(height: 12), Text(t.webExpired)],
                if (widget.creating) ...[const SizedBox(height: 12), Text(t.webPinCreateBody)],
                const SizedBox(height: 16),
                _field(_pin, t.webPinLabel, autofocus: true),
                if (widget.creating) _field(_again, t.webPinConfirm),
                if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _valid && !_busy ? _submit : null,
                  child: _busy
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(widget.creating ? t.continueButton : t.webUnlock),
                ),
                if (widget.onForgot != null)
                  TextButton(onPressed: _busy ? null : widget.onForgot, child: Text(t.webForgotPin)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The QR code the phone scans (Settings → Linked devices); waits until the phone approves.
class LinkScreen extends StatefulWidget {
  const LinkScreen({super.key, required this.core, required this.onLinked});
  final Core core;
  final VoidCallback onLinked;

  @override
  State<LinkScreen> createState() => _LinkScreenState();
}

class _LinkScreenState extends State<LinkScreen> {
  String? _qr;
  bool _stopped = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _stopped = true;
    super.dispose();
  }

  /// A new code each time one expires (5 minutes), until the phone approves.
  Future<void> _run() async {
    while (!_stopped) {
      try {
        final qr = await widget.core.linkBegin(deviceName: browser.deviceName());
        if (_stopped) return;
        setState(() => _qr = qr);
        while (!_stopped) {
          await Future<void>.delayed(const Duration(seconds: 2));
          if (await widget.core.linkWait()) {
            if (!_stopped) widget.onLinked();
            return;
          }
        }
      } on CoreError catch (e) {
        if (_stopped) return;
        if (e.code != 'link_expired') {
          if (mounted) showError(context, e);
          await Future<void>.delayed(const Duration(seconds: 10));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final qr = _qr;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              children: [
                Text(t.webLinkTitle, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                Text(t.webLinkBody, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                if (qr == null)
                  const CircularProgressIndicator()
                else
                  // Dark on white whatever the theme: scanners need the contrast.
                  ColoredBox(
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: QrImageView(data: qr, size: 260, semanticsLabel: t.webLinkTitle),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(t.webLinkWaiting),
                Text(t.linkedDevicesHelp, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
