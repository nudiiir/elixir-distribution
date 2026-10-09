-- 0016_distribution : distribution (grossiste → commerces et professionnels).
--   * Commandes clients (« Commandes clients ») : saisie bureau / téléphone /
--     WhatsApp / commercial / boutique web, validation avec contrôle du crédit,
--     préparation par lot (FEFO), BL, livraison, facturation, reliquats.
--   * Tarifs : prix spéciaux client / groupe, promotions (UG, remise
--     quantitative), quotas par client.
--   * Livraisons : tournées, véhicules, arrêts, encaissement à la livraison.
--   * Fiche client distribution (type, statut CRM, commercial, tournée…).
-- Additive uniquement : aucune table existante n'est reconstruite et la
-- contrainte CHECK de documents.doc_type est inchangée (les commandes vivent
-- dans leurs propres tables ; BL, factures et règlements restent des documents).
-- Conventions : ids UUIDv7 TEXT, montants en centimes, quantités en millièmes,
-- pourcentages ×100, horodatages ISO-8601 UTC, dates métier YYYY-MM-DD.

-- ---- Tournées et véhicules (référencés par les partenaires) ----------------
CREATE TABLE vehicles (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  plate        TEXT NOT NULL DEFAULT '',
  capacity_kg  INTEGER NOT NULL DEFAULT 0,
  active       INTEGER NOT NULL DEFAULT 1,
  notes        TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);

CREATE TABLE delivery_routes (
  id                     TEXT PRIMARY KEY,
  name                   TEXT NOT NULL UNIQUE,
  wilayas_json           TEXT NOT NULL DEFAULT '[]',   -- ["16","09"] ou noms
  communes_json          TEXT NOT NULL DEFAULT '[]',
  weekdays_json          TEXT NOT NULL DEFAULT '[]',   -- ISO : 1 = lundi … 7 = dimanche
  default_driver_user_id TEXT REFERENCES users(id),
  default_driver_name    TEXT NOT NULL DEFAULT '',
  default_vehicle_id     TEXT REFERENCES vehicles(id),
  active                 INTEGER NOT NULL DEFAULT 1,
  notes                  TEXT NOT NULL DEFAULT '',
  created_at             TEXT NOT NULL,
  updated_at             TEXT NOT NULL
);

-- ---- Fiche client distribution / CRM -----------------------------------------
ALTER TABLE partners ADD COLUMN client_type TEXT NOT NULL DEFAULT 'other'
  CHECK (client_type IN ('supermarket','restaurant','hotel','wholesaler','retailer','individual','other'));
ALTER TABLE partners ADD COLUMN crm_status TEXT NOT NULL DEFAULT 'active'
  CHECK (crm_status IN ('prospect','active','dormant','blocked'));
ALTER TABLE partners ADD COLUMN rep_user_id TEXT REFERENCES users(id);
ALTER TABLE partners ADD COLUMN route_id TEXT REFERENCES delivery_routes(id);
ALTER TABLE partners ADD COLUMN wilaya TEXT NOT NULL DEFAULT '';
ALTER TABLE partners ADD COLUMN commune TEXT NOT NULL DEFAULT '';
ALTER TABLE partners ADD COLUMN latitude REAL;
ALTER TABLE partners ADD COLUMN longitude REAL;
ALTER TABLE partners ADD COLUMN opening_hours TEXT NOT NULL DEFAULT '';
ALTER TABLE partners ADD COLUMN license_no TEXT NOT NULL DEFAULT '';
ALTER TABLE partners ADD COLUMN whatsapp TEXT NOT NULL DEFAULT '';
ALTER TABLE partners ADD COLUMN website TEXT NOT NULL DEFAULT '';
ALTER TABLE partners ADD COLUMN source TEXT NOT NULL DEFAULT 'manual'
  CHECK (source IN ('manual','web','import','rep','portal'));
