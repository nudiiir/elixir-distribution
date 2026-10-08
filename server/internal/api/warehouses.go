package api

import (
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

type Warehouse struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	IsDefault bool   `json:"is_default"`
	Active    bool   `json:"active"`
	Address   string `json:"address"`
	Phone     string `json:"phone"`
}

func (s *Server) listWarehouses(w http.ResponseWriter, _ *http.Request) {
	rows, err := s.db.Query(`SELECT id, name, is_default, active, address, phone FROM warehouses
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
		if err := rows.Scan(&wh.ID, &wh.Name, &isDefault, &active, &wh.Address, &wh.Phone); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		wh.IsDefault, wh.Active = isDefault == 1, active == 1
		items = append(items, wh)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type warehouseIn struct {
	Name    string `json:"name"`
	Address string `json:"address"`
	Phone   string `json:"phone"`
}

// warehouseNameTaken: two active depots must not share a name (case-insensitive).
func (s *Server) warehouseNameTaken(name, exceptID string) bool {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM warehouses WHERE active = 1 AND lower(name) = lower(?) AND id != ?`,
		name, exceptID).Scan(&n)
	return n > 0
}

func (s *Server) createWarehouse(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "settings") {
		forbid(w)
		return
	}
	var in warehouseIn
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		writeErr(w, http.StatusBadRequest, "Le nom du dépôt est obligatoire.")
		return
	}
	if s.warehouseNameTaken(in.Name, "") {
		writeErr(w, http.StatusConflict, fmt.Sprintf("Un dépôt « %s » existe déjà.", in.Name))
		return
	}
	id, now := domain.NewID(), domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO warehouses (id, name, is_default, active, address, phone, created_at, updated_at)
		VALUES (?, ?, 0, 1, ?, ?, ?, ?)`, id, in.Name, strings.TrimSpace(in.Address),
		strings.TrimSpace(in.Phone), now, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	s.audit(r, "warehouse.create", "warehouse", id, "création du dépôt « "+in.Name+" »")
	writeJSON(w, http.StatusCreated, Warehouse{ID: id, Name: in.Name, Active: true,
		Address: strings.TrimSpace(in.Address), Phone: strings.TrimSpace(in.Phone)})
}

// updateWarehouse renames a depot and changes its address/phone.
func (s *Server) updateWarehouse(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "settings") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in warehouseIn
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		writeErr(w, http.StatusBadRequest, "Le nom du dépôt est obligatoire.")
		return
	}
	if s.warehouseNameTaken(in.Name, id) {
		writeErr(w, http.StatusConflict, fmt.Sprintf("Un dépôt « %s » existe déjà.", in.Name))
		return
	}
	var old string
	if err := s.db.QueryRow(`SELECT name FROM warehouses WHERE id = ? AND active = 1`, id).Scan(&old); err != nil {
		writeErr(w, http.StatusNotFound, "Dépôt introuvable.")
		return
	}
	if _, err := s.db.Exec(`UPDATE warehouses SET name = ?, address = ?, phone = ?, updated_at = ? WHERE id = ?`,
		in.Name, strings.TrimSpace(in.Address), strings.TrimSpace(in.Phone), domain.NowISO(), id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if old != in.Name {
		s.audit(r, "warehouse.rename", "warehouse", id, "dépôt « "+old+" » renommé en « "+in.Name+" »")
	}
	s.writeWarehouse(w, id)
}

func (s *Server) writeWarehouse(w http.ResponseWriter, id string) {
	var wh Warehouse
	var isDefault, active int
	if err := s.db.QueryRow(`SELECT id, name, is_default, active, address, phone FROM warehouses WHERE id = ?`, id).
		Scan(&wh.ID, &wh.Name, &isDefault, &active, &wh.Address, &wh.Phone); err != nil {
		writeErr(w, http.StatusNotFound, "Dépôt introuvable.")
		return
	}
	wh.IsDefault, wh.Active = isDefault == 1, active == 1
	writeJSON(w, http.StatusOK, wh)
}

// setDefaultWarehouse makes one depot the default (exactly one at a time).
func (s *Server) setDefaultWarehouse(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "settings") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var name string
	if err := s.db.QueryRow(`SELECT name FROM warehouses WHERE id = ? AND active = 1`, id).Scan(&name); err != nil {
		writeErr(w, http.StatusNotFound, "Dépôt introuvable.")
		return
	}
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	now := domain.NowISO()
	if _, err := tx.Exec(`UPDATE warehouses SET is_default = CASE WHEN id = ? THEN 1 ELSE 0 END,
		updated_at = ? WHERE is_default = 1 OR id = ?`, id, now, id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.audit(r, "warehouse.default", "warehouse", id, "« "+name+" » devient le dépôt par défaut")
	s.writeWarehouse(w, id)
}

// errWarehouseInUse carries the plain-words reason a depot cannot be deleted.
type errWarehouseInUse struct{ reason string }

func (e errWarehouseInUse) Error() string { return e.reason }

// warehouseDeletable explains why a depot cannot be removed, or returns nil.
func warehouseDeletable(db *sql.DB, id string) error {
	var isDefault, active int
	if err := db.QueryRow(`SELECT is_default, active FROM warehouses WHERE id = ?`, id).Scan(&isDefault, &active); err != nil || active == 0 {
		return sql.ErrNoRows
	}
	if isDefault == 1 {
		return errWarehouseInUse{"C’est le dépôt par défaut. Choisissez d’abord un autre dépôt par défaut, puis supprimez celui-ci."}
	}
	var others int
	db.QueryRow(`SELECT COUNT(*) FROM warehouses WHERE active = 1 AND id != ?`, id).Scan(&others)
	if others == 0 {
		return errWarehouseInUse{"Il faut garder au moins un dépôt."}
	}
	var stocked int
	db.QueryRow(`SELECT COUNT(*) FROM stock_levels WHERE warehouse_id = ? AND qty_milli != 0`, id).Scan(&stocked)
	if stocked > 0 {
		return errWarehouseInUse{fmt.Sprintf("Ce dépôt contient encore du stock (%d produit(s)). "+
			"Transférez ce stock vers un autre dépôt (Stock → Transferts), puis supprimez-le.", stocked)}
	}
	var docs int
	db.QueryRow(`SELECT COUNT(*) FROM documents WHERE warehouse_id = ? OR dest_warehouse_id = ?`, id, id).Scan(&docs)
	if docs == 0 {
		db.QueryRow(`SELECT COUNT(*) FROM stock_ledger WHERE warehouse_id = ?`, id).Scan(&docs)
	}
	if docs > 0 {
		return errWarehouseInUse{fmt.Sprintf("Ce dépôt apparaît dans %d document(s) (ventes, achats, transferts…). "+
			"Il doit rester pour que l’historique reste exact. Vous pouvez le renommer.", docs)}
	}
	return nil
}

// deleteWarehouse removes an unused depot. A depot with stock or documents is
// kept and the reason is explained.
func (s *Server) deleteWarehouse(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "settings") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	if err := warehouseDeletable(s.db, id); err != nil {
		var inUse errWarehouseInUse
		if errors.As(err, &inUse) {
			writeErr(w, http.StatusConflict, inUse.reason)
			return
		}
		writeErr(w, http.StatusNotFound, "Dépôt introuvable.")
		return
	}
	var name string
	s.db.QueryRow(`SELECT name FROM warehouses WHERE id = ?`, id).Scan(&name)
	// Soft delete: other tables (users' depots, settings) may still point at it.
	if _, err := s.db.Exec(`UPDATE warehouses SET active = 0, updated_at = ? WHERE id = ?`,
		domain.NowISO(), id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.db.Exec(`DELETE FROM stock_levels WHERE warehouse_id = ? AND qty_milli = 0`, id)
	s.audit(r, "warehouse.delete", "warehouse", id, "suppression du dépôt « "+name+" »")
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
