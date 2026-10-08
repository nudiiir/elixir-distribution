package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"

	"database/sql"
	"fmt"
	"github.com/go-chi/chi/v5"
	"path/filepath"
	"testing"
	"time"

	"elixir/server/internal/domain"
	"elixir/server/internal/store"
)

type stockFx struct {
	t  *testing.T
	db *sql.DB
	wh string
	n  int
}

func newStockFx(t *testing.T) *stockFx {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(db); err != nil {
		t.Fatal(err)
	}
	if err := store.Seed(db); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	f := &stockFx{t: t, db: db}
	if err := db.QueryRow(`SELECT id FROM warehouses LIMIT 1`).Scan(&f.wh); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f *stockFx) exec(q string, args ...any) {
	f.t.Helper()
	if _, err := f.db.Exec(q, args...); err != nil {
		f.t.Fatalf("%v\n%s", err, q)
	}
}

func (f *stockFx) product(id string, minMilli int64) {
	f.exec(`INSERT INTO products (id,name,unit,vat_rate,purchase_price,price_retail,active,min_stock_milli,created_at,updated_at)
		VALUES (?,?,'piece',0,500,0,1,?,'2026-01-01','2026-01-01')`, id, id, minMilli)
}

func (f *stockFx) partner(id string) {
	f.exec(`INSERT INTO partners (id,kind,name,active,created_at,updated_at) VALUES (?,'supplier',?,1,'2026-01-01','2026-01-01')`, id, id)
}

// post creates and posts a one-line document, then stamps its ledger rows
// with the given instant so periods can be tested.
func (f *stockFx) post(typ, partner, prod string, qtyMilli, price int64, at string) string {
	f.t.Helper()
	f.n++
	id := fmt.Sprintf("D%03d", f.n)
	var p any
	if partner != "" {
		p = partner
	}
	var reason any
	if typ == domain.StockAdjustment {
		reason = "casse"
	}
	f.exec(`INSERT INTO documents (id,doc_type,status,doc_date,partner_id,warehouse_id,reason,created_at,updated_at)
		VALUES (?,?,'draft','2026-03-10',?,?,?,'2026-03-10T08:00:00Z','2026-03-10T08:00:00Z')`,
		id, typ, p, f.wh, reason)
	f.exec(`INSERT INTO document_lines (id,document_id,position,product_id,description,qty_milli,unit_price,created_at)
		VALUES (?,?,0,?,?,?,?,'2026-03-10')`, id+"-L", id, prod, prod, qtyMilli, price)
	if _, err := domain.Post(f.db, id, ""); err != nil {
		f.t.Fatalf("post %s: %v", id, err)
	}
	f.exec(`UPDATE stock_ledger SET created_at=? WHERE document_id=?`, at, id)
	return id
}

func eqi(t *testing.T, what string, got, want int64) {
	t.Helper()
	if got != want {
		t.Errorf("%s = %d, want %d", what, got, want)
	}
}

func TestStockLedgerRunningBalance(t *testing.T) {
	f := newStockFx(t)
	f.product("A", 0)
	f.product("B", 0)
	f.partner("S")

	// Before the period: A +10 @ 1,00 DA, sale −3 → opening A = 7.
	f.post(domain.PurchaseReceipt, "S", "A", 10000, 100, "2026-02-01T09:00:00Z")
	f.post(domain.SaleTicket, "", "A", 3000, 0, "2026-02-02T09:00:00Z")
	// In the period: A +5 @ 4,00 DA, B +2, A sale −4, A broken −1.
	f.post(domain.PurchaseReceipt, "S", "A", 5000, 400, "2026-03-01T09:00:00Z")
	f.post(domain.PurchaseReceipt, "S", "B", 2000, 100, "2026-03-02T09:00:00Z")
	f.post(domain.SaleTicket, "", "A", 4000, 0, "2026-03-03T09:00:00Z")
	f.post(domain.StockAdjustment, "", "A", -1000, 0, "2026-03-04T09:00:00Z")
	// After the period (excluded by ToTS).
	f.post(domain.SaleTicket, "", "A", 1000, 0, "2026-04-02T09:00:00Z")

	p := ledgerParams{FromTS: "2026-03-01T00:00:00Z", ToTS: "2026-04-01T00:00:00Z", ViewCost: true}
	res, err := stockLedger(f.db, p)
	if err != nil {
		t.Fatal(err)
	}
	eqi(t, "opening", res.OpeningMilli, 7000)
	eqi(t, "in", res.InMilli, 7000)
	eqi(t, "out", res.OutMilli, 5000)
	eqi(t, "closing", res.ClosingMilli, 9000)
	if len(res.Rows) != 4 {
		t.Fatalf("rows = %d, want 4", len(res.Rows))
	}
	// Running balance per product: A 7→12→8→7, B 0→2.
	wantBal := []int64{12000, 2000, 8000, 7000}
	for i, r := range res.Rows {
		eqi(t, fmt.Sprintf("row %d balance", i), r.BalanceMilli, wantBal[i])
	}
	// Opening value: 7 × 1,00 = 7,00 DA. CUMP after +5 @ 4: (7×100+5×400)/12 = 225.
	eqi(t, "opening value", res.OpeningValue, 700)
	eqi(t, "closing value", res.ClosingValue, 7*225+2*100)

	// Type filter: only sales are shown; balance still the real stock.
	p.Kinds = []string{"sales"}
	res, err = stockLedger(f.db, p)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Rows) != 1 {
		t.Fatalf("sales rows = %d, want 1", len(res.Rows))
	}
	eqi(t, "sale balance", res.Rows[0].BalanceMilli, 8000)
	eqi(t, "sales out", res.OutMilli, 4000)
	eqi(t, "sales in", res.InMilli, 0)
	eqi(t, "closing (unfiltered)", res.ClosingMilli, 9000)

	// Product filter.
	p = ledgerParams{FromTS: "2026-03-01T00:00:00Z", ToTS: "2026-04-01T00:00:00Z", ProductID: "B"}
	res, err = stockLedger(f.db, p)
	if err != nil {
		t.Fatal(err)
	}
	eqi(t, "B opening", res.OpeningMilli, 0)
	eqi(t, "B closing", res.ClosingMilli, 2000)
	eqi(t, "B value hidden", res.ClosingValue, 0)

	// No period: everything from the start; limit keeps the latest rows.
	res, err = stockLedger(f.db, ledgerParams{Limit: 2})
	if err != nil {
		t.Fatal(err)
	}
	eqi(t, "all opening", res.OpeningMilli, 0)
	eqi(t, "all closing", res.ClosingMilli, 8000)
	if !res.Truncated || len(res.Rows) != 2 {
		t.Fatalf("truncation: %v %d", res.Truncated, len(res.Rows))
	}
	eqi(t, "last balance", res.Rows[1].BalanceMilli, 6000)
}

