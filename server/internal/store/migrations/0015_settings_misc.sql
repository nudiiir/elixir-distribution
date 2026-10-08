-- 0015_settings_misc: settings work — depot address/phone, company logo.

ALTER TABLE warehouses ADD COLUMN address TEXT NOT NULL DEFAULT '';
ALTER TABLE warehouses ADD COLUMN phone TEXT NOT NULL DEFAULT '';

-- One row (id = 1): the logo printed on documents. Kept out of the settings
-- table so GET /settings stays small.
CREATE TABLE company_logo (
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  mime       TEXT NOT NULL,
  data       BLOB NOT NULL,
  updated_at TEXT NOT NULL
);
