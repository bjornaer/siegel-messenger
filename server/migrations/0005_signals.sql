-- M7 part 6: per-account abuse signals, daily counts kept 30 days. They order the moderators'
-- queue and never act on their own.
CREATE TABLE IF NOT EXISTS signals (
  account_id uuid NOT NULL,
  name       text NOT NULL,
  day        date NOT NULL DEFAULT current_date,
  count      int NOT NULL DEFAULT 1,
  PRIMARY KEY (account_id, name, day)
);
