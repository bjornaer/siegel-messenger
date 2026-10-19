# EU Child Sexual Abuse Regulation (CSAR, "chat control") and Siegel

Status: analysis, 2026-10-19. Not legal advice: every "must" below is our reading of drafts and
needs the lawyer (OQ-014). The regulation is **not adopted yet**; this is what to build so we
can comply when it is, without breaking end-to-end encryption (TRUST-01).

## Where it stands

- **Proposal:** COM(2022) 209, procedure 2022/0155(COD), May 2022.
- **Parliament mandate (Nov 2023):** detection only as a last resort, ordered by a judge, and
  never on end-to-end encrypted communications.
- **Council mandate (26 Nov 2025):** no mandatory detection orders. It keeps mandatory risk
  assessment and mitigation, makes voluntary detection permanent, and adds high, medium and
  low risk categories.
- **Trilogues** since Dec 2025. The Council's note of 22 June 2026 (ST 10906/26) says:
  - risk assessment, mitigation and reporting (Articles 3 to 5) were agreed at the trilogue of
    16 April 2026 and aligned with the DSA;
  - "some mitigation measures should be compulsory for certain providers", with providers
    choosing the concrete measures;
  - the regulation covers all providers "regardless of their size", so there is **no small
    provider exemption**;
  - whether age verification is mandatory or optional for messaging services "that have
    identified a risk of solicitation" is still a political question;
  - risk categories are postponed to the detection discussion.
- **Detection** is the last open point. Reporting says the co-legislators agree that end-to-end
  encrypted content stays out of detection technologies. Later trilogues (one reported for
  29 Sep 2026) had no final deal yet.
- **Interim scanning derogation** (Reg. 2021/1232, "chat control 1.0") lapsed on 3 April 2026.
  It was reportedly reinstated in July 2026 until April 2028. It only allows *voluntary*
  scanning, and Siegel doesn't scan, so it doesn't concern us either way.

## What it would mean for Siegel

Siegel counts as an *interpersonal communications service*. As a store of encrypted blobs, invite
snapshots and public @usernames, it may also count as a *hosting service*. Lawyer: confirm.

| Duty (2022 article numbers; final numbers will differ) | What it asks | Siegel today | What to build |
| --- | --- | --- | --- |
| Risk assessment (Art. 3) | Assess how the service could be used to share CSAM or to groom children, considering its features. Update it periodically. | Nothing written. | A written risk assessment (`docs/csa-risk-assessment.md`): features, risks, mitigations, residual risk. Reviewed yearly and with every feature that adds reach, such as discovery, links or groups. |
| Risk mitigation (Art. 4) | Reasonable, proportionate measures; some may become compulsory. Possibly age verification where there is a solicitation risk. | Several exist: message requests from strangers (MSG-15), blocking (MSG-16), no public directory, discovery opt-in only (DISC-03), new-chat limits (CMP-04), age gate (CMP-02). | Reporting (M7 part 2), enforcement (part 3), and the decisions below on minors and age assurance. |
| Risk reporting (Art. 5) | Send the assessment and measures to the national Coordinating Authority. | No authority known yet. | Track Spain's designation; send the assessment once the regulation applies. |
| User flagging (Art. 12(3)) | An "accessible, age-appropriate and user-friendly" way for users to flag potential abuse. | None. | M7 part 2 (CMP-03), with a child-safety category and wording a teenager understands. |
| Reporting to the EU Centre (Art. 12-13) | When we become aware of potential CSA (in practice: a user report), report it to the EU Centre without delay. The user is told unless the Centre says not to. | None. | Part 6: a report goes to the EU Centre once it operates; until then to the national police, as the lawyer advises. |
| Preservation (Art. 22) | Keep what was reported and the related data only as long as needed, at most 12 months unless a court asks for more. | No reports stored yet. | Report retention: 12 months maximum for child-safety reports; deleted after. |
| Removal orders (Art. 14) | Remove or disable specified material within 24 hours. | We can delete a blob, an invite link or a username by ID, but we can't see content. | `siegel-admin remove <blob\|link\|username>` (part 4) and an on-call path that meets 24 hours. |
| Points of contact (Art. 23) | A single point of contact for authorities, published. | None. | A contact on `/terms` (part 1), monitored with a 24-hour target. |
| Detection orders (Art. 7-11) | Scanning ordered by a court. | Not possible: we never see content. | **Nothing, deliberately.** If the final text ever reached end-to-end encrypted messaging, scanning would break TRUST-01, and that becomes a product decision, not an engineering task. |
| Penalties | Up to 6% of worldwide turnover. | — | — |

## What we will not do

- **Scan messages,** on the server or on the phone (client-side scanning), hash-match media or
  keep a spare key. The drafts as reported exclude end-to-end encrypted content from detection,
  and Siegel's design depends on it.
- **Read user reports beyond what the reporter chose to send.**

## Decisions this adds for you

1. **Minors.** Today we only check "at least 14/16". Options:
   - (a) keep that;
   - (b) ask the birth year at sign-up and give under-18s safer defaults: message requests only
     from people whose number they have, no group adds by strangers, discovery off;
   - (c) also offer a privacy-preserving age check (the EU age-verification app or EUDI wallet)
     if the final text makes age verification mandatory where there is a solicitation risk.

   I'd build (b) now and keep (c) ready.
2. **Who files reports** to the EU Centre or the police, and the second person who signs off on
   child-safety cases. This is the same question as OQ-014 and the trust-and-safety plan.
3. **24-hour on-call** for removal orders and child-safety reports: you alone, or shared?

## Watch list

- The final text: check whether detection could apply to end-to-end encrypted messaging, whether
  age verification is mandatory for messaging, the application date (the 2022 proposal applied
  6 months after entry into force) and the article numbers.
- Spain's Coordinating Authority.
- The start date of the EU Centre.

## Sources

- [Wikipedia: Regulation to Prevent and Combat Child Sexual Abuse](https://en.wikipedia.org/wiki/Regulation_to_Prevent_and_Combat_Child_Sexual_Abuse). Its own banner warns of possible errors.
- [Council note ST 10906/26, 22 June 2026: state of play of the trilogues](https://data.consilium.europa.eu/doc/document/ST-10906-2026-INIT/en/pdf)
- [Council position, 26 Nov 2025 (reported)](https://ieu-monitoring.com/editorial/protecting-children-from-online-abuse-eu-council-reaches-position-on-new-law/860929/)
- [Chat Control (Wikipedia)](https://en.wikipedia.org/wiki/Chat_Control); [patrick-breyer.de](https://www.patrick-breyer.de/en/posts/chat-control/)
