# Siegel Messenger: Privacy Policy

> **DRAFT for legal review (CMP-07).** Describes what the code does as of October 2026.
> Fill in the bracketed fields, have a lawyer check it, then publish it at
> `https://siegel.schlk.in/privacy`. Update it whenever a feature changes what we process
> (push notifications, media, contact discovery).

Last updated: [DATE]

## Who we are

Siegel Messenger ("Siegel", "we") is operated by [CONTROLLER: legal name], [address],
Spain. Contact for privacy questions: [email]. [If appointed: Data Protection Officer, contact.]

## The short version

Your messages, your profile name and your contacts' names are end-to-end encrypted. We
cannot read them, and they are stored only on your phone. We hold the minimum needed to
deliver messages: a keyed hash of your phone number, your @username, public encryption keys,
and messages waiting for delivery, which we can't read either.

## What we process and why

| Data | What we keep | Why | Legal basis (GDPR art. 6) | How long |
| --- | --- | --- | --- | --- |
| Phone number | Sent to our SMS provider to deliver your code. Afterwards we store only a keyed hash (HMAC) of it, never the number. | Verify you own the number; stop one number from holding several accounts; abuse limits. | Contract (1b); legitimate interest in preventing abuse (1f) | The hash: until you delete your account. The code: 10 minutes. |
| @username | Stored as you chose it. Anyone who knows it can find your account. | So people can start a chat with you. | Contract (1b) | Until you change it or delete your account. A released username stays reserved for 30 days so nobody can impersonate you right away. |
| Profile (display name) | Only as ciphertext. The key is shared only with your contacts. | So your contacts see your name. | Contract (1b) | Until you replace it or delete your account. |
| Public keys and identity binding | Your public identity key, device keys and one-time key packages. | So others can start encrypted chats with you. | Contract (1b) | Until used, replaced or your account is deleted. |
| Messages waiting for delivery | Encrypted payloads addressed to your device. We don't store who sent them when sent to contacts. | Deliver messages while you're offline. | Contract (1b) | Deleted when your device confirms receipt, or after 30 days. |
| Registration Lock PIN (optional) | A one-way hash (Argon2id). | Stop someone who steals your number from taking over your account. | Contract (1b) | Until you remove it or the lock lapses after 7 days without any of your devices connecting. |
| Device and account activity | The day your device last connected. | Registration Lock lapse; [once SRV-01 ships] deleting accounts inactive for 180 days. | Legitimate interest (1f) | Until your account is deleted. |
| IP address | In memory only, for rate limits. Never written to logs or disk. | Abuse prevention. | Legitimate interest (1f) | At most 24 hours. |
| Usage statistics | Aggregate counters only (for example "codes sent today"), never per person. | Run and protect the service. | Legitimate interest (1f) | [period] |

We don't use analytics, advertising or tracking SDKs, and we don't sell or rent data.

## What stays on your phone

Your message history, attachments, contacts list, your contacts' names and your settings are
stored only on your device, in an encrypted database. We have no copy and no backup of them.
If you lose your phone, reset it or delete the app, that history is gone.

## Who else processes data

- **Hosting:** Hetzner Online GmbH, Germany (servers in the EU). Processor.
- **SMS delivery:** GatewayAPI (OnlineCity ApS), Denmark. Receives your phone number and code to
  send the SMS. Processor. [Confirm data location: EU (`.eu`) or other platform, OQ-006.]
- **Google (Play Integrity) and Apple (App Attest):** [once ID-02 ships] confirm the request comes
  from a genuine app install; they see that a check happened, not your messages.
- **Push notifications (Google Firebase Cloud Messaging, Apple Push Notification service):**
  [once push ships] receive a device token and a content-free wake-up signal.

We have data processing agreements with each processor. [List any transfers outside the
EEA and their safeguards.]

## Your rights

You can access, correct, delete, restrict or object to the processing of your data, and
receive it in a portable form. Delete your account in the app (Settings → Delete account);
this removes your server data immediately and it disappears from our backups within 24 hours.
For anything else, write to [email]. You can also complain to the Spanish data protection
authority (Agencia Española de Protección de Datos, www.aepd.es).

## Children

You must be at least 14 in Spain, or 16 or the minimum age of digital consent in your country
elsewhere, to use Siegel.

## Security

Messages use the MLS protocol (RFC 9420) and are encrypted end to end. Connections use TLS 1.3
with certificate pinning. Keys protecting phone-number hashes are held in a separate key store,
not in the database. Our source code is public at https://github.com/bjornaer/siegel-messenger.

## Changes

We'll announce material changes in the app before they take effect.
