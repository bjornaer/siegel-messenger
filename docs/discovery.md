# Phone-number discovery (M5)

Status: design for review, 2026-10-18. Implements DISC-03 to DISC-07 of the requirements spec.

People can find contacts who use Siegel by phone number, if **both** sides want it: the person being
found switched on "Let people who have my number find me" (off by default, DISC-03), and the person
searching allowed Siegel to read their contacts (DISC-04). Nothing else needs either.

## What each side learns

| Who | Learns | Never learns |
| --- | --- | --- |
| Searcher | Which of their own contacts use Siegel and opted in, and those contacts' @usernames | Anyone's number they didn't already have; any other user's @username |
| Person found | Nothing (no notification) | Who searched for them |
| Server | That an account searched, how many numbers, and which directory buckets it fetched | The searched numbers; which entry in a bucket matched |

The server never stores an address book, hashed or otherwise. Hashes of phone numbers can be reversed by
trying every number, so the design uses an OPRF instead: a keyed function only the server can evaluate,
and only one number at a time, without seeing the number.

## Mechanism

Curve: ristretto255. `H(n)` maps a number to a curve point (SHA-512 of the E.164 string, then the standard
ristretto255 one-way map).

**Keys.** No new secret: the keys come from the phone pepper, which never leaves OpenBao (ID-05). The
server asks OpenBao for HMAC-SHA-512 of a fixed label (`siegel-disc-v1:master` for `m`,
`siegel-disc-v1:period:N` for the key `k` of period N) and reduces it to a scalar. Labels never look like
the E.164 numbers the pepper otherwise hashes. Periods last 90 days **[default]** (DISC-05.1), so keys
rotate without anyone re-registering.

**Opting in (DISC-03).** The app sends its own number once, over TLS. The server checks it against the
account's stored HMAC (ID-05), so nobody can register a number that isn't theirs, then stores
`Y = m·H(n)`, a keyed value like the HMAC, never the number. Opting out deletes `Y`.

**The directory.** For each opted-in account the server computes the current OPRF output
`O = SHA-256("siegel-disc-v1" ‖ k·H(n))` (from `Y`, as `k·m⁻¹·Y`) and publishes one entry:

- `id = first 16 bytes of SHA-256("id" ‖ O)`
- `box = AES-256-GCM(key = SHA-256("key" ‖ O), @username)`

Entries are grouped into buckets by the first bits of `id`, with as few bits as keep every bucket at 256
entries or more **[default]** (DISC-05.5). Under 512 opted-in users that is one bucket for everyone.

**Searching (DISC-05.3–5).** For each contact the app picks a random `r`, sends `r·H(n)`, gets back
`k·r·H(n)` and removes `r`, which leaves `k·H(n)` and so `O`. The server saw only random-looking points. The
app then downloads the buckets its contacts' `id`s fall into and opens the entries it can: only an entry
whose `O` it computed decrypts. Every other entry in the bucket stays unreadable, so downloading a bucket
doesn't reveal other users' @usernames (ID-08 stays true).

**Limits (DISC-06).** 5,000 evaluations for an account's first sync, then 100 a day **[default]**. That is
what stops someone from trying every number. The app keeps each contact's result for the key period, so
only new numbers count. A new key period makes every result stale, so the 5,000 first-sync allowance
renews with each period (every 90 days).

**Result (DISC-07).** A match shows the contact's name from the phone's address book and their @username,
with a button to start a chat (a normal @username chat, which is a message request on their side unless
they know you).

## Differences from the spec text, for review

1. **No separate membership filter (DISC-05.2).** The spec has the server publish a cuckoo filter so the
   app only fetches buckets for real matches. Instead the app fetches the buckets for all its contacts.
   The server learns less (which buckets the address book covers, not which contacts matched) at the cost
   of some download size. Until the directory is large every user fits in a few buckets anyway. Add the
   filter if bucket downloads get heavy.
2. **OPRF output hashes only the evaluated point**, not the number as well (RFC 9497 also hashes the
   input). That lets the server rotate keys from `Y` without ever holding numbers again. The security
   argument (one-more Diffie-Hellman) is the same.
3. **Entries are encrypted to the OPRF output**, which the spec doesn't say but needs: without it, each
   downloaded bucket would list 256 @usernames.

## Out of scope for now

- Private information retrieval instead of bucket downloads (roadmap note in section 6).
- Discovery on the web client.
