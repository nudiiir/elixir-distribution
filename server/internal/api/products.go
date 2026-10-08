package api

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
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
	TrackSerials    bool     `json:"track_serials"`
	Description     string   `json:"description"`
	Brand           string   `json:"brand"`
	TrackExpiry     bool     `json:"track_expiry"`
	DefaultSupplier *string  `json:"default_supplier_id"`
	Barcodes        []string `json:"barcodes"`
	BarcodesEx      []BarcodeEntry `json:"barcodes_ex"`
	Packagings      []Packaging    `json:"packagings"`
	// Kind: 'standard' | 'service' (un service ne bouge jamais le stock).
	Kind string `json:"kind"`
	// ImageRev change à chaque ajout/suppression de photo (0 = aucune) ;
	// le client s'en sert comme clé de cache (?v=rev).
	ImageRev   int64  `json:"image_rev"`
	ImageCount int64  `json:"image_count"`
	CreatedAt  string `json:"created_at"`
	UpdatedAt  string `json:"updated_at"`
}

// BarcodeEntry is one additional barcode with its optional descriptive label
// ("2001156633089 - Pomme"). The label drives nothing.
type BarcodeEntry struct {
	Code  string `json:"code"`
	Label string `json:"label"`
}

// Packaging is a purchasing unit: carton = 24 pièces. Its own barcode, when
// scanned at reception, selects the pack and its factor.
type Packaging struct {
	ID          string  `json:"id,omitempty"`
	Name        string  `json:"name"`
	FactorMilli int64   `json:"factor_milli"`
	Barcode     *string `json:"barcode"`
}

const productCols = `id, barcode, sku, name, name_ar, category_id, unit, is_weighable,
	vat_rate, purchase_price, price_retail, price_wholesale, min_stock_milli, track_lots,
	active, promo_price, promo_start, promo_end, parent_product_id, variant_label,
	warranty_months, track_serials, description, brand, track_expiry, default_supplier_id,
	kind, image_rev,
	(SELECT COUNT(*) FROM product_images pi WHERE pi.product_id = products.id),
	created_at, updated_at`

func scanProduct(row interface{ Scan(...any) error }) (Product, error) {
	var p Product
	var weighable, trackLots, active, trackSerials, trackExpiry int
	err := row.Scan(&p.ID, &p.Barcode, &p.SKU, &p.Name, &p.NameAr, &p.CategoryID, &p.Unit,
		&weighable, &p.VatRate, &p.PurchasePrice, &p.PriceRetail, &p.PriceWholesale,
		&p.MinStockMilli, &trackLots, &active,
		&p.PromoPrice, &p.PromoStart, &p.PromoEnd, &p.ParentProductID, &p.VariantLabel,
		&p.WarrantyMonths, &trackSerials, &p.Description, &p.Brand, &trackExpiry,
		&p.DefaultSupplier, &p.Kind, &p.ImageRev, &p.ImageCount, &p.CreatedAt, &p.UpdatedAt)
	p.IsWeighable, p.TrackLots, p.Active = weighable == 1, trackLots == 1, active == 1
	p.TrackSerials, p.TrackExpiry = trackSerials == 1, trackExpiry == 1
	// La colonne image_rev ne fait que croître (une photo supprimée puis une
	// autre ajoutée ne réutilise jamais une clé de cache) ; le JSON dit 0
	// quand il n'y a plus de photo.
	if p.ImageCount == 0 {
		p.ImageRev = 0
	}
	if p.Kind == "" {
		p.Kind = "standard"
	}
	p.Barcodes = []string{}
	p.BarcodesEx = []BarcodeEntry{}
	p.Packagings = []Packaging{}
	return p, err
}

// loadExtraBarcodes fills p.Barcodes / p.BarcodesEx / p.Packagings for a batch
// of products in one query each.
func (s *Server) loadExtraBarcodes(items []Product) {
	if len(items) == 0 {
		return
	}
	byID := map[string]*Product{}
	for i := range items {
		byID[items[i].ID] = &items[i]
	}
	rows, err := s.db.Query(`SELECT product_id, barcode, label FROM product_barcodes`)
	if err != nil {
		return
	}
	for rows.Next() {
		var pid, bc, label string
		if rows.Scan(&pid, &bc, &label) == nil {
			if p, ok := byID[pid]; ok {
				p.Barcodes = append(p.Barcodes, bc)
				p.BarcodesEx = append(p.BarcodesEx, BarcodeEntry{Code: bc, Label: label})
			}
		}
	}
	rows.Close()
	prow, err := s.db.Query(`SELECT id, product_id, name, factor_milli, barcode FROM packagings`)
	if err != nil {
		return
	}
	defer prow.Close()
	for prow.Next() {
		var id, pid, name string
		var factor int64
		var bc *string
		if prow.Scan(&id, &pid, &name, &factor, &bc) == nil {
			if p, ok := byID[pid]; ok {
				p.Packagings = append(p.Packagings, Packaging{ID: id, Name: name, FactorMilli: factor, Barcode: bc})
			}
		}
	}
}

