package domain_test

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"elixir/server/internal/domain"
	"elixir/server/internal/store"
)

// ---- fixture ---------------------------------------------------------------

type fx struct {
	t  *testing.T
	db *sql.DB
	wh string
	n  int
}

func newFx(t *testing.T) *fx {
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
	f := &fx{t: t, db: db}
	if err := db.QueryRow(`SELECT id FROM warehouses LIMIT 1`).Scan(&f.wh); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f *fx) exec(q string, args ...any) {
	f.t.Helper()
	if _, err := f.db.Exec(q, args...); err != nil {
		f.t.Fatalf("%v\n%s", err, q)
	}
}

func (f *fx) product(id string, tracked bool) {
	tr := 0
	if tracked {
		tr = 1
	}
	f.exec(`INSERT INTO products (id,name,unit,vat_rate,purchase_price,price_retail,active,track_lots,track_expiry,created_at,updated_at)
		VALUES (?,?,'pièce',0,0,0,1,?,?,'2026-01-01','2026-01-01')`, id, id, tr, tr)
}

func (f *fx) partner(id, kind string) {
	f.exec(`INSERT INTO partners (id,kind,name,active,created_at,updated_at) VALUES (?,?,?,1,'2026-01-01','2026-01-01')`,
		id, kind, id)
}

type ln struct {
	prod       string
	qty, price int64 // qty in milli
	pack, free int64
	lot, exp   string
	expected   *int64
}

type dc struct {
	typ, partner, method, ref, supRef string
}

func (f *fx) doc(d dc, lines ...ln) string {
	f.t.Helper()
	f.n++
	id := fmt.Sprintf("D%03d", f.n)
	nn := func(s string) any {
		if s == "" {
			return nil
		}
		return s
	}
	f.exec(`INSERT INTO documents (id,doc_type,status,doc_date,partner_id,warehouse_id,ref_document_id,
			payment_method,supplier_ref,created_at,updated_at)
		VALUES (?,?, 'draft','2026-03-10',?,?,?,?,?,'2026-03-10T08:00:00Z','2026-03-10T08:00:00Z')`,
		id, d.typ, nn(d.partner), f.wh, nn(d.ref), nn(d.method), nn(d.supRef))
	for i, l := range lines {
		pack := l.pack
		if pack == 0 {
			pack = 1000
		}
		f.exec(`INSERT INTO document_lines (id,document_id,position,product_id,description,qty_milli,unit_price,
				pack_factor_milli,qty_free_milli,lot_number,expiry_date,expected_milli,created_at)
			VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'2026-03-10')`,
			fmt.Sprintf("%s-L%d", id, i), id, i, l.prod, l.prod, l.qty, l.price, pack, l.free,
			nn(l.lot), nn(l.exp), l.expected)
	}
	return id
}

func (f *fx) post(id string) {
	f.t.Helper()
	if _, err := domain.Post(f.db, id, ""); err != nil {
		f.t.Fatalf("post %s: %v", id, err)
	}
}

func (f *fx) postErr(id string) error {
	f.t.Helper()
	_, err := domain.Post(f.db, id, "")
	return err
}

func (f *fx) level(prod string) (qty, avg int64) {
	f.db.QueryRow(`SELECT qty_milli, avg_cost FROM stock_levels WHERE product_id=?`, prod).Scan(&qty, &avg)
	return
}

func (f *fx) lineCost(docID string, pos int) int64 {
	var c sql.NullInt64
	f.db.QueryRow(`SELECT unit_cost FROM document_lines WHERE document_id=? AND position=?`, docID, pos).Scan(&c)
	return c.Int64
}

func (f *fx) mustVerify() {
	f.t.Helper()
	dv, err := domain.VerifyStock(f.db, false)
	if err != nil {
		f.t.Fatal(err)
	}
	if len(dv) > 0 {
		f.t.Fatalf("ledger replay diverges from cache: %+v", dv)
	}
}

func eq(t *testing.T, what string, got, want int64) {
	t.Helper()
	if got != want {
		t.Errorf("%s = %d, want %d", what, got, want)
	}
}

func (f *fx) receive(prod string, qtyUnits, costCentimes int64) {
	f.t.Helper()
	f.post(f.doc(dc{typ: domain.PurchaseReceipt, partner: "S"},
		ln{prod: prod, qty: qtyUnits * 1000, price: costCentimes}))
}

// ---- tests -----------------------------------------------------------------

func TestTimbreScale(t *testing.T) {
	for _, c := range []struct{ ttc, want int64 }{
		{30000, 0},           // 300 DA : exonéré
		{30100, 500},         // 4 tranches → 4 DA → plancher 5 DA
		{100000, 1000},       // 1 000 DA → 10 DA
		{3000000, 30000},     // 30 000 DA → 300 DA
		{3000100, 45200},     // tranche à 1,5 DA : 301 × 1,5 = 451,5 → 452 DA
		{10000000, 150000},   // 100 000 DA → 1 500 DA
		{10000100, 200200},   // au-delà : 2 DA/tranche
		{100000000, 1000000}, // plafond 10 000 DA
	} {
		if got := domain.Timbre(c.ttc); got != c.want {
			t.Errorf("Timbre(%d) = %d, want %d", c.ttc, got, c.want)
		}
	}
}

