import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'l10n/app_localizations.dart';
import 'src/rust/api/core.dart';

/// ID-15 timeout choices in seconds (0 = immediately). [default] 60.
const lockTimeouts = [0, 60, 300, 1800, 3600];
const defaultLockTimeout = 60;

const _window = MethodChannel('siegel/window');
final _auth = LocalAuthentication();

/// Lock timeout in seconds, or null when app lock is off.
int? lockTimeout(Core core) => int.tryParse(core.setting(key: 'app_lock') ?? '');

/// Locks when app lock is on and the app was away for at least the timeout. A cold start counts as away.
bool shouldLock({required int? timeout, required DateTime? leftAt, required DateTime now}) =>
    timeout != null && (leftAt == null || now.difference(leftAt).inSeconds >= timeout);

/// Android FLAG_SECURE (ID-15 "screen security"). No-op elsewhere.
Future<void> setScreenSecurity(Core core, bool on) async {
  core.setSetting(key: 'screen_security', value: on ? '1' : '0');
  if (Platform.isAndroid) await _window.invokeMethod('setSecure', on);
}

/// True while a system auth prompt is up: it backgrounds the app on some phones, which must not count as leaving.
bool _authenticating = false;

/// Device biometrics or passcode. False when the user cancels or the phone has no screen lock.
Future<bool> authenticate(String reason) async {
  if (_authenticating) return false;
  _authenticating = true;
  try {
    return await _auth.isDeviceSupported() && await _auth.authenticate(localizedReason: reason);
  } on Exception {
    return false;
  } finally {
    _authenticating = false;
  }
}

/// Wraps the app: hides content in the app switcher and shows the lock screen when due.
class AppLock extends StatefulWidget {
  const AppLock({super.key, required this.core, required this.child});
  final Core core;
  final Widget child;

  @override
  State<AppLock> createState() => _AppLockState();
}

class _AppLockState extends State<AppLock> with WidgetsBindingObserver {
  late bool _locked = shouldLock(timeout: lockTimeout(widget.core), leftAt: null, now: DateTime.now());
  bool _covered = false;
  DateTime? _leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid && widget.core.setting(key: 'screen_security') == '1') {
      _window.invokeMethod('setSecure', true);
    }
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_authenticating) return;
    if (state == AppLifecycleState.resumed) {
      // No _leftAt here means we only went inactive (auth prompt, notification shade), never away.
      final lock =
          !_locked &&
          _leftAt != null &&
          shouldLock(timeout: lockTimeout(widget.core), leftAt: _leftAt, now: DateTime.now());
      setState(() {
        _covered = false;
        _locked = _locked || lock;
        _leftAt = null;
      });
      if (lock) {
        Navigator.of(context).popUntil((r) => r.isFirst); // no dialog may stay above the lock screen
        _unlock();
      }
    } else {
      setState(() => _covered = true);
      if (state != AppLifecycleState.inactive) _leftAt ??= DateTime.now();
    }
  }

  Future<void> _unlock() async {
    final ok = await authenticate(AppLocalizations.of(context)!.unlockReason);
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Stack(
      children: [
        widget.child,
        if (_locked)
          Positioned.fill(
            child: Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline, size: 48),
                    const SizedBox(height: 16),
                    Text(t.lockedTitle, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _unlock, child: Text(t.unlock)),
                  ],
                ),
              ),
            ),
          )
        else if (_covered)
          // ponytail: Android < 13 may still snapshot before this frame; screen security covers that case.
          Positioned.fill(child: ColoredBox(color: Theme.of(context).colorScheme.surface)),
      ],
    );
  }
}

/// Settings rows for ID-15.
class AppLockSettings extends StatefulWidget {
  const AppLockSettings({super.key, required this.core});
  final Core core;

  @override
  State<AppLockSettings> createState() => _AppLockSettingsState();
}

class _AppLockSettingsState extends State<AppLockSettings> {
  Core get core => widget.core;

  Future<void> _toggleLock(bool on) async {
    final t = AppLocalizations.of(context)!;
    if (on && !await authenticate(t.unlockReason)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.errNoDeviceLock)));
      return;
    }
    setState(() => core.setSetting(key: 'app_lock', value: on ? '$defaultLockTimeout' : ''));
  }

  String _label(AppLocalizations t, int s) =>
      s == 0 ? t.lockImmediately : (s < 3600 ? t.lockMinutes(s ~/ 60) : t.lockHours(s ~/ 3600));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final timeout = lockTimeout(core);
    return Column(
      children: [
        SwitchListTile(
          title: Text(t.appLock),
          subtitle: Text(t.appLockSubtitle),
          value: timeout != null,
          onChanged: _toggleLock,
        ),
        if (timeout != null)
          ListTile(
            title: Text(t.lockAfter),
            trailing: DropdownButton<int>(
              value: timeout,
              items: [for (final s in lockTimeouts) DropdownMenuItem(value: s, child: Text(_label(t, s)))],
              onChanged: (s) => setState(() => core.setSetting(key: 'app_lock', value: '$s')),
            ),
          ),
        if (Platform.isAndroid)
          SwitchListTile(
            title: Text(t.screenSecurity),
            subtitle: Text(t.screenSecuritySubtitle),
            value: core.setting(key: 'screen_security') == '1',
            onChanged: (on) async {
              await setScreenSecurity(core, on);
              setState(() {});
            },
          ),
      ],
    );
  }
}
