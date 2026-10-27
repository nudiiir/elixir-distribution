-- 0017_crm: customer relationship (contacts, tags, customer file documents,
-- activities, tasks, segments, sales rep targets, messages).

CREATE TABLE partner_contacts (
  id         TEXT PRIMARY KEY,
  partner_id TEXT NOT NULL REFERENCES partners(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  role       TEXT NOT NULL DEFAULT '',   -- manager, buyer, accountant…
  phone      TEXT NOT NULL DEFAULT '',
  whatsapp   TEXT NOT NULL DEFAULT '',
  email      TEXT NOT NULL DEFAULT '',
  is_primary INTEGER NOT NULL DEFAULT 0,
  notes      TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_partner_contacts_partner ON partner_contacts(partner_id);

CREATE TABLE tags (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL UNIQUE,
  colour     TEXT NOT NULL DEFAULT '#00CC99',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE partner_tags (
  partner_id TEXT NOT NULL REFERENCES partners(id) ON DELETE CASCADE,
  tag_id     TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  PRIMARY KEY (partner_id, tag_id)
);
CREATE INDEX idx_partner_tags_tag ON partner_tags(tag_id);

-- Customer file documents (approval, trade register, NIF card…),
-- stored like document_attachments (BLOB, 5 MB max).
CREATE TABLE partner_files (
  id         TEXT PRIMARY KEY,
  partner_id TEXT NOT NULL REFERENCES partners(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL DEFAULT 'other'
             CHECK (kind IN ('license','registre','nif','nis','contract','id','other')),
  name       TEXT NOT NULL,
  mime       TEXT NOT NULL,
  data       BLOB NOT NULL,
  expires_at TEXT,                         -- YYYY-MM-DD (approval…)
  notes      TEXT NOT NULL DEFAULT '',
  created_by TEXT REFERENCES users(id),
  created_at TEXT NOT NULL
);
CREATE INDEX idx_partner_files_partner ON partner_files(partner_id, created_at);

CREATE TABLE crm_activities (
  id           TEXT PRIMARY KEY,
  partner_id   TEXT NOT NULL REFERENCES partners(id) ON DELETE CASCADE,
  type         TEXT NOT NULL CHECK (type IN ('call','visit','note','whatsapp','sms','email','meeting')),
  outcome      TEXT NOT NULL DEFAULT '',   -- free text: order, callback, not interested…
  summary      TEXT NOT NULL DEFAULT '',
  at           TEXT NOT NULL,              -- ISO-8601 UTC
  duration_min INTEGER NOT NULL DEFAULT 0,
  user_id      TEXT REFERENCES users(id),
  order_id     TEXT REFERENCES customer_orders(id) ON DELETE SET NULL,
  document_id  TEXT REFERENCES documents(id) ON DELETE SET NULL,
  latitude     REAL,
  longitude    REAL,
  next_action  TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);
CREATE INDEX idx_crm_activities_partner ON crm_activities(partner_id, at);
CREATE INDEX idx_crm_activities_user ON crm_activities(user_id, at);

CREATE TABLE crm_tasks (
  id           TEXT PRIMARY KEY,
  title        TEXT NOT NULL,
  description  TEXT NOT NULL DEFAULT '',
  partner_id   TEXT REFERENCES partners(id) ON DELETE CASCADE,
  order_id     TEXT REFERENCES customer_orders(id) ON DELETE SET NULL,
  assignee_id  TEXT REFERENCES users(id),
  due_at       TEXT,                       -- YYYY-MM-DD or ISO timestamp
  priority     INTEGER NOT NULL DEFAULT 0 CHECK (priority IN (0,1,2)),
  status       TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','done','cancelled')),
  type         TEXT NOT NULL DEFAULT 'other'
               CHECK (type IN ('call','visit','collect_payment','follow_up','other')),
  source       TEXT NOT NULL DEFAULT 'manual'
               CHECK (source IN ('manual','auto_overdue','auto_inactive','auto_backorder')),
  auto_key     TEXT,                       -- idempotency key of automatic tasks
  completed_at TEXT,
  completed_by TEXT REFERENCES users(id),
  result       TEXT NOT NULL DEFAULT '',
  created_by   TEXT REFERENCES users(id),
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);
CREATE INDEX idx_crm_tasks_assignee ON crm_tasks(assignee_id, status, due_at);
CREATE INDEX idx_crm_tasks_partner ON crm_tasks(partner_id);
CREATE INDEX idx_crm_tasks_auto ON crm_tasks(auto_key);

CREATE TABLE crm_segments (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL UNIQUE,
  rules_json TEXT NOT NULL DEFAULT '{}',
  created_by TEXT REFERENCES users(id),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE rep_targets (
  id                 TEXT PRIMARY KEY,
  user_id            TEXT NOT NULL REFERENCES users(id),
  month              TEXT NOT NULL,          -- YYYY-MM
  sales_target       INTEGER NOT NULL DEFAULT 0,  -- centimes incl. VAT
  orders_target      INTEGER NOT NULL DEFAULT 0,
  visits_target      INTEGER NOT NULL DEFAULT 0,
  new_customers_target INTEGER NOT NULL DEFAULT 0,
  collections_target INTEGER NOT NULL DEFAULT 0,  -- centimes
  created_at         TEXT NOT NULL,
  updated_at         TEXT NOT NULL,
  UNIQUE (user_id, month)
);

CREATE TABLE message_templates (
  id         TEXT PRIMARY KEY,
  code       TEXT NOT NULL,
  channel    TEXT NOT NULL CHECK (channel IN ('whatsapp','sms','email')),
  lang       TEXT NOT NULL DEFAULT 'fr' CHECK (lang IN ('fr','ar')),
  name       TEXT NOT NULL DEFAULT '',
  subject    TEXT NOT NULL DEFAULT '',
  body       TEXT NOT NULL,
  active     INTEGER NOT NULL DEFAULT 1,
  is_system  INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (code, channel, lang)
);

CREATE TABLE message_log (
  id          TEXT PRIMARY KEY,
  partner_id  TEXT REFERENCES partners(id) ON DELETE CASCADE,
  order_id    TEXT REFERENCES customer_orders(id) ON DELETE SET NULL,
  channel     TEXT NOT NULL CHECK (channel IN ('whatsapp','sms','email')),
  template_code TEXT NOT NULL DEFAULT '',
  recipient   TEXT NOT NULL DEFAULT '',
  subject     TEXT NOT NULL DEFAULT '',
  body        TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'prepared' CHECK (status IN ('prepared','sent','failed')),
  error       TEXT NOT NULL DEFAULT '',
  user_id     TEXT REFERENCES users(id),
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_message_log_partner ON message_log(partner_id, created_at);

-- Default templates (French). {{placeholders}}: see docs/API_DISTRIBUTION.md.
INSERT INTO message_templates (id, code, channel, lang, name, subject, body, active, is_system, created_at, updated_at) VALUES
('tpl-order_confirmed-wa', 'order_confirmed', 'whatsapp', 'fr', 'Commande confirmée', '',
 'Bonjour {{client}}, votre commande {{numero}} d''un montant de {{montant}} est confirmée. Merci de votre confiance. — {{magasin}}',
 1, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('tpl-order_ready-wa', 'order_ready', 'whatsapp', 'fr', 'Commande prête', '',
 'Bonjour {{client}}, votre commande {{numero}} est prête. — {{magasin}}',
 1, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('tpl-order_shipped-wa', 'order_shipped', 'whatsapp', 'fr', 'Commande expédiée', '',
 'Bonjour {{client}}, votre commande {{numero}} est en cours de livraison. Suivi : {{lien_suivi}} — {{magasin}}',
 1, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('tpl-order_delivered-wa', 'order_delivered', 'whatsapp', 'fr', 'Commande livrée', '',
 'Bonjour {{client}}, votre commande {{numero}} a été livrée le {{date}}. Merci ! — {{magasin}}',
 1, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('tpl-payment_reminder-wa', 'payment_reminder', 'whatsapp', 'fr', 'Relance de paiement', '',
 'Bonjour {{client}}, sauf erreur de notre part, votre solde au {{date}} s''élève à {{solde}}. Merci de prévoir son règlement. — {{magasin}}',
 1, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('tpl-statement-wa', 'statement', 'whatsapp', 'fr', 'Relevé de compte', '',
 'Bonjour {{client}}, votre solde au {{date}} est de {{solde}}. Le relevé détaillé est disponible sur demande. — {{magasin}}',
 1, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('tpl-backorder_available-wa', 'backorder_available', 'whatsapp', 'fr', 'Reliquat disponible', '',
 'Bonjour {{client}}, bonne nouvelle : {{produit}} est de nouveau disponible pour votre commande {{numero}}. — {{magasin}}',
 1, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('tpl-promo-wa', 'promo', 'whatsapp', 'fr', 'Promotion', '',
 'Bonjour {{client}}, découvrez nos offres du moment : {{promo}} — {{magasin}}',
 1, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('tpl-order_confirmed-email', 'order_confirmed', 'email', 'fr', 'Commande confirmée', 'Votre commande {{numero}} est confirmée',
 'Bonjour {{client}},

Votre commande {{numero}} d''un montant de {{montant}} est confirmée.

Cordialement,
{{magasin}}',
 1, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('tpl-payment_reminder-email', 'payment_reminder', 'email', 'fr', 'Relance de paiement', 'Relance — solde de votre compte',
 'Bonjour {{client}},

Sauf erreur de notre part, votre solde au {{date}} s''élève à {{solde}}.
Merci de prévoir son règlement.

Cordialement,
{{magasin}}',
 1, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
('tpl-statement-email', 'statement', 'email', 'fr', 'Relevé de compte', 'Votre relevé de compte au {{date}}',
 'Bonjour {{client}},

Votre solde au {{date}} est de {{solde}}.

Cordialement,
{{magasin}}',
 1, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'));
