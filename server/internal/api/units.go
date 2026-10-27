package api

import (
	"database/sql"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// Serialized inventory: one row per physical unit (IMEI, serial no.).
// Quantities still live in the stock ledger — units answer "which one, to whom".

type ProductUnit struct {
	ID            string  `json:"id"`
	ProductID     string  `json:"product_id"`
	ProductName   string  `json:"product_name"`
	Serial        string  `json:"serial"`
	Status        string  `json:"status"`
	IsUsed        bool    `json:"is_used"`
	SaleDocID     *string `json:"sale_doc_id"`
	SaleDocNumber *string `json:"sale_doc_number"`
	SaleDate      *string `json:"sale_date"`
	PartnerID     *string `json:"partner_id"`
	PartnerName   *string `json:"partner_name"`
	Notes         *string `json:"notes"`
	CreatedAt     string  `json:"created_at"`
}

const unitCols = `pu.id, pu.product_id, p.name, pu.serial, pu.status, pu.is_used,
	pu.sale_doc_id, d.number, d.doc_date, pu.partner_id, pa.name, pu.notes, pu.created_at`

const unitJoins = ` FROM product_units pu
	JOIN products p ON p.id = pu.product_id
	LEFT JOIN documents d ON d.id = pu.sale_doc_id
	LEFT JOIN partners pa ON pa.id = pu.partner_id`

func scanUnit(row interface{ Scan(...any) error }) (ProductUnit, error) {
	var u ProductUnit
	var used int
	err := row.Scan(&u.ID, &u.ProductID, &u.ProductName, &u.Serial, &u.Status, &used,
		&u.SaleDocID, &u.SaleDocNumber, &u.SaleDate, &u.PartnerID, &u.PartnerName,
		&u.Notes, &u.CreatedAt)
	u.IsUsed = used == 1
	return u, err
}

func (s *Server) listUnits(w http.ResponseWriter, r *http.Request) {
	where, args := "WHERE 1=1", []any{}
	if p := r.URL.Query().Get("product_id"); p != "" {
		where += " AND pu.product_id = ?"
		args = append(args, p)
	}
	if st := r.URL.Query().Get("status"); st != "" {
		where += " AND pu.status = ?"
		args = append(args, st)
	}
	if q := strings.TrimSpace(r.URL.Query().Get("q")); q != "" {
		where += " AND pu.serial LIKE ?"
		args = append(args, "%"+q+"%")
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	args = append(args, limit)
	rows, err := s.db.Query(`SELECT `+unitCols+unitJoins+" "+where+
		` ORDER BY pu.created_at DESC LIMIT ?`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []ProductUnit{}
	for rows.Next() {
		u, err := scanUnit(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, u)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) getUnitBySerial(w http.ResponseWriter, r *http.Request) {
	serial := strings.TrimSpace(chi.URLParam(r, "serial"))
	u, err := scanUnit(s.db.QueryRow(`SELECT `+unitCols+unitJoins+
		` WHERE pu.serial = ?`, serial))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "numéro de série inconnu")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, u)
}

// createUnits registers a batch of serials for a product (at reception).
func (s *Server) createUnits(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "stock") && !s.can(r, "products") {
		forbid(w)
		return
	}
	var in struct {
		ProductID string   `json:"product_id"`
		Serials   []string `json:"serials"`
		IsUsed    bool     `json:"is_used"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.ProductID == "" || len(in.Serials) == 0 {
		writeErr(w, http.StatusBadRequest, "product_id and serials are required")
		return
	}
	now := domain.NowISO()
	added, dupes := 0, []string{}
	for _, raw := range in.Serials {
		serial := strings.TrimSpace(raw)
		if serial == "" {
			continue
		}
		_, err := s.db.Exec(`INSERT INTO product_units
			(id, product_id, serial, status, is_used, created_at, updated_at)
			VALUES (?, ?, ?, 'in_stock', ?, ?, ?)`,
			domain.NewID(), in.ProductID, serial, b2i(in.IsUsed), now, now)
		if err != nil {
			dupes = append(dupes, serial)
			continue
		}
		added++
	}
	writeJSON(w, http.StatusOK, map[string]any{"added": added, "duplicates": dupes})
}

func (s *Server) updateUnit(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "stock") && !s.can(r, "products") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in struct {
		Status string  `json:"status"`
		Notes  *string `json:"notes"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	valid := map[string]bool{"in_stock": true, "sold": true, "returned": true,
		"repair": true, "scrapped": true}
	if !valid[in.Status] {
		writeErr(w, http.StatusBadRequest, "invalid status")
		return
	}
	res, err := s.db.Exec(`UPDATE product_units SET status = ?, notes = ?, updated_at = ?
		WHERE id = ?`, in.Status, in.Notes, domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "unit not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "updated"})
}

func (s *Server) deleteUnit(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "stock") && !s.can(r, "products") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	res, err := s.db.Exec(`DELETE FROM product_units WHERE id = ? AND status = 'in_stock'`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusConflict,
			"seule une unité encore en stock peut être supprimée")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// sellUnit marks a serial as sold and links it to the sale. If the serial was
// never registered, it is created directly as sold — a missing reception entry
// must never block a sale at the till.
func (s *Server) sellUnit(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") && !s.can(r, "sales") {
		forbid(w)
		return
	}
	var in struct {
		Serial    string  `json:"serial"`
		ProductID string  `json:"product_id"`
		SaleDocID *string `json:"sale_doc_id"`
		PartnerID *string `json:"partner_id"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	in.Serial = strings.TrimSpace(in.Serial)
	if in.Serial == "" {
		writeErr(w, http.StatusBadRequest, "serial is required")
		return
	}
	now := domain.NowISO()
	res, err := s.db.Exec(`UPDATE product_units
		SET status = 'sold', sale_doc_id = ?, partner_id = ?, updated_at = ?
		WHERE serial = ?`, in.SaleDocID, in.PartnerID, now, in.Serial)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		if in.ProductID == "" {
			writeErr(w, http.StatusNotFound, "numéro de série inconnu")
			return
		}
		if _, err := s.db.Exec(`INSERT INTO product_units
			(id, product_id, serial, status, sale_doc_id, partner_id, created_at, updated_at)
			VALUES (?, ?, ?, 'sold', ?, ?, ?, ?)`,
			domain.NewID(), in.ProductID, in.Serial, in.SaleDocID, in.PartnerID,
			now, now); err != nil {
			writeErr(w, http.StatusConflict, err.Error())
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "sold"})
}
