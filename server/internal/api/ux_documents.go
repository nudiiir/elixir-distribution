package api

import (
	"database/sql"
	"io"
	"mime"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// routesDocumentsUX registers the documents routes added by the UX-benchmark work.
func (s *Server) routesDocumentsUX(r chi.Router) {
	r.Get("/documents/{id}/attachments", s.listAttachments)
	r.Post("/documents/{id}/attachments", s.addAttachment)
	r.Get("/documents/{id}/attachments/{aid}", s.getAttachment)
	r.Delete("/documents/{id}/attachments/{aid}", s.deleteAttachment)
}

const maxAttachment = 5 << 20 // 5 Mo

// Attachment is a file attached to a document (scan of the supplier's BL,
// signed delivery note…). Data travels only on the dedicated GET.
type Attachment struct {
	ID         string `json:"id"`
	DocumentID string `json:"document_id"`
	Name       string `json:"name"`
	Mime       string `json:"mime"`
	Size       int64  `json:"size"`
	CreatedAt  string `json:"created_at"`
}

// attachmentDoc checks the document exists and the caller may act on it.
func (s *Server) attachmentDoc(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := chi.URLParam(r, "id")
	var docType string
	err := s.db.QueryRow(`SELECT doc_type FROM documents WHERE id = ?`, id).Scan(&docType)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "document not found")
		return "", false
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return "", false
	}
	if !docPermOK(authFrom(r), docType) {
		forbid(w)
		return "", false
	}
	return id, true
}

func (s *Server) listAttachments(w http.ResponseWriter, r *http.Request) {
	id, ok := s.attachmentDoc(w, r)
	if !ok {
		return
	}
	rows, err := s.db.Query(`SELECT id, document_id, name, mime, length(data), created_at
		FROM document_attachments WHERE document_id = ? ORDER BY created_at, id`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Attachment{}
	for rows.Next() {
		var a Attachment
		if err := rows.Scan(&a.ID, &a.DocumentID, &a.Name, &a.Mime, &a.Size, &a.CreatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, a)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) addAttachment(w http.ResponseWriter, r *http.Request) {
	id, ok := s.attachmentDoc(w, r)
	if !ok {
		return
	}
	name := strings.TrimSpace(filepath.Base(strings.ReplaceAll(r.URL.Query().Get("name"), "\\", "/")))
	if name == "" || name == "." || name == "/" {
		writeErr(w, http.StatusBadRequest, "nom de fichier requis (?name=)")
		return
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, maxAttachment+1))
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(data) == 0 {
		writeErr(w, http.StatusBadRequest, "fichier vide")
		return
	}
	if len(data) > maxAttachment {
		writeErr(w, http.StatusRequestEntityTooLarge, "fichier trop volumineux (5 Mo maximum)")
		return
	}
	mt := mime.TypeByExtension(strings.ToLower(filepath.Ext(name)))
	if mt == "" {
		mt = http.DetectContentType(data)
	}
	a := Attachment{ID: domain.NewID(), DocumentID: id, Name: name, Mime: mt,
		Size: int64(len(data)), CreatedAt: domain.NowISO()}
	if _, err := s.db.Exec(`INSERT INTO document_attachments (id, document_id, name, mime, data, created_at)
		VALUES (?, ?, ?, ?, ?, ?)`, a.ID, a.DocumentID, a.Name, a.Mime, data, a.CreatedAt); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.audit(r, "document.attach", "document", id, "pièce jointe « "+name+" »")
	writeJSON(w, http.StatusCreated, a)
}

func (s *Server) getAttachment(w http.ResponseWriter, r *http.Request) {
	id, ok := s.attachmentDoc(w, r)
	if !ok {
		return
	}
	var name, mt string
	var data []byte
	err := s.db.QueryRow(`SELECT name, mime, data FROM document_attachments
		WHERE id = ? AND document_id = ?`, chi.URLParam(r, "aid"), id).Scan(&name, &mt, &data)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "pièce jointe introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", mt)
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": name}))
	w.WriteHeader(http.StatusOK)
	w.Write(data)
}

func (s *Server) deleteAttachment(w http.ResponseWriter, r *http.Request) {
	id, ok := s.attachmentDoc(w, r)
	if !ok {
		return
	}
	aid := chi.URLParam(r, "aid")
	var name string
	s.db.QueryRow(`SELECT name FROM document_attachments WHERE id = ? AND document_id = ?`, aid, id).Scan(&name)
	res, err := s.db.Exec(`DELETE FROM document_attachments WHERE id = ? AND document_id = ?`, aid, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "pièce jointe introuvable")
		return
	}
	s.audit(r, "document.detach", "document", id, "pièce jointe supprimée « "+name+" »")
	writeJSON(w, http.StatusOK, map[string]any{"deleted": aid})
}
