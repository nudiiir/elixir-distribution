-- Documents : note interne (jamais imprimée) et pièces jointes (scan du BL
-- fournisseur, bon signé, photo…). La note imprimée reste documents.notes.
ALTER TABLE documents ADD COLUMN internal_notes TEXT;

CREATE TABLE document_attachments (
  id          TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  mime        TEXT NOT NULL,
  data        BLOB NOT NULL,              -- max 5 Mo
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_document_attachments_doc ON document_attachments(document_id, created_at);
