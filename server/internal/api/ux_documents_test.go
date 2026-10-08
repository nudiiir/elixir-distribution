package api

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"elixir/server/internal/store"
)

// ---- fixture: a real migrated DB behind the real router ---------------------

type apiFx struct {
	t     *testing.T
	db    *sql.DB
	h     http.Handler
	token string
	wh    string
}

func newAPIFx(t *testing.T) *apiFx {
	t.Helper()
	path := filepath.Join(t.TempDir(), "t.db")
	db, err := store.Open(path)
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
	f := &apiFx{t: t, db: db, h: New(db, path, nil)}
	secret, err := ensureAuthSecret(db)
	if err != nil {
		t.Fatal(err)
	}
	var uid string
	if err := db.QueryRow(`SELECT id FROM users WHERE username='admin'`).Scan(&uid); err != nil {
		t.Fatal(err)
	}
	f.token = (&Server{secret: secret}).makeToken(uid)
	if err := db.QueryRow(`SELECT id FROM warehouses LIMIT 1`).Scan(&f.wh); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f *apiFx) do(method, path string, body any, raw []byte) (int, []byte) {
	f.t.Helper()
	var rd io.Reader
	if raw != nil {
		rd = bytes.NewReader(raw)
	} else if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req := httptest.NewRequest(method, "/api/v1"+path, rd)
	req.Header.Set("Authorization", "Bearer "+f.token)
	rec := httptest.NewRecorder()
	f.h.ServeHTTP(rec, req)
	return rec.Code, rec.Body.Bytes()
}

func (f *apiFx) ok(method, path string, body any, out any) {
	f.t.Helper()
	code, b := f.do(method, path, body, nil)
	if code >= 300 {
		f.t.Fatalf("%s %s: %d %s", method, path, code, b)
	}
	if out != nil {
		if err := json.Unmarshal(b, out); err != nil {
			f.t.Fatalf("decode %s: %v", b, err)
		}
	}
}

func (f *apiFx) exec(q string, args ...any) {
	f.t.Helper()
	if _, err := f.db.Exec(q, args...); err != nil {
		f.t.Fatalf("%v\n%s", err, q)
	}
}

func (f *apiFx) partner(id, kind, name string) {
	f.exec(`INSERT INTO partners (id,kind,name,active,created_at,updated_at) VALUES (?,?,?,1,'2026-01-01','2026-01-01')`,
		id, kind, name)
}

func (f *apiFx) product(id string) {
	f.exec(`INSERT INTO products (id,name,unit,vat_rate,purchase_price,price_retail,active,created_at,updated_at)
		VALUES (?,?,'pièce',0,0,0,1,'2026-01-01','2026-01-01')`, id, id)
}

// postDoc creates and posts a document through the API and returns its id.
func (f *apiFx) postDoc(in map[string]any) Document {
	f.t.Helper()
	var d Document
	f.ok("POST", "/documents", in, &d)
	f.ok("POST", "/documents/"+d.ID+"/post", nil, &d)
	return d
}

func line(prod *string, desc string, qty, price int64) map[string]any {
	return map[string]any{"product_id": prod, "description": desc, "qty_milli": qty,
		"unit_price": price, "discount_pct": 0, "vat_rate": 0}
}

func strp(s string) *string { return &s }

func (f *apiFx) list(query string) []Document {
	f.t.Helper()
	var out struct {
		Items []Document `json:"items"`
	}
	f.ok("GET", "/documents?"+query, nil, &out)
	return out.Items
}

// ---- tests -------------------------------------------------------------------

func TestDocumentsSearchQ(t *testing.T) {
	f := newAPIFx(t)
	f.partner("C1", "customer", "Boulangerie Amrani")
	f.partner("S1", "supplier", "Grossiste Sétif")
	f.ok("POST", "/documents", map[string]any{"doc_type": "QUOTE", "doc_date": "2026-03-10",
		"partner_id": "C1", "notes": "livraison urgente", "lines": []any{line(nil, "Transport", 1000, 150000)}}, nil)
	f.ok("POST", "/documents", map[string]any{"doc_type": "PURCHASE_ORDER", "doc_date": "2026-03-11",
		"partner_id": "S1", "supplier_ref": "FAC-7781", "lines": []any{line(nil, "Divers", 2000, 25025)}}, nil)

	cases := map[string]int{
		"q=amrani":                   1, // partner name
		"q=FAC-77":                   1, // supplier ref
		"q=urgente":                  1, // notes
		"q=1500":                     1, // amount in DA (draft totals are kept)
		"q=500%2C50":                 1, // 500,50 DA
		"q=introuvable":              0,
		"types=QUOTE,PURCHASE_ORDER": 2,
	}
	for q, want := range cases {
		if got := len(f.list(q)); got != want {
			t.Errorf("%s: %d documents, want %d", q, got, want)
		}
	}
	// status=cancelled
	d := f.list("q=amrani")[0]
	f.ok("POST", "/documents/"+d.ID+"/cancel", nil, nil)
	if got := len(f.list("status=cancelled")); got != 1 {
		t.Errorf("status=cancelled: %d", got)
	}
}

