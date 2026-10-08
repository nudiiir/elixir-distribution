package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/store"
)

type posFx struct {
	t  *testing.T
	db *sql.DB
	s  *Server
	h  http.Handler
	wh string
}

func newPosFx(t *testing.T) *posFx {
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
	f := &posFx{t: t, db: db, s: &Server{db: db}}
	db.QueryRow(`SELECT id FROM warehouses LIMIT 1`).Scan(&f.wh)
	var uid string
	db.QueryRow(`SELECT id FROM users LIMIT 1`).Scan(&uid)
	usr := &AuthUser{ID: uid, Username: "admin", Role: "admin", Active: true,
		Perms: EffectivePerms("admin", "{}")}
	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			next.ServeHTTP(w, req.WithContext(context.WithValue(req.Context(), userKey, usr)))
		})
	})
	r.Route("/api/v1", func(r chi.Router) {
		r.Post("/caisse/open", f.s.caisseOpen)
		r.Get("/caisse/report", f.s.caisseReport)
		r.Post("/caisse/close", f.s.caisseClose)
		r.Get("/reports/breakdown", f.s.reportBreakdown)
		f.s.routesPosUX(r)
	})
	f.h = r
	f.exec(`INSERT OR REPLACE INTO settings (key,value,updated_at) VALUES ('allow_negative_stock','1','2026-03-10')`)
	f.exec(`INSERT INTO products (id,name,unit,vat_rate,purchase_price,price_retail,active,created_at,updated_at)
		VALUES ('P','Produit','piece',0,0,100000,1,'2026-01-01','2026-01-01')`)
	f.exec(`INSERT INTO partners (id,kind,name,active,created_at,updated_at)
		VALUES ('C','customer','Client',1,'2026-01-01','2026-01-01')`)
	return f
}

func (f *posFx) exec(q string, args ...any) {
	f.t.Helper()
	if _, err := f.db.Exec(q, args...); err != nil {
		f.t.Fatalf("%v\n%s", err, q)
	}
}

