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

-- Resends of a pending code: each one waits twice as long as the last (ID-04).
ALTER TABLE otps ADD COLUMN IF NOT EXISTS sends int NOT NULL DEFAULT 1;
ALTER TABLE otps ADD COLUMN IF NOT EXISTS last_sent_at timestamptz NOT NULL DEFAULT now();

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

-- M2 Delivery Service (ARCH-04). Rows cascade from devices, so revocation (ID-09) clears them.
CREATE TABLE IF NOT EXISTS key_packages (
  id          bigserial PRIMARY KEY,
  account_id  uuid NOT NULL,
  device_id   uuid NOT NULL,
  data        bytea NOT NULL,
  last_resort boolean NOT NULL DEFAULT false,
  FOREIGN KEY (account_id, device_id) REFERENCES devices ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS key_packages_device ON key_packages (account_id, device_id, last_resort);
CREATE UNIQUE INDEX IF NOT EXISTS key_packages_one_last_resort ON key_packages (account_id, device_id) WHERE last_resort;

-- Never contains the sender (MSG-10).
CREATE TABLE IF NOT EXISTS queue (
  id          bigserial PRIMARY KEY,
  account_id  uuid NOT NULL,
  device_id   uuid NOT NULL,
  payload     bytea NOT NULL,
  enqueued_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (account_id, device_id) REFERENCES devices ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS queue_device ON queue (account_id, device_id, id);

-- Opaque group ID and epoch only (GRP-03); one commit per epoch (CRY-14).
CREATE TABLE IF NOT EXISTS groups (
  group_id   bytea PRIMARY KEY,
  epoch      bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- MSG-10: encrypted profile and the hash of its delivery token. Never a name or picture.
CREATE TABLE IF NOT EXISTS profiles (
  account_id uuid PRIMARY KEY REFERENCES accounts ON DELETE CASCADE,
  encrypted  bytea NOT NULL,
  verifier   bytea NOT NULL
);

-- GRP-16: invite link snapshots, encrypted by the client with a key the server never sees.
CREATE TABLE IF NOT EXISTS group_invites (
  id         bytea PRIMARY KEY,
  write_hash bytea NOT NULL,
  snapshot   bytea NOT NULL,
  expires_at timestamptz NOT NULL
);

-- MED-03, MED-13: an opaque blob and when it goes. upload_hash is set until the one upload.
CREATE TABLE IF NOT EXISTS attachments (
  blob_id     bytea PRIMARY KEY,
  size        bigint NOT NULL,
  upload_hash bytea,
  expires_at  timestamptz NOT NULL
);

-- MED-15: the profile's current picture blob; it doesn't expire while it is referenced here.
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS avatar_blob bytea;
