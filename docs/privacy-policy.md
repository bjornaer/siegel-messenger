# Privacy policy

The published policy is `server/pages/privacy.html`, served at `https://siegel.schlk.in/privacy`
(account deletion: `server/pages/delete-account.html` at `/delete-account`). Edit it there.

Before public launch (CMP-07, OQ-011):

- Set `SIEGEL_OPERATOR` (legal name and postal address) and `SIEGEL_CONTACT_EMAIL` in the server
  `.env`; the pages show them without a code change.
- Have a lawyer review it, then drop the "draft" note.
- Confirm where GatewayAPI processes data (OQ-006) and list any transfers outside the EEA.
- Add Apple (App Attest, APNs) when the iOS app ships, and media and contact discovery when they do.
