-- CMP-03, M7: user reports, sealed by the reporter's app to the moderators' key. The category is
-- in clear to order the queue. No foreign keys: a report outlives the accounts it names.
CREATE TABLE IF NOT EXISTS reports (
  id               bigserial PRIMARY KEY,
  reporter         uuid NOT NULL,
  reported         uuid,
  category         smallint NOT NULL,
  sealed           bytea NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  resolved_at      timestamptz,
  outcome          text
);
CREATE INDEX IF NOT EXISTS reports_open ON reports (category, created_at) WHERE resolved_at IS NULL;
