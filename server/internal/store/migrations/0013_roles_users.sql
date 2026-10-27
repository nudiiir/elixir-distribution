-- 0013: editable roles (permissions + limits + scope) and full
-- user record (phone, email, depots, till code, sessions).
--
-- Permission keys: <module>.view|create|edit|cancel|validate|export|print
-- and the special rights (view_cost, discount, credit_sale…). The server
-- derives the old module key (« sales ») from « sales.view ».
-- Limits (limits_json): max_discount_pct (×100), max_credit (centimes),
-- approval_above (centimes) — 0 = no limit.
-- The Administrateur role (role-admin) has EVERYTHING, whatever perms_json contains.

CREATE TABLE roles (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  description TEXT NOT NULL DEFAULT '',
  perms_json  TEXT NOT NULL DEFAULT '{}',
  limits_json TEXT NOT NULL DEFAULT '{}',
  scope       TEXT NOT NULL DEFAULT 'all' CHECK (scope IN ('all','own','warehouse')),
  is_system   INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

INSERT INTO roles (id, name, description, perms_json, limits_json, scope, is_system, created_at, updated_at) VALUES
('role-admin', 'Administrateur',
 'Accès complet : gère les utilisateurs, les rôles et tous les réglages. Ce rôle ne peut pas être modifié.',
 '{}', '{}', 'all', 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('role-manager', 'Gérant',
 'Tous les modules et toutes les actions, sans gérer les utilisateurs ni les réglages réservés à l''administrateur.',
 '{"dashboard.view":true,"pos.view":true,"assistant.view":true,"reports.view":true,"reports.export":true,"reports.print":true,"webstore.view":true,"settings.view":true,"sales.view":true,"sales.create":true,"sales.edit":true,"sales.cancel":true,"sales.validate":true,"sales.export":true,"sales.print":true,"purchases.view":true,"purchases.create":true,"purchases.edit":true,"purchases.cancel":true,"purchases.validate":true,"purchases.export":true,"purchases.print":true,"stock.view":true,"stock.create":true,"stock.edit":true,"stock.cancel":true,"stock.validate":true,"stock.export":true,"stock.print":true,"products.view":true,"products.create":true,"products.edit":true,"products.export":true,"products.print":true,"partners.view":true,"partners.create":true,"partners.edit":true,"partners.export":true,"partners.print":true,"view_cost":true,"discount":true,"price_edit":true,"credit_sale":true,"refund":true,"void_document":true,"change_date":true,"open_drawer":true,"close_till":true,"view_today":true,"stock_adjust":true,"import_data":true,"export_data":true}',
 '{"max_discount_pct":0,"max_credit":0,"approval_above":0}', 'all', 0,
 strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('role-cashier', 'Caissier',
 'La caisse et l''assistant. Crée des ventes mais ne fait ni remise, ni avoir, ni vente à crédit sans le code du gérant.',
 '{"pos.view":true,"assistant.view":true,"sales.view":true,"sales.create":true,"sales.print":true,"open_drawer":true,"close_till":true}',
 '{"max_discount_pct":0,"max_credit":0,"approval_above":0}', 'own', 0,
 strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'));

ALTER TABLE users ADD COLUMN role_id TEXT REFERENCES roles(id);
ALTER TABLE users ADD COLUMN pin_hash TEXT;
ALTER TABLE users ADD COLUMN phone TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN email TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN warehouse_ids_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE users ADD COLUMN default_warehouse_id TEXT;
ALTER TABLE users ADD COLUMN last_login_at TEXT;
ALTER TABLE users ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0;

UPDATE users SET role_id = CASE role
  WHEN 'admin' THEN 'role-admin'
  WHEN 'manager' THEN 'role-manager'
  ELSE 'role-cashier' END;

CREATE INDEX idx_users_role ON users(role_id);
CREATE INDEX IF NOT EXISTS idx_documents_posted_by ON documents(posted_by);