func TestNegativeStockRefusedUnlessAllowed(t *testing.T) {
	f := newFx(t)
	f.product("P", false)
	sale := f.doc(dc{typ: domain.SaleTicket, method: "cash"}, ln{prod: "P", qty: 1000, price: 15000})
	err := f.postErr(sale)
	if err == nil || !strings.Contains(err.Error(), "stock insuffisant") {
		t.Fatalf("expected insufficient-stock refusal, got %v", err)
	}
	f.exec(`INSERT OR REPLACE INTO settings (key,value,updated_at) VALUES ('allow_negative_stock','1','2026-03-10')`)
	f.post(sale)
	q, _ := f.level("P")
	eq(t, "stock after allowed negative sale", q, -1000)
}

func TestInvoiceOnDeliveryNoDoubleMoveAndInheritedCost(t *testing.T) {
	f := newFx(t)
	f.partner("S", "supplier")
	f.partner("C", "customer")
	f.product("P", false)
	f.product("Q", false)
	f.receive("P", 10, 10000)
	f.receive("Q", 5, 2000)

	bl := f.doc(dc{typ: domain.DeliveryNote, partner: "C"}, ln{prod: "P", qty: 4000, price: 15000})
	f.post(bl)
	q, _ := f.level("P")
	eq(t, "P after BL", q, 6000)

	// Invoice carries P x6 (BL only had 4) and Q x2 (not on the BL at all).
	inv := f.doc(dc{typ: domain.SaleInvoice, partner: "C", method: "credit", ref: bl},
		ln{prod: "P", qty: 6000, price: 15000}, ln{prod: "Q", qty: 2000, price: 3000})
	f.post(inv)
	q, _ = f.level("P")
	eq(t, "P after invoice (4 skipped, 2 moved)", q, 4000)
	q, _ = f.level("Q")
	eq(t, "Q after invoice (line not on BL still moves)", q, 3000)
	eq(t, "invoice P cost inherited from BL", f.lineCost(inv, 0), 10000)
	eq(t, "invoice Q cost = CUMP", f.lineCost(inv, 1), 2000)

	// A second invoice on the same BL: the BL is already fully invoiced.
	inv2 := f.doc(dc{typ: domain.SaleInvoice, partner: "C", method: "credit", ref: bl},
		ln{prod: "P", qty: 1000, price: 15000})
	f.post(inv2)
	q, _ = f.level("P")
	eq(t, "P after 2nd invoice (fully consumed BL → moves)", q, 3000)
	f.mustVerify()
}

func TestCreditNoteCostAndSingleRefund(t *testing.T) {
	f := newFx(t)
	f.partner("S", "supplier")
	f.partner("C", "customer")
	f.product("P", false)
	f.receive("P", 10, 10000)

	tk := f.doc(dc{typ: domain.SaleTicket, partner: "C", method: "cash"}, ln{prod: "P", qty: 1000, price: 15000})
	f.post(tk)
	f.receive("P", 10, 20000) // CUMP moves on afterwards

	av := f.doc(dc{typ: domain.SaleCreditNote, partner: "C", method: "cash", ref: tk},
		ln{prod: "P", qty: 1000, price: 15000})
	f.post(av)
	eq(t, "avoir line cost = cost of the original sale", f.lineCost(av, 0), 10000)
	var n int
	f.db.QueryRow(`SELECT COUNT(*) FROM partner_ledger WHERE document_id=?`, av).Scan(&n)
	eq(t, "cash-refunded avoir leaves the customer account alone", int64(n), 0)

	// Credit sale returned: the refund must reduce the debt, never go out in cash.
	fv := f.doc(dc{typ: domain.SaleInvoice, partner: "C", method: "credit"}, ln{prod: "P", qty: 1000, price: 15000})
	f.post(fv)
	av2 := f.doc(dc{typ: domain.SaleCreditNote, partner: "C", method: "cash", ref: fv},
		ln{prod: "P", qty: 1000, price: 15000})
	f.post(av2)
	var bal int64
	f.db.QueryRow(`SELECT COALESCE(SUM(amount),0) FROM partner_ledger WHERE partner_id='C'`).Scan(&bal)
	eq(t, "customer balance after credit sale + its return", bal, 0)
	var m string
	f.db.QueryRow(`SELECT payment_method FROM documents WHERE id=?`, av2).Scan(&m)
	if m != "credit" {
		t.Errorf("avoir on a credit sale must not stay a cash refund, payment_method=%q", m)
	}
	f.mustVerify()
}

