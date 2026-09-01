package api

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// ficheProduct answers the question the merchant actually asks: why does it
// say forty-five when I count forty-three. Everything on it is recomputed from
// the ledger and the caches — nothing here is stored.
func (s *Server) ficheProduct(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

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
	p = batch[0]

	canCost := s.can(r, "view_cost")

	// Niveaux par dépôt.
	type level struct {
		WarehouseID string `json:"warehouse_id"`
		Warehouse   string `json:"warehouse"`
		QtyMilli    int64  `json:"qty_milli"`
		AvgCost     int64  `json:"avg_cost"`
	}
	levels := []level{}
	rows, err := s.db.Query(`SELECT sl.warehouse_id, w.name, sl.qty_milli, sl.avg_cost
		FROM stock_levels sl JOIN warehouses w ON w.id = sl.warehouse_id
		WHERE sl.product_id = ?`, id)
	if err == nil {
		for rows.Next() {
			var l level
			if rows.Scan(&l.WarehouseID, &l.Warehouse, &l.QtyMilli, &l.AvgCost) == nil {
				if !canCost {
					l.AvgCost = 0
				}
				levels = append(levels, l)
			}
		}
		rows.Close()
	}

	// Lots avec quantité restante (somme du journal par lot), triés par DLC.
	type lotRow struct {
		ID        string  `json:"id"`
		LotNumber string  `json:"lot_number"`
		Expiry    *string `json:"expiry_date"`
		QtyMilli  int64   `json:"qty_milli"`
	}
	lots := []lotRow{}
	rows, err = s.db.Query(`SELECT l.id, l.lot_number, l.expiry_date,
			COALESCE((SELECT SUM(sl.qty_delta_milli) FROM stock_ledger sl WHERE sl.lot_id = l.id), 0)
		FROM lots l WHERE l.product_id = ?
		ORDER BY l.expiry_date IS NULL, l.expiry_date`, id)
	if err == nil {
		for rows.Next() {
			var l lotRow
			if rows.Scan(&l.ID, &l.LotNumber, &l.Expiry, &l.QtyMilli) == nil {
				lots = append(lots, l)
			}
		}
		rows.Close()
	}

	// Derniers mouvements (5), avec le document derrière chacun.
	type mv struct {
		Date      string  `json:"date"`
		DocType   string  `json:"doc_type"`
		DocNumber *string `json:"doc_number"`
		DocID     string  `json:"doc_id"`
		Warehouse string  `json:"warehouse"`
		QtyMilli  int64   `json:"qty_milli"`
		UnitCost  int64   `json:"unit_cost"`
	}
	moves := []mv{}
	rows, err = s.db.Query(`SELECT sl.created_at, d.doc_type, d.number, d.id, w.name,
			sl.qty_delta_milli, sl.unit_cost
		FROM stock_ledger sl
		JOIN documents d ON d.id = sl.document_id
		JOIN warehouses w ON w.id = sl.warehouse_id
		WHERE sl.product_id = ?
		ORDER BY sl.created_at DESC, sl.id DESC LIMIT ?`, id, ficheMoveLimit(r))
	if err == nil {
		for rows.Next() {
			var m mv
			if rows.Scan(&m.Date, &m.DocType, &m.DocNumber, &m.DocID, &m.Warehouse,
				&m.QtyMilli, &m.UnitCost) == nil {
				if !canCost {
					m.UnitCost = 0
				}
				moves = append(moves, m)
			}
		}
		rows.Close()
	}

	// Dernier prix payé à chaque fournisseur.
	type sup struct {
		PartnerID string `json:"partner_id"`
		Partner   string `json:"partner"`
		UnitCost  int64  `json:"unit_cost"`
		Date      string `json:"date"`
	}
	suppliers := []sup{}
	if canCost {
		rows, err = s.db.Query(`SELECT sp.partner_id, pa.name, sp.unit_cost, MAX(sp.created_at)
			FROM supplier_prices sp JOIN partners pa ON pa.id = sp.partner_id
			WHERE sp.product_id = ?
			GROUP BY sp.partner_id ORDER BY MAX(sp.created_at) DESC`, id)
		if err == nil {
			for rows.Next() {
				var v sup
				if rows.Scan(&v.PartnerID, &v.Partner, &v.UnitCost, &v.Date) == nil {
					suppliers = append(suppliers, v)
				}
			}
			rows.Close()
		}
	}

	// Déclinaisons (produits enfants) avec leur stock total.
	type variant struct {
		Product
		StockMilli int64 `json:"stock_milli"`
	}
	variants := []variant{}
	rows, err = s.db.Query(`SELECT `+productCols+` FROM products
		WHERE parent_product_id = ? AND active = 1 ORDER BY name`, id)
	if err == nil {
		var vs []Product
		for rows.Next() {
			if vp, err := scanProduct(rows); err == nil {
				s.redactCost(r, &vp)
				vs = append(vs, vp)
			}
		}
		rows.Close()
		s.loadExtraBarcodes(vs)
		for _, vp := range vs {
			var stock int64
			s.db.QueryRow(`SELECT COALESCE(SUM(qty_milli),0) FROM stock_levels WHERE product_id=?`,
				vp.ID).Scan(&stock)
			variants = append(variants, variant{Product: vp, StockMilli: stock})
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"product":   p,
		"levels":    levels,
		"lots":      lots,
		"moves":     moves,
		"suppliers": suppliers,
		"variants":  variants,
	})
}