func TestDocumentsPaidRemainingFIFO(t *testing.T) {
	f := newAPIFx(t)
	f.partner("C1", "customer", "Client crédit")
	f.partner("S1", "supplier", "Fournisseur")
	f.exec(`UPDATE settings SET value='1' WHERE key='allow_negative_stock'`)
	f.exec(`INSERT OR REPLACE INTO settings (key,value,updated_at) VALUES ('allow_negative_stock','1','2026-01-01')`)

	inv := func(amount int64) Document {
		return f.postDoc(map[string]any{"doc_type": "SALE_INVOICE", "doc_date": "2026-03-10",
			"partner_id": "C1", "warehouse_id": f.wh, "payment_method": "credit",
			"lines": []any{line(nil, "Prestation", 1000, amount)}})
	}
	a := inv(100000) // 1 000 DA
	b := inv(50000)  // 500 DA
	cash := f.postDoc(map[string]any{"doc_type": "SALE_INVOICE", "doc_date": "2026-03-10",
		"partner_id": "C1", "warehouse_id": f.wh, "payment_method": "cib",
		"lines": []any{line(nil, "Prestation", 1000, 20000)}})
	// Payment of 1 200 DA: A fully, B 200 / 500.
	f.postDoc(map[string]any{"doc_type": "PAYMENT_IN", "doc_date": "2026-03-11",
		"partner_id": "C1", "amount": 120000, "payment_method": "cash"})

	got := map[string]Document{}
	for _, d := range f.list("types=SALE_INVOICE") {
		got[d.ID] = d
	}
	check := func(name string, d Document, paid, rem int64, st string) {
		t.Helper()
		g := got[d.ID]
		if g.Paid != paid || g.Remaining != rem || g.PaymentStatus != st {
			t.Errorf("%s: paid=%d remaining=%d status=%q, want %d/%d/%q",
				name, g.Paid, g.Remaining, g.PaymentStatus, paid, rem, st)
		}
	}
	check("A", a, 100000, 0, "paid")
	check("B", b, 20000, 30000, "partial")
	check("cash", cash, 20000, 0, "paid")

	// Supplier invoice, nothing paid yet → due; detail carries it too.
	si := f.postDoc(map[string]any{"doc_type": "PURCHASE_INVOICE", "doc_date": "2026-03-10",
		"partner_id": "S1", "warehouse_id": f.wh, "supplier_ref": "F-1",
		"lines": []any{line(nil, "Frais", 1000, 80000)}})
	var det Document
	f.ok("GET", "/documents/"+si.ID, nil, &det)
	if det.PaymentStatus != "due" || det.Remaining != 80000 {
		t.Errorf("supplier invoice: %q %d", det.PaymentStatus, det.Remaining)
	}

	// Open items agree with the list.
	var oi struct {
		TotalOpen int64 `json:"total_open"`
		Items     []struct {
			DocumentID  string `json:"document_id"`
			Outstanding int64  `json:"outstanding"`
		} `json:"open_items"`
	}
	f.ok("GET", "/partners/C1/open-items", nil, &oi)
	if oi.TotalOpen != 30000 || len(oi.Items) != 1 || oi.Items[0].DocumentID != b.ID {
		t.Errorf("open items: %+v", oi)
	}

	// Prepayment then invoice: the carried credit settles it.
	f.partner("C2", "customer", "Client acompte")
	f.postDoc(map[string]any{"doc_type": "PAYMENT_IN", "doc_date": "2026-03-10",
		"partner_id": "C2", "amount": 30000, "payment_method": "cash"})
	c := f.postDoc(map[string]any{"doc_type": "SALE_INVOICE", "doc_date": "2026-03-11",
		"partner_id": "C2", "warehouse_id": f.wh, "payment_method": "credit",
		"lines": []any{line(nil, "Prestation", 1000, 30000)}})
	f.ok("GET", "/documents/"+c.ID, nil, &det)
	if det.PaymentStatus != "paid" {
		t.Errorf("prepaid invoice: %q remaining %d", det.PaymentStatus, det.Remaining)
	}
}

