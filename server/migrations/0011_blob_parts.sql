-- Large attachments go up in parts, each its own object (<blob id>.<n>), so an upload resumes
-- where it stopped. parts counts those received; 0 is a blob uploaded whole, as older apps do.
ALTER TABLE attachments ADD COLUMN IF NOT EXISTS parts int NOT NULL DEFAULT 0;
