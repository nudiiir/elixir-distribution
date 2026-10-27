-- Product + receipt screens specification (September 2026).
-- Products: brand, expiry tracking separate from lot tracking, usual supplier.
ALTER TABLE products ADD COLUMN brand TEXT NOT NULL DEFAULT '';
ALTER TABLE products ADD COLUMN track_expiry INTEGER NOT NULL DEFAULT 0;
ALTER TABLE products ADD COLUMN default_supplier_id TEXT REFERENCES partners(id);
-- Products already tracked by lot implicitly expected an expiry date.
UPDATE products SET track_expiry = track_lots;

-- Each barcode carries an optional descriptive label ("… - Pomme").
ALTER TABLE product_barcodes ADD COLUMN label TEXT NOT NULL DEFAULT '';

-- Packagings: carton = 24 pieces. The carton's barcode pre-fills
-- the pack quantity on receipt.
CREATE TABLE packagings (
  id           TEXT PRIMARY KEY,
  product_id   TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  factor_milli INTEGER NOT NULL,        -- base units per pack (24 pieces = 24000)
  barcode      TEXT UNIQUE,
  created_at   TEXT NOT NULL
);
CREATE INDEX idx_packagings_product ON packagings(product_id);

-- Documents: supplier reference (delivery note/invoice no.), due date, landed costs,
-- adjustment reason, derived order status, logged acceptances.
ALTER TABLE documents ADD COLUMN supplier_ref TEXT;
ALTER TABLE documents ADD COLUMN due_date TEXT;
ALTER TABLE documents ADD COLUMN freight_cost INTEGER NOT NULL DEFAULT 0;
ALTER TABLE documents ADD COLUMN reason TEXT;
ALTER TABLE documents ADD COLUMN order_status TEXT;   -- PO: NULL|partial|received|closed
ALTER TABLE documents ADD COLUMN accept_short_dated INTEGER NOT NULL DEFAULT 0;
ALTER TABLE documents ADD COLUMN accept_over_receipt INTEGER NOT NULL DEFAULT 0;

-- Lines: free units, lot/expiry entered on the line, unit conversion,
-- sale price applied on posting, tracking of the outstanding quantity on POs.
ALTER TABLE document_lines ADD COLUMN qty_free_milli INTEGER NOT NULL DEFAULT 0;
ALTER TABLE document_lines ADD COLUMN lot_number TEXT;
ALTER TABLE document_lines ADD COLUMN expiry_date TEXT;
ALTER TABLE document_lines ADD COLUMN pack_factor_milli INTEGER NOT NULL DEFAULT 1000;
ALTER TABLE document_lines ADD COLUMN new_sale_price INTEGER;
ALTER TABLE document_lines ADD COLUMN qty_received_milli INTEGER NOT NULL DEFAULT 0;
ALTER TABLE document_lines ADD COLUMN qty_cancelled_milli INTEGER NOT NULL DEFAULT 0;

-- Purchase price history per supplier (last price paid + variance).
CREATE TABLE supplier_prices (
  id          TEXT PRIMARY KEY,
  partner_id  TEXT NOT NULL REFERENCES partners(id),
  product_id  TEXT NOT NULL REFERENCES products(id),
  unit_cost   INTEGER NOT NULL,          -- effective net cost, centimes / base unit
  document_id TEXT REFERENCES documents(id),
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_supplier_prices ON supplier_prices(product_id, partner_id, created_at DESC);

-- Supplier policy: minimum remaining shelf life, tolerance for
-- over-receipt (pct x100, 500 = 5 %).
ALTER TABLE partners ADD COLUMN min_shelf_days INTEGER NOT NULL DEFAULT 0;
ALTER TABLE partners ADD COLUMN over_receipt_pct INTEGER NOT NULL DEFAULT 500;
