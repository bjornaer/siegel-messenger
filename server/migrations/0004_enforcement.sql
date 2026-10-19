-- M7 part 4: what moderators did to an account, shown to it as a statement of reasons.
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS suspended_until timestamptz;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS suspended_rule smallint;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS suspended_reason text;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS username_removed_rule smallint;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS username_removed_reason text;

-- Banned numbers can't register again (until a date, or for good when NULL). Keyed by the phone
-- HMAC like accounts (ID-05): never the number.
CREATE TABLE IF NOT EXISTS banned_numbers (
  phone_hmac bytea PRIMARY KEY,
  until      timestamptz,
  rule       smallint NOT NULL,
  reason     text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Every moderator action, append-only. Each row hashes the one before, so an edit or a deletion
-- breaks the chain (`siegel-admin audit --verify`).
CREATE TABLE IF NOT EXISTS audit_log (
  id        bigserial PRIMARY KEY,
  at        timestamptz NOT NULL DEFAULT now(),
  operator  text NOT NULL,
  action    text NOT NULL,
  target    text NOT NULL,
  reason    text NOT NULL,
  prev_hash bytea NOT NULL,
  hash      bytea NOT NULL
);
