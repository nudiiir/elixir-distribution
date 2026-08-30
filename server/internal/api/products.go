package api

import (
	"database/sql"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

type Product struct {
	ID             string  `json:"id"`
	Barcode        *string `json:"barcode"`
	SKU            *string `json:"sku"`
	Name           string  `json:"name"`
	NameAr         *string `json:"name_ar"`
	CategoryID     *string `json:"category_id"`
	Unit           string  `json:"unit"`
	IsWeighable    bool    `json:"is_weighable"`
	VatRate        int64   `json:"vat_rate"`
	PurchasePrice  int64   `json:"purchase_price"`
	PriceRetail    int64   `json:"price_retail"`
	PriceWholesale *int64  `json:"price_wholesale"`
	MinStockMilli  int64   `json:"min_stock_milli"`
	TrackLots      bool    `json:"track_lots"`
	Active         bool    `json:"active"`
	CreatedAt      string  `json:"created_at"`
	UpdatedAt      string  `json:"updated_at"`
}

const productCols = `id, barcode, sku, name, name_ar, category_id, unit, is_weighable,
	vat_rate, purchase_price, price_retail, price_wholesale, min_stock_milli, track_lots,
	active, created_at, updated_at`

func scanProduct(row interface{ Scan(...any) error }) (Product, error) {
	var p Product
	var weighable, trackLots, active int
	err := row.Scan(&p.ID, &p.Barcode, &p.SKU, &p.Name, &p.NameAr, &p.CategoryID, &p.Unit,
		&weighable, &p.VatRate, &p.PurchasePrice, &p.PriceRetail, &p.PriceWholesale,
		&p.MinStockMilli, &trackLots, &active, &p.CreatedAt, &p.UpdatedAt)
	p.IsWeighable, p.TrackLots, p.Active = weighable == 1, trackLots == 1, active == 1
	return p, err
}

// redactCost blanks purchase pricing for users without the view_cost right.
func (s *Server) redactCost(r *http.Request, p *Product) {
	if !s.can(r, "view_cost") {
		p.PurchasePrice = 0
	}
}

func (s *Server) listProducts(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))

	where := "WHERE active = 1"
	args := []any{}
	if r.URL.Query().Get("include_inactive") == "true" {
		where = "WHERE 1=1"
	}
	if q != "" {
		where += " AND (name LIKE ? OR name_ar LIKE ? OR barcode = ? OR sku = ?)"
		like := "%" + q + "%"
		args = append(args, like, like, q, q)
	}
	args = append(args, limit, offset)

	rows, err := s.db.Query(`SELECT `+productCols+` FROM products `+where+
		` ORDER BY name LIMIT ? OFFSET ?`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Product{}
	for rows.Next() {
		p, err := scanProduct(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		s.redactCost(r, &p)
		items = append(items, p)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type productInput struct {
	Barcode        *string `json:"barcode"`
	SKU            *string `json:"sku"`
	Name           string  `json:"name"`
	NameAr         *string `json:"name_ar"`
	CategoryID     *string `json:"category_id"`
	Unit           string  `json:"unit"`
	IsWeighable    bool    `json:"is_weighable"`
	VatRate        int64   `json:"vat_rate"`
	PurchasePrice  int64   `json:"purchase_price"`
	PriceRetail    int64   `json:"price_retail"`
	PriceWholesale *int64  `json:"price_wholesale"`
	MinStockMilli  int64   `json:"min_stock_milli"`
	TrackLots      bool    `json:"track_lots"`
	Active         *bool   `json:"active"`
}

func (in *productInput) normalize() {
	if in.Unit == "" {
		in.Unit = "piece"
	}
	if in.Barcode != nil && strings.TrimSpace(*in.Barcode) == "" {
		in.Barcode = nil
	}
}

func (s *Server) createProduct(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "products") {
		forbid(w)
		return
	}
	var in productInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		writeErr(w, http.StatusBadRequest, "name is required")
		return
	}
	in.normalize()
	id, now := domain.NewID(), domain.NowISO()
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	_, err := s.db.Exec(`INSERT INTO products (id, barcode, sku, name, name_ar, category_id, unit,
			is_weighable, vat_rate, purchase_price, price_retail, price_wholesale, min_stock_milli,
			track_lots, active, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, in.Barcode, in.SKU, in.Name, in.NameAr, in.CategoryID, in.Unit,
		b2i(in.IsWeighable), in.VatRate, in.PurchasePrice, in.PriceRetail, in.PriceWholesale,
		in.MinStockMilli, b2i(in.TrackLots), b2i(active), now, now)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	s.getByID(w, r, id)
}

func (s *Server) getProduct(w http.ResponseWriter, r *http.Request) {
	s.getByID(w, r, chi.URLParam(r, "id"))
}

func (s *Server) getByID(w http.ResponseWriter, r *http.Request, id string) {
	p, err := scanProduct(s.db.QueryRow(`SELECT `+productCols+` FROM products WHERE id = ?`, id))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "product not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.redactCost(r, &p)
	writeJSON(w, http.StatusOK, p)
}

func (s *Server) updateProduct(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "products") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in productInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		writeErr(w, http.StatusBadRequest, "name is required")
		return
	}
	in.normalize()
	// A user allowed to edit products but not to see costs must not wipe the
	// (redacted) purchase price they never saw.
	if !s.can(r, "view_cost") {
		s.db.QueryRow(`SELECT purchase_price FROM products WHERE id = ?`, id).
			Scan(&in.PurchasePrice)
	}
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	res, err := s.db.Exec(`UPDATE products SET barcode=?, sku=?, name=?, name_ar=?, category_id=?,
			unit=?, is_weighable=?, vat_rate=?, purchase_price=?, price_retail=?, price_wholesale=?,
			min_stock_milli=?, track_lots=?, active=?, updated_at=?
		WHERE id=?`,
		in.Barcode, in.SKU, in.Name, in.NameAr, in.CategoryID, in.Unit,
		b2i(in.IsWeighable), in.VatRate, in.PurchasePrice, in.PriceRetail, in.PriceWholesale,
		in.MinStockMilli, b2i(in.TrackLots), b2i(active), domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "product not found")
		return
	}
	s.getByID(w, r, id)
}

func (s *Server) deactivateProduct(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "products") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	res, err := s.db.Exec(`UPDATE products SET active = 0, updated_at = ? WHERE id = ?`,
		domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "product not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deactivated"})
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}
