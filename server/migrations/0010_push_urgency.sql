-- Whether a queued payload is worth a notification: urgent ones wake the device at high
-- priority; the rest (receipts, commits) at normal priority, and never through web push.
ALTER TABLE queue ADD COLUMN IF NOT EXISTS urgent boolean NOT NULL DEFAULT true;
