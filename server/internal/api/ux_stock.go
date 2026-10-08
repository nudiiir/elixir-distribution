package api

import (
	"database/sql"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// routesStockUX registers the stock routes added by the UX-benchmark work.
func (s *Server) routesStockUX(r chi.Router) {
	r.Get("/stock/ledger", s.stockLedgerHandler)
	r.Get("/stock/reorder", s.stockReorderHandler)
	r.Get("/stock/documents", s.stockDocumentsHandler)
	r.Get("/stock/inventory/{id}", s.stockInventoryDraft)
}

// ---------------------------------------------------------------------------
// Journal de stock (Mouvements)
// ---------------------------------------------------------------------------

// ledgerKinds maps the UI type pills to document types.
var ledgerKinds = map[string][]string{
	"sales":       {domain.SaleTicket, domain.SaleInvoice, domain.DeliveryNote},
	"purchases":   {domain.PurchaseReceipt, domain.PurchaseInvoice},
	"returns":     {domain.SaleCreditNote, domain.PurchaseCreditNote},
	"adjustments": {domain.StockAdjustment},
	"inventory":   {domain.InventoryCount},
	"transfers":   {domain.StockTransfer},
}

type ledgerParams struct {
	FromTS, ToTS string // RFC3339 UTC bounds, from inclusive, to exclusive ("" = open)
	WarehouseID  string
	ProductID    string
	Q            string
	Kinds        []string // UI kinds (sales, purchases…); empty = all
	Limit        int
	ViewCost     bool
}

type ledgerRow struct {
	ID            string  `json:"id"`
	CreatedAt     string  `json:"created_at"`
	DocType       string  `json:"doc_type"`
	Number        *string `json:"number"`
	DocumentID    string  `json:"document_id"`
	WarehouseID   string  `json:"warehouse_id"`
	WarehouseName string  `json:"warehouse_name"`
	ProductID     string  `json:"product_id"`
	ProductName   string  `json:"product_name"`
	LotNumber     *string `json:"lot_number"`
	InMilli       int64   `json:"in_milli"`
	OutMilli      int64   `json:"out_milli"`
	BalanceMilli  int64   `json:"balance_milli"`
	UnitCost      int64   `json:"unit_cost"`
	IsReversal    bool    `json:"is_reversal"`
}

type ledgerResult struct {
	OpeningMilli int64       `json:"opening_milli"`
	InMilli      int64       `json:"in_milli"`
	OutMilli     int64       `json:"out_milli"`
	ClosingMilli int64       `json:"closing_milli"`
	OpeningValue int64       `json:"opening_value"`
	ClosingValue int64       `json:"closing_value"`
	Truncated    bool        `json:"truncated"`
	Rows         []ledgerRow `json:"rows"`
}

// stockLedger replays the movement ledger for the filtered products and
// warehouses. The running balance is per product × warehouse and starts from
// every movement before FromTS; the CUMP is replayed with the same rules as
// the nightly check (domain.VerifyStock) to value the opening and closing.
//
// The type filter only selects which rows are SHOWN (and summed in in/out):
// balances always include every movement, so a row's balance is the real
// stock after it. Zero-quantity revaluation rows are never shown.
func stockLedger(db *sql.DB, p ledgerParams) (*ledgerResult, error) {
	where := "WHERE 1=1"
	args := []any{}
	if p.ToTS != "" {
		where += " AND sl.created_at < ?"
		args = append(args, p.ToTS)
	}
	if p.WarehouseID != "" {
		where += " AND sl.warehouse_id = ?"
		args = append(args, p.WarehouseID)
	}
	if p.ProductID != "" {
		where += " AND sl.product_id = ?"
		args = append(args, p.ProductID)
	}
	if q := strings.TrimSpace(p.Q); q != "" {
		where += " AND (p.name LIKE ? OR p.barcode = ? OR p.sku = ?)"
		args = append(args, "%"+q+"%", q, q)
	}
	rows, err := db.Query(`SELECT sl.id, sl.created_at, d.doc_type, d.number, d.id, sl.warehouse_id,
			COALESCE(w.name,''), sl.product_id, p.name, lt.lot_number, sl.qty_delta_milli,
			sl.unit_cost, sl.is_reversal, sl.avg_after
		FROM stock_ledger sl
		JOIN documents d ON d.id = sl.document_id
		JOIN products p ON p.id = sl.product_id
		LEFT JOIN warehouses w ON w.id = sl.warehouse_id
		LEFT JOIN lots lt ON lt.id = sl.lot_id `+where+`
		ORDER BY sl.created_at, sl.id`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	show := map[string]bool{}
	for _, k := range p.Kinds {
		for _, t := range ledgerKinds[k] {
			show[t] = true
		}
	}

	type key struct{ p, w string }
	type acc struct{ qty, avg int64 }
	state := map[key]*acc{}
	snapshot := func() (qty, value int64) {
		for _, a := range state {
			qty += a.qty
			if a.qty > 0 {
				value += stockMulMilli(a.qty, a.avg)
			}
		}
		return
	}

	res := &ledgerResult{Rows: []ledgerRow{}}
	opened := p.FromTS == ""
	for rows.Next() {
		var lr ledgerRow
		var delta, cost, rev int64
		var avgAfter sql.NullInt64
		if err := rows.Scan(&lr.ID, &lr.CreatedAt, &lr.DocType, &lr.Number, &lr.DocumentID, &lr.WarehouseID,
			&lr.WarehouseName, &lr.ProductID, &lr.ProductName, &lr.LotNumber, &delta,
			&cost, &rev, &avgAfter); err != nil {
			return nil, err
		}
		if !opened && lr.CreatedAt >= p.FromTS {
			res.OpeningMilli, res.OpeningValue = snapshot()
			opened = true
		}
		k := key{lr.ProductID, lr.WarehouseID}
		a := state[k]
		if a == nil {
			a = &acc{}
			state[k] = a
		}
		// CUMP replay — same rules as domain.VerifyStock.
		valued := lr.DocType == domain.PurchaseReceipt || lr.DocType == domain.PurchaseInvoice ||
			lr.DocType == domain.StockTransfer || lr.DocType == domain.StockAdjustment
		switch {
		case avgAfter.Valid:
			a.avg = avgAfter.Int64
		case rev == 1:
			if delta < 0 && valued {
				rest := a.qty + delta
				if rest > 0 {
					if v := stockDivRound(a.qty*a.avg+delta*cost, rest); v >= 0 {
						a.avg = v
					}
				}
			}
			a.qty += delta
		default:
			if delta > 0 && valued {
				if a.qty <= 0 {
					a.avg = cost
				} else {
					a.avg = stockDivRound(a.qty*a.avg+delta*cost, a.qty+delta)
				}
			}
			a.qty += delta
		}
		if !opened || delta == 0 {
			continue
		}
		if len(show) > 0 && !show[lr.DocType] {
			continue
		}
		lr.IsReversal = rev == 1
		lr.BalanceMilli = a.qty
		lr.UnitCost = cost
		if !p.ViewCost {
			lr.UnitCost = 0
		}
		if delta > 0 {
			lr.InMilli = delta
			res.InMilli += delta
		} else {
			lr.OutMilli = -delta
			res.OutMilli += -delta
		}
		res.Rows = append(res.Rows, lr)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if !opened {
		res.OpeningMilli, res.OpeningValue = snapshot()
	}
	res.ClosingMilli, res.ClosingValue = snapshot()
	if p.Limit > 0 && len(res.Rows) > p.Limit {
		res.Rows = res.Rows[len(res.Rows)-p.Limit:]
		res.Truncated = true
	}
	if !p.ViewCost {
		res.OpeningValue, res.ClosingValue = 0, 0
	}
	return res, nil
}

// localDayBound turns a local YYYY-MM-DD into the RFC3339 UTC instant of its
// midnight (+days). Ledger timestamps are UTC; periods are the shop's days.
func localDayBound(day string, plusDays int) string {
	t, err := time.ParseInLocation("2006-01-02", day, time.Local)
	if err != nil {
		return ""
	}
	return t.AddDate(0, 0, plusDays).UTC().Format(time.RFC3339)
}

func (s *Server) stockLedgerHandler(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "stock") {
		forbid(w)
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	if limit <= 0 || limit > 20000 {
		limit = 3000
	}
	p := ledgerParams{
		WarehouseID: q.Get("warehouse_id"),
		ProductID:   q.Get("product_id"),
		Q:           q.Get("q"),
		Limit:       limit,
		ViewCost:    s.can(r, "view_cost"),
	}
	if f := q.Get("from"); f != "" {
		p.FromTS = localDayBound(f, 0)
	}
	if t := q.Get("to"); t != "" {
		p.ToTS = localDayBound(t, 1)
	}
	for _, k := range strings.Split(q.Get("kind"), ",") {
		if k = strings.TrimSpace(k); k != "" {
			p.Kinds = append(p.Kinds, k)
		}
	}
	res, err := stockLedger(s.db, p)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// ---------------------------------------------------------------------------
// À commander
// ---------------------------------------------------------------------------

type reorderRow struct {
	ProductID       string  `json:"product_id"`
	ProductName     string  `json:"product_name"`
	Barcode         *string `json:"barcode"`
	Unit            string  `json:"unit"`
	ImageRev        int64   `json:"image_rev"`
	QtyMilli        int64   `json:"qty_milli"`
	MinStockMilli   int64   `json:"min_stock_milli"`
	Sold30Milli     int64   `json:"sold_30d_milli"`
	AvgDailyMilli   int64   `json:"avg_daily_milli"`
	CoverageDays    *int64  `json:"coverage_days"` // null = no sales
	SupplierID      *string `json:"supplier_id"`
	SupplierName    *string `json:"supplier_name"`
	LastUnitCost    int64   `json:"last_unit_cost"`
	PackName        *string `json:"pack_name"`
	PackFactorMilli int64   `json:"pack_factor_milli"`
	TargetMilli     int64   `json:"target_milli"`
	SuggestedMilli  int64   `json:"suggested_milli"`
	Urgent          bool    `json:"urgent"`
	VatRate         int64   `json:"vat_rate"`
}

// reorderDays is the sales window and the coverage target.
const reorderDays = 30

// stockReorder computes the replenishment proposal. A candidate is an active
// non-service product with a minimum stock or sales in the last 30 days.
// Target = max(2 × min, 30 days of sales); suggested = target − stock on hand,
// rounded up to whole units (unless weighed) and to the smallest packaging.
// Only rows with a positive suggestion are returned; « urgent » = out of
// stock, under the minimum, or less than 7 days of coverage.
func stockReorder(db *sql.DB, warehouseID string, now time.Time) ([]reorderRow, error) {
	since := now.AddDate(0, 0, -reorderDays).UTC().Format(time.RFC3339)

	// Stock on hand.
	qty := map[string]int64{}
	{
		qs, args := `SELECT product_id, SUM(qty_milli) FROM stock_levels`, []any{}
		if warehouseID != "" {
			qs += ` WHERE warehouse_id = ?`
			args = append(args, warehouseID)
		}
		rows, err := db.Query(qs+` GROUP BY product_id`, args...)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id string
			var q int64
			if err := rows.Scan(&id, &q); err != nil {
				rows.Close()
				return nil, err
			}
			qty[id] = q
		}
		rows.Close()
	}

	// Sales over the window (net of voided sales: reversal rows are positive).
	sold := map[string]int64{}
	{
		qs := `SELECT sl.product_id, -SUM(sl.qty_delta_milli) FROM stock_ledger sl
			JOIN documents d ON d.id = sl.document_id
			WHERE d.doc_type IN ('SALE_TICKET','SALE_INVOICE','DELIVERY_NOTE') AND sl.created_at >= ?`
		args := []any{since}
		if warehouseID != "" {
			qs += ` AND sl.warehouse_id = ?`
			args = append(args, warehouseID)
		}
		rows, err := db.Query(qs+` GROUP BY sl.product_id`, args...)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id string
			var q int64
			if err := rows.Scan(&id, &q); err != nil {
				rows.Close()
				return nil, err
			}
			sold[id] = q
		}
		rows.Close()
	}

	// Last supplier + last price (latest supplier_prices row per product), and
	// the latest price per (product, supplier) for the default-supplier case.
	type sp struct {
		partner string
		cost    int64
	}
	last := map[string]sp{}
	lastBy := map[[2]string]int64{}
	{
		rows, err := db.Query(`SELECT product_id, partner_id, unit_cost FROM supplier_prices
			ORDER BY created_at DESC, id DESC`)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var pid, partner string
			var c int64
			if err := rows.Scan(&pid, &partner, &c); err != nil {
				rows.Close()
				return nil, err
			}
			if _, ok := last[pid]; !ok {
				last[pid] = sp{partner, c}
			}
			if _, ok := lastBy[[2]string{pid, partner}]; !ok {
				lastBy[[2]string{pid, partner}] = c
			}
		}
		rows.Close()
	}

	// Smallest purchase packaging (> 1 unit) per product.
	type pack struct {
		name   string
		factor int64
	}
	packs := map[string]pack{}
	{
		rows, err := db.Query(`SELECT product_id, name, factor_milli FROM packagings
			WHERE factor_milli > 1000 ORDER BY factor_milli`)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var pid, name string
			var f int64
			if err := rows.Scan(&pid, &name, &f); err != nil {
				rows.Close()
				return nil, err
			}
			if _, ok := packs[pid]; !ok {
				packs[pid] = pack{name, f}
			}
		}
		rows.Close()
	}

	partnerNames := map[string]string{}
	{
		rows, err := db.Query(`SELECT id, name FROM partners`)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id, name string
			if err := rows.Scan(&id, &name); err != nil {
				rows.Close()
				return nil, err
			}
			partnerNames[id] = name
		}
		rows.Close()
	}

	rows, err := db.Query(`SELECT id, name, barcode, unit, image_rev, min_stock_milli,
			default_supplier_id, purchase_price, is_weighable, vat_rate
		FROM products WHERE active = 1 AND kind <> 'service' ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []reorderRow{}
	for rows.Next() {
		var rr reorderRow
		var defSupplier sql.NullString
		var purchase, weighable int64
		if err := rows.Scan(&rr.ProductID, &rr.ProductName, &rr.Barcode, &rr.Unit, &rr.ImageRev,
			&rr.MinStockMilli, &defSupplier, &purchase, &weighable, &rr.VatRate); err != nil {
			return nil, err
		}
		rr.QtyMilli = qty[rr.ProductID]
		rr.Sold30Milli = sold[rr.ProductID]
		if rr.Sold30Milli < 0 {
			rr.Sold30Milli = 0
		}
		if rr.MinStockMilli <= 0 && rr.Sold30Milli <= 0 {
			continue
		}
		rr.AvgDailyMilli = stockDivRound(rr.Sold30Milli, reorderDays)
		if rr.AvgDailyMilli > 0 {
			c := rr.QtyMilli / rr.AvgDailyMilli
			if rr.QtyMilli < 0 {
				c = 0
			}
			rr.CoverageDays = &c
		}
		rr.TargetMilli = 2 * rr.MinStockMilli
		if s := rr.Sold30Milli; s > rr.TargetMilli { // 30 jours de ventes
			rr.TargetMilli = s
		}
		onHand := rr.QtyMilli
		if onHand < 0 {
			onHand = 0
		}
		need := rr.TargetMilli - onHand
		if need <= 0 {
			continue
		}
		if weighable == 0 {
			need = ceilTo(need, 1000)
		}
		if pk, ok := packs[rr.ProductID]; ok {
			n := pk.name
			rr.PackName, rr.PackFactorMilli = &n, pk.factor
			need = ceilTo(need, pk.factor)
		}
		rr.SuggestedMilli = need

		// Fournisseur : le dernier qui a livré, sinon le fournisseur habituel.
		rr.LastUnitCost = purchase
		if l, ok := last[rr.ProductID]; ok {
			id := l.partner
			rr.SupplierID, rr.LastUnitCost = &id, l.cost
		} else if defSupplier.Valid && defSupplier.String != "" {
			id := defSupplier.String
			rr.SupplierID = &id
			if c, ok := lastBy[[2]string{rr.ProductID, id}]; ok {
				rr.LastUnitCost = c
			}
		}
		if rr.SupplierID != nil {
			if n, ok := partnerNames[*rr.SupplierID]; ok {
				rr.SupplierName = &n
			}
		}
		rr.Urgent = rr.QtyMilli <= 0 ||
			(rr.MinStockMilli > 0 && rr.QtyMilli < rr.MinStockMilli) ||
			(rr.CoverageDays != nil && *rr.CoverageDays < 7)
		out = append(out, rr)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(out, func(i, j int) bool {
		si, sj := "", ""
		if out[i].SupplierName != nil {
			si = *out[i].SupplierName
		}
		if out[j].SupplierName != nil {
			sj = *out[j].SupplierName
		}
		if si != sj {
			if si == "" {
				return false
			}
			if sj == "" {
				return true
			}
			return si < sj
		}
		return out[i].ProductName < out[j].ProductName
	})
	return out, nil
}

func ceilTo(v, step int64) int64 {
	if step <= 0 || v <= 0 {
		return v
	}
	return ((v + step - 1) / step) * step
}

func (s *Server) stockReorderHandler(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "stock") && !s.can(r, "purchases") {
		forbid(w)
		return
	}
	items, err := stockReorder(s.db, r.URL.Query().Get("warehouse_id"), time.Now())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !s.can(r, "view_cost") {
		for i := range items {
			items[i].LastUnitCost = 0
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// ---------------------------------------------------------------------------
// Ajustements / inventaires / transferts
// ---------------------------------------------------------------------------

type stockDoc struct {
	ID                string  `json:"id"`
	DocType           string  `json:"doc_type"`
	Number            *string `json:"number"`
	Status            string  `json:"status"`
	DocDate           string  `json:"doc_date"`
	WarehouseID       *string `json:"warehouse_id"`
	WarehouseName     *string `json:"warehouse_name"`
	DestWarehouseID   *string `json:"dest_warehouse_id"`
	DestWarehouseName *string `json:"dest_warehouse_name"`
	Reason            *string `json:"reason"`
	Notes             *string `json:"notes"`
	LineCount         int64   `json:"line_count"`
	InMilli           int64   `json:"in_milli"`
	OutMilli          int64   `json:"out_milli"`
	Value             int64   `json:"value"` // net stock value moved in the source depot (centimes)
	CreatedBy         *string `json:"created_by"`
	CreatedAt         string  `json:"created_at"`
	UpdatedAt         string  `json:"updated_at"`
}

// stockDocumentsHandler lists STOCK_ADJUSTMENT / INVENTORY_COUNT /
// STOCK_TRANSFER documents with what the stock screens show (depots, motif,
// quantities and value moved). Filters: types (comma list), from/to
// (doc_date), warehouse_id (source or destination), status.
func (s *Server) stockDocumentsHandler(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "stock") {
		forbid(w)
		return
	}
	q := r.URL.Query()
	allowed := map[string]bool{domain.StockAdjustment: true, domain.InventoryCount: true, domain.StockTransfer: true}
	types := []any{}
	ph := []string{}
	for _, t := range strings.Split(q.Get("types"), ",") {
		t = strings.TrimSpace(t)
		if allowed[t] {
			types = append(types, t)
			ph = append(ph, "?")
		}
	}
	if len(types) == 0 {
		for _, t := range []string{domain.StockAdjustment, domain.InventoryCount, domain.StockTransfer} {
			types = append(types, t)
			ph = append(ph, "?")
		}
	}
	where := "WHERE d.doc_type IN (" + strings.Join(ph, ",") + ")"
	args := append([]any{}, types...)
	if f := q.Get("from"); f != "" {
		where += " AND d.doc_date >= ?"
		args = append(args, f)
	}
	if t := q.Get("to"); t != "" {
		where += " AND d.doc_date <= ?"
		args = append(args, t)
	}
	if wh := q.Get("warehouse_id"); wh != "" {
		where += " AND (d.warehouse_id = ? OR d.dest_warehouse_id = ?)"
		args = append(args, wh, wh)
	}
	if st := q.Get("status"); st != "" {
		where += " AND d.status = ?"
		args = append(args, st)
	}
	rows, err := s.db.Query(`SELECT d.id, d.doc_type, d.number, d.status, d.doc_date,
			d.warehouse_id, w.name, d.dest_warehouse_id, w2.name, d.reason, d.notes,
			(SELECT COUNT(*) FROM document_lines l WHERE l.document_id = d.id),
			(SELECT COALESCE(SUM(CASE WHEN sl.qty_delta_milli > 0 THEN sl.qty_delta_milli ELSE 0 END),0)
				FROM stock_ledger sl WHERE sl.document_id = d.id AND sl.is_reversal = 0
				AND (d.doc_type <> 'STOCK_TRANSFER' OR sl.warehouse_id = d.dest_warehouse_id)),
			(SELECT COALESCE(SUM(CASE WHEN sl.qty_delta_milli < 0 THEN -sl.qty_delta_milli ELSE 0 END),0)
				FROM stock_ledger sl WHERE sl.document_id = d.id AND sl.is_reversal = 0
				AND (d.doc_type <> 'STOCK_TRANSFER' OR sl.warehouse_id = d.warehouse_id)),
			(SELECT COALESCE(SUM(sl.qty_delta_milli * sl.unit_cost),0)
				FROM stock_ledger sl WHERE sl.document_id = d.id AND sl.is_reversal = 0
				AND sl.warehouse_id = d.warehouse_id),
			u.full_name, d.created_at, d.updated_at
		FROM documents d
		LEFT JOIN warehouses w ON w.id = d.warehouse_id
		LEFT JOIN warehouses w2 ON w2.id = d.dest_warehouse_id
		LEFT JOIN users u ON u.id = d.created_by `+where+`
		ORDER BY d.doc_date DESC, d.created_at DESC LIMIT 2000`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	viewCost := s.can(r, "view_cost")
	items := []stockDoc{}
	for rows.Next() {
		var d stockDoc
		var valueMilli int64
		if err := rows.Scan(&d.ID, &d.DocType, &d.Number, &d.Status, &d.DocDate,
			&d.WarehouseID, &d.WarehouseName, &d.DestWarehouseID, &d.DestWarehouseName,
			&d.Reason, &d.Notes, &d.LineCount, &d.InMilli, &d.OutMilli, &valueMilli,
			&d.CreatedBy, &d.CreatedAt, &d.UpdatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if viewCost {
			d.Value = stockDivRound(valueMilli, 1000)
		}
		items = append(items, d)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type invDraftLine struct {
	ProductID     string `json:"product_id"`
	Description   string `json:"description"`
	QtyMilli      int64  `json:"qty_milli"`
	ExpectedMilli *int64 `json:"expected_milli"`
}

// stockInventoryDraft returns a DRAFT inventory count with the stock it
// expected at count time (expected_milli), so a saved session can resume.
func (s *Server) stockInventoryDraft(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "stock") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var docType, status, docDate string
	var wh, notes *string
	err := s.db.QueryRow(`SELECT doc_type, status, doc_date, warehouse_id, notes FROM documents WHERE id = ?`, id).
		Scan(&docType, &status, &docDate, &wh, &notes)
	if err == sql.ErrNoRows || (err == nil && docType != domain.InventoryCount) {
		writeErr(w, http.StatusNotFound, "inventaire introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	rows, err := s.db.Query(`SELECT COALESCE(product_id,''), description, qty_milli, expected_milli
		FROM document_lines WHERE document_id = ? AND product_id IS NOT NULL ORDER BY position, created_at`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	lines := []invDraftLine{}
	for rows.Next() {
		var l invDraftLine
		if err := rows.Scan(&l.ProductID, &l.Description, &l.QtyMilli, &l.ExpectedMilli); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		lines = append(lines, l)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id": id, "status": status, "doc_date": docDate, "warehouse_id": wh,
		"notes": notes, "lines": lines,
	})
}
