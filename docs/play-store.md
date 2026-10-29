# Google Play submission notes

Answers for the Play Console forms, matching what the app does today. Re-check them when
push (FCM), media or contact discovery ship.

## App setup

- Package: `in.schlk.siegel`. Signed upload key: SHA-256
  `93:43:99:00:88:1C:CE:F0:BF:39:66:96:C5:E1:5C:BC:B0:90:DF:A1:7C:BA:6A:E9:AF:F2:24:C1:E8:34:3C:08`.
  Use Play App Signing.
- Store title "Siegel Messenger"; the launcher label stays "Siegel".
- Category: Communication. Free, no ads, no in-app purchases.
- Personal developer account: production needs a closed test with at least 12 testers who
  stay opted in for 14 continuous days first.

## Build and upload

```sh
cd app
flutter build appbundle --release --build-number <n>   # n must grow with every upload
# upload build/app/outputs/bundle/release/app-release.aab
```

### From a GitHub release (CI)

Publishing a release whose tag ends in the build number (`build-18`, `v18`) runs
`.github/workflows/release.yml`. It attaches `siegel-<n>.aab` (upload to Play) and
`siegel-<n>.sha256` to the release.

It signs with the upload key, stored as secrets of the `production` environment. Set them once,
from your machine, so the key never passes through anyone else. Each `gh secret set` without a
value prompts for it:

```sh
base64 < <path to the upload keystore .jks> | tr -d "\n" | gh secret set ANDROID_UPLOAD_KEYSTORE --env production
gh secret set ANDROID_UPLOAD_STORE_PASSWORD --env production
gh secret set ANDROID_UPLOAD_KEY_ALIAS --env production
gh secret set ANDROID_UPLOAD_KEY_PASSWORD --env production
```

The values are the ones in `app/android/key.properties`. Without them the job stops, rather than
shipping a debug-signed build.

## Store listing

Short description (76/80):

> Sealed. Not shared. Private, end-to-end encrypted messaging, made in Europe.

Full description (only claims what ships):

```
Sealed. Not shared.

Siegel is a private messenger. Your messages are encrypted on your phone and can only be read by the person you're talking to. Not by us, not by anyone in between.

YOUR MESSAGES LIVE ON YOUR PHONE
Your chat history is stored only on your device, in an encrypted database. There's no copy on our servers and no cloud backup that someone else could open.

NO PHONE NUMBER ON SHOW
People find you by your @username, a contact link or QR code, or, only if you switch it on, by your phone number. Your number is never shown to anyone you chat with, and we don't even store it: only a scrambled fingerprint of it.

WE SEE AS LITTLE AS POSSIBLE
• End-to-end encryption with MLS, the modern open standard for secure messaging
• Sealed sender: when contacts write to you, our server doesn't learn who sent the message
• Your name and profile are encrypted too, visible only to your contacts
• Notifications carry no content and no sender: your phone fetches and decrypts the message itself
• No ads, no analytics, no tracking

YOU DECIDE WHO REACHES YOU
• Strangers land in Message requests until you accept them
• Block anyone silently
• Compare safety numbers or scan a QR code in person to be sure you're talking to the right person
• Registration Lock: a PIN that stops anyone who gets hold of your number from taking over your account

EVERYTHING A CHAT NEEDS
• Groups with invite links, @mentions and group photos
• Voice messages, photos, videos and files, all end-to-end encrypted
• View-once photos, stickers (make your own) and GIFs
• Saved messages: a chat with yourself for notes
• Replies, reactions with any emoji, edits and delete for everyone
• Delivery and read receipts, typing indicators: turn them off any time
• App lock with your fingerprint or device PIN, and screen protection against screenshots
• Colour themes named after German legends and moods: Drache, Löwe, Lindwurm, Krampus, Nordlicht and more

ON YOUR COMPUTER TOO
Link up to 4 devices, including Siegel Web in your browser. Your phone approves each one.

MADE IN EUROPE, OPEN FOR ALL TO CHECK
Siegel is run from Spain on servers in the EU, under European data protection law. The source code is public, so anyone can verify what it does.

Siegel is German for "seal". What you write stays sealed.
```

