package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/store"
)

// ---- fixture: a real migrated DB behind the product routes ----------------

type prodFx struct {
	t   *testing.T
	db  *sql.DB
	s   *Server
	h   http.Handler
	wh  string
	usr *AuthUser
}

func newProdFx(t *testing.T) *prodFx {
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
	f := &prodFx{t: t, db: db, s: &Server{db: db}}
	if err := db.QueryRow(`SELECT id FROM warehouses LIMIT 1`).Scan(&f.wh); err != nil {
		t.Fatal(err)
	}
	var uid string
	db.QueryRow(`SELECT id FROM users LIMIT 1`).Scan(&uid)
	f.usr = &AuthUser{ID: uid, Username: "admin", Role: "admin", Active: true,
		Perms: EffectivePerms("admin", "{}")}
	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			next.ServeHTTP(w, req.WithContext(context.WithValue(req.Context(), userKey, f.usr)))
		})
	})
	r.Route("/api/v1", func(r chi.Router) {
		r.Get("/products/{id}", f.s.getProduct)
		r.Post("/products", f.s.createProduct)
		r.Put("/products/{id}", f.s.updateProduct)
		r.Get("/products/{id}/fiche", f.s.ficheProduct)
		f.s.routesProductsUX(r)
	})
	f.h = r
	return f
}

func (f *prodFx) exec(q string, args ...any) {
	f.t.Helper()
	if _, err := f.db.Exec(q, args...); err != nil {
		f.t.Fatalf("%v\n%s", err, q)
	}
}

func (f *prodFx) product(id, name string) {
	f.exec(`INSERT INTO products (id,name,unit,vat_rate,purchase_price,price_retail,active,created_at,updated_at)
		VALUES (?,?,'piece',1900,100,200,1,'2026-01-01','2026-01-01')`, id, name)
}

func (f *prodFx) do(method, path, ct string, body []byte) *httptest.ResponseRecorder {
	f.t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	if ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	rec := httptest.NewRecorder()
	f.h.ServeHTTP(rec, req)
	return rec
}

func (f *prodFx) json(method, path string, v any) (*httptest.ResponseRecorder, map[string]any) {
	f.t.Helper()
	b, _ := json.Marshal(v)
	rec := f.do(method, path, "application/json", b)
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec, out
}

func testImage(w, h int) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.SetNRGBA(x, y, color.NRGBA{R: uint8(x), G: uint8(y), B: 120, A: 255})
		}
	}
	return img
}

// ---- photos ----------------------------------------------------------------

