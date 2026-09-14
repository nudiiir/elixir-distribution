-- 0008_analytics : module analyses (adapté au retail).
-- Vues plates (jointures seules, jamais de sous-requête corrélée), index de
-- lecture, rapports enregistrés et tableaux de bord. Convention d'unités à la
-- frontière des vues : montants en centimes, quantités en millièmes d'unité,
-- valeur = qty_milli*coût/1000. Aucune écriture dans le moteur de validation.

-- ---- index de lecture ------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_document_lines_product ON document_lines(product_id);
CREATE INDEX IF NOT EXISTS idx_documents_posted_at ON documents(posted_at);
CREATE INDEX IF NOT EXISTS idx_documents_status_type_date ON documents(status, doc_type, doc_date);
CREATE INDEX IF NOT EXISTS idx_documents_created_by ON documents(created_by);
CREATE INDEX IF NOT EXISTS idx_partner_ledger_doc ON partner_ledger(document_id);
CREATE INDEX IF NOT EXISTS idx_stock_ledger_lot ON stock_ledger(lot_id);
CREATE INDEX IF NOT EXISTS idx_lots_expiry ON lots(expiry_date);

-- ---- v_sale_lines : une ligne par ligne vendue (avoirs en négatif) --------
CREATE VIEW v_sale_lines AS
SELECT d.doc_date,
       d.posted_at,
       d.id            AS document_id,
       d.number        AS document_number,
       d.doc_type,
       CASE WHEN d.doc_type = 'SALE_CREDIT_NOTE' THEN 'return' ELSE 'sale' END AS doc_kind,
       COALESCE(d.payment_method, '')  AS payment_method,
       d.warehouse_id,
       COALESCE(w.name, '')            AS warehouse_name,
       d.created_by,
       COALESCE(u.full_name, u.username, '') AS cashier_name,
       l.product_id,
       p.name          AS product_name,
       p.category_id,
       COALESCE(c.name, '')            AS category_name,
       p.brand,
       CASE WHEN d.doc_type = 'SALE_CREDIT_NOTE' THEN -1 ELSE 1 END
         * l.qty_milli * COALESCE(NULLIF(l.pack_factor_milli, 0), 1000) / 1000   AS qty_milli,
       l.unit_price,
       COALESCE(l.unit_cost, 0)        AS unit_cost,
       l.discount_pct,
       CASE WHEN d.doc_type = 'SALE_CREDIT_NOTE' THEN -1 ELSE 1 END
         * (l.unit_price * l.qty_milli * l.discount_pct / 10000 / 1000)            AS discount_amount,
       l.vat_rate,
       CASE WHEN d.doc_type = 'SALE_CREDIT_NOTE' THEN -1 ELSE 1 END * l.line_ht   AS line_ht,
       CASE WHEN d.doc_type = 'SALE_CREDIT_NOTE' THEN -1 ELSE 1 END * l.line_vat  AS line_vat,
       CASE WHEN d.doc_type = 'SALE_CREDIT_NOTE' THEN -1 ELSE 1 END * l.line_ttc  AS line_ttc,
       CASE WHEN d.doc_type = 'SALE_CREDIT_NOTE' THEN -1 ELSE 1 END
         * (l.line_ht - l.qty_milli * COALESCE(l.unit_cost, 0) / 1000)             AS margin_ht,
       l.lot_id,
       COALESCE(l.expiry_date, lo.expiry_date) AS expiry_date,
       d.partner_id,
       COALESCE(pa.name, '')           AS partner_name
  FROM document_lines l
  JOIN documents d   ON d.id = l.document_id
  JOIN products  p   ON p.id = l.product_id
  LEFT JOIN product_categories c ON c.id = p.category_id
  LEFT JOIN warehouses w ON w.id = d.warehouse_id
  LEFT JOIN users u      ON u.id = d.created_by
  LEFT JOIN partners pa  ON pa.id = d.partner_id
  LEFT JOIN lots lo      ON lo.id = l.lot_id
 WHERE d.status = 'posted'
   AND d.doc_type IN ('SALE_TICKET', 'SALE_INVOICE', 'SALE_CREDIT_NOTE');

-- ---- v_purchase_lines : réceptions + factures sans réception liée --------
CREATE VIEW v_purchase_lines AS
SELECT d.doc_date,
       d.posted_at,
       d.id            AS document_id,
       d.number        AS document_number,
       d.doc_type,
       CASE WHEN d.doc_type = 'PURCHASE_CREDIT_NOTE' THEN 'return' ELSE 'purchase' END AS doc_kind,
       d.partner_id    AS supplier_id,
       COALESCE(pa.name, '') AS supplier_name,
       d.warehouse_id,
       COALESCE(w.name, '')  AS warehouse_name,
       d.supplier_ref,
       l.product_id,
       p.name          AS product_name,
       p.category_id,
       COALESCE(c.name, '')  AS category_name,
       p.brand,
       CASE WHEN d.doc_type = 'PURCHASE_CREDIT_NOTE' THEN -1 ELSE 1 END
         * (l.qty_milli + l.qty_free_milli) * COALESCE(NULLIF(l.pack_factor_milli, 0), 1000) / 1000 AS qty_milli,
       CASE WHEN d.doc_type = 'PURCHASE_CREDIT_NOTE' THEN -1 ELSE 1 END
         * l.qty_free_milli * COALESCE(NULLIF(l.pack_factor_milli, 0), 1000) / 1000                 AS qty_free_milli,
       COALESCE(l.unit_cost, l.unit_price) AS unit_cost,
       CASE WHEN d.doc_type = 'PURCHASE_CREDIT_NOTE' THEN -1 ELSE 1 END * l.line_ht  AS line_ht,
       CASE WHEN d.doc_type = 'PURCHASE_CREDIT_NOTE' THEN -1 ELSE 1 END * l.line_ttc AS line_ttc,
       l.lot_id,
       COALESCE(l.expiry_date, lo.expiry_date) AS expiry_date
  FROM document_lines l
  JOIN documents d   ON d.id = l.document_id
  JOIN products  p   ON p.id = l.product_id
  LEFT JOIN product_categories c ON c.id = p.category_id
  LEFT JOIN partners pa ON pa.id = d.partner_id
  LEFT JOIN warehouses w ON w.id = d.warehouse_id
  LEFT JOIN lots lo     ON lo.id = l.lot_id
 WHERE d.status = 'posted'
   AND (d.doc_type = 'PURCHASE_RECEIPT'
     OR d.doc_type = 'PURCHASE_CREDIT_NOTE'
     OR (d.doc_type = 'PURCHASE_INVOICE' AND d.ref_document_id IS NULL));

