import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_localizations.dart';
import 'src/rust/api/core.dart';

const _app = MethodChannel('siegel/app');

/// Asks testers and users to update: a banner when a newer build is in the store, a dialog that
/// can't be dismissed when this build is older than the server's minimum. The server publishes
/// both numbers (SIEGEL_ANDROID_LATEST_BUILD, SIEGEL_ANDROID_MIN_BUILD). Checked on start and
/// whenever the app comes back to the foreground.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key, required this.core});
  final Core core;

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> with WidgetsBindingObserver {
  bool _available = false;
  bool _dismissed = false;
  bool _forced = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (!Platform.isAndroid) return; // ponytail: iOS reads its build the same way once it ships
    try {
      final build = await _app.invokeMethod<int>('build') ?? 0;
      final v = await widget.core.appVersion(platform: DevicePlatform.android);
      if (!mounted) return;
      setState(() => _available = v.latest > build);
      if (v.minimum > build && !_forced) {
        _forced = true;
        await _mustUpdate();
      }
    } on Object {
      // offline or no server value: no prompt
    }
  }

  Future<void> _mustUpdate() {
    final t = AppLocalizations.of(context)!;
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (d) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Text(t.updateRequired),
          actions: [FilledButton(onPressed: _openStore, child: Text(t.update))],
        ),
      ),
    );
  }

  void _openStore() => _app.invokeMethod<void>('openStore');

  @override
  Widget build(BuildContext context) {
    if (!_available || _dismissed) return const SizedBox.shrink();
    final t = AppLocalizations.of(context)!;
    return MaterialBanner(
      leading: const Icon(Icons.system_update_outlined),
      content: Text(t.updateAvailable),
      actions: [
        TextButton(onPressed: () => setState(() => _dismissed = true), child: Text(t.later)),
        FilledButton(onPressed: _openStore, child: Text(t.update)),
      ],
    );
  }
}
