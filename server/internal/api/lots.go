package api

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// DLC tracking: lots carry an expiry date and an informational quantity so the
// shop can chase soon-to-expire stock. The stock ledger stays authoritative.

type Lot struct {
	ID          string  `json:"id"`
	ProductID   string  `json:"product_id"`
	ProductName string  `json:"product_name"`
	LotNumber   string  `json:"lot_number"`
	ExpiryDate  *string `json:"expiry_date"`
	QtyMilli    int64   `json:"qty_milli"`
}

func (s *Server) listLots(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "stock") {
		forbid(w)
		return
	}
	where, args := "WHERE 1=1", []any{}
	if p := r.URL.Query().Get("product_id"); p != "" {
		where += " AND l.product_id = ?"
		args = append(args, p)
	}
	if d := r.URL.Query().Get("expiring_days"); d != "" {
		if days, err := strconv.Atoi(d); err == nil {
			where += ` AND l.expiry_date IS NOT NULL
				AND l.expiry_date <= date('now', '+' || ? || ' days')`
			args = append(args, days)
		}
	}
	rows, err := s.db.Query(`SELECT l.id, l.product_id, p.name, l.lot_number,
			l.expiry_date, l.qty_milli
		FROM lots l JOIN products p ON p.id = l.product_id `+where+
		` ORDER BY l.expiry_date IS NULL, l.expiry_date LIMIT 500`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Lot{}
	for rows.Next() {
		var l Lot
		if err := rows.Scan(&l.ID, &l.ProductID, &l.ProductName, &l.LotNumber,
			&l.ExpiryDate, &l.QtyMilli); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, l)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) createLot(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "stock") {
		forbid(w)
		return
	}
	var in struct {
		ProductID  string  `json:"product_id"`
		LotNumber  string  `json:"lot_number"`
		ExpiryDate *string `json:"expiry_date"`
		QtyMilli   int64   `json:"qty_milli"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.ProductID == "" {
		writeErr(w, http.StatusBadRequest, "product_id is required")
		return
	}
	in.LotNumber = strings.TrimSpace(in.LotNumber)
	if in.LotNumber == "" {
		// Unnamed lots key on their expiry date.
		if in.ExpiryDate != nil {
			in.LotNumber = "DLC " + *in.ExpiryDate
		} else {
			writeErr(w, http.StatusBadRequest, "lot_number ou expiry_date requis")
			return
		}
	}
	id := domain.NewID()
	if _, err := s.db.Exec(`INSERT INTO lots (id, product_id, lot_number, expiry_date, qty_milli, created_at)
		VALUES (?, ?, ?, ?, ?, ?)`,
		id, in.ProductID, in.LotNumber, in.ExpiryDate, in.QtyMilli, domain.NowISO()); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) updateLot(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "stock") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in struct {
		LotNumber  string  `json:"lot_number"`
		ExpiryDate *string `json:"expiry_date"`
		QtyMilli   int64   `json:"qty_milli"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	res, err := s.db.Exec(`UPDATE lots SET lot_number = ?, expiry_date = ?, qty_milli = ?
		WHERE id = ?`, strings.TrimSpace(in.LotNumber), in.ExpiryDate, in.QtyMilli, id)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "lot not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "updated"})
}

func (s *Server) deleteLot(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "stock") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	res, err := s.db.Exec(`DELETE FROM lots WHERE id = ?`, id)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "lot not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}
