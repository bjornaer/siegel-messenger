-- M7 part 5: the moderation console. Operators log in with passkeys; enrolment links are single
-- use; sessions last 12 hours. Reporters are told once that their report was reviewed.
CREATE TABLE IF NOT EXISTS console_operators (
  id          bytea PRIMARY KEY,            -- the WebAuthn user handle
  name        text NOT NULL UNIQUE,         -- shown in the audit log
  credentials jsonb NOT NULL DEFAULT '[]',
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS console_enrolments (
  token_hash bytea PRIMARY KEY,
  name       text NOT NULL,
  expires_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS console_sessions (
  token_hash  bytea PRIMARY KEY,
  operator_id bytea NOT NULL REFERENCES console_operators ON DELETE CASCADE,
  expires_at  timestamptz NOT NULL
);
ALTER TABLE reports ADD COLUMN IF NOT EXISTS reporter_told boolean NOT NULL DEFAULT false;
