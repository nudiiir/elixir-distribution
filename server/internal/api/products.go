package api

import (
	"crypto/rand"
	"database/sql"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

type Product struct {
	ID              string   `json:"id"`
	Barcode         *string  `json:"barcode"`
	SKU             *string  `json:"sku"`
	Name            string   `json:"name"`
	NameAr          *string  `json:"name_ar"`
	CategoryID      *string  `json:"category_id"`
	Unit            string   `json:"unit"`
	IsWeighable     bool     `json:"is_weighable"`
	VatRate         int64    `json:"vat_rate"`
	PurchasePrice   int64    `json:"purchase_price"`
	PriceRetail     int64    `json:"price_retail"`
	PriceWholesale  *int64   `json:"price_wholesale"`
	MinStockMilli   int64    `json:"min_stock_milli"`
	TrackLots       bool     `json:"track_lots"`
	Active          bool     `json:"active"`
	PromoPrice      *int64   `json:"promo_price"`
	PromoStart      *string  `json:"promo_start"`
	PromoEnd        *string  `json:"promo_end"`
	ParentProductID *string  `json:"parent_product_id"`
	VariantLabel    *string  `json:"variant_label"`
	WarrantyMonths  int64    `json:"warranty_months"`
	Barcodes        []string `json:"barcodes"`
	CreatedAt       string   `json:"created_at"`
	UpdatedAt       string   `json:"updated_at"`
}

const productCols = `id, barcode, sku, name, name_ar, category_id, unit, is_weighable,
	vat_rate, purchase_price, price_retail, price_wholesale, min_stock_milli, track_lots,
	active, promo_price, promo_start, promo_end, parent_product_id, variant_label,
	warranty_months, created_at, updated_at`

func scanProduct(row interface{ Scan(...any) error }) (Product, error) {
	var p Product
	var weighable, trackLots, active int
	err := row.Scan(&p.ID, &p.Barcode, &p.SKU, &p.Name, &p.NameAr, &p.CategoryID, &p.Unit,
		&weighable, &p.VatRate, &p.PurchasePrice, &p.PriceRetail, &p.PriceWholesale,
		&p.MinStockMilli, &trackLots, &active,
		&p.PromoPrice, &p.PromoStart, &p.PromoEnd, &p.ParentProductID, &p.VariantLabel,
		&p.WarrantyMonths, &p.CreatedAt, &p.UpdatedAt)
	p.IsWeighable, p.TrackLots, p.Active = weighable == 1, trackLots == 1, active == 1
	p.Barcodes = []string{}
	return p, err
}

// loadExtraBarcodes fills p.Barcodes for a batch of products in one query.
func (s *Server) loadExtraBarcodes(items []Product) {
	if len(items) == 0 {
		return
	}
	byID := map[string]*Product{}
	for i := range items {
		byID[items[i].ID] = &items[i]
	}
	rows, err := s.db.Query(`SELECT product_id, barcode FROM product_barcodes`)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var pid, bc string
		if rows.Scan(&pid, &bc) == nil {
			if p, ok := byID[pid]; ok {
				p.Barcodes = append(p.Barcodes, bc)
			}
		}
	}
}