// barcodeOwner names the product that already uses a barcode (excluding one id).
// Checks the primary column, the extra barcodes and the packaging barcodes —
// one barcode belongs to exactly one product across the whole shop.
func (s *Server) barcodeOwner(code, excludeProductID string) string {
	code = strings.TrimSpace(code)
	if code == "" {
		return ""
	}
	var name string
	s.db.QueryRow(`SELECT name FROM products WHERE barcode = ? AND id <> ?`,
		code, excludeProductID).Scan(&name)
	if name != "" {
		return name
	}
	s.db.QueryRow(`SELECT p.name FROM product_barcodes b JOIN products p ON p.id = b.product_id
		WHERE b.barcode = ? AND b.product_id <> ?`, code, excludeProductID).Scan(&name)
	if name != "" {
		return name
	}
	s.db.QueryRow(`SELECT p.name FROM packagings k JOIN products p ON p.id = k.product_id
		WHERE k.barcode = ? AND k.product_id <> ?`, code, excludeProductID).Scan(&name)
	return name
}

// saveExtraBarcodes replaces a product's additional barcodes (with labels).
func (s *Server) saveExtraBarcodes(productID string, entries []BarcodeEntry) error {
	if _, err := s.db.Exec(`DELETE FROM product_barcodes WHERE product_id = ?`, productID); err != nil {
		return err
	}
	now := domain.NowISO()
	for _, e := range entries {
		code := strings.TrimSpace(e.Code)
		if code == "" {
			continue
		}
		if _, err := s.db.Exec(`INSERT OR IGNORE INTO product_barcodes (barcode, product_id, label, created_at)
			VALUES (?, ?, ?, ?)`, code, productID, strings.TrimSpace(e.Label), now); err != nil {
			return err
		}
	}
	return nil
}

