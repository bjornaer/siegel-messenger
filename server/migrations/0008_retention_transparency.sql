-- M7 part 7. A court can ask us to keep a report longer than the retention allows.
ALTER TABLE reports ADD COLUMN IF NOT EXISTS hold_until timestamptz;

-- Preservation orders: a snapshot of what we hold about an account (the CMP-06 export), 90 days.
CREATE TABLE IF NOT EXISTS preservations (
  id         bigserial PRIMARY KEY,
  account_id uuid NOT NULL,
  order_ref  text NOT NULL,
  snapshot   jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL
);

-- Yearly counts for the transparency report. Only numbers: never who, never what.
CREATE TABLE IF NOT EXISTS transparency (
  year  int NOT NULL,
  item  text NOT NULL,
  count bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (year, item)
);
