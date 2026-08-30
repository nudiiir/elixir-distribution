-- 0002: per-user permission overrides (JSON {perm: bool}), merged over role defaults.
ALTER TABLE users ADD COLUMN perms TEXT NOT NULL DEFAULT '{}';
