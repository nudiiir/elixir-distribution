-- Paiement mixte à la caisse : un ticket réglé par plusieurs moyens garde
-- documents.payment_method à NULL et porte une ligne par moyen ici.
-- La part « credit » va au compte client ; le timbre n'est dû que sur la
-- part payée en espèces (il est inclus dans le montant de la ligne « cash »).
CREATE TABLE document_payments (
  id          TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  method      TEXT NOT NULL CHECK (method IN ('cash','cib','edahabia','cheque','transfer','credit','gift')),
  amount      INTEGER NOT NULL CHECK (amount > 0),
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_document_payments_doc ON document_payments(document_id);
