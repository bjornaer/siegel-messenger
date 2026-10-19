# Child sexual abuse risk assessment

Version 1, 2026-10-19. Required by the EU CSA Regulation once it applies (risk assessment and
mitigation, Art. 3-4 in the 2022 numbering; see `docs/csa-regulation.md`). Reviewed yearly, and
before any feature ships that lets people reach more strangers. The national Coordinating
Authority gets a copy when the regulation applies.

## The service

Siegel is an end-to-end encrypted messenger (MLS, RFC 9420): one-to-one chats and groups of up to
256 people, with text, photos, videos, files, voice notes and stickers.
- **What the server knows:** it can't read messages or media. It knows accounts, @usernames,
  devices, group IDs and counters.
- **Who can sign up:** 14 and over in Spain, 16 elsewhere (CMP-02), confirmed with a checkbox today.
- **What it lacks:** no public profiles, no feeds, no channels, no "people nearby", no search
  beyond exact @usernames.

## Risks by feature

Risk levels: **H** high, **M** medium, **L** low. "Remaining" is what's left after the mitigations
in place.

| Feature | How it could be misused | In place | Remaining | Planned |
| --- | --- | --- | --- | --- |
| @username lookup (ID-06) | An adult finds a child by guessing a username and messages them (grooming). | Exact match only, with no browsing or suggestions; 1,000 lookups a day per account (ID-08); reserved names. A stranger's first message is a request (MSG-15): no read receipts, no profile, until accepted. | **H** for under-18s | Part 2: under-18s can't be found by username. |
| Message requests | Unsolicited sexual images, and grooming openers. | Requests sit apart and can be declined or blocked; senders don't learn whether they were read. **Gap:** photos in a request download by themselves, and their preview shows before accepting. | **H** | Part 2 (decided): in requests, media stays blurred and isn't downloaded until accepted. Part 3: Report and block. |
| Discovery by number (DISC-03) | Someone holding a child's number finds their account. | Off by default; opt-in; blinded queries, so the server never learns the numbers; rate limits (DISC-06). | M | Part 2: stays off by default for under-18s. |
| Contact links and QR codes (DISC-08) | A link shared publicly lets anyone skip the request. | Off unless the user shares it; can be reset to cut everyone who had it. | L | Guidelines warn to share only with people you trust. |
| Group invite links (GRP-16) | Abuse material shared in groups that anyone with the link can join. | Links expire after a week; admins revoke them; the server can delete a link. | M | Parts 4 and 5: link takedown and removal orders within 24 hours. |
| Being added to groups | A child added to a group with adults they don't know. | Adds by non-contacts arrive as invites (GRP-11) by default. | M | Part 2: locked to contacts only for under-18s. |
| Media, stickers | Sharing abuse material. | End-to-end encrypted: we can't see it and won't scan (TRUST-01). Files expire from the server after 30 days. | **H**, structural | Part 3: user reports with readable evidence; Part 7: reporting to the authorities and the EU Centre. |
| Age | Children younger than allowed, or adults posing as children. | Age checkbox (CMP-02). | **H** | Part 2: birth year at sign-up; an age check ready if the law requires one. |
| Reporting | Victims can't tell us. | None in the app yet; email per `/terms`. | **H** | Part 3: in-app reporting, worded for teenagers. |
| Accounts after enforcement | A banned abuser re-registers. | One account per number; SMS verification. | M | Part 4: banned numbers' hashes are blocked from registering again. |

## What we won't do, and why

We won't scan messages or media, on the server or the phone, and we won't keep a key that would let
us. Scanning would break the security every user relies on, children included, and the drafts as
reported exclude end-to-end encrypted content from detection. Our protection comes from:
- limiting who can reach a child;
- making reporting easy;
- acting fast on reports;
- reporting abuse to the authorities.

## Open actions

1. M7 Part 2 (minors), Part 3 (reporting), Part 4 (bans) and Part 7 (reporting to the authorities).
2. Blur and hold media in message requests: decided, M7 Part 2.
3. Review this document when M7 is complete, then every year.
