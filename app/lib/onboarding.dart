import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import 'l10n/app_localizations.dart';
import 'src/rust/api/core.dart';

/// CMP-02: minimum age per country calling code. GDPR default is 16; Spain allows 14 (LOPDGDD art. 7).
/// ponytail: fill in per launch country once Q2 is settled.
const _minAgeByCallingCode = {'34': 14};
const _defaultMinAge = 16;

void showError(BuildContext context, CoreError e) {
  final t = AppLocalizations.of(context)!;
  final msg = switch (e.code) {
    'phone_invalid' => t.errPhoneInvalid,
    'rate_limited' => t.errRateLimited,
    'otp_invalid' => t.errOtpInvalid,
    'registration_lock_invalid' => t.errLockInvalid,
    'registration_lock_locked' => t.errLockLocked,
    'username_invalid' => t.errUsernameInvalid,
    'username_taken' => t.errUsernameTaken,
    'username_change_too_soon' => t.errUsernameTooSoon,
    'pin_invalid' => t.errPinInvalid,
    'display_name_invalid' => t.errDisplayNameInvalid,
    'username_not_found' => t.errUsernameNotFound,
    'no_key_packages' => t.errNoKeyPackages,
    'text_invalid' => t.errTextInvalid,
    'request_pending' => t.errRequestPending,
    'not_allowed' => t.errNotAllowed,
    'attestation_failed' => t.errAttestation,
    'group_left' => t.errGroupLeft,
    'peer_outdated' => t.errPeerOutdated,
    'resend_too_soon' => t.errResendTooSoon,
    'link_invalid' => t.errLinkInvalid,
    'link_stale' => t.errLinkStale,
    'invite_not_found' => t.errInviteNotFound,
    'already_member' => t.errAlreadyMember,
    'link_key_mismatch' => t.errLinkKeyMismatch,
    'group_too_large' => t.errGroupTooLarge,
    'name_invalid' => t.errNameInvalid,
    'network' => t.errNetwork,
    _ => t.errGeneric,
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

enum _Step { welcome, phone, code, pin, profile, lock }

DevicePlatform get _platform => Platform.isIOS ? DevicePlatform.ios : DevicePlatform.android;

/// ID-02: proof that this is a genuine app on a genuine device, bound to the number. Empty when
/// unavailable (no Play services, iOS until App Attest); the server then refuses to send an SMS.
Future<String> attestationToken(String phone) async {
  if (!Platform.isAndroid) return '';
  try {
    return await const MethodChannel('siegel/attest').invokeMethod<String>('token', phone) ?? '';
  } on PlatformException {
    return '';
  } on MissingPluginException {
    return ''; // widget tests
  }
}

class Onboarding extends StatefulWidget {
  const Onboarding({super.key, required this.core, required this.onDone});
  final Core core;
  final VoidCallback onDone;

  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  // Resume at the profile step if the app was closed after verifying.
  late _Step step = widget.core.isRegistered() ? _Step.profile : _Step.welcome;
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _username = TextEditingController();
  final _name = TextEditingController();
  PhoneNumber? _parsed;
  bool _ageOk = false;
  bool _busy = false;
  // ID-04: the server sets when a resend is allowed; each wait doubles, with a daily cap.
  int _resendLeft = 0; // seconds; the server enforces the real wait
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final phone = _parsed!.international;
    final wait = await core.requestOtp(
      phoneE164: phone,
      attestationToken: await attestationToken(phone),
      platform: _platform,
    );
    _tick?.cancel();
    setState(() => _resendLeft = wait);
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _resendLeft <= 1) t.cancel();
      if (mounted) setState(() => _resendLeft--);
    });
  }

  Core get core => widget.core;

  /// Runs a core call with a busy flag; CoreErrors become localized snackbars.
  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on CoreError catch (e) {
      if (!mounted) return;
      if (e.code == 'registration_lock_required') {
        setState(() => step = _Step.pin);
      } else {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onPhoneChanged(String v) {
    final region = PlatformDispatcher.instance.locale.countryCode;
    final caller = IsoCode.values.where((c) => c.name == region).firstOrNull;
    try {
      final p = PhoneNumber.parse(v, callerCountry: caller);
      setState(() => _parsed = p.isValid(type: PhoneNumberType.mobile) || p.isValid() ? p : null);
    } on PhoneNumberException {
      setState(() => _parsed = null);
    }
  }

  Future<void> _verify() => _run(() async {
    await core.verify(
      phoneE164: _parsed!.international,
      otp: _code.text.trim(),
      pin: _pin.text.trim(),
      platform: _platform,
    );
    setState(() => step = _Step.profile);
  });

  Future<void> _skipLock(AppLocalizations t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t.skipWarningTitle),
        content: Text(t.skipWarningBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t.skipAnyway)),
        ],
      ),
    );
    if (ok == true) widget.onDone();
  }

  Widget _resendButton(AppLocalizations t) {
    final waiting = _resendLeft > 0;
    final mmss = '${_resendLeft ~/ 60}:${(_resendLeft % 60).toString().padLeft(2, '0')}';
    return TextButton(
      onPressed: waiting || _busy
          ? null
          : () => _run(() async {
              await _sendCode();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.codeResent)));
              }
            }),
      child: Text(waiting ? t.resendIn(mmss) : t.resendCode),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final minAge = _minAgeByCallingCode[_parsed?.countryCode] ?? _defaultMinAge;
    Widget primary(String label, VoidCallback? onPressed) =>
        FilledButton(onPressed: _busy ? null : onPressed, child: Text(label));

    final (title, children) = switch (step) {
      _Step.welcome => (
        t.welcomeTitle,
        [
          Center(
            child: ClipOval(
              child: Image.asset(
                Theme.of(context).brightness == Brightness.dark ? 'assets/logo_dark.jpeg' : 'assets/logo.jpeg',
                height: 160,
                semanticLabel: t.appLogo,
              ),
            ),
          ),
          Text(t.historyNotice), // ID-14
          primary(t.continueButton, () => setState(() => step = _Step.phone)),
        ],
      ),
      _Step.phone => (
        t.phoneTitle,
        [
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            decoration: InputDecoration(labelText: t.phoneTitle, hintText: t.phoneHint),
            onChanged: _onPhoneChanged,
          ),
          CheckboxListTile(
            value: _ageOk,
            onChanged: (v) => setState(() => _ageOk = v ?? false),
            title: Text(t.ageConfirm(minAge)),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          primary(
            t.sendCode,
            _parsed == null || !_ageOk
                ? null
                : () => _run(() async {
                    await _sendCode();
                    setState(() => step = _Step.code);
                  }),
          ),
        ],
      ),
      _Step.code => (
        t.codeTitle(_parsed?.international ?? ''),
        [
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            maxLength: 6,
            decoration: InputDecoration(labelText: t.codeLabel),
          ),
          primary(t.verify, _verify),
          _resendButton(t),
        ],
      ),
      _Step.pin => (
        t.pinTitle,
        [
          Text(t.pinHelp),
          TextField(
            controller: _pin,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            decoration: InputDecoration(labelText: t.pinLabel),
          ),
          primary(t.verify, _verify),
        ],
      ),
      _Step.profile => (
        t.profileTitle,
        [
          // ID-09: a re-registered account keeps its @username; only the name is asked again
          // (the old profile key left with the old install).
          if (core.username() case final kept?)
            Text(t.homeRegistered(kept), style: Theme.of(context).textTheme.titleMedium)
          else
            TextField(
              controller: _username,
              autocorrect: false,
              decoration: InputDecoration(labelText: t.usernameLabel, helperText: t.usernameHelp, helperMaxLines: 3),
            ),
          TextField(
            controller: _name,
            maxLength: 64,
            decoration: InputDecoration(labelText: t.displayNameLabel),
          ),
          primary(
            t.save,
            () => _run(() async {
              core.setDisplayName(name: _name.text);
              if (core.username() == null) await core.setUsername(username: _username.text.trim());
              // An account that already has a PIN doesn't get offered one again.
              if (core.hasRegistrationLock()) {
                widget.onDone();
              } else {
                setState(() => step = _Step.lock);
              }
            }),
          ),
        ],
      ),
      _Step.lock => (
        t.lockOfferTitle,
        [
          Text(t.lockOfferBody),
          TextField(
            controller: _pin,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            decoration: InputDecoration(labelText: t.pinLabel),
          ),
          primary(
            t.setPin,
            () => _run(() async {
              await core.setRegistrationLock(pin: _pin.text.trim());
              widget.onDone();
            }),
          ),
          TextButton(onPressed: _busy ? null : () => _skipLock(t), child: Text(t.skip)),
        ],
      ),
    };

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView(
          // Fresh fields per step: a reused field keeps the previous step's keyboard type (numeric after the code).
          key: ValueKey(step),
          padding: const EdgeInsets.all(16),
          children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 16), child: c)],
        ),
      ),
    );
  }
}
