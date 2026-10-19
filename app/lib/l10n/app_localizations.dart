import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_pt.dart';

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
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
    Locale('es'),
    Locale('pt'),
  ];

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

  /// No description provided for @appLogo.
  ///
  /// In en, this message translates to:
  /// **'Siegel logo'**
  String get appLogo;

  /// No description provided for @chatsTitle.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get chatsTitle;

  /// No description provided for @newChat.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get newChat;

  /// No description provided for @noChats.
  ///
  /// In en, this message translates to:
  /// **'No chats yet. Start one with someone\'s @username.'**
  String get noChats;

  /// No description provided for @newContact.
  ///
  /// In en, this message translates to:
  /// **'New contact'**
  String get newContact;

  /// No description provided for @messageHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get messageHint;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @startChat.
  ///
  /// In en, this message translates to:
  /// **'Start chat'**
  String get startChat;

  /// No description provided for @errUsernameNotFound.
  ///
  /// In en, this message translates to:
  /// **'No one has that username.'**
  String get errUsernameNotFound;

  /// No description provided for @errNoKeyPackages.
  ///
  /// In en, this message translates to:
  /// **'That account can\'t receive messages right now. Try again later.'**
  String get errNoKeyPackages;

  /// No description provided for @errTextInvalid.
  ///
  /// In en, this message translates to:
  /// **'Messages can be up to 64 KB of text.'**
  String get errTextInvalid;

  /// No description provided for @messageRequests.
  ///
  /// In en, this message translates to:
  /// **'Message requests'**
  String get messageRequests;

  /// No description provided for @messageRequestsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 message request} other{{count} message requests}}'**
  String messageRequestsCount(int count);

  /// No description provided for @noRequests.
  ///
  /// In en, this message translates to:
  /// **'No message requests.'**
  String get noRequests;

  /// No description provided for @requestBanner.
  ///
  /// In en, this message translates to:
  /// **'{name} wants to chat with you. They won\'t see your name or know you read this until you accept.'**
  String requestBanner(String name);

  /// No description provided for @accept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get accept;

  /// No description provided for @block.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get block;

  /// No description provided for @blockConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Block {name}?'**
  String blockConfirmTitle(String name);

  /// No description provided for @blockConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'They won\'t be able to message you or start new chats, and they won\'t be told.'**
  String get blockConfirmBody;

  /// No description provided for @errRequestPending.
  ///
  /// In en, this message translates to:
  /// **'Accept the request before replying.'**
  String get errRequestPending;

  /// No description provided for @reply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get reply;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @editing.
  ///
  /// In en, this message translates to:
  /// **'Editing message'**
  String get editing;

  /// No description provided for @edited.
  ///
  /// In en, this message translates to:
  /// **'edited'**
  String get edited;

  /// No description provided for @editHistory.
  ///
  /// In en, this message translates to:
  /// **'Edit history'**
  String get editHistory;

  /// No description provided for @deleteForMe.
  ///
  /// In en, this message translates to:
  /// **'Delete for me'**
  String get deleteForMe;

  /// No description provided for @deleteForEveryone.
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone'**
  String get deleteForEveryone;

  /// No description provided for @deleteForEveryoneBody.
  ///
  /// In en, this message translates to:
  /// **'The message is replaced with \"This message was deleted\" for everyone in this chat. Someone using a modified app could still keep a copy.'**
  String get deleteForEveryoneBody;

  /// No description provided for @messageDeleted.
  ///
  /// In en, this message translates to:
  /// **'This message was deleted'**
  String get messageDeleted;

  /// No description provided for @originalMissing.
  ///
  /// In en, this message translates to:
  /// **'Original message not available'**
  String get originalMissing;

  /// No description provided for @you.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get you;

  /// No description provided for @typing.
  ///
  /// In en, this message translates to:
  /// **'typing…'**
  String get typing;

  /// No description provided for @notSentRetry.
  ///
  /// In en, this message translates to:
  /// **'Not sent. Tap to retry.'**
  String get notSentRetry;

  /// No description provided for @statusSending.
  ///
  /// In en, this message translates to:
  /// **'Sending'**
  String get statusSending;

  /// No description provided for @statusSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get statusSent;

  /// No description provided for @statusDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get statusDelivered;

  /// No description provided for @statusRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get statusRead;

  /// No description provided for @readReceipts.
  ///
  /// In en, this message translates to:
  /// **'Read receipts'**
  String get readReceipts;

  /// No description provided for @readReceiptsHelp.
  ///
  /// In en, this message translates to:
  /// **'If you turn these off, you won\'t see when others read your messages either.'**
  String get readReceiptsHelp;

  /// No description provided for @typingIndicators.
  ///
  /// In en, this message translates to:
  /// **'Typing indicators'**
  String get typingIndicators;

  /// No description provided for @typingIndicatorsHelp.
  ///
  /// In en, this message translates to:
  /// **'If you turn these off, you won\'t see when others are typing either.'**
  String get typingIndicatorsHelp;

  /// No description provided for @errNotAllowed.
  ///
  /// In en, this message translates to:
  /// **'That\'s no longer possible for this message.'**
  String get errNotAllowed;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @safetyNumber.
  ///
  /// In en, this message translates to:
  /// **'Safety number'**
  String get safetyNumber;

  /// No description provided for @safetyNumberHelp.
  ///
  /// In en, this message translates to:
  /// **'Compare these numbers with {name}, or scan their code when you\'re together. If they match, nobody is in the middle of your chat.'**
  String safetyNumberHelp(String name);

  /// No description provided for @safetyNumberUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The safety number isn\'t available yet.'**
  String get safetyNumberUnavailable;

  /// No description provided for @scanCode.
  ///
  /// In en, this message translates to:
  /// **'Scan their code'**
  String get scanCode;

  /// No description provided for @verified.
  ///
  /// In en, this message translates to:
  /// **'Verified'**
  String get verified;

  /// No description provided for @verifiedDone.
  ///
  /// In en, this message translates to:
  /// **'Verified. The safety number matches.'**
  String get verifiedDone;

  /// No description provided for @verifyMismatch.
  ///
  /// In en, this message translates to:
  /// **'This code doesn\'t match. Make sure you scan {name}\'s code for this chat.'**
  String verifyMismatch(String name);

  /// No description provided for @keyChanged.
  ///
  /// In en, this message translates to:
  /// **'{name}\'s safety number changed, for example because they reinstalled Siegel or got a new phone. Tap to compare.'**
  String keyChanged(String name);

  /// No description provided for @blockedPeople.
  ///
  /// In en, this message translates to:
  /// **'Blocked people'**
  String get blockedPeople;

  /// No description provided for @noBlocked.
  ///
  /// In en, this message translates to:
  /// **'You haven\'t blocked anyone.'**
  String get noBlocked;

  /// No description provided for @unblock.
  ///
  /// In en, this message translates to:
  /// **'Unblock'**
  String get unblock;

  /// No description provided for @notificationChannel.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get notificationChannel;

  /// No description provided for @errAttestation.
  ///
  /// In en, this message translates to:
  /// **'This copy of Siegel couldn\'t be verified. Install it from Google Play and try again.'**
  String get errAttestation;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @selected.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get selected;

  /// No description provided for @themeSiegel.
  ///
  /// In en, this message translates to:
  /// **'Seal. The green of our logo.'**
  String get themeSiegel;

  /// No description provided for @themeDrache.
  ///
  /// In en, this message translates to:
  /// **'Dragon. Deep red, a little fierce.'**
  String get themeDrache;

  /// No description provided for @themeLoewe.
  ///
  /// In en, this message translates to:
  /// **'Lion. Old gold, like a coat of arms.'**
  String get themeLoewe;

  /// No description provided for @themeLindwurm.
  ///
  /// In en, this message translates to:
  /// **'The serpent dragon of Alpine legend. Teal and scales.'**
  String get themeLindwurm;

  /// No description provided for @themeSchnee.
  ///
  /// In en, this message translates to:
  /// **'Snow. Quiet, pale blue.'**
  String get themeSchnee;

  /// No description provided for @themeKrampus.
  ///
  /// In en, this message translates to:
  /// **'The Alpine winter demon. Ember orange.'**
  String get themeKrampus;

  /// No description provided for @themeNordlicht.
  ///
  /// In en, this message translates to:
  /// **'Northern lights. Violet with a shimmer.'**
  String get themeNordlicht;

  /// No description provided for @themeFernweh.
  ///
  /// In en, this message translates to:
  /// **'The longing for faraway places. Open-sea blue.'**
  String get themeFernweh;

  /// No description provided for @mute.
  ///
  /// In en, this message translates to:
  /// **'Mute notifications'**
  String get mute;

  /// No description provided for @messageInfo.
  ///
  /// In en, this message translates to:
  /// **'Message info'**
  String get messageInfo;

  /// No description provided for @sentAt.
  ///
  /// In en, this message translates to:
  /// **'Sent {when}'**
  String sentAt(String when);

  /// No description provided for @newGroup.
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get newGroup;

  /// No description provided for @groupName.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get groupName;

  /// No description provided for @group.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get group;

  /// No description provided for @addPeople.
  ///
  /// In en, this message translates to:
  /// **'Add people'**
  String get addPeople;

  /// No description provided for @addPeopleHint.
  ///
  /// In en, this message translates to:
  /// **'@username, then Add'**
  String get addPeopleHint;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @membersCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 member} other{{count} members}}'**
  String membersCount(int count);

  /// No description provided for @groupInfo.
  ///
  /// In en, this message translates to:
  /// **'Group info'**
  String get groupInfo;

  /// No description provided for @admin.
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get admin;

  /// No description provided for @makeAdmin.
  ///
  /// In en, this message translates to:
  /// **'Make admin'**
  String get makeAdmin;

  /// No description provided for @removeAdmin.
  ///
  /// In en, this message translates to:
  /// **'Remove as admin'**
  String get removeAdmin;

  /// No description provided for @removeFromGroup.
  ///
  /// In en, this message translates to:
  /// **'Remove from group'**
  String get removeFromGroup;

  /// No description provided for @leaveGroup.
  ///
  /// In en, this message translates to:
  /// **'Leave group'**
  String get leaveGroup;

  /// No description provided for @leaveGroupBody.
  ///
  /// In en, this message translates to:
  /// **'You won\'t get new messages from this group. The chat stays on this phone.'**
  String get leaveGroupBody;

  /// No description provided for @leftGroup.
  ///
  /// In en, this message translates to:
  /// **'You\'re no longer in this group.'**
  String get leftGroup;

  /// No description provided for @onlyAdminsEditInfo.
  ///
  /// In en, this message translates to:
  /// **'Only admins can edit the group name and photo'**
  String get onlyAdminsEditInfo;

  /// No description provided for @onlyAdminsAdd.
  ///
  /// In en, this message translates to:
  /// **'Only admins can add members'**
  String get onlyAdminsAdd;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @isTyping.
  ///
  /// In en, this message translates to:
  /// **'{name} is typing…'**
  String isTyping(String name);

  /// No description provided for @someone.
  ///
  /// In en, this message translates to:
  /// **'Someone'**
  String get someone;

  /// No description provided for @evCreated.
  ///
  /// In en, this message translates to:
  /// **'{actor} created the group'**
  String evCreated(String actor);

  /// No description provided for @evAdded.
  ///
  /// In en, this message translates to:
  /// **'{actor} added {targets}'**
  String evAdded(String actor, String targets);

  /// No description provided for @evRemoved.
  ///
  /// In en, this message translates to:
  /// **'{actor} removed {targets}'**
  String evRemoved(String actor, String targets);

  /// No description provided for @evLeft.
  ///
  /// In en, this message translates to:
  /// **'{actor} left'**
  String evLeft(String actor);

  /// No description provided for @evRenamed.
  ///
  /// In en, this message translates to:
  /// **'{actor} renamed the group to {targets}'**
  String evRenamed(String actor, String targets);

  /// No description provided for @evAdminAdded.
  ///
  /// In en, this message translates to:
  /// **'{actor} made {targets} an admin'**
  String evAdminAdded(String actor, String targets);

  /// No description provided for @evAdminRemoved.
  ///
  /// In en, this message translates to:
  /// **'{actor} removed {targets} as admin'**
  String evAdminRemoved(String actor, String targets);

  /// No description provided for @evSettings.
  ///
  /// In en, this message translates to:
  /// **'{actor} changed the group settings'**
  String evSettings(String actor);

  /// No description provided for @inviteBanner.
  ///
  /// In en, this message translates to:
  /// **'You were added to this group by someone who isn\'t in your contacts. Members won\'t see your name until you accept.'**
  String get inviteBanner;

  /// No description provided for @decline.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get decline;

  /// No description provided for @groupAdds.
  ///
  /// In en, this message translates to:
  /// **'Who can add me to groups'**
  String get groupAdds;

  /// No description provided for @groupAddsEveryone.
  ///
  /// In en, this message translates to:
  /// **'Everyone'**
  String get groupAddsEveryone;

  /// No description provided for @groupAddsContacts.
  ///
  /// In en, this message translates to:
  /// **'My contacts'**
  String get groupAddsContacts;

  /// No description provided for @groupAddsHelp.
  ///
  /// In en, this message translates to:
  /// **'Anyone else sends you an invite to accept or decline.'**
  String get groupAddsHelp;

  /// No description provided for @muteFor8h.
  ///
  /// In en, this message translates to:
  /// **'For 8 hours'**
  String get muteFor8h;

  /// No description provided for @muteFor1w.
  ///
  /// In en, this message translates to:
  /// **'For 1 week'**
  String get muteFor1w;

  /// No description provided for @muteAlways.
  ///
  /// In en, this message translates to:
  /// **'Always'**
  String get muteAlways;

  /// No description provided for @unmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get unmute;

  /// No description provided for @mutedUntil.
  ///
  /// In en, this message translates to:
  /// **'Muted until {when}'**
  String mutedUntil(String when);

  /// No description provided for @muted.
  ///
  /// In en, this message translates to:
  /// **'Muted'**
  String get muted;

  /// No description provided for @errGroupLeft.
  ///
  /// In en, this message translates to:
  /// **'You\'re no longer in this group.'**
  String get errGroupLeft;

  /// No description provided for @errGroupTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Groups can have up to 256 members.'**
  String get errGroupTooLarge;

  /// No description provided for @errNameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Group names have 1 to 64 characters.'**
  String get errNameInvalid;

  /// No description provided for @editProfile.
  ///
  /// In en, this message translates to:
  /// **'Edit profile'**
  String get editProfile;

  /// No description provided for @orStartChat.
  ///
  /// In en, this message translates to:
  /// **'Or start a chat with someone\'s @username'**
  String get orStartChat;

  /// No description provided for @errPeerOutdated.
  ///
  /// In en, this message translates to:
  /// **'Someone you added has an old version of Siegel. They need to update before joining a group.'**
  String get errPeerOutdated;

  /// No description provided for @resendCode.
  ///
  /// In en, this message translates to:
  /// **'Resend code'**
  String get resendCode;

  /// No description provided for @resendIn.
  ///
  /// In en, this message translates to:
  /// **'Resend code in {time}'**
  String resendIn(String time);

  /// No description provided for @codeResent.
  ///
  /// In en, this message translates to:
  /// **'Code sent again.'**
  String get codeResent;

  /// No description provided for @errResendTooSoon.
  ///
  /// In en, this message translates to:
  /// **'Please wait a little before asking for another code.'**
  String get errResendTooSoon;

  /// No description provided for @updateAvailable.
  ///
  /// In en, this message translates to:
  /// **'A new version of Siegel is available.'**
  String get updateAvailable;

  /// No description provided for @update.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get update;

  /// No description provided for @later.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get later;

  /// No description provided for @updateRequired.
  ///
  /// In en, this message translates to:
  /// **'This version of Siegel is no longer supported. Update to keep using it.'**
  String get updateRequired;

  /// No description provided for @myLink.
  ///
  /// In en, this message translates to:
  /// **'My link'**
  String get myLink;

  /// No description provided for @myLinkSubtitle.
  ///
  /// In en, this message translates to:
  /// **'People who open it chat with you straight away, no request.'**
  String get myLinkSubtitle;

  /// No description provided for @myLinkHelp.
  ///
  /// In en, this message translates to:
  /// **'Anyone with this link or code can start a chat with you, without a message request. Scanning it in person also verifies you.'**
  String get myLinkHelp;

  /// No description provided for @showLink.
  ///
  /// In en, this message translates to:
  /// **'Show code'**
  String get showLink;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @resetLink.
  ///
  /// In en, this message translates to:
  /// **'Reset link'**
  String get resetLink;

  /// No description provided for @resetLinkBody.
  ///
  /// In en, this message translates to:
  /// **'Your old link and code stop skipping the message request. Share the new one with people you want to hear from.'**
  String get resetLinkBody;

  /// No description provided for @scanQr.
  ///
  /// In en, this message translates to:
  /// **'Scan a QR code'**
  String get scanQr;

  /// No description provided for @errLinkInvalid.
  ///
  /// In en, this message translates to:
  /// **'That isn\'t a Siegel link.'**
  String get errLinkInvalid;

  /// No description provided for @errLinkKeyMismatch.
  ///
  /// In en, this message translates to:
  /// **'This link doesn\'t match this person\'s key. Don\'t trust this chat; ask them for a new link.'**
  String get errLinkKeyMismatch;

  /// No description provided for @joinGroupTitle.
  ///
  /// In en, this message translates to:
  /// **'Join {name}?'**
  String joinGroupTitle(String name);

  /// No description provided for @join.
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get join;

  /// No description provided for @inviteLinks.
  ///
  /// In en, this message translates to:
  /// **'Invite links'**
  String get inviteLinks;

  /// No description provided for @newInviteLink.
  ///
  /// In en, this message translates to:
  /// **'Create invite link'**
  String get newInviteLink;

  /// No description provided for @inviteLinkHelp.
  ///
  /// In en, this message translates to:
  /// **'Anyone with this link or code can join the group straight away, for one week. You can remove people afterwards, or revoke the link.'**
  String get inviteLinkHelp;

  /// No description provided for @expiresOn.
  ///
  /// In en, this message translates to:
  /// **'Expires {when}'**
  String expiresOn(String when);

  /// No description provided for @revoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get revoke;

  /// No description provided for @errLinkStale.
  ///
  /// In en, this message translates to:
  /// **'The group just changed. Try the link again in a moment.'**
  String get errLinkStale;

  /// No description provided for @errInviteNotFound.
  ///
  /// In en, this message translates to:
  /// **'This link has expired or was revoked.'**
  String get errInviteNotFound;

  /// No description provided for @errAlreadyMember.
  ///
  /// In en, this message translates to:
  /// **'You\'re already in this group.'**
  String get errAlreadyMember;

  /// No description provided for @voiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Voice message'**
  String get voiceMessage;

  /// No description provided for @recordVoice.
  ///
  /// In en, this message translates to:
  /// **'Record a voice message'**
  String get recordVoice;

  /// No description provided for @recording.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get recording;

  /// No description provided for @attachAudio.
  ///
  /// In en, this message translates to:
  /// **'Send an audio file'**
  String get attachAudio;

  /// No description provided for @micDenied.
  ///
  /// In en, this message translates to:
  /// **'Siegel needs the microphone to record voice messages. You can allow it in the system settings.'**
  String get micDenied;

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @errAttachmentExpired.
  ///
  /// In en, this message translates to:
  /// **'This attachment is no longer on the server. Ask the sender to send it again.'**
  String get errAttachmentExpired;

  /// No description provided for @errAttachmentCorrupt.
  ///
  /// In en, this message translates to:
  /// **'This attachment was damaged on the way and can\'t be opened.'**
  String get errAttachmentCorrupt;

  /// No description provided for @errAttachmentTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Files can be up to 100 MB.'**
  String get errAttachmentTooLarge;

  /// No description provided for @errUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'The upload didn\'t finish. Try again.'**
  String get errUploadFailed;

  /// No description provided for @profilePhoto.
  ///
  /// In en, this message translates to:
  /// **'Profile photo'**
  String get profilePhoto;

  /// No description provided for @choosePhoto.
  ///
  /// In en, this message translates to:
  /// **'Choose a photo'**
  String get choosePhoto;

  /// No description provided for @removePhoto.
  ///
  /// In en, this message translates to:
  /// **'Remove photo'**
  String get removePhoto;

  /// No description provided for @errAvatarInvalid.
  ///
  /// In en, this message translates to:
  /// **'That picture can\'t be used. Try another one.'**
  String get errAvatarInvalid;

  /// No description provided for @evAvatar.
  ///
  /// In en, this message translates to:
  /// **'{actor} changed the group photo'**
  String evAvatar(String actor);

  /// No description provided for @themeEdelweiss.
  ///
  /// In en, this message translates to:
  /// **'Edelweiss, the Alpine star flower. Snow white into silver.'**
  String get themeEdelweiss;

  /// No description provided for @photo.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get photo;

  /// No description provided for @video.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get video;

  /// No description provided for @file.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get file;

  /// No description provided for @attach.
  ///
  /// In en, this message translates to:
  /// **'Attach'**
  String get attach;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @saveToDevice.
  ///
  /// In en, this message translates to:
  /// **'Save to device'**
  String get saveToDevice;

  /// No description provided for @forward.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get forward;

  /// No description provided for @forwardTo.
  ///
  /// In en, this message translates to:
  /// **'Forward to…'**
  String get forwardTo;

  /// No description provided for @forwarded.
  ///
  /// In en, this message translates to:
  /// **'Forwarded'**
  String get forwarded;

  /// No description provided for @compressVideo.
  ///
  /// In en, this message translates to:
  /// **'Compress the video?'**
  String get compressVideo;

  /// No description provided for @compressVideoBody.
  ///
  /// In en, this message translates to:
  /// **'A compressed video is smaller and quicker to send, at a lower quality.'**
  String get compressVideoBody;

  /// No description provided for @compressVideoMust.
  ///
  /// In en, this message translates to:
  /// **'This video is over 100 MB, the most Siegel can send. Compress it to send it.'**
  String get compressVideoMust;

  /// No description provided for @sendOriginal.
  ///
  /// In en, this message translates to:
  /// **'Send original'**
  String get sendOriginal;

  /// No description provided for @compress.
  ///
  /// In en, this message translates to:
  /// **'Compress'**
  String get compress;

  /// No description provided for @autoDownload.
  ///
  /// In en, this message translates to:
  /// **'Auto-download'**
  String get autoDownload;

  /// No description provided for @autoDownloadHelp.
  ///
  /// In en, this message translates to:
  /// **'What downloads by itself when it arrives. Voice messages download when you play them.'**
  String get autoDownloadHelp;

  /// No description provided for @onWifi.
  ///
  /// In en, this message translates to:
  /// **'On Wi-Fi'**
  String get onWifi;

  /// No description provided for @onMobile.
  ///
  /// In en, this message translates to:
  /// **'On mobile data'**
  String get onMobile;

  /// No description provided for @photos.
  ///
  /// In en, this message translates to:
  /// **'Photos'**
  String get photos;

  /// No description provided for @videos.
  ///
  /// In en, this message translates to:
  /// **'Videos'**
  String get videos;

  /// No description provided for @files.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get files;

  /// No description provided for @none.
  ///
  /// In en, this message translates to:
  /// **'Nothing'**
  String get none;

  /// No description provided for @errAttachmentInvalid.
  ///
  /// In en, this message translates to:
  /// **'That file can\'t be sent.'**
  String get errAttachmentInvalid;

  /// No description provided for @findContacts.
  ///
  /// In en, this message translates to:
  /// **'Find contacts'**
  String get findContacts;

  /// No description provided for @findContactsIntro.
  ///
  /// In en, this message translates to:
  /// **'See which people in your phone\'s contacts use Siegel and turned on \"Let people who have my number find me\". Their numbers are checked in a way that hides them from the server, and nothing from your contacts is stored there.'**
  String get findContactsIntro;

  /// No description provided for @checkContacts.
  ///
  /// In en, this message translates to:
  /// **'Check my contacts'**
  String get checkContacts;

  /// No description provided for @contactsDenied.
  ///
  /// In en, this message translates to:
  /// **'Siegel can\'t read your contacts. You can allow it in your phone\'s settings.'**
  String get contactsDenied;

  /// No description provided for @noContactsFound.
  ///
  /// In en, this message translates to:
  /// **'None of your contacts can be found yet. People show up here once they turn on \"Let people who have my number find me\".'**
  String get noContactsFound;

  /// No description provided for @discoverable.
  ///
  /// In en, this message translates to:
  /// **'Let people who have my number find me'**
  String get discoverable;

  /// No description provided for @discoverableHelp.
  ///
  /// In en, this message translates to:
  /// **'People with your number in their contacts can see your @username. Your number isn\'t shown to anyone.'**
  String get discoverableHelp;

  /// No description provided for @myNumberTitle.
  ///
  /// In en, this message translates to:
  /// **'Your phone number'**
  String get myNumberTitle;

  /// No description provided for @myNumberHelp.
  ///
  /// In en, this message translates to:
  /// **'The number you registered with'**
  String get myNumberHelp;

  /// No description provided for @errPhoneMismatch.
  ///
  /// In en, this message translates to:
  /// **'That isn\'t the number this account was registered with.'**
  String get errPhoneMismatch;

  /// No description provided for @sourceCode.
  ///
  /// In en, this message translates to:
  /// **'Source code'**
  String get sourceCode;

  /// No description provided for @sourceCodeHelp.
  ///
  /// In en, this message translates to:
  /// **'Siegel is free software (AGPL-3.0)'**
  String get sourceCodeHelp;

  /// No description provided for @changeNumber.
  ///
  /// In en, this message translates to:
  /// **'Change number'**
  String get changeNumber;

  /// No description provided for @changeNumberHelp.
  ///
  /// In en, this message translates to:
  /// **'Your chats, groups, contacts and @username stay as they are. Nobody is told your new number.'**
  String get changeNumberHelp;

  /// No description provided for @newNumber.
  ///
  /// In en, this message translates to:
  /// **'New phone number'**
  String get newNumber;

  /// No description provided for @numberChanged.
  ///
  /// In en, this message translates to:
  /// **'Your number is now {number}.'**
  String numberChanged(String number);

  /// No description provided for @noNumber.
  ///
  /// In en, this message translates to:
  /// **'No phone number: add one so you can recover your account'**
  String get noNumber;

  /// No description provided for @numberRemovedTitle.
  ///
  /// In en, this message translates to:
  /// **'Your number moved to another account'**
  String get numberRemovedTitle;

  /// No description provided for @numberRemovedBody.
  ///
  /// In en, this message translates to:
  /// **'Your number was verified on another Siegel account. Your account still works; add a number in Settings so you can recover it later.'**
  String get numberRemovedBody;

  /// No description provided for @errNumberChangeTooSoon.
  ///
  /// In en, this message translates to:
  /// **'You can change your number once every 7 days.'**
  String get errNumberChangeTooSoon;

  /// No description provided for @errNumberSame.
  ///
  /// In en, this message translates to:
  /// **'That\'s already your number.'**
  String get errNumberSame;

  /// No description provided for @skTitle.
  ///
  /// In en, this message translates to:
  /// **'What Siegel knows about me'**
  String get skTitle;

  /// No description provided for @skHelp.
  ///
  /// In en, this message translates to:
  /// **'Everything the server holds about your account'**
  String get skHelp;

  /// No description provided for @skIntro.
  ///
  /// In en, this message translates to:
  /// **'This is everything Siegel\'s server holds about your account, fetched just now. It can\'t read your messages, your contacts or your profile.'**
  String get skIntro;

  /// No description provided for @skAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get skAccount;

  /// No description provided for @skCreated.
  ///
  /// In en, this message translates to:
  /// **'Account created'**
  String get skCreated;

  /// No description provided for @skPhone.
  ///
  /// In en, this message translates to:
  /// **'Phone number'**
  String get skPhone;

  /// No description provided for @skPhoneHash.
  ///
  /// In en, this message translates to:
  /// **'Kept only as a code that can\'t be turned back into your number: {hash}'**
  String skPhoneHash(String hash);

  /// No description provided for @skNumberChanged.
  ///
  /// In en, this message translates to:
  /// **'Number last changed'**
  String get skNumberChanged;

  /// No description provided for @skUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get skUsername;

  /// No description provided for @skUsernameSince.
  ///
  /// In en, this message translates to:
  /// **'@{username}, since {day}'**
  String skUsernameSince(String username, String day);

  /// No description provided for @skReleased.
  ///
  /// In en, this message translates to:
  /// **'Old usernames you can still take back'**
  String get skReleased;

  /// No description provided for @skIdentityKey.
  ///
  /// In en, this message translates to:
  /// **'Identity key'**
  String get skIdentityKey;

  /// No description provided for @skIdentityKeyHelp.
  ///
  /// In en, this message translates to:
  /// **'Public. Others use it to check that messages really come from you: {key}'**
  String skIdentityKeyHelp(String key);

  /// No description provided for @skOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get skOn;

  /// No description provided for @skOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get skOff;

  /// No description provided for @skProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get skProfile;

  /// No description provided for @skProfileStored.
  ///
  /// In en, this message translates to:
  /// **'Your name and about, encrypted. Only people you chat with can read them.'**
  String get skProfileStored;

  /// No description provided for @skProfilePicture.
  ///
  /// In en, this message translates to:
  /// **'Profile picture'**
  String get skProfilePicture;

  /// No description provided for @skPictureStored.
  ///
  /// In en, this message translates to:
  /// **'Encrypted. Only people you chat with can see it.'**
  String get skPictureStored;

  /// No description provided for @skChecked.
  ///
  /// In en, this message translates to:
  /// **'Contact numbers checked recently'**
  String get skChecked;

  /// No description provided for @skCheckedCount.
  ///
  /// In en, this message translates to:
  /// **'{count}. Only how many, never which ones.'**
  String skCheckedCount(int count);

  /// No description provided for @skDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get skDevices;

  /// No description provided for @skThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This phone'**
  String get skThisDevice;

  /// No description provided for @skOtherDevice.
  ///
  /// In en, this message translates to:
  /// **'Another device'**
  String get skOtherDevice;

  /// No description provided for @skLastSeen.
  ///
  /// In en, this message translates to:
  /// **'{platform}, last connected {day}'**
  String skLastSeen(String platform, String day);

  /// No description provided for @skQueued.
  ///
  /// In en, this message translates to:
  /// **'Encrypted messages waiting: {count}'**
  String skQueued(int count);

  /// No description provided for @skKeys.
  ///
  /// In en, this message translates to:
  /// **'Keys for starting chats: {count}'**
  String skKeys(int count);

  /// No description provided for @skPushYes.
  ///
  /// In en, this message translates to:
  /// **'Notification token: stored'**
  String get skPushYes;

  /// No description provided for @skPushNo.
  ///
  /// In en, this message translates to:
  /// **'Notification token: none'**
  String get skPushNo;

  /// No description provided for @skCopyJson.
  ///
  /// In en, this message translates to:
  /// **'Copy as JSON'**
  String get skCopyJson;

  /// No description provided for @unreadCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 unread message} other{{count} unread messages}}'**
  String unreadCount(int count);

  /// No description provided for @messageOptions.
  ///
  /// In en, this message translates to:
  /// **'Message options'**
  String get messageOptions;

  /// No description provided for @themeKraehe.
  ///
  /// In en, this message translates to:
  /// **'Crow. Midnight blue into black.'**
  String get themeKraehe;

  /// No description provided for @chatBackground.
  ///
  /// In en, this message translates to:
  /// **'Chat background'**
  String get chatBackground;

  /// No description provided for @backgroundPattern.
  ///
  /// In en, this message translates to:
  /// **'The theme\'s pattern'**
  String get backgroundPattern;

  /// No description provided for @backgroundPlain.
  ///
  /// In en, this message translates to:
  /// **'Plain'**
  String get backgroundPlain;

  /// No description provided for @backgroundPhoto.
  ///
  /// In en, this message translates to:
  /// **'My photo'**
  String get backgroundPhoto;

  /// No description provided for @archive.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get archive;

  /// No description provided for @unarchive.
  ///
  /// In en, this message translates to:
  /// **'Unarchive'**
  String get unarchive;

  /// No description provided for @archived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get archived;

  /// No description provided for @noArchived.
  ///
  /// In en, this message translates to:
  /// **'No archived chats.'**
  String get noArchived;

  /// No description provided for @unreadChats.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 chat with unread messages} other{{count} chats with unread messages}}'**
  String unreadChats(int count);

  /// No description provided for @deleteChat.
  ///
  /// In en, this message translates to:
  /// **'Delete chat'**
  String get deleteChat;

  /// No description provided for @deleteChatTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete the chat with {name}?'**
  String deleteChatTitle(String name);

  /// No description provided for @deleteChatBody.
  ///
  /// In en, this message translates to:
  /// **'Its messages are deleted from this phone. If they write again, the chat comes back.'**
  String get deleteChatBody;

  /// No description provided for @leaveAndDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave {name} and delete the chat?'**
  String leaveAndDeleteTitle(String name);

  /// No description provided for @leaveAndDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'Members see that you left. The messages are deleted from this phone.'**
  String get leaveAndDeleteBody;

  /// No description provided for @moreReactions.
  ///
  /// In en, this message translates to:
  /// **'More reactions'**
  String get moreReactions;

  /// No description provided for @sticker.
  ///
  /// In en, this message translates to:
  /// **'Sticker'**
  String get sticker;

  /// No description provided for @stickers.
  ///
  /// In en, this message translates to:
  /// **'Stickers'**
  String get stickers;

  /// No description provided for @myStickers.
  ///
  /// In en, this message translates to:
  /// **'Mine'**
  String get myStickers;

  /// No description provided for @noStickers.
  ///
  /// In en, this message translates to:
  /// **'Make one from a photo, or long-press a sticker in a chat and add it here.'**
  String get noStickers;

  /// No description provided for @stickerFromPhoto.
  ///
  /// In en, this message translates to:
  /// **'From a photo'**
  String get stickerFromPhoto;

  /// No description provided for @importStickerPack.
  ///
  /// In en, this message translates to:
  /// **'Import pack'**
  String get importStickerPack;

  /// No description provided for @removeStickerPack.
  ///
  /// In en, this message translates to:
  /// **'Remove the pack {pack}'**
  String removeStickerPack(String pack);

  /// No description provided for @removeSticker.
  ///
  /// In en, this message translates to:
  /// **'Remove this sticker?'**
  String get removeSticker;

  /// No description provided for @addToMyStickers.
  ///
  /// In en, this message translates to:
  /// **'Add to my stickers'**
  String get addToMyStickers;

  /// No description provided for @stickerAdded.
  ///
  /// In en, this message translates to:
  /// **'Added to your stickers.'**
  String get stickerAdded;

  /// No description provided for @errStickerInvalid.
  ///
  /// In en, this message translates to:
  /// **'That can\'t be a sticker: WebP or PNG, up to 1 MB.'**
  String get errStickerInvalid;

  /// No description provided for @termsAndGuidelines.
  ///
  /// In en, this message translates to:
  /// **'Terms and community guidelines'**
  String get termsAndGuidelines;

  /// No description provided for @privacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy policy'**
  String get privacyPolicy;

  /// No description provided for @terms.
  ///
  /// In en, this message translates to:
  /// **'Terms'**
  String get terms;

  /// No description provided for @guidelines.
  ///
  /// In en, this message translates to:
  /// **'Guidelines'**
  String get guidelines;

  /// No description provided for @agreeToTerms.
  ///
  /// In en, this message translates to:
  /// **'By continuing you accept our'**
  String get agreeToTerms;

  /// No description provided for @birthMonth.
  ///
  /// In en, this message translates to:
  /// **'Birth month'**
  String get birthMonth;

  /// No description provided for @birthYear.
  ///
  /// In en, this message translates to:
  /// **'Birth year'**
  String get birthYear;

  /// No description provided for @birthTitle.
  ///
  /// In en, this message translates to:
  /// **'When were you born?'**
  String get birthTitle;

  /// No description provided for @birthWhy.
  ///
  /// In en, this message translates to:
  /// **'Siegel protects people under 18: strangers can\'t find them by @username, and only their contacts can add them to groups. Your birth date stays on this phone; we only learn whether you\'re under 18.'**
  String get birthWhy;

  /// No description provided for @tooYoung.
  ///
  /// In en, this message translates to:
  /// **'Siegel is for people aged {age} and over.'**
  String tooYoung(int age);

  /// No description provided for @groupAddsMinor.
  ///
  /// In en, this message translates to:
  /// **'Contacts only: you\'re under 18.'**
  String get groupAddsMinor;

  /// No description provided for @skMinor.
  ///
  /// In en, this message translates to:
  /// **'Under 18'**
  String get skMinor;

  /// No description provided for @yes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get yes;

  /// No description provided for @no.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get no;

  /// No description provided for @tapToView.
  ///
  /// In en, this message translates to:
  /// **'From someone you haven\'t accepted. Tap to view.'**
  String get tapToView;
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
      <String>['de', 'en', 'es', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'pt':
      return AppLocalizationsPt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
