// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get appTitle => 'Siegel';

  @override
  String get continueButton => 'Weiter';

  @override
  String get welcomeTitle => 'Willkommen bei Siegel';

  @override
  String get historyNotice =>
      'Deine Nachrichten werden nur auf diesem Telefon gespeichert. Wenn du es verlierst, zurücksetzt oder die App löschst, ist dein Chatverlauf für immer weg. Es gibt keine Backups.';

  @override
  String get phoneTitle => 'Deine Telefonnummer';

  @override
  String get phoneHint => '+49 151 00000000';

  @override
  String ageConfirm(int age) {
    return 'Ich bin mindestens $age Jahre alt';
  }

  @override
  String get sendCode => 'Code senden';

  @override
  String codeTitle(String phone) {
    return 'Gib den 6-stelligen Code ein, der an $phone gesendet wurde';
  }

  @override
  String get codeLabel => 'Code';

  @override
  String get verify => 'Bestätigen';

  @override
  String get pinTitle => 'Registrierungssperre';

  @override
  String get pinHelp =>
      'Diese Nummer ist mit einer PIN geschützt. Gib sie ein, um fortzufahren.';

  @override
  String get pinLabel => '4-stellige PIN';

  @override
  String get profileTitle => 'Dein Profil';

  @override
  String get usernameLabel => '@Benutzername';

  @override
  String get usernameHelp =>
      '4 bis 32 Zeichen: a–z, 0–9, _ und . Beginnt mit einem Buchstaben. So finden dich andere.';

  @override
  String get displayNameLabel => 'Anzeigename';

  @override
  String get save => 'Speichern';

  @override
  String get lockOfferTitle => 'Schütze dein Konto mit einer PIN';

  @override
  String get lockOfferBody =>
      'Wenn jemand deine Telefonnummer übernimmt, braucht diese Person zusätzlich diese PIN, um sie zu registrieren. Vergiss sie nicht.';

  @override
  String get setPin => 'PIN festlegen';

  @override
  String get skip => 'Überspringen';

  @override
  String get skipWarningTitle => 'PIN überspringen?';

  @override
  String get skipWarningBody =>
      'Ohne PIN kann jeder, der deine Telefonnummer unter seine Kontrolle bringt (zum Beispiel per SIM-Tausch), dein Konto und deinen @Benutzernamen übernehmen.';

  @override
  String get skipAnyway => 'Trotzdem überspringen';

  @override
  String get cancel => 'Abbrechen';

  @override
  String homeRegistered(String username) {
    return 'Du bist @$username';
  }

  @override
  String get settings => 'Einstellungen';

  @override
  String get deleteAccount => 'Konto löschen';

  @override
  String get deleteConfirmTitle => 'Dein Konto löschen?';

  @override
  String get deleteConfirmBody =>
      'Dein Konto, dein @Benutzername und alle Daten auf unserem Server werden gelöscht, und dieses Telefon wird geleert. Das lässt sich nicht rückgängig machen.';

  @override
  String get delete => 'Löschen';

  @override
  String get errPhoneInvalid =>
      'Das sieht nicht nach einer gültigen Telefonnummer aus.';

  @override
  String get errRateLimited =>
      'Zu viele Versuche. Bitte warte und versuche es später erneut.';

  @override
  String get errOtpInvalid => 'Falscher oder abgelaufener Code.';

  @override
  String get errLockInvalid => 'Falsche PIN.';

  @override
  String get errLockLocked =>
      'Zu oft eine falsche PIN. Versuche es in 24 Stunden erneut.';

  @override
  String get errUsernameInvalid => 'Dieser Benutzername ist nicht erlaubt.';

  @override
  String get errUsernameTaken => 'Dieser Benutzername ist vergeben.';

  @override
  String get errUsernameTooSoon =>
      'Du kannst deinen Benutzernamen einmal alle 30 Tage ändern.';

  @override
  String get errPinInvalid => 'Die PIN muss genau 4 Ziffern haben.';

  @override
  String get errDisplayNameInvalid =>
      'Gib einen Namen mit 1 bis 64 Zeichen ein.';

  @override
  String get errNetwork =>
      'Der Server ist nicht erreichbar. Prüfe deine Verbindung.';

  @override
  String get errGeneric =>
      'Etwas ist schiefgelaufen. Bitte versuche es erneut.';

  @override
  String get appLock => 'App-Sperre';

  @override
  String get appLockSubtitle =>
      'Fingerabdruck, Gesicht oder Telefon-Code zum Öffnen von Siegel verlangen.';

  @override
  String get lockAfter => 'Sperren nach';

  @override
  String get lockImmediately => 'Sofort';

  @override
  String lockMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Minuten',
      one: '1 Minute',
    );
    return '$_temp0';
  }

  @override
  String lockHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Stunden',
      one: '1 Stunde',
    );
    return '$_temp0';
  }

  @override
  String get screenSecurity => 'Bildschirmschutz';

  @override
  String get screenSecuritySubtitle =>
      'Screenshots und Bildschirmaufnahmen von Siegel blockieren.';

  @override
  String get lockedTitle => 'Siegel ist gesperrt';

  @override
  String get unlock => 'Entsperren';

  @override
  String get unlockReason => 'Siegel entsperren';

  @override
  String get errNoDeviceLock =>
      'Wir konnten nicht bestätigen, dass du es bist. Richte zuerst eine Displaysperre auf deinem Telefon ein.';

  @override
  String get appLogo => 'Siegel-Logo';

  @override
  String get chatsTitle => 'Chats';

  @override
  String get newChat => 'Neuer Chat';

  @override
  String get noChats =>
      'Noch keine Chats. Starte einen mit dem @Benutzernamen von jemandem.';

  @override
  String get newContact => 'Neuer Kontakt';

  @override
  String get messageHint => 'Nachricht';

  @override
  String get send => 'Senden';

  @override
  String get startChat => 'Chat starten';

  @override
  String get errUsernameNotFound => 'Niemand hat diesen Benutzernamen.';

  @override
  String get errNoKeyPackages =>
      'Dieses Konto kann gerade keine Nachrichten empfangen. Versuche es später erneut.';

  @override
  String get errTextInvalid =>
      'Nachrichten können bis zu 64 KB Text enthalten.';

  @override
  String get messageRequests => 'Nachrichtenanfragen';

  @override
  String messageRequestsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Nachrichtenanfragen',
      one: '1 Nachrichtenanfrage',
    );
    return '$_temp0';
  }

  @override
  String get noRequests => 'Keine Nachrichtenanfragen.';

  @override
  String requestBanner(String name) {
    return '$name möchte mit dir chatten. Erst wenn du annimmst, sieht diese Person deinen Namen oder dass du das gelesen hast.';
  }

  @override
  String get accept => 'Annehmen';

  @override
  String get block => 'Blockieren';

  @override
  String blockConfirmTitle(String name) {
    return '$name blockieren?';
  }

  @override
  String get blockConfirmBody =>
      'Diese Person kann dir dann keine Nachrichten schicken und keine neuen Chats starten. Sie wird nicht benachrichtigt.';

  @override
  String get errRequestPending => 'Nimm die Anfrage an, bevor du antwortest.';

  @override
  String get reply => 'Antworten';

  @override
  String get copy => 'Kopieren';

  @override
  String get copied => 'Kopiert';

  @override
  String get edit => 'Bearbeiten';

  @override
  String get editing => 'Nachricht bearbeiten';

  @override
  String get edited => 'bearbeitet';

  @override
  String get editHistory => 'Bearbeitungsverlauf';

  @override
  String get deleteForMe => 'Für mich löschen';

  @override
  String get deleteForEveryone => 'Für alle löschen';

  @override
  String get deleteForEveryoneBody =>
      'Die Nachricht wird für alle in diesem Chat durch „Diese Nachricht wurde gelöscht“ ersetzt. Wer eine veränderte App nutzt, könnte trotzdem eine Kopie behalten.';

  @override
  String get messageDeleted => 'Diese Nachricht wurde gelöscht';

  @override
  String get originalMissing => 'Ursprüngliche Nachricht nicht verfügbar';

  @override
  String get you => 'Du';

  @override
  String get typing => 'schreibt…';

  @override
  String get notSentRetry =>
      'Nicht gesendet. Tippe, um es erneut zu versuchen.';

  @override
  String get statusSending => 'Wird gesendet';

  @override
  String get statusSent => 'Gesendet';

  @override
  String get statusDelivered => 'Zugestellt';

  @override
  String get statusRead => 'Gelesen';

  @override
  String get readReceipts => 'Lesebestätigungen';

  @override
  String get readReceiptsHelp =>
      'Wenn du sie ausschaltest, siehst du auch nicht, wann andere deine Nachrichten lesen.';

  @override
  String get typingIndicators => 'Tippanzeige';

  @override
  String get typingIndicatorsHelp =>
      'Wenn du sie ausschaltest, siehst du auch nicht, wann andere schreiben.';

  @override
  String get errNotAllowed => 'Das ist für diese Nachricht nicht mehr möglich.';

  @override
  String get close => 'Schließen';

  @override
  String get safetyNumber => 'Sicherheitsnummer';

  @override
  String safetyNumberHelp(String name) {
    return 'Vergleiche diese Nummern mit $name oder scanne den Code, wenn ihr zusammen seid. Stimmen sie überein, hängt niemand zwischen euch im Chat.';
  }

  @override
  String get safetyNumberUnavailable =>
      'Die Sicherheitsnummer ist noch nicht verfügbar.';

  @override
  String get scanCode => 'Code scannen';

  @override
  String get verified => 'Verifiziert';

  @override
  String get verifiedDone =>
      'Verifiziert. Die Sicherheitsnummer stimmt überein.';

  @override
  String verifyMismatch(String name) {
    return 'Dieser Code stimmt nicht überein. Achte darauf, den Code von $name für diesen Chat zu scannen.';
  }

  @override
  String keyChanged(String name) {
    return 'Die Sicherheitsnummer von $name hat sich geändert, zum Beispiel wegen einer Neuinstallation von Siegel oder eines neuen Telefons. Tippe zum Vergleichen.';
  }

  @override
  String get blockedPeople => 'Blockierte Personen';

  @override
  String get noBlocked => 'Du hast niemanden blockiert.';

  @override
  String get unblock => 'Blockierung aufheben';

  @override
  String get notificationChannel => 'Nachrichten';

  @override
  String get errAttestation =>
      'Diese Kopie von Siegel konnte nicht verifiziert werden. Installiere sie aus Google Play und versuche es erneut.';

  @override
  String get theme => 'Design';

  @override
  String get selected => 'Ausgewählt';

  @override
  String get themeSiegel => 'Das Grün unseres Logos.';

  @override
  String get themeDrache => 'Tiefrot, ein wenig wild.';

  @override
  String get themeLoewe => 'Altgold, wie ein Wappen.';

  @override
  String get themeLindwurm =>
      'Der Schlangendrache der Alpensagen. Türkis und Schuppen.';

  @override
  String get themeSchnee => 'Ruhiges, blasses Blau.';

  @override
  String get themeKrampus => 'Der Winterdämon der Alpen. Glutorange.';

  @override
  String get themeNordlicht => 'Violett mit Schimmer.';

  @override
  String get themeFernweh => 'Die Sehnsucht nach der Ferne. Hochseeblau.';

  @override
  String get mute => 'Benachrichtigungen stumm';

  @override
  String get messageInfo => 'Nachrichteninfo';

  @override
  String sentAt(String when) {
    return 'Gesendet $when';
  }

  @override
  String get newGroup => 'Neue Gruppe';

  @override
  String get groupName => 'Gruppenname';

  @override
  String get group => 'Gruppe';

  @override
  String get addPeople => 'Personen hinzufügen';

  @override
  String get addPeopleHint => '@Benutzername, dann Hinzufügen';

  @override
  String get add => 'Hinzufügen';

  @override
  String get create => 'Erstellen';

  @override
  String membersCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Mitglieder',
      one: '1 Mitglied',
    );
    return '$_temp0';
  }

  @override
  String get groupInfo => 'Gruppeninfo';

  @override
  String get admin => 'Admin';

  @override
  String get makeAdmin => 'Zum Admin machen';

  @override
  String get removeAdmin => 'Als Admin entfernen';

  @override
  String get removeFromGroup => 'Aus Gruppe entfernen';

  @override
  String get leaveGroup => 'Gruppe verlassen';

  @override
  String get leaveGroupBody =>
      'Du bekommst keine neuen Nachrichten aus dieser Gruppe. Der Chat bleibt auf diesem Telefon.';

  @override
  String get leftGroup => 'Du bist nicht mehr in dieser Gruppe.';

  @override
  String get onlyAdminsEditInfo =>
      'Nur Admins können Gruppenname und -bild ändern';

  @override
  String get onlyAdminsAdd => 'Nur Admins können Mitglieder hinzufügen';

  @override
  String get rename => 'Umbenennen';

  @override
  String isTyping(String name) {
    return '$name schreibt…';
  }

  @override
  String get someone => 'Jemand';

  @override
  String evCreated(String actor) {
    return '$actor hat die Gruppe erstellt';
  }

  @override
  String evAdded(String actor, String targets) {
    return '$actor hat $targets hinzugefügt';
  }

  @override
  String evRemoved(String actor, String targets) {
    return '$actor hat $targets entfernt';
  }

  @override
  String evLeft(String actor) {
    return '$actor hat die Gruppe verlassen';
  }

  @override
  String evRenamed(String actor, String targets) {
    return '$actor hat die Gruppe in $targets umbenannt';
  }

  @override
  String evAdminAdded(String actor, String targets) {
    return '$actor hat $targets zum Admin gemacht';
  }

  @override
  String evAdminRemoved(String actor, String targets) {
    return '$actor hat $targets als Admin entfernt';
  }

  @override
  String evSettings(String actor) {
    return '$actor hat die Gruppeneinstellungen geändert';
  }

  @override
  String get inviteBanner =>
      'Jemand, der nicht in deinen Kontakten ist, hat dich zu dieser Gruppe hinzugefügt. Die Mitglieder sehen deinen Namen erst, wenn du annimmst.';

  @override
  String get decline => 'Ablehnen';

  @override
  String get groupAdds => 'Wer mich zu Gruppen hinzufügen kann';

  @override
  String get groupAddsEveryone => 'Alle';

  @override
  String get groupAddsContacts => 'Meine Kontakte';

  @override
  String get groupAddsHelp =>
      'Alle anderen schicken dir eine Einladung zum Annehmen oder Ablehnen.';

  @override
  String get muteFor8h => 'Für 8 Stunden';

  @override
  String get muteFor1w => 'Für 1 Woche';

  @override
  String get muteAlways => 'Immer';

  @override
  String get unmute => 'Stummschaltung aufheben';

  @override
  String mutedUntil(String when) {
    return 'Stumm bis $when';
  }

  @override
  String get muted => 'Stumm';

  @override
  String get errGroupLeft => 'Du bist nicht mehr in dieser Gruppe.';

  @override
  String get errGroupTooLarge => 'Gruppen können bis zu 256 Mitglieder haben.';

  @override
  String get errNameInvalid => 'Gruppennamen haben 1 bis 64 Zeichen.';

  @override
  String get editProfile => 'Profil bearbeiten';

  @override
  String get orStartChat =>
      'Oder starte einen Chat mit dem @Benutzernamen von jemandem';

  @override
  String get errPeerOutdated =>
      'Jemand, den du hinzugefügt hast, nutzt eine alte Version von Siegel. Erst nach einem Update ist ein Gruppenbeitritt möglich.';

  @override
  String get resendCode => 'Code erneut senden';

  @override
  String resendIn(String time) {
    return 'Code erneut senden in $time';
  }

  @override
  String get codeResent => 'Code erneut gesendet.';

  @override
  String get errResendTooSoon =>
      'Bitte warte kurz, bevor du einen neuen Code anforderst.';

  @override
  String get updateAvailable => 'Eine neue Version von Siegel ist verfügbar.';

  @override
  String get update => 'Aktualisieren';

  @override
  String get later => 'Später';

  @override
  String get updateRequired =>
      'Diese Version von Siegel wird nicht mehr unterstützt. Aktualisiere sie, um Siegel weiter zu nutzen.';

  @override
  String get myLink => 'Mein Link';

  @override
  String get myLinkSubtitle =>
      'Wer ihn öffnet, chattet direkt mit dir, ohne Anfrage.';

  @override
  String get myLinkHelp =>
      'Jeder mit diesem Link oder Code kann ohne Nachrichtenanfrage einen Chat mit dir starten. Persönlich gescannt, verifiziert er dich auch.';

  @override
  String get showLink => 'Code zeigen';

  @override
  String get share => 'Teilen';

  @override
  String get resetLink => 'Link zurücksetzen';

  @override
  String get resetLinkBody =>
      'Dein alter Link und Code überspringen die Nachrichtenanfrage nicht mehr. Teile den neuen mit allen, von denen du hören möchtest.';

  @override
  String get scanQr => 'QR-Code scannen';

  @override
  String get errLinkInvalid => 'Das ist kein Siegel-Link.';

  @override
  String get errLinkKeyMismatch =>
      'Dieser Link passt nicht zum Schlüssel dieser Person. Vertraue diesem Chat nicht und bitte um einen neuen Link.';

  @override
  String joinGroupTitle(String name) {
    return '$name beitreten?';
  }

  @override
  String get join => 'Beitreten';

  @override
  String get inviteLinks => 'Einladungslinks';

  @override
  String get newInviteLink => 'Einladungslink erstellen';

  @override
  String get inviteLinkHelp =>
      'Jeder mit diesem Link oder Code kann der Gruppe eine Woche lang direkt beitreten. Du kannst Personen danach entfernen oder den Link widerrufen.';

  @override
  String expiresOn(String when) {
    return 'Läuft ab $when';
  }

  @override
  String get revoke => 'Widerrufen';

  @override
  String get errLinkStale =>
      'Die Gruppe hat sich gerade geändert. Versuche den Link gleich noch einmal.';

  @override
  String get errInviteNotFound =>
      'Dieser Link ist abgelaufen oder wurde widerrufen.';

  @override
  String get errAlreadyMember => 'Du bist schon in dieser Gruppe.';

  @override
  String get voiceMessage => 'Sprachnachricht';

  @override
  String get recordVoice => 'Sprachnachricht aufnehmen';

  @override
  String get recording => 'Aufnahme';

  @override
  String get attachAudio => 'Audiodatei senden';

  @override
  String get micDenied =>
      'Siegel braucht das Mikrofon, um Sprachnachrichten aufzunehmen. Du kannst es in den Systemeinstellungen erlauben.';

  @override
  String get play => 'Abspielen';

  @override
  String get pause => 'Pause';

  @override
  String get errAttachmentExpired =>
      'Dieser Anhang ist nicht mehr auf dem Server. Bitte die Person, ihn noch einmal zu senden.';

  @override
  String get errAttachmentCorrupt =>
      'Dieser Anhang wurde unterwegs beschädigt und lässt sich nicht öffnen.';

  @override
  String get errAttachmentTooLarge => 'Dateien können bis zu 100 MB groß sein.';

  @override
  String get errUploadFailed =>
      'Der Upload wurde nicht abgeschlossen. Versuche es erneut.';

  @override
  String get profilePhoto => 'Profilbild';

  @override
  String get choosePhoto => 'Foto auswählen';

  @override
  String get removePhoto => 'Foto entfernen';

  @override
  String get errAvatarInvalid =>
      'Dieses Bild lässt sich nicht verwenden. Versuche ein anderes.';

  @override
  String evAvatar(String actor) {
    return '$actor hat das Gruppenbild geändert';
  }

  @override
  String get themeEdelweiss => 'Der Alpenstern. Schneeweiß bis Silber.';

  @override
  String get photo => 'Foto';

  @override
  String get video => 'Video';

  @override
  String get file => 'Datei';

  @override
  String get attach => 'Anhängen';

  @override
  String get download => 'Herunterladen';

  @override
  String get saveToDevice => 'Auf dem Gerät speichern';

  @override
  String get forward => 'Weiterleiten';

  @override
  String get forwardTo => 'Weiterleiten an…';

  @override
  String get forwarded => 'Weitergeleitet';

  @override
  String get compressVideo => 'Video komprimieren?';

  @override
  String get compressVideoBody =>
      'Ein komprimiertes Video ist kleiner und schneller gesendet, aber in geringerer Qualität.';

  @override
  String get compressVideoMust =>
      'Dieses Video ist größer als 100 MB, das Maximum für Siegel. Komprimiere es, um es zu senden.';

  @override
  String get sendOriginal => 'Original senden';

  @override
  String get compress => 'Komprimieren';

  @override
  String get autoDownload => 'Automatischer Download';

  @override
  String get autoDownloadHelp =>
      'Was beim Empfang von selbst heruntergeladen wird. Sprachnachrichten laden beim Abspielen.';

  @override
  String get onWifi => 'Im WLAN';

  @override
  String get onMobile => 'Mit mobilen Daten';

  @override
  String get photos => 'Fotos';

  @override
  String get videos => 'Videos';

  @override
  String get files => 'Dateien';

  @override
  String get none => 'Nichts';

  @override
  String get errAttachmentInvalid => 'Diese Datei lässt sich nicht senden.';

  @override
  String get findContacts => 'Kontakte finden';

  @override
  String get findContactsIntro =>
      'Sieh, wer aus deinen Telefonkontakten Siegel nutzt und \"Über meine Nummer finden lassen\" eingeschaltet hat. Die Nummern werden so geprüft, dass der Server sie nicht sieht, und von deinen Kontakten wird dort nichts gespeichert.';

  @override
  String get checkContacts => 'Meine Kontakte prüfen';

  @override
  String get contactsDenied =>
      'Siegel kann deine Kontakte nicht lesen. Du kannst es in den Einstellungen deines Telefons erlauben.';

  @override
  String get noContactsFound =>
      'Noch kann keiner deiner Kontakte gefunden werden. Sie erscheinen hier, sobald sie \"Über meine Nummer finden lassen\" einschalten.';

  @override
  String get discoverable => 'Über meine Nummer finden lassen';

  @override
  String get discoverableHelp =>
      'Wer deine Nummer in seinen Kontakten hat, sieht deinen @Benutzernamen. Deine Nummer wird niemandem gezeigt.';

  @override
  String get myNumberTitle => 'Deine Telefonnummer';

  @override
  String get myNumberHelp => 'Die Nummer, mit der du dich registriert hast';

  @override
  String get errPhoneMismatch =>
      'Mit dieser Nummer wurde dieses Konto nicht registriert.';

  @override
  String get sourceCode => 'Quellcode';

  @override
  String get sourceCodeHelp => 'Siegel ist freie Software (AGPL-3.0)';

  @override
  String get changeNumber => 'Nummer ändern';

  @override
  String get changeNumberHelp =>
      'Deine Chats, Gruppen, Kontakte und dein @Benutzername bleiben, wie sie sind. Niemand erfährt deine neue Nummer.';

  @override
  String get newNumber => 'Neue Telefonnummer';

  @override
  String numberChanged(String number) {
    return 'Deine Nummer ist jetzt $number.';
  }

  @override
  String get noNumber =>
      'Keine Telefonnummer: Füge eine hinzu, damit du dein Konto wiederherstellen kannst';

  @override
  String get numberRemovedTitle =>
      'Deine Nummer gehört jetzt zu einem anderen Konto';

  @override
  String get numberRemovedBody =>
      'Deine Nummer wurde für ein anderes Siegel-Konto bestätigt. Dein Konto funktioniert weiter; füge in den Einstellungen eine Nummer hinzu, damit du es später wiederherstellen kannst.';

  @override
  String get errNumberChangeTooSoon =>
      'Du kannst deine Nummer einmal alle 7 Tage ändern.';

  @override
  String get errNumberSame => 'Das ist bereits deine Nummer.';

  @override
  String get skTitle => 'Was Siegel über mich weiß';

  @override
  String get skHelp => 'Alles, was der Server über dein Konto speichert';

  @override
  String get skIntro =>
      'Das ist alles, was der Siegel-Server über dein Konto speichert, gerade eben abgerufen. Er kann deine Nachrichten, deine Kontakte und dein Profil nicht lesen.';

  @override
  String get skAccount => 'Konto';

  @override
  String get skCreated => 'Konto erstellt';

  @override
  String get skPhone => 'Telefonnummer';

  @override
  String skPhoneHash(String hash) {
    return 'Nur als Code gespeichert, aus dem sich deine Nummer nicht zurückgewinnen lässt: $hash';
  }

  @override
  String get skNumberChanged => 'Nummer zuletzt geändert';

  @override
  String get skUsername => 'Benutzername';

  @override
  String skUsernameSince(String username, String day) {
    return '@$username, seit $day';
  }

  @override
  String get skReleased => 'Alte Benutzernamen, die du noch zurückholen kannst';

  @override
  String get skIdentityKey => 'Identitätsschlüssel';

  @override
  String skIdentityKeyHelp(String key) {
    return 'Öffentlich. Andere prüfen damit, dass Nachrichten wirklich von dir kommen: $key';
  }

  @override
  String get skOn => 'An';

  @override
  String get skOff => 'Aus';

  @override
  String get skProfile => 'Profil';

  @override
  String get skProfileStored =>
      'Dein Name und Info, verschlüsselt. Nur Leute, mit denen du chattest, können sie lesen.';

  @override
  String get skProfilePicture => 'Profilbild';

  @override
  String get skPictureStored =>
      'Verschlüsselt. Nur Leute, mit denen du chattest, können es sehen.';

  @override
  String get skChecked => 'Kürzlich geprüfte Kontaktnummern';

  @override
  String skCheckedCount(int count) {
    return '$count. Nur wie viele, nie welche.';
  }

  @override
  String get skDevices => 'Geräte';

  @override
  String get skThisDevice => 'Dieses Telefon';

  @override
  String get skOtherDevice => 'Anderes Gerät';

  @override
  String skLastSeen(String platform, String day) {
    return '$platform, zuletzt verbunden am $day';
  }

  @override
  String skQueued(int count) {
    return 'Wartende verschlüsselte Nachrichten: $count';
  }

  @override
  String skKeys(int count) {
    return 'Schlüssel zum Starten von Chats: $count';
  }

  @override
  String get skPushYes => 'Benachrichtigungs-Token: gespeichert';

  @override
  String get skPushNo => 'Benachrichtigungs-Token: keiner';

  @override
  String get skCopyJson => 'Als JSON kopieren';

  @override
  String unreadCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ungelesene Nachrichten',
      one: '1 ungelesene Nachricht',
    );
    return '$_temp0';
  }

  @override
  String get messageOptions => 'Nachrichtenoptionen';

  @override
  String get themeKraehe => 'Mitternachtsblau bis Schwarz.';

  @override
  String get chatBackground => 'Chat-Hintergrund';

  @override
  String get backgroundPattern => 'Das Muster des Themas';

  @override
  String get backgroundPlain => 'Einfarbig';

  @override
  String get backgroundPhoto => 'Mein Foto';

  @override
  String get archive => 'Archivieren';

  @override
  String get unarchive => 'Aus dem Archiv holen';

  @override
  String get archived => 'Archiviert';

  @override
  String get noArchived => 'Keine archivierten Chats.';

  @override
  String unreadChats(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Chats mit ungelesenen Nachrichten',
      one: '1 Chat mit ungelesenen Nachrichten',
    );
    return '$_temp0';
  }

  @override
  String get deleteChat => 'Chat löschen';

  @override
  String deleteChatTitle(String name) {
    return 'Chat mit $name löschen?';
  }

  @override
  String get deleteChatBody =>
      'Die Nachrichten werden von diesem Telefon gelöscht. Schreibt die Person wieder, kommt der Chat zurück.';

  @override
  String leaveAndDeleteTitle(String name) {
    return '$name verlassen und den Chat löschen?';
  }

  @override
  String get leaveAndDeleteBody =>
      'Die Mitglieder sehen, dass du gegangen bist. Die Nachrichten werden von diesem Telefon gelöscht.';
}
