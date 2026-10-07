package api

import (
	"net/http"
	"strconv"
	"strings"
)

type StockLevel struct {
	ProductID   string `json:"product_id"`
	ProductName string `json:"product_name"`
	Barcode     *string `json:"barcode"`
	WarehouseID string `json:"warehouse_id"`
	QtyMilli    int64  `json:"qty_milli"`
	AvgCost     int64  `json:"avg_cost"`
}

type StockMovement struct {
	ID          string  `json:"id"`
	ProductName string  `json:"product_name"`
	QtyMilli    int64   `json:"qty_delta_milli"`
	DocType     string  `json:"doc_type"`
	DocNumber   *string `json:"doc_number"`
	CreatedAt   string  `json:"created_at"`
}

// stockMovements returns the most recent stock ledger entries with product
// and source-document context — feeds the dashboard "Mouvements récents".
func (s *Server) stockMovements(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	rows, err := s.db.Query(`SELECT sl.id, p.name, sl.qty_delta_milli, d.doc_type, d.number, sl.created_at
		FROM stock_ledger sl
		JOIN products p ON p.id = sl.product_id
		JOIN documents d ON d.id = sl.document_id
		WHERE sl.qty_delta_milli <> 0
		ORDER BY sl.created_at DESC, sl.id DESC LIMIT ?`, limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []StockMovement{}
	for rows.Next() {
		var m StockMovement
		if err := rows.Scan(&m.ID, &m.ProductName, &m.QtyMilli, &m.DocType,
			&m.DocNumber, &m.CreatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, m)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) stockLevels(w http.ResponseWriter, r *http.Request) {
	where := "WHERE 1=1"
	args := []any{}
	if wh := r.URL.Query().Get("warehouse_id"); wh != "" {
		where += " AND sl.warehouse_id = ?"
		args = append(args, wh)
	}
	if q := strings.TrimSpace(r.URL.Query().Get("q")); q != "" {
		where += " AND (p.name LIKE ? OR p.barcode = ?)"
		args = append(args, "%"+q+"%", q)
	}
	rows, err := s.db.Query(`SELECT sl.product_id, p.name, p.barcode, sl.warehouse_id,
			sl.qty_milli, sl.avg_cost
		FROM stock_levels sl JOIN products p ON p.id = sl.product_id `+where+
		` ORDER BY p.name LIMIT 1000`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	viewCost := s.can(r, "view_cost")
	items := []StockLevel{}
	for rows.Next() {
		var sl StockLevel
		if err := rows.Scan(&sl.ProductID, &sl.ProductName, &sl.Barcode,
			&sl.WarehouseID, &sl.QtyMilli, &sl.AvgCost); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if !viewCost {
			sl.AvgCost = 0
		}
		items = append(items, sl)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}