-- Délai de paiement (jours) des factures issues des commandes ; NULL = réglage
-- « default_payment_days » (30 par défaut).
ALTER TABLE partners ADD COLUMN payment_terms_days INTEGER;
CREATE INDEX idx_partners_rep ON partners(rep_user_id);
CREATE INDEX idx_partners_route ON partners(route_id);
CREATE INDEX idx_partners_wilaya ON partners(wilaya);
CREATE INDEX idx_partners_phone ON partners(phone);

-- ---- Commandes clients -------------------------------------------------------
-- Statuts : new → validated → preparing → ready → shipping → delivered →
-- invoiced ; cancelled depuis tout statut antérieur à delivered.
CREATE TABLE customer_orders (
  id                TEXT PRIMARY KEY,
  number            TEXT NOT NULL UNIQUE,           -- CC-2026-000001 (numérotation CUSTOMER_ORDER)
  order_date        TEXT NOT NULL,                  -- YYYY-MM-DD
  partner_id        TEXT NOT NULL REFERENCES partners(id),
  source            TEXT NOT NULL DEFAULT 'manual'
                    CHECK (source IN ('manual','phone','whatsapp','rep','web','portal')),
  external_ref      TEXT,                           -- id de la commande sur la boutique web
  external_number   TEXT,                           -- n° affiché par la boutique web
  status            TEXT NOT NULL DEFAULT 'new'
                    CHECK (status IN ('new','validated','preparing','ready','shipping','delivered','invoiced','cancelled')),
  is_partial        INTEGER NOT NULL DEFAULT 0,     -- livrée en partie (reliquat ou rupture)
  has_backorder     INTEGER NOT NULL DEFAULT 0,     -- au moins une ligne en reliquat
  warehouse_id      TEXT NOT NULL REFERENCES warehouses(id),
  rep_user_id       TEXT REFERENCES users(id),
  route_id          TEXT REFERENCES delivery_routes(id),
  priority          INTEGER NOT NULL DEFAULT 0 CHECK (priority IN (0,1,2)), -- normale | haute | urgente
  payment_mode      TEXT NOT NULL DEFAULT 'account' CHECK (payment_mode IN ('account','cod')),
  requested_date    TEXT,
  delivery_address  TEXT NOT NULL DEFAULT '',
  wilaya            TEXT NOT NULL DEFAULT '',
  commune           TEXT NOT NULL DEFAULT '',
  contact_name      TEXT NOT NULL DEFAULT '',
  contact_phone     TEXT NOT NULL DEFAULT '',
  notes             TEXT NOT NULL DEFAULT '',       -- imprimée / visible client
  internal_notes    TEXT NOT NULL DEFAULT '',
  total_ht          INTEGER NOT NULL DEFAULT 0,
  total_vat         INTEGER NOT NULL DEFAULT 0,
  total_discount    INTEGER NOT NULL DEFAULT 0,
  shipping_fee      INTEGER NOT NULL DEFAULT 0,     -- TTC, hors lignes produit
  extra_discount    INTEGER NOT NULL DEFAULT 0,     -- TTC (code promo web…), hors lignes
  promo_code        TEXT NOT NULL DEFAULT '',
  total_ttc         INTEGER NOT NULL DEFAULT 0,     -- lignes + frais − remise globale
  cancel_reason     TEXT NOT NULL DEFAULT '',
  credit_override   INTEGER NOT NULL DEFAULT 0,     -- validée malgré l'alerte crédit
  delivery_note_id  TEXT REFERENCES documents(id),
  invoice_id        TEXT REFERENCES documents(id),
  payment_id        TEXT REFERENCES documents(id),  -- encaissement à la livraison (hors tournée)
  web_status_dirty  INTEGER NOT NULL DEFAULT 0,     -- statut à renvoyer à la boutique
  created_by        TEXT REFERENCES users(id),
  validated_by      TEXT REFERENCES users(id),
  validated_at      TEXT,
  delivered_at      TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_customer_orders_ext ON customer_orders(source, external_ref) WHERE external_ref IS NOT NULL;
CREATE INDEX idx_customer_orders_status ON customer_orders(status, order_date);
CREATE INDEX idx_customer_orders_partner ON customer_orders(partner_id, order_date);
CREATE INDEX idx_customer_orders_rep ON customer_orders(rep_user_id);
CREATE INDEX idx_customer_orders_dirty ON customer_orders(web_status_dirty) WHERE web_status_dirty = 1;

CREATE TABLE customer_order_lines (
  id                          TEXT PRIMARY KEY,
  order_id                    TEXT NOT NULL REFERENCES customer_orders(id) ON DELETE CASCADE,
  position                    INTEGER NOT NULL DEFAULT 0,
  product_id                  TEXT NOT NULL REFERENCES products(id),
  description                 TEXT NOT NULL DEFAULT '',
  qty_ordered_milli           INTEGER NOT NULL DEFAULT 0,
  qty_validated_milli         INTEGER NOT NULL DEFAULT 0,  -- engagé sur cette commande
  qty_prepared_milli          INTEGER NOT NULL DEFAULT 0,  -- somme des prélèvements (payant + UG)
  qty_delivered_milli         INTEGER NOT NULL DEFAULT 0,  -- payant + UG parti sur le BL
  qty_backorder_milli         INTEGER NOT NULL DEFAULT 0,  -- reliquat en attente de stock
  qty_free_milli              INTEGER NOT NULL DEFAULT 0,  -- unités gratuites (UG)
  unit_price                  INTEGER NOT NULL DEFAULT 0,  -- centimes HT
  discount_pct                INTEGER NOT NULL DEFAULT 0,
  vat_rate                    INTEGER NOT NULL DEFAULT 0,
  line_ht                     INTEGER NOT NULL DEFAULT 0,
  line_vat                    INTEGER NOT NULL DEFAULT 0,
  line_ttc                    INTEGER NOT NULL DEFAULT 0,
  price_source                TEXT NOT NULL DEFAULT 'retail',
  promo_rule_id               TEXT,
  substituted_from_line_id    TEXT REFERENCES customer_order_lines(id),
  substituted_from_product_id TEXT REFERENCES products(id),
  backorder_from_line_id      TEXT REFERENCES customer_order_lines(id),
  notes                       TEXT NOT NULL DEFAULT '',
  created_at                  TEXT NOT NULL,
  updated_at                  TEXT NOT NULL
);
CREATE INDEX idx_customer_order_lines_order ON customer_order_lines(order_id, position);
CREATE INDEX idx_customer_order_lines_product ON customer_order_lines(product_id);
CREATE INDEX idx_customer_order_lines_backorder ON customer_order_lines(product_id) WHERE qty_backorder_milli > 0;

CREATE TABLE customer_order_events (
  id          TEXT PRIMARY KEY,
  order_id    TEXT NOT NULL REFERENCES customer_orders(id) ON DELETE CASCADE,
  action      TEXT NOT NULL,          -- create | update | validate | pick | ready | ship | …
  from_status TEXT,
  to_status   TEXT,
  user_id     TEXT REFERENCES users(id),
  note        TEXT NOT NULL DEFAULT '',
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_customer_order_events_order ON customer_order_events(order_id, created_at);

-- Prélèvements de préparation : ligne → lot, quantité (payant + UG confondus).
CREATE TABLE customer_order_picks (
  id         TEXT PRIMARY KEY,
  order_id   TEXT NOT NULL REFERENCES customer_orders(id) ON DELETE CASCADE,
  line_id    TEXT NOT NULL REFERENCES customer_order_lines(id) ON DELETE CASCADE,
  lot_id     TEXT REFERENCES lots(id),
  qty_milli  INTEGER NOT NULL CHECK (qty_milli > 0),
  barcode    TEXT NOT NULL DEFAULT '',
  picked_by  TEXT REFERENCES users(id),
  created_at TEXT NOT NULL
);
CREATE INDEX idx_customer_order_picks_line ON customer_order_picks(line_id);
CREATE INDEX idx_customer_order_picks_lot ON customer_order_picks(lot_id);

-- ---- Tarifs --------------------------------------------------------------------
-- Prix spécial HT par client OU par groupe de clients, avec quantité minimale
-- (prix par palier) et période de validité optionnelles.
CREATE TABLE customer_prices (
  id            TEXT PRIMARY KEY,
  partner_id    TEXT REFERENCES partners(id) ON DELETE CASCADE,
  group_id      TEXT REFERENCES customer_groups(id) ON DELETE CASCADE,
  product_id    TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  price_ht      INTEGER NOT NULL CHECK (price_ht >= 0),
  min_qty_milli INTEGER NOT NULL DEFAULT 0,
  start_date    TEXT,
  end_date      TEXT,
  notes         TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  CHECK ((partner_id IS NULL) <> (group_id IS NULL))
);
CREATE INDEX idx_customer_prices_product ON customer_prices(product_id);
CREATE INDEX idx_customer_prices_partner ON customer_prices(partner_id);
CREATE INDEX idx_customer_prices_group ON customer_prices(group_id);

-- Promotions : UG « N achetés + M gratuits » (free_goods) ou remise à partir
-- de N unités (qty_discount), sur un produit, une catégorie, une marque ou tout.
CREATE TABLE promo_rules (
  id             TEXT PRIMARY KEY,
  name           TEXT NOT NULL,
  scope          TEXT NOT NULL CHECK (scope IN ('product','category','brand','all')),
  product_id     TEXT REFERENCES products(id) ON DELETE CASCADE,
  category_id    TEXT REFERENCES product_categories(id) ON DELETE CASCADE,
  brand          TEXT NOT NULL DEFAULT '',
  type           TEXT NOT NULL CHECK (type IN ('free_goods','qty_discount')),
  min_qty_milli  INTEGER NOT NULL CHECK (min_qty_milli > 0),  -- N
  free_qty_milli INTEGER NOT NULL DEFAULT 0,                  -- M (free_goods)
  discount_pct   INTEGER NOT NULL DEFAULT 0 CHECK (discount_pct >= 0 AND discount_pct <= 10000),
  start_date     TEXT,
  end_date       TEXT,
  audience       TEXT NOT NULL DEFAULT 'all' CHECK (audience IN ('all','group','partner')),
  group_id       TEXT REFERENCES customer_groups(id) ON DELETE CASCADE,
  partner_id     TEXT REFERENCES partners(id) ON DELETE CASCADE,
  channel        TEXT NOT NULL DEFAULT 'all' CHECK (channel IN ('all','desk','web')),
  active         INTEGER NOT NULL DEFAULT 1,
  notes          TEXT NOT NULL DEFAULT '',
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);
CREATE INDEX idx_promo_rules_active ON promo_rules(active, type);

-- Quotas : quantité maximale par client et par période pour un produit rare.
-- partner_id NULL = s'applique à chaque client.
CREATE TABLE product_quotas (
  id            TEXT PRIMARY KEY,
  product_id    TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  partner_id    TEXT REFERENCES partners(id) ON DELETE CASCADE,
  max_qty_milli INTEGER NOT NULL CHECK (max_qty_milli > 0),
  period        TEXT NOT NULL CHECK (period IN ('day','week','month')),
  active        INTEGER NOT NULL DEFAULT 1,
  notes         TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
CREATE INDEX idx_product_quotas_product ON product_quotas(product_id);

-- ---- Livraisons -------------------------------------------------------------------
CREATE TABLE delivery_runs (
  id              TEXT PRIMARY KEY,
  run_date        TEXT NOT NULL,
  route_id        TEXT REFERENCES delivery_routes(id),
  driver_user_id  TEXT REFERENCES users(id),
  driver_name     TEXT NOT NULL DEFAULT '',
  vehicle_id      TEXT REFERENCES vehicles(id),
  status          TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned','out','closed','cancelled')),
  departed_at     TEXT,
  closed_at       TEXT,
  closed_by       TEXT REFERENCES users(id),
  cash_expected   INTEGER NOT NULL DEFAULT 0,
  cash_collected  INTEGER NOT NULL DEFAULT 0,
  cash_difference INTEGER NOT NULL DEFAULT 0,  -- collecté − attendu
  counted_cash    INTEGER,                     -- remis par le livreur (facultatif)
  notes           TEXT NOT NULL DEFAULT '',
  created_by      TEXT REFERENCES users(id),
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);
CREATE INDEX idx_delivery_runs_date ON delivery_runs(run_date, status);

CREATE TABLE run_stops (
  id             TEXT PRIMARY KEY,
  run_id         TEXT NOT NULL REFERENCES delivery_runs(id) ON DELETE CASCADE,
  order_id       TEXT NOT NULL REFERENCES customer_orders(id),
  sequence       INTEGER NOT NULL DEFAULT 0,
  status         TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','delivered','partial','failed')),
  failure_reason TEXT NOT NULL DEFAULT '',
  cod_expected   INTEGER NOT NULL DEFAULT 0,
  cod_collected  INTEGER NOT NULL DEFAULT 0,
  payment_method TEXT NOT NULL DEFAULT 'cash' CHECK (payment_method IN ('cash','cib','edahabia','cheque','transfer')),
  payment_id     TEXT REFERENCES documents(id),
  receiver_name  TEXT NOT NULL DEFAULT '',
  delivered_at   TEXT,
  note           TEXT NOT NULL DEFAULT '',
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL,
  UNIQUE (run_id, order_id)
);
CREATE INDEX idx_run_stops_order ON run_stops(order_id);

-- ---- Vue analyses : une ligne par ligne de commande client --------------------
CREATE VIEW v_customer_order_lines AS
SELECT o.order_date,
       o.created_at                      AS created_at,
       o.id                              AS order_id,
       o.number                          AS order_number,
       o.status,
       o.source,
       o.priority,
       o.partner_id,
       pa.name                           AS partner_name,
       pa.client_type,
       o.wilaya,
       o.rep_user_id,
       COALESCE(u.full_name, u.username, '') AS rep_name,
       o.route_id,
       COALESCE(rt.name, '')             AS route_name,
       o.warehouse_id,
       l.product_id,
       p.name                            AS product_name,
       p.category_id,
       COALESCE(c.name, '')              AS category_name,
       p.brand,
       l.qty_ordered_milli,
       l.qty_validated_milli,
       l.qty_delivered_milli,
       l.qty_backorder_milli,
       l.qty_free_milli,
       l.unit_price,
       l.discount_pct,
       l.line_ht,
       l.line_ttc,
       CASE WHEN o.has_backorder = 1 THEN 1 ELSE 0 END AS has_backorder
FROM customer_order_lines l
JOIN customer_orders o ON o.id = l.order_id
JOIN partners pa ON pa.id = o.partner_id
JOIN products p ON p.id = l.product_id
LEFT JOIN product_categories c ON c.id = p.category_id
LEFT JOIN users u ON u.id = o.rep_user_id
LEFT JOIN delivery_routes rt ON rt.id = o.route_id;

-- ---- Permissions : le rôle Gérant reçoit les nouveaux droits ------------------
UPDATE roles SET perms_json = json_set(perms_json,
    '$."orders.view"', json('true'), '$."orders.manage"', json('true'),
    '$."orders.validate"', json('true'), '$."orders.override_credit"', json('true'),
    '$."deliveries.view"', json('true'), '$."deliveries.manage"', json('true'),
    '$."crm.view"', json('true'), '$."crm.edit"', json('true'), '$."crm.all_customers"', json('true'),
    '$."pricing.view"', json('true'), '$."pricing.edit"', json('true')),
  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
WHERE id = 'role-manager';
