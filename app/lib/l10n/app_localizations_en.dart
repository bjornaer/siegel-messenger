// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Siegel';

  @override
  String get continueButton => 'Continue';

  @override
  String get welcomeTitle => 'Welcome to Siegel';

  @override
  String get historyNotice =>
      'Your messages are stored only on this phone. If you lose it, reset it or delete the app, your chat history is gone for good. There are no backups.';

  @override
  String get phoneTitle => 'Your phone number';

  @override
  String get phoneHint => '+34 600 000 000';

  @override
  String ageConfirm(int age) {
    return 'I am at least $age years old';
  }

  @override
  String get sendCode => 'Send code';

  @override
  String codeTitle(String phone) {
    return 'Enter the 6-digit code sent to $phone';
  }

  @override
  String get codeLabel => 'Code';

  @override
  String get verify => 'Verify';

  @override
  String get pinTitle => 'Registration Lock';

  @override
  String get pinHelp =>
      'This number is protected by a PIN. Enter it to continue.';

  @override
  String get pinLabel => '4-digit PIN';

  @override
  String get profileTitle => 'Your profile';

  @override
  String get usernameLabel => '@username';

  @override
  String get usernameHelp =>
      '4 to 32 characters: a–z, 0–9, _ and . Starts with a letter. This is how people find you.';

  @override
  String get displayNameLabel => 'Display name';

  @override
  String get save => 'Save';

  @override
  String get lockOfferTitle => 'Protect your account with a PIN';

  @override
  String get lockOfferBody =>
      'If someone takes over your phone number, they will also need this PIN to register it. Don\'t forget it.';

  @override
  String get setPin => 'Set PIN';

  @override
  String get skip => 'Skip';

  @override
  String get skipWarningTitle => 'Skip the PIN?';

  @override
  String get skipWarningBody =>
      'Without a PIN, anyone who gets control of your phone number (for example through a SIM swap) can take over your account and @username.';

  @override
  String get skipAnyway => 'Skip anyway';

  @override
  String get cancel => 'Cancel';

  @override
  String homeRegistered(String username) {
    return 'You are @$username';
  }

  @override
  String get settings => 'Settings';

  @override
  String get deleteAccount => 'Delete account';

  @override
  String get deleteConfirmTitle => 'Delete your account?';

  @override
  String get deleteConfirmBody =>
      'Your account, @username and all data on our server are deleted, and this phone is wiped. This cannot be undone.';

  @override
  String get delete => 'Delete';

  @override
  String get errPhoneInvalid => 'That doesn\'t look like a valid phone number.';

  @override
  String get errRateLimited =>
      'Too many attempts. Please wait and try again later.';

  @override
  String get errOtpInvalid => 'Wrong or expired code.';

  @override
  String get errLockInvalid => 'Wrong PIN.';

  @override
  String get errLockLocked => 'Too many wrong PINs. Try again in 24 hours.';

  @override
  String get errUsernameInvalid => 'That username isn\'t allowed.';

  @override
  String get errUsernameTaken => 'That username is taken.';

  @override
  String get errUsernameTooSoon =>
      'You can change your username once every 30 days.';

  @override
  String get errPinInvalid => 'The PIN must be exactly 4 digits.';

  @override
  String get errDisplayNameInvalid => 'Enter a name of 1 to 64 characters.';

  @override
  String get errNetwork => 'Can\'t reach the server. Check your connection.';

  @override
  String get errGeneric => 'Something went wrong. Please try again.';

  @override
  String get appLock => 'App lock';

  @override
  String get appLockSubtitle =>
      'Require your fingerprint, face or phone passcode to open Siegel.';

  @override
  String get lockAfter => 'Lock after';

  @override
  String get lockImmediately => 'Immediately';

  @override
  String lockMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes',
      one: '1 minute',
    );
    return '$_temp0';
  }

  @override
  String lockHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours',
      one: '1 hour',
    );
    return '$_temp0';
  }

  @override
  String get screenSecurity => 'Screen security';

  @override
  String get screenSecuritySubtitle =>
      'Block screenshots and screen recording of Siegel.';

  @override
  String get lockedTitle => 'Siegel is locked';

  @override
  String get unlock => 'Unlock';

  @override
  String get unlockReason => 'Unlock Siegel';

  @override
  String get errNoDeviceLock =>
      'Couldn\'t verify it\'s you. Set up a screen lock on your phone first.';

  @override
  String get appLogo => 'Siegel logo';
}