func TestVoidReceiptRestoresCUMP(t *testing.T) {
	f := newFx(t)
	f.partner("S", "supplier")
	f.product("P", false)
	f.receive("P", 10, 10000)
	second := f.doc(dc{typ: domain.PurchaseReceipt, partner: "S"}, ln{prod: "P", qty: 10000, price: 20000})
	f.post(second)
	_, avg := f.level("P")
	eq(t, "avg after 2 receipts", avg, 15000)

	if err := domain.Void(f.db, second, "", "erreur"); err != nil {
		t.Fatal(err)
	}
	q, avg := f.level("P")
	eq(t, "qty after void", q, 10000)
	eq(t, "avg restored after void", avg, 10000)
	f.mustVerify()

	// If the goods are already gone, the void is refused (no silent negative stock).
	third := f.doc(dc{typ: domain.PurchaseReceipt, partner: "S"}, ln{prod: "P", qty: 10000, price: 20000})
	f.post(third)
	f.post(f.doc(dc{typ: domain.SaleTicket, method: "cash"}, ln{prod: "P", qty: 15000, price: 30000}))
	err := domain.Void(f.db, third, "", "")
	if err == nil || !strings.Contains(err.Error(), "contrepassation impossible") {
		t.Fatalf("void of an already-sold receipt must be refused, got %v", err)
	}
}

func TestPackFactorSaleCostPerCarton(t *testing.T) {
	f := newFx(t)
	f.partner("S", "supplier")
	f.product("P", false)
	f.receive("P", 48, 1000) // 48 pieces at 10 DA
	tk := f.doc(dc{typ: domain.SaleTicket, method: "cash"},
		ln{prod: "P", qty: 1000, price: 24000, pack: 24000}) // 1 carton of 24
	f.post(tk)
	q, _ := f.level("P")
	eq(t, "stock after selling one carton of 24", q, 24000)
	eq(t, "line cost is per carton (24 × 10 DA)", f.lineCost(tk, 0), 24000)
	f.mustVerify()
}

func TestSupplierInvoicePriceVarianceRevalues(t *testing.T) {
	f := newFx(t)
	f.partner("S", "supplier")
	f.product("P", false)
	rc := f.doc(dc{typ: domain.PurchaseReceipt, partner: "S", supRef: "F9"}, ln{prod: "P", qty: 10000, price: 10000})
	f.post(rc)

	// Hand-typed invoice for the same supplier ref would enter the stock twice.
	dup := f.doc(dc{typ: domain.PurchaseInvoice, partner: "S", supRef: "F9"}, ln{prod: "P", qty: 10000, price: 11000})
	err := f.postErr(dup)
	if err == nil || !strings.Contains(err.Error(), "rattachez") {
		t.Fatalf("expected a refusal asking to link the receipt, got %v", err)
	}

	inv := f.doc(dc{typ: domain.PurchaseInvoice, partner: "S", ref: rc, supRef: "F9"}, ln{prod: "P", qty: 10000, price: 11000})
	f.post(inv)
	q, avg := f.level("P")
	eq(t, "qty unchanged by the invoice", q, 10000)
	eq(t, "CUMP revalued to the invoiced price", avg, 11000)
	f.mustVerify()
}

func TestInventoryCountAppliesVarianceNotOverwrite(t *testing.T) {
	f := newFx(t)
	f.partner("S", "supplier")
	f.product("P", false)
	f.receive("P", 10, 10000)
	exp := int64(10000)
	count := f.doc(dc{typ: domain.InventoryCount}, ln{prod: "P", qty: 7000, expected: &exp})
	// two units sold between the count and its validation
	f.post(f.doc(dc{typ: domain.SaleTicket, method: "cash"}, ln{prod: "P", qty: 2000, price: 15000}))
	f.post(count)
	q, _ := f.level("P")
	eq(t, "10 − 2 sold − 3 counted missing", q, 5000)
	f.mustVerify()
}

func TestLotsFollowMovementsFEFO(t *testing.T) {
	f := newFx(t)
	f.partner("S", "supplier")
	f.product("P", true)
	f.post(f.doc(dc{typ: domain.PurchaseReceipt, partner: "S"},
		ln{prod: "P", qty: 5000, price: 1000, lot: "A", exp: "2099-12-01"},
		ln{prod: "P", qty: 5000, price: 1000, lot: "B", exp: "2099-06-01"}))
	f.post(f.doc(dc{typ: domain.SaleTicket, method: "cash"}, ln{prod: "P", qty: 7000, price: 2000}))
	var a, b int64
	f.db.QueryRow(`SELECT qty_milli FROM lots WHERE lot_number='A'`).Scan(&a)
	f.db.QueryRow(`SELECT qty_milli FROM lots WHERE lot_number='B'`).Scan(&b)
	eq(t, "lot B (earliest expiry) emptied first", b, 0)
	eq(t, "lot A keeps the rest", a, 3000)
	f.mustVerify()
}
