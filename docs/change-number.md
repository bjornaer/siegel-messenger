# Changing your phone number (spec Q6)

Status: design for review, 2026-10-18. Q6: wanted in v1. Needs new requirement IDs in section 5 once
approved.

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

1. **The new number must not belong to another account.** If it does, the change is refused and the app
   says so ("This number already has a Siegel account. Delete that account first."). The alternative,
   silently deleting the other account, is easy to abuse.
2. **At most one change per 7 days [proposed default]**, so a stolen session can't hop numbers to dodge
   limits.
3. **Registration Lock stays** with the account (it protects the account, not the number).

## Not covered

- Moving to a new phone *and* a new number at once: register the new number as a new account, as today.
  Message history isn't recoverable in v1 (ID-14).
