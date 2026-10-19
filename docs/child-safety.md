# Child safety: what to do with a report

M7 part 7. For reports in the "Sexual content involving a minor" category, and anything else that
turns out to involve a child. Target: reviewed within **24 hours** (D1). Not legal advice. The
lawyer confirms the steps marked ⚖ (OQ-014, O4).

## When the alert arrives

`SIEGEL_ALERT_WEBHOOK` posts "a new child_safety report is waiting". Open the console through the
tunnel (`docs/deploy.md`).

## Review

1. **Look at the minimum.** Open the report and load the key. If the first image or message makes
   it clear, stop looking. Don't download or copy media to your machine.
2. **Second operator (O1).** Ask the second person to confirm before acting, unless a child is in
   immediate danger (then act, and they confirm after).
3. **Preserve** before anything else, because the account's data goes when it's banned:
   `$A preserve --order "CSAM report <id>" --reason "child safety" <account>`, then
   `$A hold --days 365 --reason "child safety report preserved" <report id>`.
4. **Ban:** in the console, or with `$A ban --rule child_safety --reason "…" <account>`. Their number
   can't come back, and their @username stays taken.
5. **Report to the authorities ⚖** without delay:
   - Until the EU Centre operates (CSAR Art. 12): the authority the lawyer names (O4), for example
     the Policía Nacional or Guardia Civil cyber units.
   - Send them the report ID, the time, the preservation snapshot, and how to request the evidence.
     Don't email the images themselves unless the authority asks for them through a channel it gives
     you.
   - Log it: `$A request-log --kind other --outcome answered --order "<their reference>" --reason "CSAM report <id> referred" "<authority>"`.
6. **Resolve** the report as "reported to authorities". The reporter is told it was reviewed.
7. **The reported person** is told they were banned and why (the app shows it), unless the
   authority asks us not to tell them ⚖. If so, don't resolve it until they say we may.

## Look after yourself

This material is distressing. Take a break after a case, and don't review alone at night if you
can avoid it. If it stays with you, talk to someone.

## Retention

The report is kept at most 12 months (D2), or as long as the hold you set, and the preservation
snapshot 90 days. Delete nothing by hand.
