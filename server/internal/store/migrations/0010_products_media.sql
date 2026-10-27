-- Products: type (a service does not move stock) and photos.
ALTER TABLE products ADD COLUMN kind TEXT NOT NULL DEFAULT 'standard';
-- image_rev changes on every photo add/removal: it serves as a
-- client-side cache key (0 = no photo).
ALTER TABLE products ADD COLUMN image_rev INTEGER NOT NULL DEFAULT 0;

CREATE TABLE product_images (
  id         TEXT PRIMARY KEY,
  product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  position   INTEGER NOT NULL DEFAULT 0,   -- 0 = main photo
  mime       TEXT NOT NULL,
  data       BLOB NOT NULL,                -- original image (max 2 MB)
  thumb      BLOB NOT NULL,                -- thumbnail 160 px (PNG/JPEG)
  created_at TEXT NOT NULL
);
CREATE INDEX idx_product_images_product ON product_images(product_id, position);
