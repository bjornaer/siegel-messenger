import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Siegel'**
  String get appTitle;

  /// No description provided for @continueButton.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueButton;

  /// No description provided for @welcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Siegel'**
  String get welcomeTitle;

  /// No description provided for @historyNotice.
  ///
  /// In en, this message translates to:
  /// **'Your messages are stored only on this phone. If you lose it, reset it or delete the app, your chat history is gone for good. There are no backups.'**
  String get historyNotice;

  /// No description provided for @phoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Your phone number'**
  String get phoneTitle;

  /// No description provided for @phoneHint.
  ///
  /// In en, this message translates to:
  /// **'+34 600 000 000'**
  String get phoneHint;

  /// No description provided for @ageConfirm.
  ///
  /// In en, this message translates to:
  /// **'I am at least {age} years old'**
  String ageConfirm(int age);

  /// No description provided for @sendCode.
  ///
  /// In en, this message translates to:
  /// **'Send code'**
  String get sendCode;

  /// No description provided for @codeTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter the 6-digit code sent to {phone}'**
  String codeTitle(String phone);

  /// No description provided for @codeLabel.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get codeLabel;

  /// No description provided for @verify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get verify;

  /// No description provided for @pinTitle.
  ///
  /// In en, this message translates to:
  /// **'Registration Lock'**
  String get pinTitle;

  /// No description provided for @pinHelp.
  ///
  /// In en, this message translates to:
  /// **'This number is protected by a PIN. Enter it to continue.'**
  String get pinHelp;

  /// No description provided for @pinLabel.
  ///
  /// In en, this message translates to:
  /// **'4-digit PIN'**
  String get pinLabel;

  /// No description provided for @profileTitle.
  ///
  /// In en, this message translates to:
  /// **'Your profile'**
  String get profileTitle;

  /// No description provided for @usernameLabel.
  ///
  /// In en, this message translates to:
  /// **'@username'**
  String get usernameLabel;

  /// No description provided for @usernameHelp.
  ///
  /// In en, this message translates to:
  /// **'4 to 32 characters: a–z, 0–9, _ and . Starts with a letter. This is how people find you.'**
  String get usernameHelp;

  /// No description provided for @displayNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get displayNameLabel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @lockOfferTitle.
  ///
  /// In en, this message translates to:
  /// **'Protect your account with a PIN'**
  String get lockOfferTitle;

  /// No description provided for @lockOfferBody.
  ///
  /// In en, this message translates to:
  /// **'If someone takes over your phone number, they will also need this PIN to register it. Don\'t forget it.'**
  String get lockOfferBody;

  /// No description provided for @setPin.
  ///
  /// In en, this message translates to:
  /// **'Set PIN'**
  String get setPin;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @skipWarningTitle.
  ///
  /// In en, this message translates to:
  /// **'Skip the PIN?'**
  String get skipWarningTitle;

  /// No description provided for @skipWarningBody.
  ///
  /// In en, this message translates to:
  /// **'Without a PIN, anyone who gets control of your phone number (for example through a SIM swap) can take over your account and @username.'**
  String get skipWarningBody;

  /// No description provided for @skipAnyway.
  ///
  /// In en, this message translates to:
  /// **'Skip anyway'**
  String get skipAnyway;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @homeRegistered.
  ///
  /// In en, this message translates to:
  /// **'You are @{username}'**
  String homeRegistered(String username);

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @deleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get deleteAccount;

  /// No description provided for @deleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete your account?'**
  String get deleteConfirmTitle;

  /// No description provided for @deleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Your account, @username and all data on our server are deleted, and this phone is wiped. This cannot be undone.'**
  String get deleteConfirmBody;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @errPhoneInvalid.
  ///
  /// In en, this message translates to:
  /// **'That doesn\'t look like a valid phone number.'**
  String get errPhoneInvalid;

  /// No description provided for @errRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Please wait and try again later.'**
  String get errRateLimited;

  /// No description provided for @errOtpInvalid.
  ///
  /// In en, this message translates to:
  /// **'Wrong or expired code.'**
  String get errOtpInvalid;

  /// No description provided for @errLockInvalid.
  ///
  /// In en, this message translates to:
  /// **'Wrong PIN.'**
  String get errLockInvalid;

  /// No description provided for @errLockLocked.
  ///
  /// In en, this message translates to:
  /// **'Too many wrong PINs. Try again in 24 hours.'**
  String get errLockLocked;

  /// No description provided for @errUsernameInvalid.
  ///
  /// In en, this message translates to:
  /// **'That username isn\'t allowed.'**
  String get errUsernameInvalid;

  /// No description provided for @errUsernameTaken.
  ///
  /// In en, this message translates to:
  /// **'That username is taken.'**
  String get errUsernameTaken;

  /// No description provided for @errUsernameTooSoon.
  ///
  /// In en, this message translates to:
  /// **'You can change your username once every 30 days.'**
  String get errUsernameTooSoon;

  /// No description provided for @errPinInvalid.
  ///
  /// In en, this message translates to:
  /// **'The PIN must be exactly 4 digits.'**
  String get errPinInvalid;

  /// No description provided for @errDisplayNameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a name of 1 to 64 characters.'**
  String get errDisplayNameInvalid;

  /// No description provided for @errNetwork.
  ///
  /// In en, this message translates to:
  /// **'Can\'t reach the server. Check your connection.'**
  String get errNetwork;

  /// No description provided for @errGeneric.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get errGeneric;

  /// No description provided for @appLock.
  ///
  /// In en, this message translates to:
  /// **'App lock'**
  String get appLock;

  /// No description provided for @appLockSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Require your fingerprint, face or phone passcode to open Siegel.'**
  String get appLockSubtitle;

  /// No description provided for @lockAfter.
  ///
  /// In en, this message translates to:
  /// **'Lock after'**
  String get lockAfter;

  /// No description provided for @lockImmediately.
  ///
  /// In en, this message translates to:
  /// **'Immediately'**
  String get lockImmediately;

  /// No description provided for @lockMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute} other{{count} minutes}}'**
  String lockMinutes(int count);

  /// No description provided for @lockHours.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour} other{{count} hours}}'**
  String lockHours(int count);

  /// No description provided for @screenSecurity.
  ///
  /// In en, this message translates to:
  /// **'Screen security'**
  String get screenSecurity;

  /// No description provided for @screenSecuritySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Block screenshots and screen recording of Siegel.'**
  String get screenSecuritySubtitle;

  /// No description provided for @lockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Siegel is locked'**
  String get lockedTitle;

  /// No description provided for @unlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get unlock;

  /// No description provided for @unlockReason.
  ///
  /// In en, this message translates to:
  /// **'Unlock Siegel'**
  String get unlockReason;

  /// No description provided for @errNoDeviceLock.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t verify it\'s you. Set up a screen lock on your phone first.'**
  String get errNoDeviceLock;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
