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
`.github/workflows/release.yml`. It attaches `siegel-<n>.aab` (upload to Play),
`siegel-<n>.apk` (install directly) and `siegel-<n>.sha256` to the release.

It signs with the upload key, stored as secrets of the `production` environment. Set them once,
from your machine, so the key never passes through anyone else. Each `gh secret set` without a
value prompts for it:

```sh
base64 -i <path to the upload keystore .jks> | gh secret set ANDROID_UPLOAD_KEYSTORE --env production
gh secret set ANDROID_UPLOAD_STORE_PASSWORD --env production
gh secret set ANDROID_UPLOAD_KEY_ALIAS --env production
gh secret set ANDROID_UPLOAD_KEY_PASSWORD --env production
```

The values are the ones in `app/android/key.properties`. Without them the job stops, rather than
shipping a debug-signed build.

The APK is signed with the upload key; Play re-signs the AAB with Google's app-signing key. A phone
that installed the APK can't take Play updates over it (different signatures), and the other way
round: uninstall first.

## Store listing

Short description (76/80):

> Sealed. Not shared. Private, end-to-end encrypted messaging, made in Europe.

Full description (only claims what ships; update when groups and media land):

```
Sealed. Not shared.

Siegel is a private messenger. Your messages are encrypted on your phone and can only be read by the person you're talking to. Not by us, not by anyone in between.

YOUR MESSAGES LIVE ON YOUR PHONE
Your chat history is stored only on your device, in an encrypted database. There's no copy on our servers and no cloud backup that someone else could open.

NO PHONE NUMBER ON SHOW
People find you by your @username. Your phone number is used once to verify your account and is never shown to anyone you chat with. We don't even store it: only a scrambled fingerprint of it.

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
• Replies, reactions, edits and delete for everyone
• Delivery and read receipts, typing indicators: turn them off any time
• App lock with your fingerprint or device PIN, and screen protection against screenshots
• Eight colour themes named after German legends and moods: Drache, Löwe, Lindwurm, Krampus, Nordlicht and more

MADE IN EUROPE, OPEN FOR ALL TO CHECK
Siegel is run from Spain on servers in the EU, under European data protection law. The source code is public, so anyone can verify what it does.

Siegel is German for "seal". What you write stays sealed.

Group chats, photos and file sharing are on the way.
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

Not collected: location, contacts (phone contact discovery isn't built), financial info,
health, photos or files (end-to-end encrypted), audio, calendar, app activity, web browsing,
app info and performance (no crash reporting). The last-connected day is account
housekeeping that goes with the account itself, so it isn't listed separately.

Deletion: Play asks for a web link for deletion requests; serve one at
`https://siegel.schlk.in/delete-account` together with the privacy policy.

IP addresses are processed in memory for rate limiting only and never stored, which Google
treats as ephemeral processing, so they aren't declared.


## Permissions to justify

- `CAMERA`: scanning a contact's safety-number QR code (CRY-12). Requested only when the user
  taps "Scan their code".
- `USE_BIOMETRIC`: app lock (ID-15).
- `INTERNET`, `ACCESS_NETWORK_STATE`: messaging.

## Closed testing

1. Testing → Closed testing → create a track, add the tester email list.
2. Upload the AAB, add release notes, roll out.
3. Testers must join through the opt-in link and install from Play. Keep at least 12 opted in
   for 14 days, then apply for production access.
