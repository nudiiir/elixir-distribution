package api

import (
	"database/sql"
	"io"
	"net/http"
	"strconv"
	"time"

	"elixir/server/internal/domain"
)

// getSettings returns all settings as a flat {key: value} object.
// The auth secret and the SMTP password never leave the server; the latter is
// reported as smtp_pass_set = '1' | '0'.
func (s *Server) getSettings(w http.ResponseWriter, _ *http.Request) {
	rows, err := s.db.Query(`SELECT key, value FROM settings WHERE key != 'auth_secret'`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if k == "smtp_pass" {
			if v != "" {
				out["smtp_pass_set"] = "1"
			}
			continue
		}
		out[k] = v
	}
	if _, ok := out["smtp_pass_set"]; !ok {
		out["smtp_pass_set"] = "0"
	}
	writeJSON(w, http.StatusOK, out)
}

// putSettings upserts the given {key: value} pairs. Admin only.
func (s *Server) putSettings(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	var in map[string]string
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	delete(in, "auth_secret")
	delete(in, "smtp_pass_set") // derived, never stored
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	now := domain.NowISO()
	for k, v := range in {
		if _, err := tx.Exec(`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
			ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
			k, v, now); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	domain.RefreshSettingsCache(s.db) // timbre on/off for the previews
	s.getSettings(w, r)
}

// ---- Company logo (one image, shown on documents) ----

const maxLogoBytes = 1 << 20 // 1 Mo

// getLogo serves the logo bytes (404 when none). Cache-busted by the
// `logo_rev` setting the client appends as ?v=.
func (s *Server) getLogo(w http.ResponseWriter, _ *http.Request) {
	var mime string
	var data []byte
	if err := s.db.QueryRow(`SELECT mime, data FROM company_logo WHERE id = 1`).Scan(&mime, &data); err != nil {
		writeErr(w, http.StatusNotFound, "aucun logo")
		return
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("Cache-Control", "private, max-age=31536000")
	w.WriteHeader(http.StatusOK)
	w.Write(data)
}

// putLogo stores the raw PNG/JPEG body (≤ 1 Mo). Admin only.
func (s *Server) putLogo(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, maxLogoBytes+1))
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(data) == 0 {
		writeErr(w, http.StatusBadRequest, "Fichier vide.")
		return
	}
	if len(data) > maxLogoBytes {
		writeErr(w, http.StatusRequestEntityTooLarge, "Le logo dépasse 1 Mo. Choisissez une image plus légère.")
		return
	}
	mime := http.DetectContentType(data)
	if mime != "image/png" && mime != "image/jpeg" {
		writeErr(w, http.StatusUnsupportedMediaType, "Format non accepté : choisissez une image PNG ou JPEG.")
		return
	}
	now := domain.NowISO()
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT INTO company_logo (id, mime, data, updated_at) VALUES (1, ?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET mime = excluded.mime, data = excluded.data, updated_at = excluded.updated_at`,
		mime, data, now); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	rev, err := bumpLogoRev(tx, now)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.audit(r, "settings.logo", "settings", "logo", "nouveau logo de l’entreprise")
	writeJSON(w, http.StatusOK, map[string]any{"logo_rev": rev, "mime": mime, "size_bytes": len(data)})
}

func (s *Server) deleteLogo(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	now := domain.NowISO()
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM company_logo WHERE id = 1`); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if _, err := tx.Exec(`INSERT INTO settings (key, value, updated_at) VALUES ('logo_rev', '0', ?)
		ON CONFLICT (key) DO UPDATE SET value = '0', updated_at = excluded.updated_at`, now); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.audit(r, "settings.logo", "settings", "logo", "logo de l’entreprise retiré")
	writeJSON(w, http.StatusOK, map[string]any{"logo_rev": 0})
}

// bumpLogoRev increments the `logo_rev` setting (0 = no logo).
func bumpLogoRev(tx *sql.Tx, now string) (int, error) {
	var cur string
	tx.QueryRow(`SELECT value FROM settings WHERE key = 'logo_rev'`).Scan(&cur)
	n, _ := strconv.Atoi(cur)
	// Never reuse a revision after a delete (0): use a time-based floor.
	next := n + 1
	if t := int(time.Now().Unix() % 1_000_000_000); next < t {
		next = t
	}
	_, err := tx.Exec(`INSERT INTO settings (key, value, updated_at) VALUES ('logo_rev', ?, ?)
		ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
		strconv.Itoa(next), now)
	return next, err
}
