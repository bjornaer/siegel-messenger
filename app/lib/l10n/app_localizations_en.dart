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

  @override
  String get errAttestation =>
      'This copy of Siegel couldn\'t be verified. Install it from Google Play and try again.';

  @override
  String get theme => 'Theme';

  @override
  String get selected => 'Selected';

  @override
  String get themeSiegel => 'Seal. The green of our logo.';

  @override
  String get themeDrache => 'Dragon. Deep red, a little fierce.';

  @override
  String get themeLoewe => 'Lion. Old gold, like a coat of arms.';

  @override
  String get themeLindwurm =>
      'The serpent dragon of Alpine legend. Teal and scales.';

  @override
  String get themeSchnee => 'Snow. Quiet, pale blue.';

  @override
  String get themeKrampus => 'The Alpine winter demon. Ember orange.';

  @override
  String get themeNordlicht => 'Northern lights. Violet with a shimmer.';

  @override
  String get themeFernweh => 'The longing for faraway places. Open-sea blue.';

  @override
  String get mute => 'Mute notifications';

  @override
  String get messageInfo => 'Message info';

  @override
  String sentAt(String when) {
    return 'Sent $when';
  }

  @override
  String get newGroup => 'New group';

  @override
  String get groupName => 'Group name';

  @override
  String get group => 'Group';

  @override
  String get addPeople => 'Add people';

  @override
  String get addPeopleHint => '@username, then Add';

  @override
  String get add => 'Add';

  @override
  String get create => 'Create';

  @override
  String membersCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count members',
      one: '1 member',
    );
    return '$_temp0';
  }

  @override
  String get groupInfo => 'Group info';

  @override
  String get admin => 'Admin';

  @override
  String get makeAdmin => 'Make admin';

  @override
  String get removeAdmin => 'Remove as admin';

  @override
  String get removeFromGroup => 'Remove from group';

  @override
  String get leaveGroup => 'Leave group';

  @override
  String get leaveGroupBody =>
      'You won\'t get new messages from this group. The chat stays on this phone.';

  @override
  String get leftGroup => 'You\'re no longer in this group.';

  @override
  String get onlyAdminsEditInfo =>
      'Only admins can edit the group name and photo';

  @override
  String get onlyAdminsAdd => 'Only admins can add members';

  @override
  String get rename => 'Rename';

  @override
  String isTyping(String name) {
    return '$name is typing…';
  }

  @override
  String get someone => 'Someone';

  @override
  String evCreated(String actor) {
    return '$actor created the group';
  }

  @override
  String evAdded(String actor, String targets) {
    return '$actor added $targets';
  }

  @override
  String evRemoved(String actor, String targets) {
    return '$actor removed $targets';
  }

  @override
  String evLeft(String actor) {
    return '$actor left';
  }

  @override
  String evRenamed(String actor, String targets) {
    return '$actor renamed the group to $targets';
  }

  @override
  String evAdminAdded(String actor, String targets) {
    return '$actor made $targets an admin';
  }

  @override
  String evAdminRemoved(String actor, String targets) {
    return '$actor removed $targets as admin';
  }

  @override
  String evSettings(String actor) {
    return '$actor changed the group settings';
  }

  @override
  String get inviteBanner =>
      'You were added to this group by someone who isn\'t in your contacts. Members won\'t see your name until you accept.';

  @override
  String get decline => 'Decline';

  @override
  String get groupAdds => 'Who can add me to groups';

  @override
  String get groupAddsEveryone => 'Everyone';

  @override
  String get groupAddsContacts => 'My contacts';

  @override
  String get groupAddsHelp =>
      'Anyone else sends you an invite to accept or decline.';

  @override
  String get muteFor8h => 'For 8 hours';

  @override
  String get muteFor1w => 'For 1 week';

  @override
  String get muteAlways => 'Always';

  @override
  String get unmute => 'Unmute';

  @override
  String mutedUntil(String when) {
    return 'Muted until $when';
  }

  @override
  String get muted => 'Muted';

  @override
  String get errGroupLeft => 'You\'re no longer in this group.';

  @override
  String get errGroupTooLarge => 'Groups can have up to 256 members.';

  @override
  String get errNameInvalid => 'Group names have 1 to 64 characters.';

  @override
  String get editProfile => 'Edit profile';

  @override
  String get orStartChat => 'Or start a chat with someone\'s @username';

  @override
  String get errPeerOutdated =>
      'Someone you added has an old version of Siegel. They need to update before joining a group.';

  @override
  String get resendCode => 'Resend code';

  @override
  String resendIn(String time) {
    return 'Resend code in $time';
  }

  @override
  String get codeResent => 'Code sent again.';

  @override
  String get errResendTooSoon =>
      'Please wait a little before asking for another code.';

  @override
  String get updateAvailable => 'A new version of Siegel is available.';

  @override
  String get update => 'Update';

  @override
  String get later => 'Later';

  @override
  String get updateRequired =>
      'This version of Siegel is no longer supported. Update to keep using it.';

  @override
  String get myLink => 'My link';

  @override
  String get myLinkSubtitle =>
      'People who open it chat with you straight away, no request.';

  @override
  String get myLinkHelp =>
      'Anyone with this link or code can start a chat with you, without a message request. Scanning it in person also verifies you.';

  @override
  String get showLink => 'Show code';

  @override
  String get share => 'Share';

  @override
  String get resetLink => 'Reset link';

  @override
  String get resetLinkBody =>
      'Your old link and code stop skipping the message request. Share the new one with people you want to hear from.';

  @override
  String get scanQr => 'Scan a QR code';

  @override
  String get errLinkInvalid => 'That isn\'t a Siegel link.';

  @override
  String get errLinkKeyMismatch =>
      'This link doesn\'t match this person\'s key. Don\'t trust this chat; ask them for a new link.';

  @override
  String joinGroupTitle(String name) {
    return 'Join $name?';
  }

  @override
  String get join => 'Join';

  @override
  String get inviteLinks => 'Invite links';

  @override
  String get newInviteLink => 'Create invite link';

  @override
  String get inviteLinkHelp =>
      'Anyone with this link or code can join the group straight away, for one week. You can remove people afterwards, or revoke the link.';

  @override
  String expiresOn(String when) {
    return 'Expires $when';
  }

  @override
  String get revoke => 'Revoke';

  @override
  String get errLinkStale =>
      'The group just changed. Try the link again in a moment.';

  @override
  String get errInviteNotFound => 'This link has expired or was revoked.';

  @override
  String get errAlreadyMember => 'You\'re already in this group.';

  @override
  String get voiceMessage => 'Voice message';

  @override
  String get recordVoice => 'Record a voice message';

  @override
  String get recording => 'Recording';

  @override
  String get attachAudio => 'Send an audio file';

  @override
  String get micDenied =>
      'Siegel needs the microphone to record voice messages. You can allow it in the system settings.';

  @override
  String get play => 'Play';

  @override
  String get pause => 'Pause';

  @override
  String get errAttachmentExpired =>
      'This attachment is no longer on the server. Ask the sender to send it again.';

  @override
  String get errAttachmentCorrupt =>
      'This attachment was damaged on the way and can\'t be opened.';

  @override
  String get errAttachmentTooLarge => 'Files can be up to 100 MB.';

  @override
  String get errUploadFailed => 'The upload didn\'t finish. Try again.';

  @override
  String get profilePhoto => 'Profile photo';

  @override
  String get choosePhoto => 'Choose a photo';

  @override
  String get removePhoto => 'Remove photo';

  @override
  String get errAvatarInvalid =>
      'That picture can\'t be used. Try another one.';

  @override
  String evAvatar(String actor) {
    return '$actor changed the group photo';
  }

  @override
  String get themeEdelweiss =>
      'Edelweiss, the Alpine star flower. Snow white into silver.';

  @override
  String get photo => 'Photo';

  @override
  String get video => 'Video';

  @override
  String get file => 'File';

  @override
  String get attach => 'Attach';

  @override
  String get download => 'Download';

  @override
  String get saveToDevice => 'Save to device';

  @override
  String get forward => 'Forward';

  @override
  String get forwardTo => 'Forward to…';

  @override
  String get forwarded => 'Forwarded';

  @override
  String get compressVideo => 'Compress the video?';

  @override
  String get compressVideoBody =>
      'A compressed video is smaller and quicker to send, at a lower quality.';

  @override
  String get compressVideoMust =>
      'This video is over 100 MB, the most Siegel can send. Compress it to send it.';

  @override
  String get sendOriginal => 'Send original';

  @override
  String get compress => 'Compress';

  @override
  String get autoDownload => 'Auto-download';

  @override
  String get autoDownloadHelp =>
      'What downloads by itself when it arrives. Voice messages download when you play them.';

  @override
  String get onWifi => 'On Wi-Fi';

  @override
  String get onMobile => 'On mobile data';

  @override
  String get photos => 'Photos';

  @override
  String get videos => 'Videos';

  @override
  String get files => 'Files';

  @override
  String get none => 'Nothing';

  @override
  String get errAttachmentInvalid => 'That file can\'t be sent.';

  @override
  String get findContacts => 'Find contacts';

  @override
  String get findContactsIntro =>
      'See which people in your phone\'s contacts use Siegel and turned on \"Let people who have my number find me\". Their numbers are checked in a way that hides them from the server, and nothing from your contacts is stored there.';

  @override
  String get checkContacts => 'Check my contacts';

  @override
  String get contactsDenied =>
      'Siegel can\'t read your contacts. You can allow it in your phone\'s settings.';

  @override
  String get noContactsFound =>
      'None of your contacts can be found yet. People show up here once they turn on \"Let people who have my number find me\".';

  @override
  String get discoverable => 'Let people who have my number find me';

  @override
  String get discoverableHelp =>
      'People with your number in their contacts can see your @username. Your number isn\'t shown to anyone.';

  @override
  String get myNumberTitle => 'Your phone number';

  @override
  String get myNumberHelp => 'The number you registered with';

  @override
  String get errPhoneMismatch =>
      'That isn\'t the number this account was registered with.';

  @override
  String get sourceCode => 'Source code';

  @override
  String get sourceCodeHelp => 'Siegel is free software (AGPL-3.0)';

  @override
  String get changeNumber => 'Change number';

  @override
  String get changeNumberHelp =>
      'Your chats, groups, contacts and @username stay as they are. Nobody is told your new number.';

  @override
  String get newNumber => 'New phone number';

  @override
  String numberChanged(String number) {
    return 'Your number is now $number.';
  }

  @override
  String get noNumber =>
      'No phone number: add one so you can recover your account';

  @override
  String get numberRemovedTitle => 'Your number moved to another account';

  @override
  String get numberRemovedBody =>
      'Your number was verified on another Siegel account. Your account still works; add a number in Settings so you can recover it later.';

  @override
  String get errNumberChangeTooSoon =>
      'You can change your number once every 7 days.';

  @override
  String get errNumberSame => 'That\'s already your number.';

  @override
  String get skTitle => 'What Siegel knows about me';

  @override
  String get skHelp => 'Everything the server holds about your account';

  @override
  String get skIntro =>
      'This is everything Siegel\'s server holds about your account, fetched just now. It can\'t read your messages, your contacts or your profile.';

  @override
  String get skAccount => 'Account';

  @override
  String get skCreated => 'Account created';

  @override
  String get skPhone => 'Phone number';

  @override
  String skPhoneHash(String hash) {
    return 'Kept only as a code that can\'t be turned back into your number: $hash';
  }

  @override
  String get skNumberChanged => 'Number last changed';

  @override
  String get skUsername => 'Username';

  @override
  String skUsernameSince(String username, String day) {
    return '@$username, since $day';
  }

  @override
  String get skReleased => 'Old usernames you can still take back';

  @override
  String get skIdentityKey => 'Identity key';

  @override
  String skIdentityKeyHelp(String key) {
    return 'Public. Others use it to check that messages really come from you: $key';
  }

  @override
  String get skOn => 'On';

  @override
  String get skOff => 'Off';

  @override
  String get skProfile => 'Profile';

  @override
  String get skProfileStored =>
      'Your name and about, encrypted. Only people you chat with can read them.';

  @override
  String get skProfilePicture => 'Profile picture';

  @override
  String get skPictureStored =>
      'Encrypted. Only people you chat with can see it.';

  @override
  String get skChecked => 'Contact numbers checked recently';

  @override
  String skCheckedCount(int count) {
    return '$count. Only how many, never which ones.';
  }

  @override
  String get skDevices => 'Devices';

  @override
  String get skThisDevice => 'This phone';

  @override
  String get skOtherDevice => 'Another device';

  @override
  String skLastSeen(String platform, String day) {
    return '$platform, last connected $day';
  }

  @override
  String skQueued(int count) {
    return 'Encrypted messages waiting: $count';
  }

  @override
  String skKeys(int count) {
    return 'Keys for starting chats: $count';
  }

  @override
  String get skPushYes => 'Notification token: stored';

  @override
  String get skPushNo => 'Notification token: none';

  @override
  String get skCopyJson => 'Copy as JSON';

  @override
  String unreadCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count unread messages',
      one: '1 unread message',
    );
    return '$_temp0';
  }

  @override
  String get messageOptions => 'Message options';

  @override
  String get themeKraehe => 'Crow. Midnight blue into black.';
}
