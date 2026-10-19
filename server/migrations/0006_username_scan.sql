-- M7 part 8: usernames the periodic scan flagged, for a person to review. One row per name:
-- the same name is never queued twice; a new name is a new row.
CREATE TABLE IF NOT EXISTS username_flags (
  name        text PRIMARY KEY,
  account_id  uuid,
  why         text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  outcome     text
);

-- When each periodic job last ran.
CREATE TABLE IF NOT EXISTS jobs (
  name     text PRIMARY KEY,
  last_run timestamptz NOT NULL
);
