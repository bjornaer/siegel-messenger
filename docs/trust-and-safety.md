# Trust and safety (milestone M7 plan)

Status: planned 2026-10-18. Covers CMP-03 (reporting) and RM-03 (operator console). Legal questions
are OQ-014; nothing in the "Law" section is legal advice, and each point there needs a lawyer to
confirm it before launch.

## What we can and can't do

Messages are end-to-end encrypted. The server never sees content, and it won't scan for it, on the
server or on the phone, and it won't keep a spare key (TRUST-01). That leaves three sources:

1. **User reports.** The reporter's app decrypted the messages, so it can send the chosen ones to us.
   This is the main tool, as at Signal and WhatsApp.
2. **Metadata the server already holds:** accounts, usernames, devices, group IDs, counters
   (`AccountService.Export` lists all of it per account).
3. **Public surfaces:** @usernames, user and group invite links, and the group preview a link shows.

What we can do: suspend or ban accounts, block a banned number from registering again, take down
usernames and invite links, answer lawful requests with the little we hold, and publish what we did.

## Law to confirm (OQ-014)

- **EU Digital Services Act (Regulation 2022/2065).** Every intermediary service needs a point of
  contact for authorities and users (Art. 11, 12) and terms that explain moderation (Art. 14).
  Transparency reports (Art. 15) don't apply to micro and small enterprises. Notice and action
  (Art. 16) and statements of reason (Art. 17) are hosting duties. Private messages are probably out
  of scope, but public usernames, invite links and group previews may count. *Lawyer: which parts of
  Siegel are "hosting", and do we fit the small-enterprise exemption?*
- **EU e-Evidence (Regulation 2023/1543, applying from 18 August 2026, plus Directive 2023/1544).**
  Production and preservation orders from any EU state, answered within 10 days, or 8 hours in an
  emergency. Needs a designated contact point. *Lawyer: confirm the dates and what we must designate.*
- **Spain.** LSSI-CE (Ley 34/2002), duties to cooperate with courts. LOPIVI (Ley Orgánica 8/2021), a
  duty to report violence against children that we learn of. *Lawyer: who receives reports of child
  abuse material, and what we must keep or delete after handing it over.*
- **GDPR.** Reports hold personal data of both the reporter and the reported person: legal basis
  (legitimate interest, legal obligation), retention, and a privacy policy update.
- **Play Store.** Apps with user-to-user content must have in-app reporting and blocking, plus
  published terms.

## Parts

Each part ships on its own, like earlier milestones.

### Part 1: Terms and community guidelines

- `/terms` page: who may use Siegel (age per CMP-02), what isn't allowed, what we do about it,
  how to appeal, the contact for authorities. A link from onboarding, Settings and the privacy page.
- Community guidelines in plain words, using the same categories the report flow uses (below).
- Done when: both pages are live, linked from the app, and the lawyer has reviewed them.

### Part 2: Reporting in the app (CMP-03)

- **Where:** long-press a message → Report; a chat's menu → Report; a group's menu → Report group;
  a message request → Report and block.
- **What the reporter chooses:** a category, then the messages to include (pre-selected: the pressed
  message plus up to 10 before it from the same sender, adjustable, at most 50), and an optional note.
  The screen says plainly: "These messages will be sent to Siegel's moderators, readable."
- **Categories:** spam or scam; harassment or threats; hate; sexual content involving a minor;
  other sexual content without consent; violence or terrorism; impersonation; something else.
- **Sent:** the category, the note, the reported account ID (or group ID), and for each message: the
  sender's account ID, sent time, text, and for media the decrypted file. Plus the reporter's account ID.
- **Server:** a new `ReportService.Submit`. It encrypts the report on arrival to the moderators' age
  public key (`SIEGEL_REPORTS_AGE_RECIPIENT`), so the database and backups hold only ciphertext and
  only the moderators' laptops can read reports. Rate limit: 20 reports per account per day.
