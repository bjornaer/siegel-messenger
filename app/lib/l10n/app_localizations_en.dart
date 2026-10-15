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

  @override
  String get chatsTitle => 'Chats';

  @override
  String get newChat => 'New chat';

  @override
  String get noChats => 'No chats yet. Start one with someone\'s @username.';

  @override
  String get newContact => 'New contact';

  @override
  String get messageHint => 'Message';

  @override
  String get send => 'Send';

  @override
  String get startChat => 'Start chat';

  @override
  String get errUsernameNotFound => 'No one has that username.';

  @override
  String get errNoKeyPackages =>
      'That account can\'t receive messages right now. Try again later.';

  @override
  String get errTextInvalid => 'Messages can be up to 64 KB of text.';

  @override
  String get messageRequests => 'Message requests';

  @override
  String messageRequestsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count message requests',
      one: '1 message request',
    );
    return '$_temp0';
  }

  @override
  String get noRequests => 'No message requests.';

  @override
  String requestBanner(String name) {
    return '$name wants to chat with you. They won\'t see your name or know you read this until you accept.';
  }

  @override
  String get accept => 'Accept';

  @override
  String get block => 'Block';

  @override
  String blockConfirmTitle(String name) {
    return 'Block $name?';
  }

  @override
  String get blockConfirmBody =>
      'They won\'t be able to message you or start new chats, and they won\'t be told.';

  @override
  String get errRequestPending => 'Accept the request before replying.';

  @override
  String get reply => 'Reply';

  @override
  String get copy => 'Copy';

  @override
  String get copied => 'Copied';

  @override
  String get edit => 'Edit';

  @override
  String get editing => 'Editing message';

  @override
  String get edited => 'edited';

  @override
  String get editHistory => 'Edit history';

  @override
  String get deleteForMe => 'Delete for me';

  @override
  String get deleteForEveryone => 'Delete for everyone';

  @override
  String get deleteForEveryoneBody =>
      'The message is replaced with \"This message was deleted\" for everyone in this chat. Someone using a modified app could still keep a copy.';

  @override
  String get messageDeleted => 'This message was deleted';

  @override
  String get originalMissing => 'Original message not available';

  @override
  String get you => 'You';

  @override
  String get typing => 'typing…';

  @override
  String get notSentRetry => 'Not sent. Tap to retry.';

  @override
  String get statusSending => 'Sending';

  @override
  String get statusSent => 'Sent';

  @override
  String get statusDelivered => 'Delivered';

  @override
  String get statusRead => 'Read';

  @override
  String get readReceipts => 'Read receipts';

  @override
  String get readReceiptsHelp =>
      'If you turn these off, you won\'t see when others read your messages either.';

  @override
  String get typingIndicators => 'Typing indicators';

  @override
  String get typingIndicatorsHelp =>
      'If you turn these off, you won\'t see when others are typing either.';

  @override
  String get errNotAllowed => 'That\'s no longer possible for this message.';

  @override
  String get close => 'Close';

  @override
  String get safetyNumber => 'Safety number';

  @override
  String safetyNumberHelp(String name) {
    return 'Compare these numbers with $name, or scan their code when you\'re together. If they match, nobody is in the middle of your chat.';
  }

  @override
  String get safetyNumberUnavailable =>
      'The safety number isn\'t available yet.';

  @override
  String get scanCode => 'Scan their code';

  @override
  String get verified => 'Verified';

  @override
  String get verifiedDone => 'Verified. The safety number matches.';

  @override
  String verifyMismatch(String name) {
    return 'This code doesn\'t match. Make sure you scan $name\'s code for this chat.';
  }

  @override
  String keyChanged(String name) {
    return '$name\'s safety number changed, for example because they reinstalled Siegel or got a new phone. Tap to compare.';
  }

  @override
  String get blockedPeople => 'Blocked people';

  @override
  String get noBlocked => 'You haven\'t blocked anyone.';

  @override
  String get unblock => 'Unblock';

  @override
  String get notificationChannel => 'Messages';
}