func TestProductImagesRoundTrip(t *testing.T) {
	f := newProdFx(t)
	f.product("P1", "Shampoing")

	var pngBuf bytes.Buffer
	png.Encode(&pngBuf, testImage(640, 320))
	rec := f.do("POST", "/api/v1/products/P1/images", "image/png", pngBuf.Bytes())
	if rec.Code != 200 {
		t.Fatalf("upload png: %d %s", rec.Code, rec.Body.String())
	}
	var p Product
	json.Unmarshal(rec.Body.Bytes(), &p)
	if p.ImageRev == 0 || p.ImageCount != 1 {
		t.Fatalf("after upload: rev=%d count=%d", p.ImageRev, p.ImageCount)
	}

	// Original back, byte for byte, with its type and a long cache.
	rec = f.do("GET", "/api/v1/products/P1/images/0", "", nil)
	if rec.Code != 200 || rec.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("get original: %d %s", rec.Code, rec.Header().Get("Content-Type"))
	}
	if !bytes.Equal(rec.Body.Bytes(), pngBuf.Bytes()) {
		t.Fatal("original bytes differ")
	}
	if cc := rec.Header().Get("Cache-Control"); cc == "" {
		t.Fatal("no Cache-Control")
	}

	// Thumbnail fits 160 px, keeps the aspect ratio.
	rec = f.do("GET", "/api/v1/products/P1/images/0?thumb=1", "", nil)
	th, err := png.Decode(rec.Body)
	if err != nil {
		t.Fatalf("thumb decode: %v", err)
	}
	if b := th.Bounds(); b.Dx() != 160 || b.Dy() != 80 {
		t.Fatalf("thumb size %dx%d, want 160x80", b.Dx(), b.Dy())
	}

	// A JPEG second photo, made main.
	var jpgBuf bytes.Buffer
	jpeg.Encode(&jpgBuf, testImage(100, 400), nil)
	rec = f.do("POST", "/api/v1/products/P1/images", "image/jpeg", jpgBuf.Bytes())
	if rec.Code != 200 {
		t.Fatalf("upload jpeg: %d %s", rec.Code, rec.Body.String())
	}
	rec = f.do("GET", "/api/v1/products/P1/images/1?thumb=1", "", nil)
	if rec.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("second thumb type %s", rec.Header().Get("Content-Type"))
	}
	jt, err := jpeg.Decode(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	if b := jt.Bounds(); b.Dx() != 40 || b.Dy() != 160 {
		t.Fatalf("jpeg thumb %dx%d, want 40x160", b.Dx(), b.Dy())
	}
	rec = f.do("POST", "/api/v1/products/P1/images/1/main", "", nil)
	if rec.Code != 200 {
		t.Fatalf("main: %d %s", rec.Code, rec.Body.String())
	}
	rec = f.do("GET", "/api/v1/products/P1/images/0", "", nil)
	if rec.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatal("main photo not moved to position 0")
	}

	// Delete both: image_rev reported 0 again.
	f.do("DELETE", "/api/v1/products/P1/images/0", "", nil)
	rec = f.do("DELETE", "/api/v1/products/P1/images/0", "", nil)
	json.Unmarshal(rec.Body.Bytes(), &p)
	if rec.Code != 200 || p.ImageCount != 0 || p.ImageRev != 0 {
		t.Fatalf("after deletes: %d count=%d rev=%d", rec.Code, p.ImageCount, p.ImageRev)
	}
	if rec = f.do("GET", "/api/v1/products/P1/images/0", "", nil); rec.Code != 404 {
		t.Fatalf("deleted photo still served: %d", rec.Code)
	}

	// Refused: not an image, too large, no permission.
	if rec = f.do("POST", "/api/v1/products/P1/images", "image/png", []byte("hello")); rec.Code != 400 {
		t.Fatalf("garbage accepted: %d", rec.Code)
	}
	big := make([]byte, maxImageBytes+10)
	if rec = f.do("POST", "/api/v1/products/P1/images", "image/jpeg", big); rec.Code != 400 {
		t.Fatalf("oversize accepted: %d", rec.Code)
	}
	f.usr.Perms = map[string]bool{"pos": true}
	if rec = f.do("POST", "/api/v1/products/P1/images", "image/png", pngBuf.Bytes()); rec.Code != 403 {
		t.Fatalf("no-perm upload: %d", rec.Code)
	}
}

func TestDownscaleNeverUpscales(t *testing.T) {
	d := downscale(testImage(50, 30), 160)
	if d.Bounds().Dx() != 50 || d.Bounds().Dy() != 30 {
		t.Fatalf("got %v", d.Bounds())
	}
}

// ---- bulk ------------------------------------------------------------------

