# M7: Trust and safety, plan

Status: planned 2026-10-19. Covers CMP-03 (reporting), RM-03 (operator console), protecting minors,
and the duties expected from the EU Child Sexual Abuse Regulation (`docs/csa-regulation.md`). Built
in parts like earlier milestones; AAB at the end. Legal points are our reading, for the lawyer to
confirm (OQ-014).

## Principles

- **No scanning and no spare key, ever.** Messages stay end-to-end encrypted; the server never
  sees content (TRUST-01). What we act on:
  - user reports, readable because the reporter's app sends the messages they chose;
  - the little metadata the server holds (`AccountService.Export`);
  - public surfaces: @usernames, invite links, group previews.
- **A person decides.** Signals only order the review queue; there are no automatic bans.
- **Least data.** Reports are encrypted to the moderators' key on arrival, kept only as long as
  needed, then deleted.
- **Every action is explained** to the person it affects (DSA Art. 17), logged, and can be appealed.

## Decided (2026-10-18/19)

| # | Question | Decision |
| --- | --- | --- |
| D1 | Review times | Child safety and threats: within 24 hours. Everything else: within 7 days. |
| D2 | How long reports are kept | 6 months after resolution; child-safety reports at most 12 months (CSAR); longer only when a court asks. |
| D3 | Does blocking tell the server? | No. Blocking stays private, on the phone. |
| D4 | Appeals | By email to an address on `/terms`. |
| D5 | Minors | Ask the birth year at sign-up; under-18s get safer defaults (Part 2). A privacy-preserving age check stays designed but unbuilt until the law requires it. |
| D6 | Duress PIN (RM-02) | Wipes all local data and keys. Roadmap, not M7. |

## Still open: needed before the part named

| # | Question | Needed for | My suggestion |
| --- | --- | --- | --- |
| O1 | Who reviews reports and holds the moderators' key; who is the second person for child-safety cases | Part 3 (key), Part 7 (sign-off) | You review and hold the key; name a trusted second person. |
| O2 | Ban length | Part 4 | Permanent, appealable; a one-year ban for spam only. |
| O3 | Who is on call for 24-hour removal orders and child-safety reports | Part 7 | You, with alerts to your phone. |
| O4 | Where child-abuse reports go until the EU Centre exists | Part 7 | The lawyer names the authority (Policía Nacional or Guardia Civil cyber units). |
| O5 | Legal review of terms, guidelines, privacy update and risk assessment | Launch | — |

## Parts

### Part 1: Terms, guidelines, point of contact, risk assessment

- `/terms`:
  - who may use Siegel (CMP-02 ages);
  - what isn't allowed;
  - what we do about it, and how to appeal;
  - the point of contact for authorities and users (DSA Art. 11/12, CSAR).
- `/guidelines` in plain words. Its categories are the ones the report flow uses (Part 3).
- Linked from onboarding (the age step), Settings and the privacy page. The privacy page also gains
  a "Reports" section: what a report sends, who reads it, how long it's kept.
- `docs/csa-risk-assessment.md` (CSAR Art. 3-4): every feature that widens reach, how it could be
  misused against children, what mitigates it, and the risk that remains. The features are
  @username search, discovery by number, contact links, invite links, groups up to 256, media,
  stickers and message requests. It is reviewed yearly and with each new reach feature.
- **Done when:** the pages are live and linked from the app (a test checks the links), and the risk
  assessment is written.

### Part 2: Minors

- **Sign-up:** after the phone step, the app asks the birth year in place of today's checkbox.
  - Under the minimum age (14 in Spain, 16 elsewhere, CMP-02): the app explains and stops.
  - Existing accounts are asked once, after updating.
  - The year stays on the phone, in the encrypted database. The server only learns "under 18:
    yes/no" (`AccountService.SetMinor`), and the app clears it on the 18th birthday.
- **Under 18, enforced by the server:**
  - not findable by @username search: `Lookup` answers `not_found`. Strangers can't start a chat
    with a minor they found by guessing or browsing names;
  - reachable through their contact link or QR code, which they share on purpose, and by people
    who already chat with them;
  - "find me by my number" is off by default. If they turn it on, people with their number can
    find them;
  - only contacts can add them to groups. Anyone else's add becomes an invite (GRP-11), and the
    setting is locked.
- **Shown in "What Siegel knows about me":** "Under 18: yes".
- **Age check, designed but not built:** a "verify with the EU age-verification app or EUDI wallet"
  step, kept ready for when the final CSAR makes age checks mandatory for messaging with a grooming
  risk. Spec in `docs/csa-regulation.md`.
- **Done when:**
  - server tests cover lookup refusal, contact-link reach and group adds becoming invites;
  - app tests cover the birth-year flow, the once-only ask for existing users and the locked
    settings;
  - e2e: an adult can't find a minor by username, but can through the minor's link.

### Part 3: Reporting in the app (CMP-03, CSAR Art. 12(3))

