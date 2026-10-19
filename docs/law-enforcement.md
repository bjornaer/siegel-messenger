# Requests from authorities

M7 part 7. What to do when a court, prosecutor or police force asks for data, to preserve data, or to
remove something. Not legal advice. The lawyer confirms the steps marked ⚖ (OQ-014).

## What we hold, and nothing more

Exactly the CMP-06 export (`$A export`), which is the same as Settings → What Siegel knows about me:
- a hash of the phone number (not the number);
- @username, and when the account and username were created;
- devices and the day each last connected;
- whether Registration Lock and discovery are on, and whether the account is under 18;
- counts of queued encrypted messages.

**We have no message content, contacts, group membership, chat history, or IP logs.** Say so plainly
when asked.

## Steps

1. **Check the request is genuine.** Call the issuing authority back on a number you look up
   yourself, never one given in the request. Note who you spoke to.
2. **Deadlines** ⚖: EU e-Evidence production orders within **10 days**, emergencies within **8
   hours**; national orders as they state.
3. **Preservation orders:**
   `$A preserve --order "<ref>" --reason "<authority> preservation" <account>` keeps a snapshot for
   90 days.
4. **Production orders:**
   `$A export --order "<ref>" --reason "<authority> production" <account>` prints the JSON to send
   through the channel the authority specifies.
5. **Removal orders:**
   `$A remove-link`, `remove-blob` or `remove-username` with `--reason "<ref>"`, within **24 hours**.
6. **Log every request**, even refused ones or ones where we held nothing:
   `$A request-log --kind production|preservation|emergency|removal|other --outcome answered|nothing_held|refused --order "<ref>" --reason "…" "<authority>"`.
   These feed the yearly `/transparency` page as counts only.
7. **Tell the user**, unless the order forbids it ⚖. Write to them through the channel they gave, or
   leave it if we have none: we don't hold their number.

## Appeals from users

When someone appeals a suspension, ban or username removal by email: review it, then record the
outcome with `$A appeal --outcome upheld|overturned --reason "…" <account>`. If it was overturned,
also `unsuspend` (a ban can't be reversed: they register again; ask them to). Appeals are counted on
`/transparency`.
