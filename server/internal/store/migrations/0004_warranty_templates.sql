-- Warranty duration sold with a product (0 = none).
ALTER TABLE products ADD COLUMN warranty_months INTEGER NOT NULL DEFAULT 0;

-- Printable document designs (barcode labels, invoices, warranty papers),
-- edited in the app's designer. body is the layout JSON.
CREATE TABLE templates (
    id         TEXT PRIMARY KEY,
    kind       TEXT NOT NULL CHECK (kind IN ('label', 'invoice', 'warranty')),
    name       TEXT NOT NULL,
    lang       TEXT NOT NULL DEFAULT 'fr' CHECK (lang IN ('fr', 'ar')),
    body       TEXT NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX idx_templates_kind ON templates (kind, is_default);