- **Where:**
  - long-press a message → Report;
  - chat menu → Report;
  - group menu → Report group;
  - a message request → Report and block.
- **What the reporter chooses:**
  - a category: spam or scam; harassment or threats; hate; sexual content involving a minor; other
    sexual content without consent; violence or terrorism; impersonation; something else;
  - the messages to include: the pressed one plus up to 10 before it from the same sender, at most
    50;
  - an optional note.

  The wording is plain enough for a teenager. It says what is sent: "These messages will be sent
  to Siegel's moderators, readable."
- **Sent:**
  - the category and note;
  - the reported account or group;
  - each message's sender, time, text and decrypted media;
  - the reporter's account.
- **Server:**
  - `ReportService.Submit` encrypts the report on arrival to the moderators' age public key
    (`SIEGEL_REPORTS_AGE_RECIPIENT`), so the database and backups hold only ciphertext;
  - limit: 20 reports per account per day;
  - stores the category and time in clear for the queue's order.
- **Report and block** also blocks locally (MSG-16). The reporter is later told "We reviewed your
  report", without saying what we did.
- **Done when:**
  - server tests: encrypted at rest, rate limit;
  - an e2e test decrypts a submitted report with a test moderator key;
  - app tests cover every entry point and the selection limits.

### Part 4: Enforcement on the server

- **Suspended (until a date, with a reason):**
  - the auth interceptor answers `account_suspended`;
  - the stream sends the reason and the end date, then closes;
  - the app shows a screen with the reason, the rule, the end date and how to appeal;
  - messages to the account are refused as to a deleted one.
- **Banned:**
  - the account is deleted (ID-16);
  - its phone HMAC goes into `banned_numbers` (until a date, or for good, per O2), so `RequestOtp`
    answers `number_banned` and sends no SMS;
  - its @username is quarantined for good.
- **Takedowns:**
  - a username is released and quarantined for good; the account picks a new one at next start;
  - an invite link is deleted;
  - a blob is deleted.
- **Statements of reason (DSA Art. 17):** every action sends its reason, the rule and the appeal
  address to the account.
- **Done when:**
  - server tests cover each state and takedown;
  - e2e: a suspended app gets the screen, and a banned number can't register again.

### Part 5: `siegel-admin`, the operator console

- **A command-line tool run over SSH on the server.** It is never on the public API.
- **Reports** are copied to the operator's laptop and decrypted there; the server never has the
  moderators' private key.
- **Commands:**
  - `reports list|show|resolve`: the queue in D1 order;
  - `suspend <account> --until --reason`, `unsuspend`, `ban --reason [--until]`;
  - `remove username|link|blob <id> --order <ref>`: removal orders within 24 hours;
  - `signals <account>`, `export <account>` (the CMP-06 data);
  - `audit`.
- **Audit log:** an append-only table; each row hashes the previous one, so an edit or deletion
  shows. No action without a reason.
- **Done when:** every command has a test, and each action writes exactly one audit row.

### Part 6: Abuse signals

- Per-account counters, kept 30 days:
  - hits on the new-chat limit (CMP-04);
  - message requests sent versus accepted;
  - reports received;
  - registrations per number prefix per hour.
- They appear in `siegel-admin signals` and order the queue. They never act on their own.
- **Done when:** the counters exist, expire after 30 days, and show in `signals`.

### Part 7: Child safety, lawful requests, retention, transparency

- **Child-safety runbook (`docs/child-safety.md`):**
  - view only the minimum;
  - preserve the report and ban the account;
  - report without delay to the authority (O4), later to the EU Centre (CSAR Art. 12);
  - tell the reported user unless told not to;
  - a second operator signs off (O1).
- **Lawful requests (`docs/law-enforcement.md`):**
  - check the request is genuine;
  - hand over the CMP-06 export only, because we hold nothing else;
  - e-Evidence deadlines: 10 days, or 8 hours in an emergency;
  - preservation snapshots kept 90 days;
  - tell the user unless forbidden;
  - every request goes in the audit log.
- **Retention job:** reports are deleted per D2, and preservation snapshots after 90 days. Tested.
- **On-call (O3):** a push alert to the operator for each child-safety or threats report, and for
  each removal order.
- **`/transparency`:** a yearly page with reports by category, actions by type, appeals and
  outcomes, and requests received and answered.
- **Done when:** both runbooks are written and the retention job is tested. The transparency page is
  generated from the audit log.

## Order and dependencies

| Part | Can start | Blocked by |
| --- | --- | --- |
| 1 | Now | Legal review before launch (O5) |
| 2 | Now | — |
| 3 | Now | O1 only for the production key; tests use a test key |
| 4 | After 3 | O2 |
| 5 | After 4 | — |
| 6 | After 5 | — |
| 7 | After 5 | O1, O3, O4 |

Old app builds: reports, minors' settings and the suspended screen need build 16. Raise
`SIEGEL_ANDROID_MIN_BUILD` once Parts 2 and 4 are live, so no account can skip them.
