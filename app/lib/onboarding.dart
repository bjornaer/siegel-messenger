import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import 'avatar.dart';
import 'l10n/app_localizations.dart';
import 'links.dart' show isAndroid, isIOS, openPage;
import 'minors.dart';
import 'phone_field.dart';
import 'suspended.dart' show ruleLabel;
import 'src/rust/api/core.dart';
import 'themes.dart';

/// CMP-02: minimum age per country calling code. GDPR default is 16; Spain allows 14 (LOPDGDD art. 7).
/// ponytail: fill in per launch country once Q2 is settled.

void showError(BuildContext context, CoreError e) {
  final t = AppLocalizations.of(context)!;
  final msg = switch (e.code) {
    'phone_invalid' => t.errPhoneInvalid,
    'phone_mismatch' => t.errPhoneMismatch,
    'number_change_too_soon' => t.errNumberChangeTooSoon,
    'number_same' => t.errNumberSame,
    'rate_limited' => t.errRateLimited,
    'otp_invalid' => t.errOtpInvalid,
    'registration_lock_invalid' => t.errLockInvalid,
    'registration_lock_locked' => t.errLockLocked,
    'username_invalid' => t.errUsernameInvalid,
    'sticker_invalid' => t.errStickerInvalid,
    'reports_unavailable' => t.errReportsUnavailable,
    'account_suspended' => t.suspendedTitle,
    'number_banned' => t.errNumberBanned,
    'too_many_devices' => t.tooManyDevices,
    'link_expired' => t.errLinkExpired,
    'primary_only' => t.thisIsLinked,
    'report_invalid' => t.errReportInvalid,
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
    'attachment_expired' => t.errAttachmentExpired,
    'attachment_corrupt' => t.errAttachmentCorrupt,
    'attachment_too_large' => t.errAttachmentTooLarge,
    'video_compress_failed' => t.errVideoCompress,
    'upload_failed' => t.errUploadFailed,
    'avatar_invalid' => t.errAvatarInvalid,
    'attachment_invalid' => t.errAttachmentInvalid,
    'view_once_gone' || 'view_once' => t.errViewOnceGone,
    'view_once_phone_only' => t.viewOnceOnPhone,
    'network' => t.errNetwork,
    _ => t.errGeneric,
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

enum _Step { welcome, phone, code, pin, profile, lock }

DevicePlatform get _platform => isIOS ? DevicePlatform.ios : DevicePlatform.android;

/// ID-02: proof that this is a genuine app on a genuine device, bound to the number. Empty when
/// unavailable (no Play services, iOS until App Attest); the server then refuses to send an SMS.
Future<String> attestationToken(String phone) async {
  if (!isAndroid) return '';
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
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _username = TextEditingController();
  final _name = TextEditingController();
  PhoneNumber? _parsed;
  int? _birthYear;
  int? _birthMonth;
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

  Future<void> _verify() => _run(() async {
    await core.verify(
      phoneE164: _parsed!.international,
      otp: _code.text.trim(),
      pin: _pin.text.trim(),
      platform: _platform,
    );
    unawaited(syncMinor(core)); // M7: under 18 is known from now on
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
    final minAge = minAgeFor(_parsed?.countryCode);
    final age = _birthYear == null || _birthMonth == null ? null : ageAt(DateTime.now(), _birthYear!, _birthMonth!);
    final ageOk = age != null && age >= minAge;
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
          // The country with its flag (the SIM's by default), then the number; the line under it
          // shows the exact international number the SMS goes to.
          PhoneNumberField(onChanged: (p) => setState(() => _parsed = p)),
          // Terms and privacy before the first SMS (DSA Art. 14, CMP-07).
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(t.agreeToTerms),
              TextButton(onPressed: () => openPage('/terms'), child: Text(t.terms)),
              TextButton(onPressed: () => openPage('/guidelines'), child: Text(t.guidelines)),
              TextButton(onPressed: () => openPage('/privacy'), child: Text(t.privacyPolicy)),
            ],
          ),
          // CMP-02 and M7: the birth month and year stay on this phone.
          BirthDateFields(
            year: _birthYear,
            month: _birthMonth,
            onChanged: (y, m) => setState(() {
              _birthYear = y;
              _birthMonth = m;
            }),
          ),
          if (age != null && !ageOk)
            Text(t.tooYoung(minAge), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          primary(
            t.sendCode,
            _parsed == null || !ageOk
                ? null
                : () => _run(() async {
                    setBirth(core, _birthYear!, _birthMonth!);
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
          // M7: a moderator removed our @username: say why, then ask for a new one.
          if (core.notice() case final n? when !n.suspended)
            Card.outlined(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  [t.usernameRemoved, t.noticeRule(ruleLabel(t, n.rule)), if (n.reason.isNotEmpty) n.reason].join('\n'),
                ),
              ),
            ),
          Center(child: AvatarEditor(core: core)), // MED-15, optional
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
      appBar: SiegelBar(title: Text(title)),
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