func TestBulkProducts(t *testing.T) {
	f := newProdFx(t)
	f.product("A", "A")
	f.product("B", "B")
	f.product("C", "C")
	f.exec(`INSERT INTO product_categories (id, name, created_at, updated_at) VALUES ('CAT', 'Boissons', '2026-01-01', '2026-01-01')`)

	count := func(q string) int {
		var n int
		f.db.QueryRow(q).Scan(&n)
		return n
	}
	rec, out := f.json("POST", "/api/v1/products/bulk",
		map[string]any{"ids": []string{"A", "B", "B", "ZZZ"}, "op": "set_category", "category_id": "CAT"})
	if rec.Code != 200 || out["updated"].(float64) != 2 {
		t.Fatalf("set_category: %d %v", rec.Code, out)
	}
	if n := count(`SELECT COUNT(*) FROM products WHERE category_id='CAT'`); n != 2 {
		t.Fatalf("category on %d products", n)
	}
	f.json("POST", "/api/v1/products/bulk", map[string]any{"ids": []string{"A", "B", "C"}, "op": "set_vat", "vat_rate": 900})
	if n := count(`SELECT COUNT(*) FROM products WHERE vat_rate=900`); n != 3 {
		t.Fatalf("vat on %d", n)
	}
	f.json("POST", "/api/v1/products/bulk", map[string]any{"ids": []string{"A"}, "op": "set_promo",
		"promo_price": 150, "promo_start": "2026-10-01", "promo_end": "2026-10-31"})
	if n := count(`SELECT COUNT(*) FROM products WHERE promo_price=150 AND promo_end='2026-10-31'`); n != 1 {
		t.Fatal("promo not set")
	}
	f.json("POST", "/api/v1/products/bulk", map[string]any{"ids": []string{"A"}, "op": "clear_promo"})
	if n := count(`SELECT COUNT(*) FROM products WHERE promo_price IS NOT NULL`); n != 0 {
		t.Fatal("promo not cleared")
	}
	f.json("POST", "/api/v1/products/bulk", map[string]any{"ids": []string{"A", "C"}, "op": "deactivate"})
	if n := count(`SELECT COUNT(*) FROM products WHERE active=0`); n != 2 {
		t.Fatalf("deactivated %d", n)
	}
	f.json("POST", "/api/v1/products/bulk", map[string]any{"ids": []string{"C"}, "op": "activate"})
	if n := count(`SELECT COUNT(*) FROM products WHERE active=0`); n != 1 {
		t.Fatalf("still inactive %d", n)
	}
	if n := count(`SELECT COUNT(*) FROM audit_log WHERE action='product.bulk'`); n != 6 {
		t.Fatalf("audit entries %d", n)
	}
	// Refusals.
	for _, body := range []map[string]any{
		{"ids": []string{"A"}, "op": "explode"},
		{"ids": []string{}, "op": "activate"},
		{"ids": []string{"A"}, "op": "set_vat", "vat_rate": -5},
		{"ids": []string{"A"}, "op": "set_promo"},
		{"ids": []string{"A"}, "op": "set_category", "category_id": "NOPE"},
	} {
		if rec, _ := f.json("POST", "/api/v1/products/bulk", body); rec.Code != 400 {
			t.Fatalf("%v accepted: %d", body, rec.Code)
		}
	}
	f.usr.Perms = map[string]bool{"pos": true}
	if rec, _ := f.json("POST", "/api/v1/products/bulk", map[string]any{"ids": []string{"A"}, "op": "activate"}); rec.Code != 403 {
		t.Fatalf("no-perm bulk: %d", rec.Code)
	}
}

// ---- kind ------------------------------------------------------------------

func TestProductKind(t *testing.T) {
	f := newProdFx(t)
	rec, out := f.json("POST", "/api/v1/products", map[string]any{"name": "Pose écran", "kind": "service",
		"price_retail": 50000, "vat_rate": 1900})
	if rec.Code != 200 || out["kind"] != "service" {
		t.Fatalf("create service: %d %v", rec.Code, out)
	}
	id := out["id"].(string)
	// An old client that does not send kind keeps it.
	rec, out = f.json("PUT", "/api/v1/products/"+id, map[string]any{"name": "Pose écran 2", "price_retail": 50000})
	if rec.Code != 200 || out["kind"] != "service" {
		t.Fatalf("update keeps kind: %d %v", rec.Code, out)
	}
	if rec, _ := f.json("POST", "/api/v1/products", map[string]any{"name": "X", "kind": "magic"}); rec.Code != 400 {
		t.Fatalf("bad kind accepted: %d", rec.Code)
	}
}

