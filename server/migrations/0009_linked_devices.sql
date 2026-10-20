-- M8: linked devices (a browser, a tablet). The device that registered stays primary.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS name text NOT NULL DEFAULT '';
ALTER TABLE devices ADD COLUMN IF NOT EXISTS linked boolean NOT NULL DEFAULT false;

-- Links in progress: the new device's age recipient, then the phone's sealed bundle. 5 minutes.
CREATE TABLE IF NOT EXISTS device_links (
  id         bytea PRIMARY KEY,
  recipient  text NOT NULL,
  sealed     bytea,
  expires_at timestamptz NOT NULL
);
