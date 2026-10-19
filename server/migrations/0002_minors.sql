-- M7: accounts of people under 18 aren't found by @username search.
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS minor boolean NOT NULL DEFAULT false;
-- SHA-256 of a minor's current contact-link secret: the link still works for whoever was given it.
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS minor_link_hash bytea;