-- ---- v_stock_movements : le journal de stock, lu directement --------------
CREATE VIEW v_stock_movements AS
SELECT d.doc_date        AS movement_date,
       s.created_at      AS movement_at,
       s.product_id,
       p.name            AS product_name,
       p.category_id,
       COALESCE(c.name, '') AS category_name,
       p.brand,
       s.warehouse_id,
       COALESCE(w.name, '') AS warehouse_name,
       s.qty_delta_milli,
       s.unit_cost,
       s.qty_delta_milli * s.unit_cost / 1000 AS movement_value,
       CASE WHEN s.qty_delta_milli >= 0 THEN 'in' ELSE 'out' END AS direction,
       d.doc_type,
       d.id              AS document_id,
       d.number          AS document_number,
       s.lot_id,
       lo.expiry_date
  FROM stock_ledger s
  JOIN documents d  ON d.id = s.document_id
  JOIN products  p  ON p.id = s.product_id
  LEFT JOIN product_categories c ON c.id = p.category_id
  LEFT JOIN warehouses w ON w.id = s.warehouse_id
  LEFT JOIN lots lo ON lo.id = s.lot_id;

-- ---- v_stock_snapshot : état actuel (les figures de péremption sont un
-- gabarit moteur avec horizon paramétré, pas une vue) ------------------------
CREATE VIEW v_stock_snapshot AS
SELECT sl.product_id,
       p.name            AS product_name,
       p.category_id,
       COALESCE(c.name, '') AS category_name,
       p.brand,
       p.default_supplier_id AS supplier_id,
       COALESCE(sp.name, '') AS supplier_name,
       sl.warehouse_id,
       COALESCE(w.name, '')  AS warehouse_name,
       sl.qty_milli,
       sl.avg_cost,
       sl.qty_milli * sl.avg_cost / 1000 AS stock_value,
       p.price_retail,
       sl.qty_milli * p.price_retail / 1000 AS retail_value,
       p.min_stock_milli,
       (p.min_stock_milli > 0 AND sl.qty_milli < p.min_stock_milli) AS below_min,
       (sl.qty_milli <= 0) AS out_of_stock
  FROM stock_levels sl
  JOIN products p ON p.id = sl.product_id
  LEFT JOIN product_categories c ON c.id = p.category_id
  LEFT JOIN warehouses w ON w.id = sl.warehouse_id
  LEFT JOIN partners sp ON sp.id = p.default_supplier_id
 WHERE p.active = 1;

-- ---- v_partner_ledger : mouvements de créances / dettes ---------------------
CREATE VIEW v_partner_ledger AS
SELECT d.doc_date        AS movement_date,
       pl.created_at     AS movement_at,
       pl.partner_id,
       pa.name           AS partner_name,
       pa.kind           AS partner_kind,
       pl.amount,
       pl.kind           AS ledger_kind,
       d.doc_type,
       d.id              AS document_id,
       d.number          AS document_number
  FROM partner_ledger pl
  JOIN partners pa ON pa.id = pl.partner_id
  JOIN documents d ON d.id = pl.document_id;

-- ---- rapports enregistrés et tableaux de bord -----------------------------
CREATE TABLE saved_reports (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  spec_json     TEXT NOT NULL,
  spec_version  INTEGER NOT NULL DEFAULT 1,
  chart_type    TEXT NOT NULL DEFAULT 'auto',
  encoding_json TEXT NOT NULL DEFAULT '{}',
  owner_id      TEXT REFERENCES users(id),
  is_shared     INTEGER NOT NULL DEFAULT 0,
  is_default    INTEGER NOT NULL DEFAULT 0,   -- livré avec le logiciel
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
CREATE INDEX idx_saved_reports_owner ON saved_reports(owner_id);

CREATE TABLE dashboards (
  id                  TEXT PRIMARY KEY,
  name                TEXT NOT NULL,
  owner_id            TEXT REFERENCES users(id),
  is_shared           INTEGER NOT NULL DEFAULT 0,
  is_default          INTEGER NOT NULL DEFAULT 0,
  layout_json         TEXT NOT NULL DEFAULT '[]',   -- [{report_id, x, y, w, h}]
  global_range_json   TEXT NOT NULL DEFAULT '{"type":"this_month"}',
  global_warehouse_id TEXT,
  created_at          TEXT NOT NULL,
  updated_at          TEXT NOT NULL
);