- **Report and block** blocks locally as today (MSG-16) as well.
- **Fabricated evidence:** a reporter can invent a message the other person never sent. For v1,
  moderators treat a single report with care and look for corroboration (several reporters, signals).
  Later: message franking, where the sender's app commits to each message and the server signs the
  commitment at delivery, so a reported message can be proved genuine.
- Done when: a report from the app reaches the server encrypted, an e2e test decrypts it with the
  moderator key, and the app tests cover each entry point.

### Part 3: Enforcement on the server

- **Account states:** active, suspended (until a date, with a reason), banned.
  - *Suspended:* the auth interceptor answers `account_suspended`, the stream sends the reason and
    closes, and the app shows a screen with the reason, the end date and how to appeal. Messages to
    the account are refused like those to a deleted one.
  - *Banned:* the account is deleted (ID-16) and its phone HMAC goes into `banned_numbers`, so
    `RequestOtp` answers `number_banned` with no SMS sent. Its @username is quarantined forever.
- **Username takedown:** the name is released and quarantined forever, and the account has to pick
  a new one at next start (the app already has the picker).
- **Invite link takedown:** the link is deleted (GRP-16), and the group can make a new one.
- **Statement of reasons (DSA Art. 17):** every action sends the account its reason, the rule it
  broke and how to appeal, through the stream and on the suspended screen.
- Done when: server tests cover each state, and the e2e test shows a suspended app gets the screen
  and a banned number can't register again.

### Part 4: Operator console

- **A command-line tool, `siegel-admin`, run over SSH on the server.** It isn't part of the public
  API, so there is no web attack surface. Reports are copied to the operator's laptop and decrypted
  there with the moderator key: the server never holds it.
- **Commands:**
  - `reports list|show|resolve`
  - `suspend <account> --until --reason`, `unsuspend`, `ban --reason`
  - `username release <name>`, `link revoke <id>`
  - `signals <account>`
  - `export <account>` (the CMP-06 data, for lawful requests)
  - `audit`
- **Audit log:** an append-only table holding the operator, action, target, reason and time. Each
  row hashes the previous one, so an edit or deletion shows. The tool refuses to act without a
  reason.
- **Reporters:** told "We reviewed your report" when it's resolved, without saying what we did.
- Done when: every command has a test, and each action writes exactly one audit row.

### Part 5: Abuse signals

- Per-account counters, kept 30 days:
  - hits on the new-chat limit (CMP-04);
  - message requests sent versus accepted;
  - reports received;
  - registrations per number prefix per hour (ID-04, already counted in aggregate).
- `siegel-admin signals` shows them next to the account's reports.
- **No automatic bans.** Signals only order the review queue; a person decides.
- Done when: the counters exist, expire after 30 days, and show up in `signals`.

### Part 6: Lawful requests, child safety and transparency

- `docs/law-enforcement.md`:
  - checking a request is genuine (call back the issuing authority);
  - what we can hand over: the CMP-06 export and nothing else, because we have nothing else;
  - preservation: a snapshot of the export, kept 90 days;
  - telling the user, unless the order forbids it;
  - logging each request in the audit log.
- **Child abuse material in a report:**
  - only the minimum is viewed;
  - the report is preserved and the account banned;
  - authorities are told as the lawyer advises;
  - a second operator signs off.
- **Yearly transparency report** at `/transparency`: reports by category, actions by type, appeals and
  outcomes, requests received and answered. Even if Art. 15 doesn't bind us, it backs up TRUST-01.

## Decisions needed before Part 2

1. Who reviews reports, and how fast? For example: within 24 hours for child safety and threats,
   7 days for the rest.
2. How long are reports kept? Suggested: 6 months after they're resolved, longer only when tied to
   a legal case.
3. Should blocking someone tell the server, as an abuse signal? Today blocking stays on the phone.
   Suggested: no, so blocking stays private.
4. Ban length: permanent, or a set time, such as one year, before the number can register again?
5. Where appeals go: an email address on `/terms`, for a start.
6. Who holds the moderator key, and who is the second operator for child-safety cases?