// saveExtraBarcodes replaces a product's additional barcodes.
func (s *Server) saveExtraBarcodes(productID string, barcodes []string) error {
	if _, err := s.db.Exec(`DELETE FROM product_barcodes WHERE product_id = ?`, productID); err != nil {
		return err
	}
	now := domain.NowISO()
	for _, bc := range barcodes {
		bc = strings.TrimSpace(bc)
		if bc == "" {
			continue
		}
		if _, err := s.db.Exec(`INSERT OR IGNORE INTO product_barcodes (barcode, product_id, created_at)
			VALUES (?, ?, ?)`, bc, productID, now); err != nil {
			return err
		}
	}
	return nil
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
		where += ` AND (name LIKE ? OR name_ar LIKE ? OR barcode = ? OR sku = ?
			OR id IN (SELECT product_id FROM product_barcodes WHERE barcode = ?))`
		like := "%" + q + "%"
		args = append(args, like, like, q, q, q)
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
	s.loadExtraBarcodes(items)
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type productInput struct {
	Barcode         *string  `json:"barcode"`
	SKU             *string  `json:"sku"`
	Name            string   `json:"name"`
	NameAr          *string  `json:"name_ar"`
	CategoryID      *string  `json:"category_id"`
	Unit            string   `json:"unit"`
	IsWeighable     bool     `json:"is_weighable"`
	VatRate         int64    `json:"vat_rate"`
	PurchasePrice   int64    `json:"purchase_price"`
	PriceRetail     int64    `json:"price_retail"`
	PriceWholesale  *int64   `json:"price_wholesale"`
	MinStockMilli   int64    `json:"min_stock_milli"`
	TrackLots       bool     `json:"track_lots"`
	Active          *bool    `json:"active"`
	PromoPrice      *int64   `json:"promo_price"`
	PromoStart      *string  `json:"promo_start"`
	PromoEnd        *string  `json:"promo_end"`
	ParentProductID *string  `json:"parent_product_id"`
	VariantLabel    *string  `json:"variant_label"`
	WarrantyMonths  int64    `json:"warranty_months"`
	Barcodes        []string `json:"barcodes"`
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
			track_lots, active, promo_price, promo_start, promo_end,
			parent_product_id, variant_label, warranty_months, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, in.Barcode, in.SKU, in.Name, in.NameAr, in.CategoryID, in.Unit,
		b2i(in.IsWeighable), in.VatRate, in.PurchasePrice, in.PriceRetail, in.PriceWholesale,
		in.MinStockMilli, b2i(in.TrackLots), b2i(active),
		in.PromoPrice, in.PromoStart, in.PromoEnd, in.ParentProductID, in.VariantLabel,
		in.WarrantyMonths, now, now)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if in.Barcodes != nil {
		s.saveExtraBarcodes(id, in.Barcodes)
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
	batch := []Product{p}
	s.loadExtraBarcodes(batch)
	writeJSON(w, http.StatusOK, batch[0])
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
			min_stock_milli=?, track_lots=?, active=?,
			promo_price=?, promo_start=?, promo_end=?, parent_product_id=?, variant_label=?,
			warranty_months=?, updated_at=?
		WHERE id=?`,
		in.Barcode, in.SKU, in.Name, in.NameAr, in.CategoryID, in.Unit,
		b2i(in.IsWeighable), in.VatRate, in.PurchasePrice, in.PriceRetail, in.PriceWholesale,
		in.MinStockMilli, b2i(in.TrackLots), b2i(active),
		in.PromoPrice, in.PromoStart, in.PromoEnd, in.ParentProductID, in.VariantLabel,
		in.WarrantyMonths, domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "product not found")
		return
	}
	if in.Barcodes != nil {
		s.saveExtraBarcodes(id, in.Barcodes)
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

// generateBarcode mints an unused internal EAN-13. The 200 prefix is reserved
// by GS1 for in-store numbering, so these can never collide with a real
// manufacturer code.
func (s *Server) generateBarcode(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "products") {
		forbid(w)
		return
	}
	for tries := 0; tries < 200; tries++ {
		code, err := randomEAN13("200")
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		var n int
		s.db.QueryRow(`SELECT (SELECT COUNT(*) FROM products WHERE barcode = ?1)
			+ (SELECT COUNT(*) FROM product_barcodes WHERE barcode = ?1)`, code).Scan(&n)
		if n == 0 {
			writeJSON(w, http.StatusOK, map[string]string{"barcode": code})
			return
		}
	}
	writeErr(w, http.StatusInternalServerError, "could not generate a unique barcode")
}

func randomEAN13(prefix string) (string, error) {
	buf := make([]byte, 12-len(prefix))
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	digits := prefix
	for _, b := range buf {
		digits += strconv.Itoa(int(b) % 10)
	}
	sum := 0
	for i, c := range digits {
		d := int(c - '0')
		if i%2 == 1 {
			d *= 3
		}
		sum += d
	}
	return digits + strconv.Itoa((10-sum%10)%10), nil
}
