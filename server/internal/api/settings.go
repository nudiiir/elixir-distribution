package api

import (
	"net/http"

	"elixir/server/internal/domain"
)

// getSettings returns all settings as a flat {key: value} object.
// The auth secret never leaves the server.
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
		out[k] = v
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
	s.getSettings(w, r)
}
