-- Serialized inventory (IMEI / serial no.), SAV repairs, installment plans,
-- wholesale price tier, and DLC quantities on lots.

ALTER TABLE products ADD COLUMN track_serials INTEGER NOT NULL DEFAULT 0;
ALTER TABLE partners ADD COLUMN price_level TEXT NOT NULL DEFAULT 'retail';

-- Informational DLC quantity — the stock ledger stays the quantity authority.
ALTER TABLE lots ADD COLUMN qty_milli INTEGER NOT NULL DEFAULT 0;

CREATE TABLE product_units (
    id              TEXT PRIMARY KEY,
    product_id      TEXT NOT NULL REFERENCES products(id),
    serial          TEXT NOT NULL UNIQUE,
    status          TEXT NOT NULL DEFAULT 'in_stock'
                    CHECK (status IN ('in_stock','sold','returned','repair','scrapped')),
    is_used         INTEGER NOT NULL DEFAULT 0,   -- trade-in / second-hand
    purchase_doc_id TEXT REFERENCES documents(id),
    sale_doc_id     TEXT REFERENCES documents(id),
    partner_id      TEXT REFERENCES partners(id), -- buyer, set at sale
    notes           TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);
CREATE INDEX idx_units_product ON product_units(product_id, status);

CREATE TABLE repairs (
    id             TEXT PRIMARY KEY,
    number         TEXT UNIQUE,
    partner_id     TEXT REFERENCES partners(id),
    customer_name  TEXT NOT NULL,
    customer_phone TEXT,
    device         TEXT NOT NULL,
    serial         TEXT,
    fault          TEXT NOT NULL,
    deposit        INTEGER NOT NULL DEFAULT 0,
    quote          INTEGER,
    status         TEXT NOT NULL DEFAULT 'received'
                   CHECK (status IN ('received','in_progress','ready','returned','cancelled')),
    notes          TEXT,
    created_by     TEXT REFERENCES users(id),
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
);
CREATE INDEX idx_repairs_status ON repairs(status);

CREATE TABLE installment_plans (
    id          TEXT PRIMARY KEY,
    partner_id  TEXT NOT NULL REFERENCES partners(id),
    document_id TEXT REFERENCES documents(id),
    total       INTEGER NOT NULL,
    months      INTEGER NOT NULL,
    start_date  TEXT NOT NULL,
    notes       TEXT,
    created_at  TEXT NOT NULL
);
CREATE INDEX idx_plans_partner ON installment_plans(partner_id);

CREATE TABLE installment_dues (
    id       TEXT PRIMARY KEY,
    plan_id  TEXT NOT NULL REFERENCES installment_plans(id) ON DELETE CASCADE,
    due_date TEXT NOT NULL,
    amount   INTEGER NOT NULL,
    paid     INTEGER NOT NULL DEFAULT 0,
    paid_at  TEXT
);
CREATE INDEX idx_dues_plan ON installment_dues(plan_id);