// savePackagings replaces a product's purchasing units.
func (s *Server) savePackagings(productID string, packs []Packaging) error {
	if _, err := s.db.Exec(`DELETE FROM packagings WHERE product_id = ?`, productID); err != nil {
		return err
	}
	now := domain.NowISO()
	for _, p := range packs {
		name := strings.TrimSpace(p.Name)
		if name == "" || p.FactorMilli <= 0 {
			continue
		}
		if _, err := s.db.Exec(`INSERT INTO packagings (id, product_id, name, factor_milli, barcode, created_at)
			VALUES (?, ?, ?, ?, ?, ?)`,
			domain.NewID(), productID, name, p.FactorMilli, p.Barcode, now); err != nil {
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
		where += ` AND (name LIKE ? OR name_ar LIKE ? OR brand LIKE ? OR barcode = ? OR sku = ?
			OR id IN (SELECT product_id FROM product_barcodes WHERE barcode = ?)
			OR id IN (SELECT product_id FROM packagings WHERE barcode = ?))`
		like := "%" + q + "%"
		args = append(args, like, like, like, q, q, q, q)
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
	TrackSerials    bool     `json:"track_serials"`
	Description     string   `json:"description"`
	Brand           string   `json:"brand"`
	TrackExpiry     bool     `json:"track_expiry"`
	DefaultSupplier *string  `json:"default_supplier_id"`
	Barcodes        []string `json:"barcodes"`
	BarcodesEx      []BarcodeEntry `json:"barcodes_ex"`
	Packagings      []Packaging    `json:"packagings"`
	// Kind: 'standard' (défaut) | 'service'. Absent à la mise à jour = inchangé.
	Kind *string `json:"kind"`
	// Stock initial : crée et valide un document « Stock initial » à la création.
	InitialQtyMilli    int64   `json:"initial_qty_milli"`
	InitialWarehouseID *string `json:"initial_warehouse_id"`
}

// barcodeEntries normalises the two accepted shapes (legacy list of strings,
// new list with labels) into one.
func (in *productInput) barcodeEntries() []BarcodeEntry {
	if in.BarcodesEx != nil {
		return in.BarcodesEx
	}
	if in.Barcodes == nil {
		return nil
	}
	out := make([]BarcodeEntry, 0, len(in.Barcodes))
	for _, b := range in.Barcodes {
		out = append(out, BarcodeEntry{Code: b})
	}
	return out
}

// checkBarcodes refuses any barcode already owned by another product, naming it.
func (s *Server) checkBarcodes(in *productInput, excludeID string) string {
	var codes []string
	if in.Barcode != nil {
		codes = append(codes, *in.Barcode)
	}
	for _, e := range in.barcodeEntries() {
		codes = append(codes, e.Code)
	}
	for _, p := range in.Packagings {
		if p.Barcode != nil {
			codes = append(codes, *p.Barcode)
		}
	}
	for _, c := range codes {
		if owner := s.barcodeOwner(c, excludeID); owner != "" {
			return fmt.Sprintf("le code-barres %s est déjà utilisé par « %s »", strings.TrimSpace(c), owner)
		}
	}
	return ""
}

func (in *productInput) normalize() {
	if in.Unit == "" {
		in.Unit = "piece"
	}
	if in.Barcode != nil && strings.TrimSpace(*in.Barcode) == "" {
		in.Barcode = nil
	}
	if in.Kind != nil {
		k := strings.TrimSpace(*in.Kind)
		in.Kind = &k
	}
}

// validKind accepts the two product types; nil means « not sent ».
func validKind(k *string) bool {
	return k == nil || *k == "standard" || *k == "service"
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
	if !validKind(in.Kind) {
		writeErr(w, http.StatusBadRequest, "type de produit invalide (standard ou service)")
		return
	}
	kind := "standard"
	if in.Kind != nil {
		kind = *in.Kind
	}
	if kind == "service" {
		// Un service n'a pas de stock : pas de stock initial.
		in.InitialQtyMilli = 0
	}
	// Le prix d'achat est obligatoire dès qu'une quantité initiale est saisie —
	// un stock qui entre sans coût fausserait le CMUP dès le premier jour.
	if in.InitialQtyMilli > 0 && in.PurchasePrice <= 0 {
		writeErr(w, http.StatusBadRequest,
			"le prix d'achat est obligatoire quand une quantité initiale est saisie")
		return
	}
	if msg := s.checkBarcodes(&in, ""); msg != "" {
		writeErr(w, http.StatusConflict, msg)
		return
	}
	id, now := domain.NewID(), domain.NowISO()
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	_, err := s.db.Exec(`INSERT INTO products (id, barcode, sku, name, name_ar, category_id, unit,
			is_weighable, vat_rate, purchase_price, price_retail, price_wholesale, min_stock_milli,
			track_lots, active, promo_price, promo_start, promo_end,
			parent_product_id, variant_label, warranty_months, track_serials, description,
			brand, track_expiry, default_supplier_id, kind, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, in.Barcode, in.SKU, in.Name, in.NameAr, in.CategoryID, in.Unit,
		b2i(in.IsWeighable), in.VatRate, in.PurchasePrice, in.PriceRetail, in.PriceWholesale,
		in.MinStockMilli, b2i(in.TrackLots), b2i(active),
		in.PromoPrice, in.PromoStart, in.PromoEnd, in.ParentProductID, in.VariantLabel,
		in.WarrantyMonths, b2i(in.TrackSerials), in.Description,
		strings.TrimSpace(in.Brand), b2i(in.TrackExpiry), in.DefaultSupplier, kind, now, now)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if entries := in.barcodeEntries(); entries != nil {
		s.saveExtraBarcodes(id, entries)
	}
	if in.Packagings != nil {
		s.savePackagings(id, in.Packagings)
	}
	// Stock initial : un document, jamais une quantité posée à la main. Rien ne
	// change le stock hors validation d'un document.
	if in.InitialQtyMilli > 0 {
		if err := s.createInitialStock(r, id, in.Name, in.InitialQtyMilli,
			in.PurchasePrice, in.InitialWarehouseID); err != nil {
			writeErr(w, http.StatusConflict, "produit créé mais stock initial impossible : "+err.Error())
			return
		}
	}
	s.getByID(w, r, id)
}

// createInitialStock posts a STOCK_ADJUSTMENT (motif « stock initial ») whose
// line carries the declared quantity at the declared cost.
func (s *Server) createInitialStock(r *http.Request, productID, name string,
	qtyMilli, unitCost int64, warehouseID *string) error {
	whID := ""
	if warehouseID != nil {
		whID = *warehouseID
	}
	if whID == "" {
		if err := s.db.QueryRow(`SELECT id FROM warehouses WHERE is_default=1 AND active=1 LIMIT 1`).
			Scan(&whID); err != nil {
			if err := s.db.QueryRow(`SELECT id FROM warehouses WHERE active=1 LIMIT 1`).Scan(&whID); err != nil {
				return errors.New("aucun dépôt disponible")
			}
		}
	}
	docID, now := domain.NewID(), domain.NowISO()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT INTO documents (id, doc_type, status, doc_date, warehouse_id,
			reason, notes, created_at, updated_at)
		VALUES (?, 'STOCK_ADJUSTMENT', 'draft', ?, ?, 'stock initial', ?, ?, ?)`,
		docID, now[:10], whID, "Stock initial — "+name, now, now); err != nil {
		return err
	}
	// La ligne d'un ajustement est signée ; unit_price porte le coût déclaré,
	// que le posting valorise (ajustement entrant = entrée valorisée).
	if _, err := tx.Exec(`INSERT INTO document_lines (id, document_id, position, product_id,
			description, qty_milli, unit_price, discount_pct, vat_rate, pack_factor_milli, created_at)
		VALUES (?, ?, 0, ?, ?, ?, ?, 0, 0, 1000, ?)`,
		domain.NewID(), docID, productID, name, qtyMilli, unitCost, now); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	user := authFrom(r)
	userID := ""
	if user != nil {
		userID = user.ID
	}
	_, err = domain.Post(s.db, docID, userID)
	return err
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
	if !validKind(in.Kind) {
		writeErr(w, http.StatusBadRequest, "type de produit invalide (standard ou service)")
		return
	}
	if in.Kind == nil {
		// Ancien client : le type stocké reste.
		var k string
		if s.db.QueryRow(`SELECT kind FROM products WHERE id = ?`, id).Scan(&k) == nil {
			in.Kind = &k
		} else {
			std := "standard"
			in.Kind = &std
		}
	}
	if msg := s.checkBarcodes(&in, id); msg != "" {
		writeErr(w, http.StatusConflict, msg)
		return
	}
	// Le prix d'achat n'est modifiable qu'à la création : ensuite seules les
	// réceptions parlent (CMUP). On préserve la valeur stockée, quoi qu'envoie
	// le client — même règle que la redaction view_cost.
	s.db.QueryRow(`SELECT purchase_price FROM products WHERE id = ?`, id).
		Scan(&in.PurchasePrice)
	// Price changes go to the journal.
	var oldRetail int64
	var name string
	if s.db.QueryRow(`SELECT price_retail, name FROM products WHERE id = ?`, id).
		Scan(&oldRetail, &name) == nil && oldRetail != in.PriceRetail {
		s.audit(r, "product.price_change", "product", id,
			fmt.Sprintf("%s : prix de vente %s → %s DA", name,
				centimes(oldRetail), centimes(in.PriceRetail)))
	}
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	res, err := s.db.Exec(`UPDATE products SET barcode=?, sku=?, name=?, name_ar=?, category_id=?,
			unit=?, is_weighable=?, vat_rate=?, purchase_price=?, price_retail=?, price_wholesale=?,
			min_stock_milli=?, track_lots=?, active=?,
			promo_price=?, promo_start=?, promo_end=?, parent_product_id=?, variant_label=?,
			warranty_months=?, description=?, brand=?, track_expiry=?, default_supplier_id=?,
			track_serials=?, kind=?, updated_at=?
		WHERE id=?`,
		in.Barcode, in.SKU, in.Name, in.NameAr, in.CategoryID, in.Unit,
		b2i(in.IsWeighable), in.VatRate, in.PurchasePrice, in.PriceRetail, in.PriceWholesale,
		in.MinStockMilli, b2i(in.TrackLots), b2i(active),
		in.PromoPrice, in.PromoStart, in.PromoEnd, in.ParentProductID, in.VariantLabel,
		in.WarrantyMonths, in.Description, strings.TrimSpace(in.Brand), b2i(in.TrackExpiry),
		in.DefaultSupplier, b2i(in.TrackSerials), *in.Kind, domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "product not found")
		return
	}
	if entries := in.barcodeEntries(); entries != nil {
		s.saveExtraBarcodes(id, entries)
	}
	if in.Packagings != nil {
		s.savePackagings(id, in.Packagings)
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

// centimes formats an amount for audit messages ("1250,50").
func centimes(v int64) string {
	return fmt.Sprintf("%d,%02d", v/100, v%100)
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
