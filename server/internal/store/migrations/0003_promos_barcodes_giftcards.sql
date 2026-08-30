-- 0003: promotions, extra barcodes, product variants, gift cards.

-- Promotions: a temporary selling price (TTC centimes) between two dates.
ALTER TABLE products ADD COLUMN promo_price INTEGER;
ALTER TABLE products ADD COLUMN promo_start TEXT;  -- YYYY-MM-DD inclusive
ALTER TABLE products ADD COLUMN promo_end TEXT;    -- YYYY-MM-DD inclusive

-- Variants: "Coca 1L" / "Coca 2L" are separate sellable products linked to a
-- parent, each with its own barcode, price and stock.
ALTER TABLE products ADD COLUMN parent_product_id TEXT REFERENCES products(id);
ALTER TABLE products ADD COLUMN variant_label TEXT;

-- A product may carry several barcodes (old/new packaging, multipacks).
CREATE TABLE product_barcodes (
  barcode    TEXT PRIMARY KEY,
  product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_product_barcodes_product ON product_barcodes(product_id);

-- Gift cards: sold for cash, redeemed later. Redemptions are immutable rows,
-- like every other money movement in this schema.
CREATE TABLE gift_cards (
  id             TEXT PRIMARY KEY,
  code           TEXT NOT NULL UNIQUE,
  initial_amount INTEGER NOT NULL,   -- centimes
  balance        INTEGER NOT NULL,
  status         TEXT NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','depleted','cancelled')),
  expires_at     TEXT,               -- YYYY-MM-DD, NULL = never
  notes          TEXT,
  created_by     TEXT REFERENCES users(id),
  created_at     TEXT NOT NULL
);

CREATE TABLE gift_card_uses (
  id          TEXT PRIMARY KEY,
  card_id     TEXT NOT NULL REFERENCES gift_cards(id),
  document_id TEXT REFERENCES documents(id),
  amount      INTEGER NOT NULL,      -- positive = redeemed, negative = refund
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_gift_card_uses_card ON gift_card_uses(card_id);