func TestStockLedgerSkipsRevaluationRows(t *testing.T) {
	f := newStockFx(t)
	f.product("A", 0)
	f.post(domain.StockAdjustment, "", "A", 4000, 100, "2026-03-01T09:00:00Z")
	// A zero-quantity revaluation row (supplier invoice priced differently).
	f.exec(`INSERT INTO stock_ledger (id,product_id,warehouse_id,qty_delta_milli,unit_cost,document_id,created_at,is_reversal,avg_after)
		VALUES ('rv','A',?,0,50,'D001','2026-03-02T09:00:00Z',0,150)`, f.wh)
	res, err := stockLedger(f.db, ledgerParams{FromTS: "2026-03-01T00:00:00Z", ViewCost: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Rows) != 1 {
		t.Fatalf("rows = %d, want 1 (revaluation hidden)", len(res.Rows))
	}
	eqi(t, "closing value uses revalued CUMP", res.ClosingValue, 600)
}

func TestStockReorderSuggestion(t *testing.T) {
	f := newStockFx(t)
	f.partner("S1")
	f.partner("S2")
	f.product("MIN", 10000) // min 10, no sales
	f.product("FAST", 0)    // sells 3/day
	f.product("OK", 2000)   // min 2, stock 50 → nothing to order
	f.product("PACK", 5000) // min 5, carton of 12
	f.product("IDLE", 0)    // no min, no sales → not a candidate
	f.exec(`INSERT INTO packagings (id,product_id,name,factor_milli,created_at) VALUES ('pk','PACK','Carton',12000,'2026-01-01')`)
	f.exec(`UPDATE products SET default_supplier_id='S2' WHERE id='MIN'`)

	now := time.Date(2026, 3, 31, 12, 0, 0, 0, time.UTC)
	recent := now.AddDate(0, 0, -5).Format(time.RFC3339)
	f.post(domain.PurchaseReceipt, "S1", "FAST", 100000, 250, now.AddDate(0, 0, -40).Format(time.RFC3339))
	f.post(domain.SaleTicket, "", "FAST", 90000, 0, recent) // 90 in 30 days = 3/day, 10 left
	f.post(domain.PurchaseReceipt, "S1", "OK", 50000, 100, recent)
	f.post(domain.PurchaseReceipt, "S2", "PACK", 1000, 300, recent)
	f.post(domain.StockAdjustment, "", "MIN", 3000, 0, recent)

	rows, err := stockReorder(f.db, "", now)
	if err != nil {
		t.Fatal(err)
	}
	by := map[string]reorderRow{}
	for _, r := range rows {
		by[r.ProductID] = r
	}
	if _, ok := by["OK"]; ok {
		t.Error("OK should not be proposed")
	}
	if _, ok := by["IDLE"]; ok {
		t.Error("IDLE should not be a candidate")
	}
	// MIN: target 2×10 = 20, stock 3 → 17; default supplier S2, cost = purchase_price.
	m := by["MIN"]
	eqi(t, "MIN suggested", m.SuggestedMilli, 17000)
	if m.SupplierID == nil || *m.SupplierID != "S2" {
		t.Errorf("MIN supplier = %v, want S2", m.SupplierID)
	}
	eqi(t, "MIN cost", m.LastUnitCost, 500)
	if !m.Urgent {
		t.Error("MIN under its minimum must be urgent")
	}
	// FAST: avg 3/day, target 90, stock 10 → 80; last supplier S1 @ 2,50.
	fa := by["FAST"]
	eqi(t, "FAST avg daily", fa.AvgDailyMilli, 3000)
	eqi(t, "FAST coverage", *fa.CoverageDays, 3)
	eqi(t, "FAST suggested", fa.SuggestedMilli, 80000)
	eqi(t, "FAST cost", fa.LastUnitCost, 250)
	if fa.SupplierID == nil || *fa.SupplierID != "S1" {
		t.Errorf("FAST supplier = %v", fa.SupplierID)
	}
	// PACK: target 10, stock 1 → 9 → rounded up to one carton of 12.
	pk := by["PACK"]
	eqi(t, "PACK suggested", pk.SuggestedMilli, 12000)
	eqi(t, "PACK factor", pk.PackFactorMilli, 12000)
}

func (f *stockFx) get(s *Server, h http.HandlerFunc, url string, params map[string]string) map[string]any {
	f.t.Helper()
	req := httptest.NewRequest(http.MethodGet, url, nil)
	u := &AuthUser{ID: "u", Role: "admin", Perms: map[string]bool{"stock": true, "view_cost": true, "purchases": true}}
	ctx := context.WithValue(req.Context(), userKey, u)
	if len(params) > 0 {
		rc := chi.NewRouteContext()
		for k, v := range params {
			rc.URLParams.Add(k, v)
		}
		ctx = context.WithValue(ctx, chi.RouteCtxKey, rc)
	}
	rec := httptest.NewRecorder()
	h(rec, req.WithContext(ctx))
	if rec.Code != http.StatusOK {
		f.t.Fatalf("%s: %d %s", url, rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		f.t.Fatal(err)
	}
	return out
}

func TestStockHandlersSQL(t *testing.T) {
	f := newStockFx(t)
	f.product("A", 5000)
	f.product("Z", 0) // never stocked: must still appear in full mode
	f.partner("S")
	f.post(domain.PurchaseReceipt, "S", "A", 10000, 100, "2026-03-01T09:00:00Z")
	f.post(domain.StockAdjustment, "", "A", -2000, 0, "2026-03-02T09:00:00Z")
	exp := int64(8000)
	f.exec(`INSERT INTO documents (id,doc_type,status,doc_date,warehouse_id,created_at,updated_at)
		VALUES ('INV','INVENTORY_COUNT','draft','2026-03-10',?,'2026-03-10T08:00:00Z','2026-03-10T08:00:00Z')`, f.wh)
	f.exec(`INSERT INTO document_lines (id,document_id,position,product_id,description,qty_milli,expected_milli,created_at)
		VALUES ('INV-L','INV',0,'A','A',7000,?,'2026-03-10')`, exp)

	s := &Server{db: f.db}
	docs := f.get(s, s.stockDocumentsHandler, "/stock/documents?types=STOCK_ADJUSTMENT,INVENTORY_COUNT", nil)
	items := docs["items"].([]any)
	if len(items) != 2 {
		t.Fatalf("documents = %d, want 2", len(items))
	}
	var adj map[string]any
	for _, it := range items {
		if m := it.(map[string]any); m["doc_type"] == "STOCK_ADJUSTMENT" {
			adj = m
		}
	}
	if adj["out_milli"].(float64) != 2000 || adj["value"].(float64) != -200 || adj["reason"] != "casse" {
		t.Errorf("adjustment row = %v", adj)
	}

	inv := f.get(s, s.stockInventoryDraft, "/stock/inventory/INV", map[string]string{"id": "INV"})
	lines := inv["lines"].([]any)
	if len(lines) != 1 || lines[0].(map[string]any)["expected_milli"].(float64) != 8000 {
		t.Errorf("draft lines = %v", lines)
	}

	lv := f.get(s, s.stockLevels, "/stock/levels?full=1&warehouse_id="+f.wh, nil)
	rows := lv["items"].([]any)
	if len(rows) != 2 {
		t.Fatalf("full levels = %d, want 2", len(rows))
	}
	a := rows[0].(map[string]any)
	if a["product_id"] != "A" || a["qty_milli"].(float64) != 8000 || a["value"].(float64) != 800 ||
		a["min_stock_milli"].(float64) != 5000 {
		t.Errorf("level A = %v", a)
	}

	led := f.get(s, s.stockLedgerHandler, "/stock/ledger?kind=adjustments", nil)
	if len(led["rows"].([]any)) != 1 || led["closing_milli"].(float64) != 8000 {
		t.Errorf("ledger = %v", led)
	}
}
