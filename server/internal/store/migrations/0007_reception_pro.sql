-- Spécification écrans produit + réception (septembre 2026).
-- Produits : marque, suivi péremption séparé du suivi lot, fournisseur habituel.
ALTER TABLE products ADD COLUMN brand TEXT NOT NULL DEFAULT '';
ALTER TABLE products ADD COLUMN track_expiry INTEGER NOT NULL DEFAULT 0;
ALTER TABLE products ADD COLUMN default_supplier_id TEXT REFERENCES partners(id);
-- Les produits déjà suivis par lot attendaient implicitement une DLC.
UPDATE products SET track_expiry = track_lots;

-- Chaque code-barres porte un libellé descriptif optionnel ("… - Pomme").
ALTER TABLE product_barcodes ADD COLUMN label TEXT NOT NULL DEFAULT '';

-- Conditionnements : carton = 24 pièces. Le code-barres du carton pré-remplit
-- la quantité du pack à la réception.
CREATE TABLE packagings (
  id           TEXT PRIMARY KEY,
  product_id   TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  factor_milli INTEGER NOT NULL,        -- unités de base par pack (24 pièces = 24000)
  barcode      TEXT UNIQUE,
  created_at   TEXT NOT NULL
);
CREATE INDEX idx_packagings_product ON packagings(product_id);

-- Documents : référence fournisseur (n° BL/facture), échéance, frais d'approche,
-- motif d'ajustement, statut de commande dérivé, acceptations loguées.
ALTER TABLE documents ADD COLUMN supplier_ref TEXT;
ALTER TABLE documents ADD COLUMN due_date TEXT;
ALTER TABLE documents ADD COLUMN freight_cost INTEGER NOT NULL DEFAULT 0;
ALTER TABLE documents ADD COLUMN reason TEXT;
ALTER TABLE documents ADD COLUMN order_status TEXT;   -- BC : NULL|partial|received|closed
ALTER TABLE documents ADD COLUMN accept_short_dated INTEGER NOT NULL DEFAULT 0;
ALTER TABLE documents ADD COLUMN accept_over_receipt INTEGER NOT NULL DEFAULT 0;

-- Lignes : gratuités, lot/DLC saisis sur la ligne, conversion d'unité,
-- prix de vente appliqué à la validation, suivi du reliquat sur les BC.
ALTER TABLE document_lines ADD COLUMN qty_free_milli INTEGER NOT NULL DEFAULT 0;
ALTER TABLE document_lines ADD COLUMN lot_number TEXT;
ALTER TABLE document_lines ADD COLUMN expiry_date TEXT;
ALTER TABLE document_lines ADD COLUMN pack_factor_milli INTEGER NOT NULL DEFAULT 1000;
ALTER TABLE document_lines ADD COLUMN new_sale_price INTEGER;
ALTER TABLE document_lines ADD COLUMN qty_received_milli INTEGER NOT NULL DEFAULT 0;
ALTER TABLE document_lines ADD COLUMN qty_cancelled_milli INTEGER NOT NULL DEFAULT 0;

-- Historique des prix d'achat par fournisseur (dernier prix payé + variance).
CREATE TABLE supplier_prices (
  id          TEXT PRIMARY KEY,
  partner_id  TEXT NOT NULL REFERENCES partners(id),
  product_id  TEXT NOT NULL REFERENCES products(id),
  unit_cost   INTEGER NOT NULL,          -- coût net effectif, centimes / unité de base
  document_id TEXT REFERENCES documents(id),
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_supplier_prices ON supplier_prices(product_id, partner_id, created_at DESC);

-- Politique fournisseur : durée de vie restante minimale, tolérance de
-- sur-réception (pct x100, 500 = 5 %).
ALTER TABLE partners ADD COLUMN min_shelf_days INTEGER NOT NULL DEFAULT 0;
ALTER TABLE partners ADD COLUMN over_receipt_pct INTEGER NOT NULL DEFAULT 500;
