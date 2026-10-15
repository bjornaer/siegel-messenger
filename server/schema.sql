-- ponytail: idempotent schema applied at startup; switch to versioned migrations before the first prod deploy.

CREATE TABLE IF NOT EXISTS accounts (
  id                    uuid PRIMARY KEY,
  phone_hmac            bytea NOT NULL UNIQUE,  -- HMAC-SHA256(pepper, E.164), never the number (ID-05)
  identity_pub          bytea NOT NULL,
  as_signature          bytea NOT NULL,
  reg_lock_hash         text,
  reg_lock_attempts     int NOT NULL DEFAULT 0,
  reg_lock_locked_until timestamptz,
  created_day           date NOT NULL DEFAULT current_date
);

CREATE TABLE IF NOT EXISTS devices (
  account_id    uuid NOT NULL REFERENCES accounts ON DELETE CASCADE,
  device_id     uuid NOT NULL,
  token_hash    bytea NOT NULL UNIQUE,
  platform      smallint NOT NULL,
  push_token    text,
  last_seen_day date NOT NULL DEFAULT current_date,
  PRIMARY KEY (account_id, device_id)
);

-- A row with quarantined_until set is a released name; account_id keeps the
-- previous owner so they can reclaim it during quarantine (ID-07).
CREATE TABLE IF NOT EXISTS usernames (
  name              text PRIMARY KEY,
  account_id        uuid REFERENCES accounts ON DELETE SET NULL,
  claimed_day       date NOT NULL DEFAULT current_date,
  quarantined_until timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS usernames_current ON usernames (account_id) WHERE quarantined_until IS NULL;

CREATE TABLE IF NOT EXISTS otps (
  phone_hmac bytea PRIMARY KEY,
  code       text NOT NULL,
  attempts   int NOT NULL DEFAULT 0,
  expires_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS rate_limits (
  key          text NOT NULL,
  window_start timestamptz NOT NULL,
  count        int NOT NULL,
  PRIMARY KEY (key, window_start)
);

-- SEC-04: aggregate counters only, one row per counter per hour. Never per user.
CREATE TABLE IF NOT EXISTS metrics (
  name  text NOT NULL,
  hour  timestamptz NOT NULL,
  count bigint NOT NULL,
  PRIMARY KEY (name, hour)
);