// ---- fiche: running balance, sales 30 days, coverage -----------------------

func TestFicheBalanceAndCoverage(t *testing.T) {
	f := newProdFx(t)
	f.product("P", "Café")
	today := time.Now().Format("2006-01-02")
	old := time.Now().AddDate(0, 0, -60).Format("2006-01-02")
	doc := func(id, typ, date string) {
		f.exec(`INSERT INTO documents (id, doc_type, status, doc_date, warehouse_id, created_at, updated_at)
			VALUES (?, ?, 'posted', ?, ?, ?, ?)`, id, typ, date, f.wh, date+"T08:00:00Z", date+"T08:00:00Z")
	}
	led := func(id, docID string, qty int64, at string) {
		f.exec(`INSERT INTO stock_ledger (id, product_id, warehouse_id, qty_delta_milli, unit_cost, document_id, created_at)
			VALUES (?, 'P', ?, ?, 100, ?, ?)`, id, f.wh, qty, docID, at)
	}
	doc("R1", "PURCHASE_RECEIPT", old)
	led("L1", "R1", 100000, old+"T08:00:00Z") // +100
	doc("S1", "SALE_TICKET", old)
	led("L2", "S1", -10000, old+"T09:00:00Z") // 90 (outside the 30 days)
	doc("S2", "SALE_TICKET", today)
	led("L3", "S2", -27000, today+"T09:00:00Z") // 63
	doc("S3", "SALE_CREDIT_NOTE", today)
	led("L4", "S3", 3000, today+"T10:00:00Z") // 66 ; net sold today = 24
	f.exec(`INSERT INTO stock_levels (product_id, warehouse_id, qty_milli, avg_cost, updated_at)
		VALUES ('P', ?, 66000, 100, ?)`, f.wh, today)

	rec := f.do("GET", "/api/v1/products/P/fiche?full=1", "", nil)
	if rec.Code != 200 {
		t.Fatalf("fiche: %d %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Moves []struct {
			DocumentID   string `json:"document_id"`
			QtyMilli     int64  `json:"qty_milli"`
			BalanceAfter int64  `json:"balance_after"`
		} `json:"moves"`
		Sales []SalesDay `json:"sales_30d"`
		Avg   int64      `json:"avg_daily_sales_milli"`
		Cov   *int64     `json:"coverage_days"`
	}
	json.Unmarshal(rec.Body.Bytes(), &out)
	if len(out.Moves) != 4 {
		t.Fatalf("moves %d", len(out.Moves))
	}
	want := []struct {
		doc string
		bal int64
	}{{"S3", 66000}, {"S2", 63000}, {"S1", 90000}, {"R1", 100000}}
	for i, w := range want {
		if out.Moves[i].DocumentID != w.doc || out.Moves[i].BalanceAfter != w.bal {
			t.Fatalf("move %d = %+v, want %s/%d", i, out.Moves[i], w.doc, w.bal)
		}
	}
	if len(out.Sales) != 30 || out.Sales[29].Date != today || out.Sales[29].QtyMilli != 24000 {
		t.Fatalf("sales_30d last = %+v (len %d)", out.Sales[len(out.Sales)-1], len(out.Sales))
	}
	if out.Avg != 800 { // 24 u / 30 j
		t.Fatalf("avg %d", out.Avg)
	}
	if out.Cov == nil || *out.Cov != 82 { // 66 / 0.8
		t.Fatalf("coverage %v", out.Cov)
	}

	// No sales → coverage null.
	f.product("Q", "Thé")
	rec = f.do("GET", "/api/v1/products/Q/fiche", "", nil)
	var q map[string]any
	json.Unmarshal(rec.Body.Bytes(), &q)
	if q["coverage_days"] != nil {
		t.Fatalf("coverage without sales: %v", q["coverage_days"])
	}
}
