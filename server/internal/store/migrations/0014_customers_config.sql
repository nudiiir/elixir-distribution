-- Customers and loyalty (« Clients et fidélité » settings).
--
-- Customer groups: a price tier (retail / semi-wholesale) and a default discount
-- applied when the customer is picked on a sale.
CREATE TABLE customer_groups (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL UNIQUE,
  price_level  TEXT NOT NULL DEFAULT 'retail' CHECK (price_level IN ('retail','wholesale')),
  discount_pct INTEGER NOT NULL DEFAULT 0 CHECK (discount_pct >= 0 AND discount_pct <= 10000), -- pct x100
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);

ALTER TABLE partners ADD COLUMN group_id TEXT REFERENCES customer_groups(id);
CREATE INDEX idx_partners_group ON partners(group_id);

-- Loyalty points: immutable ledger, like any other movement. A customer's
-- balance is the sum of their rows.
--   earn   : points earned when a sale is posted (positive)
--   redeem : points spent at the till (negative)
--   void   : cancellation (document cancelled, or redemption cancelled via ref_id)
--   adjust : manual correction
CREATE TABLE loyalty_ledger (
  id          TEXT PRIMARY KEY,
  partner_id  TEXT NOT NULL REFERENCES partners(id),
  points      INTEGER NOT NULL,
  document_id TEXT REFERENCES documents(id),
  kind        TEXT NOT NULL CHECK (kind IN ('earn','redeem','void','adjust')),
  ref_id      TEXT REFERENCES loyalty_ledger(id),
  note        TEXT,
  created_by  TEXT REFERENCES users(id),
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_loyalty_partner ON loyalty_ledger(partner_id, created_at);
CREATE INDEX idx_loyalty_document ON loyalty_ledger(document_id);