func ficheMoveLimit(r *http.Request) int {
	if r.URL.Query().Get("full") == "1" {
		return 200
	}
	return 5
}

// splitProduct — « Séparer en déclinaisons » : a merged product whose barcodes
// were one stock pool becomes one variant per barcode. The software genuinely
// does not know the per-barcode breakdown, so the caller supplies the counted
// split; it is refused unless the quantities sum to the current stock.
func (s *Server) splitProduct(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "products") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in struct {
		WarehouseID string `json:"warehouse_id"`
		Items       []struct {
			Barcode  string `json:"barcode"`
			Suffix   string `json:"suffix"`
			QtyMilli int64  `json:"qty_milli"`
		} `json:"items"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(in.Items) < 2 {
		writeErr(w, http.StatusBadRequest, "au moins deux déclinaisons sont nécessaires")
		return
	}

	p, err := scanProduct(s.db.QueryRow(`SELECT `+productCols+` FROM products WHERE id = ?`, id))
	if err != nil {
		writeErr(w, http.StatusNotFound, "product not found")
		return
	}

	// Le partage se fait dépôt par dépôt ; v1 exige que le stock soit dans un
	// seul dépôt (transférer d'abord sinon).
	var nWarehouses int
	s.db.QueryRow(`SELECT COUNT(*) FROM stock_levels WHERE product_id=? AND qty_milli <> 0`, id).
		Scan(&nWarehouses)
	if nWarehouses > 1 {
		writeErr(w, http.StatusConflict,
			"le stock est réparti sur plusieurs dépôts — regroupez-le par transfert avant de séparer")
		return
	}
	if in.WarehouseID == "" {
		if err := s.db.QueryRow(`SELECT warehouse_id FROM stock_levels
			WHERE product_id=? AND qty_milli <> 0 LIMIT 1`, id).Scan(&in.WarehouseID); err != nil {
			s.db.QueryRow(`SELECT id FROM warehouses WHERE is_default=1 LIMIT 1`).Scan(&in.WarehouseID)
		}
	}

	var current int64
	s.db.QueryRow(`SELECT COALESCE(SUM(qty_milli),0) FROM stock_levels WHERE product_id=?`, id).
		Scan(&current)
	var sum int64
	for _, it := range in.Items {
		if strings.TrimSpace(it.Suffix) == "" {
			writeErr(w, http.StatusBadRequest, "chaque déclinaison exige un suffixe")
			return
		}
		if it.QtyMilli < 0 {
			writeErr(w, http.StatusBadRequest, "quantité négative refusée")
			return
		}
		sum += it.QtyMilli
	}
	if sum != current {
		writeErr(w, http.StatusConflict, fmt.Sprintf(
			"la somme des quantités (%s) doit égaler le stock actuel (%s)",
			fmtMilli(sum), fmtMilli(current)))
		return
	}

	avgCost := int64(0)
	s.db.QueryRow(`SELECT avg_cost FROM stock_levels WHERE product_id=? AND warehouse_id=?`,
		id, in.WarehouseID).Scan(&avgCost)

	now := domain.NowISO()
	// 1. Créer les déclinaisons (le code-barres quitte le pool du parent).
	var variantIDs []string
	for _, it := range in.Items {
		vid := domain.NewID()
		barcode := strings.TrimSpace(it.Barcode)
		var bc any
		if barcode != "" {
			bc = barcode
			s.db.Exec(`DELETE FROM product_barcodes WHERE product_id=? AND barcode=?`, id, barcode)
			if barcode == strings.TrimSpace(sqlStr(p.Barcode)) {
				s.db.Exec(`UPDATE products SET barcode=NULL, updated_at=? WHERE id=?`, now, id)
			}
		}
		if _, err := s.db.Exec(`INSERT INTO products (id, barcode, name, name_ar, category_id, unit,
				is_weighable, vat_rate, purchase_price, price_retail, price_wholesale,
				min_stock_milli, track_lots, track_expiry, active, parent_product_id, variant_label,
				warranty_months, track_serials, description, brand, default_supplier_id,
				created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			vid, bc, p.Name+" — "+strings.TrimSpace(it.Suffix), p.NameAr, p.CategoryID, p.Unit,
			b2i(p.IsWeighable), p.VatRate, avgCost, p.PriceRetail, p.PriceWholesale,
			p.MinStockMilli, b2i(p.TrackLots), b2i(p.TrackExpiry), id, strings.TrimSpace(it.Suffix),
			p.WarrantyMonths, b2i(p.TrackSerials), p.Description, p.Brand, p.DefaultSupplier,
			now, now); err != nil {
			writeErr(w, http.StatusConflict, err.Error())
			return
		}
		variantIDs = append(variantIDs, vid)
	}

	// 2. Un document d'ajustement déplace le stock du pool vers les
	// déclinaisons — jamais une écriture directe.
	docID := domain.NewID()
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT INTO documents (id, doc_type, status, doc_date, warehouse_id,
			reason, notes, created_at, updated_at)
		VALUES (?, 'STOCK_ADJUSTMENT', 'draft', ?, ?, 'séparation en déclinaisons', ?, ?, ?)`,
		docID, now[:10], in.WarehouseID, "Séparation de "+p.Name, now, now); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	pos := 0
	if current != 0 {
		if _, err := tx.Exec(`INSERT INTO document_lines (id, document_id, position, product_id,
				description, qty_milli, unit_price, pack_factor_milli, created_at)
			VALUES (?, ?, ?, ?, ?, ?, 0, 1000, ?)`,
			domain.NewID(), docID, pos, id, p.Name, -current, now); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		pos++
	}
	for i, it := range in.Items {
		if it.QtyMilli == 0 {
			continue
		}
		if _, err := tx.Exec(`INSERT INTO document_lines (id, document_id, position, product_id,
				description, qty_milli, unit_price, pack_factor_milli, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, 1000, ?)`,
			domain.NewID(), docID, pos, variantIDs[i], p.Name+" — "+it.Suffix,
			it.QtyMilli, avgCost, now); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		pos++
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if pos > 0 {
		user := authFrom(r)
		userID := ""
		if user != nil {
			userID = user.ID
		}
		if _, err := domain.Post(s.db, docID, userID); err != nil {
			writeErr(w, http.StatusConflict, "séparation créée mais validation impossible : "+err.Error())
			return
		}
	}
	s.audit(r, "product.split", "product", id,
		fmt.Sprintf("%s séparé en %d déclinaisons", p.Name, len(in.Items)))
	s.getByID(w, r, id)
}

func sqlStr(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func fmtMilli(v int64) string {
	if v%1000 == 0 {
		return fmt.Sprintf("%d", v/1000)
	}
	return fmt.Sprintf("%d,%03d", v/1000, v%1000)
}

// lastSupplierPrices returns, for one supplier, the last effective unit cost
// paid per product — the reception screen warns beyond 15 % variance.
func (s *Server) lastSupplierPrices(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "purchases") {
		forbid(w)
		return
	}
	partnerID := r.URL.Query().Get("partner_id")
	if partnerID == "" {
		writeErr(w, http.StatusBadRequest, "partner_id requis")
		return
	}
	rows, err := s.db.Query(`SELECT product_id, unit_cost FROM supplier_prices sp
		WHERE partner_id = ? AND created_at = (
			SELECT MAX(created_at) FROM supplier_prices
			WHERE partner_id = sp.partner_id AND product_id = sp.product_id)`, partnerID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	out := map[string]int64{}
	for rows.Next() {
		var pid string
		var cost int64
		if rows.Scan(&pid, &cost) == nil {
			out[pid] = cost
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"prices": out})
}

// StartStockVerifier replays the movement ledger against the cached levels
// once at startup and then every 24 h — the nightly check the founding
// principle requires. Divergences are logged to the audit trail; the ledger
// is the truth, so the cache is repaired from it.
func StartStockVerifier(db *sql.DB) {
	run := func() {
		div, err := domain.VerifyStock(db, true)
		if err != nil {
			log.Printf("stock verify: %v", err)
			return
		}
		if len(div) > 0 {
			now := domain.NowISO()
			db.Exec(`INSERT INTO audit_log (id, user_id, action, entity, entity_id, detail, created_at)
				VALUES (?, NULL, 'stock.divergence', 'stock', '', ?, ?)`,
				domain.NewID(),
				fmt.Sprintf("vérification nocturne : %d écart(s) cache/journal réparé(s)", len(div)), now)
			log.Printf("stock verify: %d divergence(s) repaired", len(div))
		}
	}
	go func() {
		run()
		t := time.NewTicker(24 * time.Hour)
		for range t.C {
			run()
		}
	}()
}

// verifyStock exposes the nightly ledger-replay check on demand (admin).
func (s *Server) verifyStock(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	repair := r.URL.Query().Get("repair") == "1"
	div, err := domain.VerifyStock(s.db, repair)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if len(div) > 0 {
		s.audit(r, "stock.divergence", "stock", "",
			fmt.Sprintf("%d écart(s) cache/journal détecté(s) (réparation: %v)", len(div), repair))
	}
	writeJSON(w, http.StatusOK, map[string]any{"divergences": div, "repaired": repair})
}
