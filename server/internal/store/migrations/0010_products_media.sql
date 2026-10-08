-- Produits : type (un service ne bouge pas le stock) et photos.
ALTER TABLE products ADD COLUMN kind TEXT NOT NULL DEFAULT 'standard';
-- image_rev change à chaque ajout/suppression de photo : il sert de clé de
-- cache côté client (0 = pas de photo).
ALTER TABLE products ADD COLUMN image_rev INTEGER NOT NULL DEFAULT 0;

CREATE TABLE product_images (
  id         TEXT PRIMARY KEY,
  product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  position   INTEGER NOT NULL DEFAULT 0,   -- 0 = photo principale
  mime       TEXT NOT NULL,
  data       BLOB NOT NULL,                -- image d'origine (max 2 Mo)
  thumb      BLOB NOT NULL,                -- vignette 160 px (PNG/JPEG)
  created_at TEXT NOT NULL
);
CREATE INDEX idx_product_images_product ON product_images(product_id, position);
