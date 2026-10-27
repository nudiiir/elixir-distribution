-- Mixed payment at the till: a ticket settled by several methods keeps
-- documents.payment_method NULL and carries one row per method here.
-- The « credit » part goes to the customer account; stamp duty is only due on the
-- part paid in cash (it is included in the amount of the « cash » row).
CREATE TABLE document_payments (
  id          TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  method      TEXT NOT NULL CHECK (method IN ('cash','cib','edahabia','cheque','transfer','credit','gift')),
  amount      INTEGER NOT NULL CHECK (amount > 0),
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_document_payments_doc ON document_payments(document_id);
