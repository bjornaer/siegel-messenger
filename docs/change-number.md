# Changing your phone number (spec Q6)

Status: implemented 2026-10-18 (M5). Q6: wanted in v1. Needs new requirement IDs in section 5.

## What the user sees

Settings → Change number:

1. Enter the new number. If a Registration Lock PIN is set, enter it too (ID-10).
2. Enter the code sent by SMS to the new number.
3. Done: "Your number is now +34 … ". Chats, groups, @username, contacts and safety numbers are unchanged.

## What happens

- **Same account, same keys.** The account ID, identity key and device stay as they are, so contacts see
  no safety-number change and groups need no commits. That is the difference from re-registering, which
  creates a new identity (ID-09).
- **Proof of the new number:** the same SMS code flow as registration, with the same per-number, per-IP
  and daily limits (ID-04) and the same device attestation (ID-02).
- **Proof it's you:** the request comes from the signed-in device, plus the Registration Lock PIN if one
  is set. A thief holding an unlocked phone can't move the account to their number without the PIN.
- **Server change:** the account's stored number hash (ID-05) is replaced by the new number's hash. The
  old number is free: registering it later creates a new, empty account.
- **Discovery:** if "find me by my number" was on, the app proves the new number and the entry moves to
  it; the old number stops matching at once.
- **Contacts aren't told.** Numbers are hidden from other users (ID-11), so there's nothing to update on
  their side.

## Rules, for review

1. **Whoever controls the number gets it.** Numbers get recycled: an old user may still have the number
   on an account long after the phone company gave it to someone else. So when the new number is on
   another account, proving it by SMS takes it: it moves to the new account, and the old account
   **keeps everything else** (identity, @username, chats, groups, devices) but has no number any more.
   Nothing is deleted, and the current phone owner is never stuck.
   - The old account's devices get a notice: "Your number was verified on another Siegel account. Your
     account still works; add a number in Settings so you can recover it later."
   - A numberless account can't be recovered by re-registering (there is no number to verify), so the
     notice asks them to add one. Changing to a new number works the same way from a numberless account.
   - If the old account had "find me by my number" on, its directory entry is removed.
   - This also covers a SIM-swap attacker: they gain the number, but not the victim's account, chats or
     @username (and a Registration Lock still blocks re-registering it). The victim keeps using Siegel and
     is told what happened.
2. **At most one change per 7 days [proposed default]**, so a stolen session can't hop numbers to dodge
   limits.
3. **Registration Lock stays** with the account (it protects the account, not the number).

## Not covered

- Moving to a new phone *and* a new number at once: register the new number as a new account, as today.
  Message history isn't recoverable in v1 (ID-14).
