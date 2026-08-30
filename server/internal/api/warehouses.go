package api

import (
	"net/http"
	"strings"

	"elixir/server/internal/domain"
)

type Warehouse struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	IsDefault bool   `json:"is_default"`
	Active    bool   `json:"active"`
}

func (s *Server) listWarehouses(w http.ResponseWriter, _ *http.Request) {
	rows, err := s.db.Query(`SELECT id, name, is_default, active FROM warehouses
		WHERE active = 1 ORDER BY is_default DESC, name`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Warehouse{}
	for rows.Next() {
		var wh Warehouse
		var isDefault, active int
		if err := rows.Scan(&wh.ID, &wh.Name, &isDefault, &active); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		wh.IsDefault, wh.Active = isDefault == 1, active == 1
		items = append(items, wh)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) createWarehouse(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "settings") {
		forbid(w)
		return
	}
	var in struct {
		Name string `json:"name"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		writeErr(w, http.StatusBadRequest, "name is required")
		return
	}
	id, now := domain.NewID(), domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO warehouses (id, name, is_default, active, created_at, updated_at)
		VALUES (?, ?, 0, 1, ?, ?)`, id, in.Name, now, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, Warehouse{ID: id, Name: in.Name, Active: true})
}