func TestDocumentAttachments(t *testing.T) {
	f := newAPIFx(t)
	var d Document
	f.ok("POST", "/documents", map[string]any{"doc_type": "QUOTE", "doc_date": "2026-03-10",
		"notes": "imprimée", "internal_notes": "marge serrée", "lines": []any{line(nil, "X", 1000, 100)}}, &d)
	if d.InternalNotes == nil || *d.InternalNotes != "marge serrée" || d.Notes == nil || *d.Notes != "imprimée" {
		t.Fatalf("notes not stored: %+v", d)
	}
	code, b := f.do("POST", "/documents/"+d.ID+"/attachments?name=bl%20scan.pdf", nil, []byte("%PDF-1.4 hello"))
	if code != http.StatusCreated {
		t.Fatalf("upload: %d %s", code, b)
	}
	var a Attachment
	json.Unmarshal(b, &a)
	if a.Mime != "application/pdf" || a.Size != 14 || a.Name != "bl scan.pdf" {
		t.Errorf("attachment: %+v", a)
	}
	var lst struct {
		Items []Attachment `json:"items"`
	}
	f.ok("GET", "/documents/"+d.ID+"/attachments", nil, &lst)
	if len(lst.Items) != 1 {
		t.Fatalf("list: %+v", lst)
	}
	code, b = f.do("GET", "/documents/"+d.ID+"/attachments/"+a.ID, nil, nil)
	if code != 200 || string(b) != "%PDF-1.4 hello" {
		t.Errorf("download: %d %q", code, b)
	}
	big := make([]byte, maxAttachment+1)
	if code, _ := f.do("POST", "/documents/"+d.ID+"/attachments?name=big.bin", nil, big); code != http.StatusRequestEntityTooLarge {
		t.Errorf("oversize: %d", code)
	}
	if code, _ := f.do("POST", "/documents/"+d.ID+"/attachments", nil, []byte("x")); code != http.StatusBadRequest {
		t.Errorf("no name: %d", code)
	}
	if code, _ := f.do("DELETE", "/documents/"+d.ID+"/attachments/"+a.ID, nil, nil); code != 200 {
		t.Errorf("delete: %d", code)
	}
	if code, _ := f.do("GET", "/documents/"+d.ID+"/attachments/"+a.ID, nil, nil); code != 404 {
		t.Errorf("after delete: %d", code)
	}
}

func TestStockTransferRoundTrip(t *testing.T) {
	f := newAPIFx(t)
	f.product("P1")
	var dest string
	var wh Warehouse
	f.ok("POST", "/warehouses", map[string]any{"name": "Dépôt 2"}, &wh)
	dest = wh.ID
	pid := strp("P1")
	// Stock in: 10 units at 100 DA.
	f.postDoc(map[string]any{"doc_type": "STOCK_ADJUSTMENT", "doc_date": "2026-03-10",
		"warehouse_id": f.wh, "reason": "stock initial", "lines": []any{line(pid, "P1", 10000, 10000)}})

	// Same depot on both sides is refused.
	if code, _ := f.do("POST", "/documents", map[string]any{"doc_type": "STOCK_TRANSFER",
		"doc_date": "2026-03-10", "warehouse_id": f.wh, "dest_warehouse_id": f.wh,
		"lines": []any{line(pid, "P1", 1000, 0)}}, nil); code != http.StatusBadRequest {
		t.Errorf("same depot: %d", code)
	}

	var d Document
	f.ok("POST", "/documents", map[string]any{"doc_type": "STOCK_TRANSFER", "doc_date": "2026-03-10",
		"warehouse_id": f.wh, "dest_warehouse_id": dest,
		"lines": []any{line(pid, "P1", 3000, 0), line(nil, "Palette consignée", 1000, 0)}}, &d)
	// Update the draft (4 units) then post it.
	f.ok("PUT", "/documents/"+d.ID, map[string]any{"doc_type": "STOCK_TRANSFER", "doc_date": "2026-03-10",
		"warehouse_id": f.wh, "dest_warehouse_id": dest,
		"lines": []any{line(pid, "P1", 4000, 0), line(nil, "Palette consignée", 1000, 0)}}, &d)
	if d.DestWarehouseID == nil || *d.DestWarehouseID != dest || len(d.Lines) != 2 {
		t.Fatalf("draft: %+v", d)
	}
	f.ok("POST", "/documents/"+d.ID+"/post", nil, &d)
	if d.Status != "posted" || d.Number == nil {
		t.Fatalf("not posted: %+v", d)
	}
	lvl := func(w string) (q int64) {
		f.db.QueryRow(`SELECT COALESCE(SUM(qty_milli),0) FROM stock_levels WHERE product_id='P1' AND warehouse_id=?`, w).Scan(&q)
		return
	}
	if a, b := lvl(f.wh), lvl(dest); a != 6000 || b != 4000 {
		t.Errorf("levels after transfer: src=%d dest=%d", a, b)
	}
	var n int
	f.db.QueryRow(`SELECT COUNT(*) FROM stock_ledger WHERE document_id=?`, d.ID).Scan(&n)
	if n != 2 {
		t.Errorf("ledger rows for transfer: %d (free-text line must not move stock)", n)
	}
}

var _ = fmt.Sprintf