## App content

**Privacy policy:** `https://siegel.schlk.in/privacy` (draft in `docs/privacy-policy.md`).

**Ads:** No.

**App access:** Restricted (needs a verified phone number). Instructions for reviewers:

> Open the app, tap Continue, enter the phone number [SIEGEL_REVIEW_PHONE], tick the age box and
> tap Send code. Enter [SIEGEL_REVIEW_CODE]. Choose any @username and name, then skip the PIN.
> To try messaging, start a chat with @[a second test account you keep signed in].

**Content rating (IARC):** Communication app. Users can talk to each other: yes. Shares
location: no. Digital purchases: no. Unrestricted internet: no.

**Target audience:** 16–17 and 18+. Doesn't appeal to children. (The in-app minimum is 14 in
Spain and 16 elsewhere; 13–15 is left out because it includes 13-year-olds.)

**News app:** No. **Health:** No. **Financial features:** None. **Government:** No.

## Data safety

Encrypted in transit: **Yes** (TLS 1.3). Users can request deletion: **Yes** (in app, Settings →
Delete account; also by email per the privacy policy). Independent security review: **No** (yet).

Messages, photos, profile names and contacts are end-to-end encrypted and readable only on
users' devices. Google's form says such data doesn't need declaring, so don't list them.

| Data type (Play category) | Collected | Shared | Optional? | Purposes |
| --- | --- | --- | --- | --- |
| Personal info → Phone number | Yes (kept only as a keyed hash; sent to the SMS processor) | No (service providers don't count as sharing) | Required | Account management; Fraud prevention, security and compliance |
| Personal info → User IDs (@username) | Yes | No | Required | App functionality; Account management |
| Device or other IDs (FCM token, Firebase installation ID, Play Integrity) | Yes | No | Required | App functionality; Fraud prevention, security and compliance |
| Contacts | Yes (only blinded values the server can't turn back into numbers; never stored) | No | Optional (contact discovery, off until the user allows it) | App functionality |
| Messages → Other in-app messages; Photos and videos; Files and docs | Yes, only in reports the user chooses to send (encrypted for our moderators) | No | Optional | Fraud prevention, security and compliance |
| App activity → In-app search history (GIF searches) | No (passed through, not kept) | Yes, to GIPHY, without the account or IP | Optional | App functionality |

Not collected: location, financial info, health, photos, files or audio outside reports (end-to-end
encrypted), calendar, other app activity, web browsing, app info and performance (no crash
reporting). Contacts and GIF searches are declared to stay on the safe side: neither is readable
or kept by us. The last-connected day is account
housekeeping that goes with the account itself, so it isn't listed separately.

Deletion: Play asks for a web link for deletion requests; serve one at
`https://siegel.schlk.in/delete-account` together with the privacy policy.

IP addresses are processed in memory for rate limiting only and never stored, which Google
treats as ephemeral processing, so they aren't declared.


## Permissions to justify

- `CAMERA`: scanning QR codes (safety numbers, contact and device links) and taking photos and
  videos in the app. Requested only when the user first does one of those.
- `RECORD_AUDIO`: voice messages, requested on the first recording.
- `READ_CONTACTS`: finding contacts who use Siegel (opt-in), requested only when the user taps
  Find contacts.
- `USE_BIOMETRIC`: app lock (ID-15).
- `INTERNET`, `ACCESS_NETWORK_STATE`: messaging.

## Closed testing

1. Testing → Closed testing → create a track, add the tester email list.
2. Upload the AAB, add release notes, roll out.
3. Testers must join through the opt-in link and install from Play. Keep at least 12 opted in
   for 14 days, then apply for production access.

## Production access questionnaire

Draft answers for Dashboard → Apply for production. Fill the [brackets]; check each field's
length limit in the Console. Keep "no open crashes" true against Android vitals and the
pre-launch report, and don't claim a legal review until O5 (docs/trust-and-safety.md) is done.

### Part 1: About your closed test

**How easy was it to recruit testers?** [Pick what matched: friends and family is usually
"Somewhat difficult" or "Neither easy nor difficult".]

**Tester engagement**

> [N] testers used Siegel daily over the 14+ days as their messenger with each other: one-to-one and group chats, voice messages, photos, videos, files, stickers, GIFs, reactions, replies, group invite links, contact links and QR codes, and phone-number discovery. Several also linked Siegel Web in a desktop browser to their phone. Usage was close to what we expect in production: small circles of people who know each other, mostly text and voice notes, with photos and stickers. One difference: the group was small and mostly from [Spain], so we saw few message requests from strangers and few reports. We tested those flows (reporting, blocking, message requests, under-18 protections) ourselves with test accounts.

**Feedback and how it was collected**

> Feedback came through [a group chat with the testers / direct messages / email to support], plus Play Console pre-launch reports and crash reports. The main points:
> - Siegel Web didn't load chats for some browsers, and one tester saw a blank page.
> - Photos and GIFs sent from the browser didn't appear.
> - Testers asked for Enter to send on desktop, replying from the web, drag and drop of images, and a "saved messages" chat with themselves.
> - Long chats needed a quick way back to the newest message.
> - Testers wanted to scrub through voice messages and to send several files at once.
> - The SMS code sometimes didn't arrive, and international numbers were confusing to enter.
> - Notifications didn't show on phones not set to English.

### Part 2: About your app

**Target audience**

> Adults and older teens (16+; 14+ in Spain, as the terms say) who want a private messenger for family, friends and small groups. In particular, people in Europe who care about privacy and want end-to-end encryption without their contact list, metadata or message content going to the operator. It doesn't target or appeal to children. Accounts that say they're under 18 get extra protections: they can't be found by username and can only be added to groups by contacts. Media from strangers stays blurred until accepted.

**Value proposition**

> Siegel is a free messenger with no ads, built so the operator can't read or profile your conversations:
> - Every message, photo, voice note and profile is end-to-end encrypted with the IETF MLS standard.
> - Sealed sender hides who is writing to whom, and notifications carry no content.
> - Phone numbers are stored only as a keyed hash, and messages live on the device, not the server.
>
> Users get what they expect from a modern messenger: groups, voice messages, media, stickers and GIFs, reactions, replies, and up to 4 linked devices including a browser. Strangers land in message requests, and there's in-app reporting and blocking. Unlike most alternatives it's built and hosted in the EU, under GDPR and the Digital Services Act.

**Installs in the first year:** 1K–10K (100–1K if there's no launch plan yet).

### Part 3: About your production readiness

**Changes from the closed test**

> Based on the closed test we shipped builds 19 to 21:
> - **Siegel Web:** fixed chats not loading (message acknowledgements failed in some browsers), and fixed photos and GIFs sent from the browser. A browser that can't run the app now says why instead of showing a blank page.
> - **Requested features:** Enter to send on desktop, replies, right-click and drag and drop on the web, a "Saved messages" chat with yourself, GIFs (via GIPHY) in the sticker sheet, a scroll-to-newest button, scrubbing through voice messages, and sending several files at once.
> - **Reliability:** a country picker for phone numbers that shows where the SMS goes, a manual code path when an SMS doesn't arrive, and notifications on phones not set to English.
> - **Security:** we kept dependencies on top of new security advisories.

**How we decided it was ready**

> - **Testing:** our automated tests (widget, accessibility, end-to-end against a real server, fuzzing of the parsers) pass on every build.
> - **Closed test:** testers used the app daily for [14+] days. The issues they reported are fixed and confirmed by them, and crash reports and pre-launch reports show no open crashes.
> - **Trust and safety:** in place before launch, as the DSA requires: terms, community guidelines, a child-safety risk assessment, in-app reporting, a moderation console with an audit log, and a published contact point.
> - **Operations:** the server runs in the EU with encrypted backups and automated deploys after tests pass. We can force an update if a fix requires it.
