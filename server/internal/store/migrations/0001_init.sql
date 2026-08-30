-- 0001_init: P0 schema. Conventions: UUIDv7 TEXT ids, money = INTEGER centimes,
-- qty = INTEGER milli-units, percentages = INTEGER percent*100, timestamps ISO-8601 UTC.

CREATE TABLE settings (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE users (
  id            TEXT PRIMARY KEY,
  username      TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  full_name     TEXT NOT NULL DEFAULT '',
  role          TEXT NOT NULL DEFAULT 'cashier' CHECK (role IN ('admin','manager','cashier')),
  active        INTEGER NOT NULL DEFAULT 1,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE TABLE product_categories (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  parent_id  TEXT REFERENCES product_categories(id),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE products (
  id              TEXT PRIMARY KEY,
  barcode         TEXT UNIQUE,
  sku             TEXT,
  name            TEXT NOT NULL,
  name_ar         TEXT,
  category_id     TEXT REFERENCES product_categories(id),
  unit            TEXT NOT NULL DEFAULT 'piece',
  is_weighable    INTEGER NOT NULL DEFAULT 0,
  vat_rate        INTEGER NOT NULL DEFAULT 1900,
  purchase_price  INTEGER NOT NULL DEFAULT 0,
  price_retail    INTEGER NOT NULL DEFAULT 0,   -- TTC
  price_wholesale INTEGER,                      -- TTC, NULL = none
  min_stock_milli INTEGER NOT NULL DEFAULT 0,
  track_lots      INTEGER NOT NULL DEFAULT 0,
  active          INTEGER NOT NULL DEFAULT 1,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);
CREATE INDEX idx_products_name ON products(name);

CREATE TABLE lots (
  id          TEXT PRIMARY KEY,
  product_id  TEXT NOT NULL REFERENCES products(id),
  lot_number  TEXT NOT NULL,
  expiry_date TEXT,
  created_at  TEXT NOT NULL,
  UNIQUE (product_id, lot_number)
);

CREATE TABLE warehouses (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  is_default INTEGER NOT NULL DEFAULT 0,
  active     INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE partners (
  id           TEXT PRIMARY KEY,
  kind         TEXT NOT NULL CHECK (kind IN ('customer','supplier','both')),
  name         TEXT NOT NULL,
  phone        TEXT,
  email        TEXT,
  address      TEXT,
  nif          TEXT,
  nis          TEXT,
  rc           TEXT,
  ai           TEXT,
  credit_limit INTEGER,           -- centimes, NULL = unlimited
  notes        TEXT,
  active       INTEGER NOT NULL DEFAULT 1,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);
CREATE INDEX idx_partners_name ON partners(name);

CREATE TABLE sequences (
  doc_type    TEXT NOT NULL,
  year        INTEGER NOT NULL,
  next_number INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (doc_type, year)
);

CREATE TABLE caisse_sessions (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES users(id),
  status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  opened_at     TEXT NOT NULL,
  closed_at     TEXT,
  opening_cash  INTEGER NOT NULL DEFAULT 0,
  expected_cash INTEGER,
  counted_cash  INTEGER,
  notes         TEXT
);

CREATE TABLE documents (
  id                TEXT PRIMARY KEY,
  doc_type          TEXT NOT NULL CHECK (doc_type IN (
                      'QUOTE','SALE_TICKET','SALE_INVOICE','SALE_CREDIT_NOTE','DELIVERY_NOTE',
                      'PURCHASE_ORDER','PURCHASE_RECEIPT','PURCHASE_INVOICE','PURCHASE_CREDIT_NOTE',
                      'STOCK_ADJUSTMENT','STOCK_TRANSFER','INVENTORY_COUNT',
                      'PAYMENT_IN','PAYMENT_OUT')),
  number            TEXT UNIQUE,   -- assigned at posting
  status            TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','cancelled')),
  doc_date          TEXT NOT NULL,
  partner_id        TEXT REFERENCES partners(id),
  warehouse_id      TEXT REFERENCES warehouses(id),
  dest_warehouse_id TEXT REFERENCES warehouses(id),
  ref_document_id   TEXT REFERENCES documents(id),
  total_ht          INTEGER NOT NULL DEFAULT 0,
  total_vat         INTEGER NOT NULL DEFAULT 0,
  total_discount    INTEGER NOT NULL DEFAULT 0,
  timbre            INTEGER NOT NULL DEFAULT 0,
  total_ttc         INTEGER NOT NULL DEFAULT 0,
  amount            INTEGER NOT NULL DEFAULT 0,  -- PAYMENT_* only
  payment_method    TEXT CHECK (payment_method IS NULL OR payment_method IN ('cash','cib','edahabia','cheque','transfer','credit')),
  caisse_session_id TEXT REFERENCES caisse_sessions(id),
  notes             TEXT,
  created_by        TEXT REFERENCES users(id),
  posted_by         TEXT REFERENCES users(id),
  posted_at         TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);
CREATE INDEX idx_documents_type_status ON documents(doc_type, status);
CREATE INDEX idx_documents_partner ON documents(partner_id);
CREATE INDEX idx_documents_date ON documents(doc_date);

CREATE TABLE document_lines (
  id           TEXT PRIMARY KEY,
  document_id  TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  position     INTEGER NOT NULL DEFAULT 0,
  product_id   TEXT REFERENCES products(id),
  lot_id       TEXT REFERENCES lots(id),
  description  TEXT NOT NULL DEFAULT '',
  qty_milli    INTEGER NOT NULL,
  unit_price   INTEGER NOT NULL DEFAULT 0,  -- centimes HT
  discount_pct INTEGER NOT NULL DEFAULT 0,
  vat_rate     INTEGER NOT NULL DEFAULT 0,
  line_ht      INTEGER NOT NULL DEFAULT 0,
  line_vat     INTEGER NOT NULL DEFAULT 0,
  line_ttc     INTEGER NOT NULL DEFAULT 0,
  unit_cost    INTEGER,                     -- in: supplier cost, out: CUMP at posting
  created_at   TEXT NOT NULL
);
CREATE INDEX idx_document_lines_doc ON document_lines(document_id);

CREATE TABLE stock_ledger (
  id             TEXT PRIMARY KEY,
  product_id     TEXT NOT NULL REFERENCES products(id),
  warehouse_id   TEXT NOT NULL REFERENCES warehouses(id),
  lot_id         TEXT REFERENCES lots(id),
  qty_delta_milli INTEGER NOT NULL,
  unit_cost      INTEGER NOT NULL DEFAULT 0,
  document_id    TEXT NOT NULL REFERENCES documents(id),
  line_id        TEXT REFERENCES document_lines(id),
  created_at     TEXT NOT NULL
);
CREATE INDEX idx_stock_ledger_product ON stock_ledger(product_id, warehouse_id);
CREATE INDEX idx_stock_ledger_doc ON stock_ledger(document_id);

CREATE TABLE stock_levels (
  product_id   TEXT NOT NULL REFERENCES products(id),
  warehouse_id TEXT NOT NULL REFERENCES warehouses(id),
  qty_milli    INTEGER NOT NULL DEFAULT 0,
  avg_cost     INTEGER NOT NULL DEFAULT 0,
  updated_at   TEXT NOT NULL,
  PRIMARY KEY (product_id, warehouse_id)
);

CREATE TABLE partner_ledger (
  id          TEXT PRIMARY KEY,
  partner_id  TEXT NOT NULL REFERENCES partners(id),
  amount      INTEGER NOT NULL,   -- signed centimes, positive = partner owes us
  kind        TEXT NOT NULL CHECK (kind IN ('invoice','credit_note','payment','adjustment')),
  document_id TEXT NOT NULL REFERENCES documents(id),
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_partner_ledger_partner ON partner_ledger(partner_id);

CREATE TABLE audit_log (
  id         TEXT PRIMARY KEY,
  user_id    TEXT,
  action     TEXT NOT NULL,
  entity     TEXT NOT NULL,
  entity_id  TEXT,
  detail     TEXT,
  created_at TEXT NOT NULL
);
