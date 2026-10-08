-- Clients et fidélité (réglages « Clients et fidélité »).
--
-- Groupes de clients : un tarif (détail / demi-gros) et une remise par défaut
-- appliqués quand le client est choisi sur une vente.
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

-- Points de fidélité : journal immuable, comme tout autre mouvement. Le solde
-- d'un client est la somme de ses lignes.
--   earn   : points gagnés à la validation d'une vente (positif)
--   redeem : points utilisés à la caisse (négatif)
--   void   : annulation (document annulé, ou utilisation annulée via ref_id)
--   adjust : correction manuelle
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
