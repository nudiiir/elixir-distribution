package api

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// Template is a printable document design (label / invoice / warranty) whose
// layout JSON is authored in the app's designer. The server just stores it.
type Template struct {
	ID        string          `json:"id"`
	Kind      string          `json:"kind"`
	Name      string          `json:"name"`
	Lang      string          `json:"lang"`
	Body      json.RawMessage `json:"body"`
	IsDefault bool            `json:"is_default"`
	CreatedAt string          `json:"created_at"`
	UpdatedAt string          `json:"updated_at"`
}

const templateCols = `id, kind, name, lang, body, is_default, created_at, updated_at`

func scanTemplate(row interface{ Scan(...any) error }) (Template, error) {
	var t Template
	var body string
	var def int
	err := row.Scan(&t.ID, &t.Kind, &t.Name, &t.Lang, &body, &def, &t.CreatedAt, &t.UpdatedAt)
	t.Body = json.RawMessage(body)
	t.IsDefault = def == 1
	return t, err
}

func validTemplateKind(k string) bool {
	return k == "label" || k == "invoice" || k == "warranty"
}

func (s *Server) listTemplates(w http.ResponseWriter, r *http.Request) {
	kind := r.URL.Query().Get("kind")
	where, args := "", []any{}
	if kind != "" {
		where = "WHERE kind = ?"
		args = append(args, kind)
	}
	rows, err := s.db.Query(`SELECT `+templateCols+` FROM templates `+where+
		` ORDER BY kind, is_default DESC, name`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Template{}
	for rows.Next() {
		t, err := scanTemplate(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, t)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type templateInput struct {
	Kind string          `json:"kind"`
	Name string          `json:"name"`
	Lang string          `json:"lang"`
	Body json.RawMessage `json:"body"`
}

func (in *templateInput) validate() string {
	if !validTemplateKind(in.Kind) {
		return "kind must be label, invoice or warranty"
	}
	if strings.TrimSpace(in.Name) == "" {
		return "name is required"
	}
	if in.Lang != "fr" && in.Lang != "ar" {
		return "lang must be fr or ar"
	}
	if !json.Valid(in.Body) || len(in.Body) < 2 {
		return "body must be valid JSON"
	}
	return ""
}

func (s *Server) createTemplate(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "settings") {
		forbid(w)
		return
	}
	var in templateInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	id, now := domain.NewID(), domain.NowISO()
	// The first template of a kind becomes the default automatically.
	var existing int
	s.db.QueryRow(`SELECT COUNT(*) FROM templates WHERE kind = ?`, in.Kind).Scan(&existing)
	_, err := s.db.Exec(`INSERT INTO templates (id, kind, name, lang, body, is_default, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		id, in.Kind, in.Name, in.Lang, string(in.Body), b2i(existing == 0), now, now)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	s.getTemplateByID(w, id)
}

func (s *Server) getTemplate(w http.ResponseWriter, r *http.Request) {
	s.getTemplateByID(w, chi.URLParam(r, "id"))
}

func (s *Server) getTemplateByID(w http.ResponseWriter, id string) {
	t, err := scanTemplate(s.db.QueryRow(`SELECT `+templateCols+` FROM templates WHERE id = ?`, id))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "template not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, t)
}

func (s *Server) updateTemplate(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "settings") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in templateInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	// kind is immutable after creation; take the stored one for validation.
	s.db.QueryRow(`SELECT kind FROM templates WHERE id = ?`, id).Scan(&in.Kind)
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	res, err := s.db.Exec(`UPDATE templates SET name = ?, lang = ?, body = ?, updated_at = ? WHERE id = ?`,
		in.Name, in.Lang, string(in.Body), domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "template not found")
		return
	}
	s.getTemplateByID(w, id)
}

func (s *Server) deleteTemplate(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "settings") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	res, err := s.db.Exec(`DELETE FROM templates WHERE id = ?`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "template not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

func (s *Server) setDefaultTemplate(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "settings") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var kind string
	if err := s.db.QueryRow(`SELECT kind FROM templates WHERE id = ?`, id).Scan(&kind); err != nil {
		writeErr(w, http.StatusNotFound, "template not found")
		return
	}
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE templates SET is_default = 0 WHERE kind = ?`, kind); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if _, err := tx.Exec(`UPDATE templates SET is_default = 1, updated_at = ? WHERE id = ?`,
		domain.NowISO(), id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.getTemplateByID(w, id)
}