func (f *posFx) call(method, path string, body any) (int, map[string]any) {
	f.t.Helper()
	var buf []byte
	if body != nil {
		buf, _ = json.Marshal(body)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(buf))
	rec := httptest.NewRecorder()
	f.h.ServeHTTP(rec, req)
	out := map[string]any{}
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func (f *posFx) checkout(session string, partner *string, method *string, pays ...PosPayment) (int, map[string]any) {
	return f.call("POST", "/api/v1/pos/checkout", map[string]any{
		"warehouse_id":      f.wh,
		"partner_id":        partner,
		"caisse_session_id": session,
		"payment_method":    method,
		"payments":          pays,
		"lines": []map[string]any{{
			"product_id": "P", "description": "Produit", "qty_milli": 1000,
			"unit_price": 100000, "discount_pct": 0, "vat_rate": 0,
		}},
	})
}

func num(m map[string]any, k string) int64 {
	v, _ := m[k].(float64)
	return int64(v)
}

func TestPosCheckoutSplitAndZReport(t *testing.T) {
	f := newPosFx(t)
	code, out := f.call("POST", "/api/v1/caisse/open", map[string]any{"opening_cash": 500000})
	if code != http.StatusCreated {
		t.Fatalf("open: %d %v", code, out)
	}
	session := out["session"].(map[string]any)["id"].(string)
	cust := "C"
	cash := "cash"

	// 1) cash + card: timbre on the 400 DA cash part (5 DA).
	code, out = f.checkout(session, nil, nil,
		PosPayment{"cib", 60000}, PosPayment{"cash", 40500})
	if code != http.StatusCreated {
		t.Fatalf("split cash+card: %d %v", code, out)
	}
	doc := out["document"].(map[string]any)
	if doc["payment_method"] != nil {
		t.Errorf("split ticket must keep payment_method NULL, got %v", doc["payment_method"])
	}
	if num(doc, "timbre") != 500 || num(doc, "total_ttc") != 100500 {
		t.Errorf("split totals: timbre=%d total=%d", num(doc, "timbre"), num(doc, "total_ttc"))
	}
	if p := out["payments"].([]any); len(p) != 2 {
		t.Errorf("payments returned: %v", p)
	}

	// 2) cash + credit: credit part to the customer's account.
	code, out = f.checkout(session, &cust, nil,
		PosPayment{"credit", 30000}, PosPayment{"cash", 70700})
	if code != http.StatusCreated {
		t.Fatalf("split cash+credit: %d %v", code, out)
	}
	var bal int64
	f.db.QueryRow(`SELECT COALESCE(SUM(amount),0) FROM partner_ledger WHERE partner_id='C'`).Scan(&bal)
	if bal != 30000 {
		t.Errorf("customer balance = %d, want 30000", bal)
	}

	// 3) classic single cash ticket (timbre 10 DA on 1 000 DA).
	code, out = f.checkout(session, nil, &cash)
	if code != http.StatusCreated {
		t.Fatalf("single cash: %d %v", code, out)
	}
	if num(out["document"].(map[string]any), "timbre") != 1000 {
		t.Errorf("single cash timbre = %v", out["document"])
	}

	// 4) refused (cash forgets the timbre): no draft left behind.
	var before, after int
	f.db.QueryRow(`SELECT COUNT(*) FROM documents`).Scan(&before)
	code, out = f.checkout(session, nil, nil, PosPayment{"cib", 60000}, PosPayment{"cash", 40000})
	if code != http.StatusConflict {
		t.Fatalf("mismatch must be refused with 409, got %d %v", code, out)
	}
	f.db.QueryRow(`SELECT COUNT(*) FROM documents`).Scan(&after)
	if before != after {
		t.Errorf("refused checkout left a draft (%d → %d documents)", before, after)
	}
	// Credit without customer refused up front.
	if code, _ := f.checkout(session, nil, nil, PosPayment{"credit", 100000}); code != http.StatusConflict {
		t.Errorf("credit without customer: %d", code)
	}

	// X report: each payment row under its method.
	code, out = f.call("GET", "/api/v1/caisse/report", nil)
	if code != http.StatusOK {
		t.Fatalf("report: %d %v", code, out)
	}
	rep := out["report"].(map[string]any)
	wantCash := int64(40500 + 70700 + 101000)
	if num(rep, "cash_sales") != wantCash {
		t.Errorf("cash_sales = %d, want %d", num(rep, "cash_sales"), wantCash)
	}
	if num(rep, "card_sales") != 60000 || num(rep, "credit_sales") != 30000 {
		t.Errorf("card=%d credit=%d", num(rep, "card_sales"), num(rep, "credit_sales"))
	}
	if num(rep, "ticket_count") != 3 || num(rep, "total_sales") != 100500+100700+101000 {
		t.Errorf("count=%d total=%d", num(rep, "ticket_count"), num(rep, "total_sales"))
	}
	if num(rep, "expected_cash") != 500000+wantCash {
		t.Errorf("expected_cash = %d, want %d", num(rep, "expected_cash"), 500000+wantCash)
	}

	// Recent tickets of the session carry their payment rows.
	code, out = f.call("GET", "/api/v1/pos/recent", nil)
	if items := out["items"].([]any); code != http.StatusOK || len(items) != 3 {
		t.Fatalf("recent: %d %v", code, out)
	}

	// Breakdown by payment: rows split, timbre off the cash rows.
	code, out = f.call("GET", "/api/v1/reports/breakdown?by=payment", nil)
	if code != http.StatusOK {
		t.Fatalf("breakdown: %d %v", code, out)
	}
	got := map[string]int64{}
	for _, it := range out["items"].([]any) {
		m := it.(map[string]any)
		got[m["key"].(string)] = num(m, "total_ttc")
	}
	if got["cash"] != 40000+70000+100000 || got["cib"] != 60000 || got["credit"] != 30000 {
		t.Errorf("breakdown by payment = %v", got)
	}

	// Z closure: expected cash identical to the X report.
	code, out = f.call("POST", "/api/v1/caisse/close", map[string]any{"counted_cash": 500000 + wantCash})
	if code != http.StatusOK || num(out["report"].(map[string]any), "expected_cash") != 500000+wantCash {
		t.Fatalf("Z: %d %v", code, out)
	}
}
