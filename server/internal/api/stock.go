package api

import (
	"net/http"
	"strconv"
	"strings"
)

type StockLevel struct {
	ProductID     string  `json:"product_id"`
	ProductName   string  `json:"product_name"`
	Barcode       *string `json:"barcode"`
	WarehouseID   string  `json:"warehouse_id"`
	WarehouseName string  `json:"warehouse_name"`
	QtyMilli      int64   `json:"qty_milli"`
	AvgCost       int64   `json:"avg_cost"`
	// Valeur au coût (centimes) : qté × CMUP, ou somme des dépôts en mode agrégé.
	Value int64 `json:"value"`

	// Contexte produit pour les filtres et les indicateurs de l'écran Stock.
	CategoryID          *string `json:"category_id"`
	CategoryName        *string `json:"category_name"`
	Brand               string  `json:"brand"`
	PriceRetail         int64   `json:"price_retail"`
	MinStockMilli       int64   `json:"min_stock_milli"`
	Unit                string  `json:"unit"`
	DefaultSupplierID   *string `json:"default_supplier_id"`
	DefaultSupplierName *string `json:"default_supplier_name"`
	ImageRev            int64   `json:"image_rev"`
	Kind                string  `json:"kind"`
	VatRate             int64   `json:"vat_rate"`
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

// stockLevels lists stock rows.
//
// Default mode (used by the POS, dashboard, editor…): one row per existing
// product × warehouse cache row, capped at 1000.
//
// full=1 (écran Stock) : one row per ACTIVE, non-service product — products
// never stocked appear with 0 (so « Rupture » is complete) — aggregated over
// the warehouses unless warehouse_id is given. No cap.
func (s *Server) stockLevels(w http.ResponseWriter, r *http.Request) {
	applyWarehouseScope(r) // users limited to their depots (ux_users.go)
	q := r.URL.Query()
	viewCost := s.can(r, "view_cost")
	if q.Get("full") == "1" {
		s.stockLevelsFull(w, r, viewCost)
		return
	}
	where := "WHERE 1=1"
	args := []any{}
	if wh := q.Get("warehouse_id"); wh != "" {
		where += " AND sl.warehouse_id = ?"
		args = append(args, wh)
	}
	if qs := strings.TrimSpace(q.Get("q")); qs != "" {
		where += " AND (p.name LIKE ? OR p.barcode = ?)"
		args = append(args, "%"+qs+"%", qs)
	}
	rows, err := s.db.Query(`SELECT sl.product_id, p.name, p.barcode, sl.warehouse_id,
			COALESCE(w.name,''), sl.qty_milli, sl.avg_cost,
			p.category_id, c.name, p.brand, p.price_retail, p.min_stock_milli, p.unit,
			p.default_supplier_id, sp.name, p.image_rev, p.kind, p.vat_rate
		FROM stock_levels sl JOIN products p ON p.id = sl.product_id
		LEFT JOIN warehouses w ON w.id = sl.warehouse_id
		LEFT JOIN product_categories c ON c.id = p.category_id
		LEFT JOIN partners sp ON sp.id = p.default_supplier_id `+where+
		` ORDER BY p.name LIMIT 1000`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []StockLevel{}
	for rows.Next() {
		var sl StockLevel
		if err := rows.Scan(&sl.ProductID, &sl.ProductName, &sl.Barcode,
			&sl.WarehouseID, &sl.WarehouseName, &sl.QtyMilli, &sl.AvgCost,
			&sl.CategoryID, &sl.CategoryName, &sl.Brand, &sl.PriceRetail, &sl.MinStockMilli,
			&sl.Unit, &sl.DefaultSupplierID, &sl.DefaultSupplierName, &sl.ImageRev, &sl.Kind, &sl.VatRate); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		sl.Value = stockMulMilli(sl.QtyMilli, sl.AvgCost)
		if !viewCost {
			sl.AvgCost, sl.Value = 0, 0
		}
		items = append(items, sl)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) stockLevelsFull(w http.ResponseWriter, r *http.Request, viewCost bool) {
	q := r.URL.Query()
	join := "LEFT JOIN stock_levels sl ON sl.product_id = p.id"
	args := []any{}
	wh := q.Get("warehouse_id")
	if wh != "" {
		join += " AND sl.warehouse_id = ?"
		args = append(args, wh)
	}
	where := "WHERE p.active = 1 AND p.kind <> 'service'"
	if qs := strings.TrimSpace(q.Get("q")); qs != "" {
		where += ` AND (p.name LIKE ? OR p.barcode = ? OR p.sku = ?
			OR EXISTS (SELECT 1 FROM product_barcodes b WHERE b.product_id = p.id AND b.barcode = ?))`
		args = append(args, "%"+qs+"%", qs, qs, qs)
	}
	rows, err := s.db.Query(`SELECT p.id, p.name, p.barcode,
			COALESCE(SUM(sl.qty_milli),0),
			COALESCE(SUM(CASE WHEN sl.qty_milli > 0 THEN sl.qty_milli * sl.avg_cost ELSE 0 END),0),
			COALESCE(MAX(sl.avg_cost),0),
			p.category_id, c.name, p.brand, p.price_retail, p.min_stock_milli, p.unit,
			p.default_supplier_id, sp.name, p.image_rev, p.kind, p.vat_rate
		FROM products p `+join+`
		LEFT JOIN product_categories c ON c.id = p.category_id
		LEFT JOIN partners sp ON sp.id = p.default_supplier_id `+where+`
		GROUP BY p.id ORDER BY p.name`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []StockLevel{}
	for rows.Next() {
		var sl StockLevel
		var valueMilli, maxAvg int64
		if err := rows.Scan(&sl.ProductID, &sl.ProductName, &sl.Barcode,
			&sl.QtyMilli, &valueMilli, &maxAvg,
			&sl.CategoryID, &sl.CategoryName, &sl.Brand, &sl.PriceRetail, &sl.MinStockMilli,
			&sl.Unit, &sl.DefaultSupplierID, &sl.DefaultSupplierName, &sl.ImageRev, &sl.Kind, &sl.VatRate); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		sl.WarehouseID = wh
		sl.Value = stockDivRound(valueMilli, 1000)
		// CMUP agrégé = valeur / quantité ; sans stock positif, le dernier
		// CMUP connu (une moyenne de rien n'est pas zéro dinar).
		if sl.QtyMilli > 0 {
			sl.AvgCost = stockDivRound(valueMilli, sl.QtyMilli)
		} else {
			sl.AvgCost = maxAvg
		}
		if !viewCost {
			sl.AvgCost, sl.Value = 0, 0
		}
		items = append(items, sl)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// stockMulMilli = qtyMilli × unit / 1000, rounded half-up (centimes).
func stockMulMilli(qtyMilli, unit int64) int64 { return stockDivRound(qtyMilli*unit, 1000) }

// stockDivRound is integer division rounded half away from zero.
func stockDivRound(n, d int64) int64 {
	if d == 0 {
		return 0
	}
	if d < 0 {
		n, d = -n, -d
	}
	if n >= 0 {
		return (n + d/2) / d
	}
	return -((-n + d/2) / d)
}
