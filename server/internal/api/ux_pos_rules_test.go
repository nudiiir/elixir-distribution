package api

import (
	"context"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
	"elixir/server/internal/store"
)

// newPosFxUser is newPosFx with a switchable caller (*cur is read on every
// request), so one test can ring tickets as a cashier then as the admin.
func newPosFxUser(t *testing.T, cur **AuthUser) *posFx {
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
	if *cur == nil {
		*cur = &AuthUser{ID: uid, Username: "admin", Role: "admin", Active: true,
			Perms: EffectivePerms("admin", "{}")}
	}
	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			next.ServeHTTP(w, req.WithContext(context.WithValue(req.Context(), userKey, *cur)))
		})
	})
	r.Route("/api/v1", func(r chi.Router) {
		r.Get("/caisse/current", f.s.caisseCurrent)
		r.Post("/caisse/open", f.s.caisseOpen)
		r.Get("/caisse/report", f.s.caisseReport)
		r.Post("/caisse/close", f.s.caisseClose)
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

func (f *posFx) setting(k, v string) {
	f.exec(`INSERT OR REPLACE INTO settings (key,value,updated_at) VALUES (?,?,'2026-03-10')`, k, v)
}

// checkoutPrice rings one line at unitPrice (VAT 0).
func (f *posFx) checkoutPrice(session string, unitPrice int64, partner *string, method *string,
	pays ...PosPayment) (int, map[string]any) {
	return f.call("POST", "/api/v1/pos/checkout", map[string]any{
		"warehouse_id":      f.wh,
		"partner_id":        partner,
		"caisse_session_id": session,
		"payment_method":    method,
		"payments":          pays,
		"lines": []map[string]any{{
			"product_id": "P", "description": "Produit", "qty_milli": 1000,
			"unit_price": unitPrice, "discount_pct": 0, "vat_rate": 0,
		}},
	})
}

func TestCashRoundingDelta(t *testing.T) {
	for _, step := range []int64{50, 100, 500} {
		for _, timbre := range []bool{false, true} {
			for goods := int64(1); goods < 400000; goods += 37 {
				d := cashRoundingDelta(goods, step, timbre)
				got := cashDue(goods+d, timbre)
				if got%step != 0 {
					t.Fatalf("step %d timbre %v goods %d: d=%d gives %d, not a multiple",
						step, timbre, goods, d, got)
				}
				if diff := absI(got - cashDue(goods, timbre)); diff > step {
					t.Fatalf("step %d timbre %v goods %d: rounded %d too far from %d",
						step, timbre, goods, got, cashDue(goods, timbre))
				}
			}
		}
	}
	if d := cashRoundingDelta(123456, 0, true); d != 0 {
		t.Errorf("no rounding configured must give 0, got %d", d)
	}
	// 123,45 DA without timbre → 123,00 (nearest DA), 123,50 at 0,50 DA.
	if d := cashRoundingDelta(12345, 100, false); d != -45 {
		t.Errorf("1 DA rounding of 123,45 = %d, want -45", d)
	}
	if d := cashRoundingDelta(12345, 50, false); d != 5 {
		t.Errorf("0,50 DA rounding of 123,45 = %d, want +5", d)
	}
}

func TestSessionFromPreviousDay(t *testing.T) {
	loc := time.FixedZone("Alger", 3600)
	now := time.Date(2026, 10, 8, 9, 0, 0, 0, loc)
	cases := map[string]bool{
		"2026-10-08T07:00:00Z": false, // 08:00 today, local
		"2026-10-07T23:30:00Z": false, // 00:30 today, local (UTC still yesterday)
		"2026-10-07T22:30:00Z": true,  // 23:30 yesterday, local
		"2026-09-30T10:00:00Z": true,
		"garbage":              false,
	}
	for in, want := range cases {
		if got := sessionFromPreviousDay(in, now); got != want {
			t.Errorf("%s: got %v want %v", in, got, want)
		}
	}
}

func TestPosDailyZRule(t *testing.T) {
	var cur *AuthUser
	f := newPosFxUser(t, &cur)
	cash := "cash"
	yesterday := time.Now().Add(-36 * time.Hour).UTC().Format(time.RFC3339)
	f.exec(`INSERT INTO caisse_sessions (id, user_id, status, opened_at, opening_cash)
		VALUES ('S1', ?, 'open', ?, 0)`, cur.ID, yesterday)

	// Default (setting absent) = rule on: refused with needs_z.
	code, out := f.checkoutPrice("S1", 100000, nil, &cash)
	if code != http.StatusConflict || out["needs_z"] != true {
		t.Fatalf("stale till must refuse with needs_z: %d %v", code, out)
	}
	_, cur2 := f.call("GET", "/api/v1/caisse/current", nil)
	if cur2["needs_z"] != true {
		t.Errorf("caisse/current must report needs_z: %v", cur2)
	}
	// Rule off: the sale goes through.
	f.setting("pos_require_daily_z", "0")
	if code, out := f.checkoutPrice("S1", 100000, nil, &cash); code != http.StatusCreated {
		t.Fatalf("rule off: %d %v", code, out)
	}
	// Rule on, Z done, new till today: sales allowed.
	f.setting("pos_require_daily_z", "1")
	if code, out := f.call("POST", "/api/v1/caisse/close", map[string]any{"counted_cash": 0}); code != http.StatusOK {
		t.Fatalf("close: %d %v", code, out)
	}
	code, out = f.call("POST", "/api/v1/caisse/open", map[string]any{"opening_cash": 0})
	if code != http.StatusCreated {
		t.Fatalf("open: %d %v", code, out)
	}
	sid := out["session"].(map[string]any)["id"].(string)
	if code, out := f.checkoutPrice(sid, 100000, nil, &cash); code != http.StatusCreated {
		t.Fatalf("fresh till: %d %v", code, out)
	}
}

func TestPosCashRounding(t *testing.T) {
	var cur *AuthUser
	f := newPosFxUser(t, &cur)
	f.setting("pos_cash_rounding", "100") // 1 DA
	code, out := f.call("POST", "/api/v1/caisse/open", map[string]any{"opening_cash": 0})
	if code != http.StatusCreated {
		t.Fatalf("open: %d %v", code, out)
	}
	sid := out["session"].(map[string]any)["id"].(string)
	cash := "cash"
	timbre := domain.TimbreApplies(domain.SaleTicket, "cash")

	// 1) single cash: 1 000,37 DA → server adds an « Arrondi » line.
	code, out = f.checkoutPrice(sid, 100037, nil, &cash)
	if code != http.StatusCreated {
		t.Fatalf("cash: %d %v", code, out)
	}
	doc := out["document"].(map[string]any)
	total1 := num(doc, "total_ttc")
	if total1%100 != 0 {
		t.Errorf("rounded cash ticket total %d is not whole DA", total1)
	}
	d := cashRoundingDelta(100037, 100, timbre)
	if total1 != cashDue(100037+d, timbre) {
		t.Errorf("total %d, want %d", total1, cashDue(100037+d, timbre))
	}
	lines := doc["lines"].([]any)
	last := lines[len(lines)-1].(map[string]any)
	if len(lines) != 2 || last["description"] != posRoundingLabel || num(last, "unit_price") != d {
		t.Errorf("rounding line missing or wrong: %v", lines)
	}

	// 2) card: no rounding.
	cib := "cib"
	code, out = f.checkoutPrice(sid, 100037, nil, &cib)
	if code != http.StatusCreated || num(out["document"].(map[string]any), "total_ttc") != 100037 {
		t.Fatalf("card must not be rounded: %d %v", code, out)
	}

	// 3) mixed: 600 DA card + the rounded cash part.
	cashGoods := int64(100037 - 60000)
	dm := cashRoundingDelta(cashGoods, 100, timbre)
	cashPart := cashDue(cashGoods+dm, timbre)
	code, out = f.checkoutPrice(sid, 100037, nil, nil, PosPayment{"cib", 60000}, PosPayment{"cash", cashPart})
	if code != http.StatusCreated {
		t.Fatalf("mixed rounded: %d %v", code, out)
	}
	total3 := num(out["document"].(map[string]any), "total_ttc")
	if total3 != 60000+cashPart {
		t.Errorf("mixed total %d, want %d", total3, 60000+cashPart)
	}
	// 4) the unrounded amount (older app) is still accepted, without a line.
	code, out = f.checkoutPrice(sid, 100037, nil, nil, PosPayment{"cash", cashDue(100037, timbre)})
	if code != http.StatusCreated {
		t.Fatalf("unrounded single row: %d %v", code, out)
	}
	total4 := num(out["document"].(map[string]any), "total_ttc")

	// X report: the drawer expects exactly the cash taken.
	code, out = f.call("GET", "/api/v1/caisse/report", nil)
	if code != http.StatusOK {
		t.Fatalf("report: %d %v", code, out)
	}
	rep := out["report"].(map[string]any)
	if want := total1 + cashPart + total4; num(rep, "cash_sales") != want {
		t.Errorf("cash_sales %d, want %d", num(rep, "cash_sales"), want)
	}
}

func TestPosCheckoutCreditRights(t *testing.T) {
	var cur *AuthUser
	f := newPosFxUser(t, &cur)
	admin := cur
	cashier := &AuthUser{ID: admin.ID, Username: "caisse", Role: "cashier", Active: true,
		Perms: EffectivePerms("cashier", "{}")}
	cashier.Perms["credit_sale"] = true // this cashier may sell on credit…
	cashier.Perms["price_edit"] = true  // (prices below are arbitrary)
	f.exec(`UPDATE partners SET credit_limit = 50000 WHERE id='C'`)
	f.exec(`INSERT INTO partners (id,kind,name,active,created_at,updated_at)
		VALUES ('D','customer','Sans plafond',1,'2026-01-01','2026-01-01')`)
	f.setting("default_credit_limit", "60000")
	code, out := f.call("POST", "/api/v1/caisse/open", map[string]any{"opening_cash": 0})
	if code != http.StatusCreated {
		t.Fatalf("open: %d %v", code, out)
	}
	sid := out["session"].(map[string]any)["id"].(string)
	cust, other := "C", "D"
	credit := "credit"

	// …within the customer's ceiling.
	cur = cashier
	if code, out := f.checkoutPrice(sid, 40000, &cust, &credit); code != http.StatusCreated {
		t.Fatalf("within ceiling: %d %v", code, out)
	}
	// Above the customer's own ceiling → manager code asked.
	code, out = f.checkoutPrice(sid, 20000, &cust, &credit)
	if code != http.StatusForbidden || out["needs_approval"] != true {
		t.Fatalf("over ceiling must ask approval: %d %v", code, out)
	}
	// A customer without a ceiling falls under the shop's default one.
	code, out = f.checkoutPrice(sid, 70000, &other, &credit)
	if code != http.StatusForbidden || out["needs_approval"] != true || out["action"] != "credit_limit" {
		t.Fatalf("over default ceiling must ask approval: %d %v", code, out)
	}
	// Without the credit_sale right: manager code.
	noCredit := &AuthUser{ID: admin.ID, Username: "c2", Role: "cashier", Active: true,
		Perms: EffectivePerms("cashier", "{}")}
	noCredit.Perms["credit_sale"] = false
	noCredit.Perms["price_edit"] = true
	cur = noCredit
	code, out = f.checkoutPrice(sid, 1000, &other, &credit)
	if code != http.StatusForbidden || out["action"] != "credit_sale" {
		t.Fatalf("cashier without credit_sale: %d %v", code, out)
	}
	// The admin may go over the ceilings.
	cur = admin
	if code, out := f.checkoutPrice(sid, 100000, &cust, &credit); code != http.StatusCreated {
		t.Fatalf("admin over ceiling: %d %v", code, out)
	}
	if code, out := f.checkoutPrice(sid, 100000, &other, &credit); code != http.StatusCreated {
		t.Fatalf("admin over default ceiling: %d %v", code, out)
	}
}

func TestPosCloseTillRight(t *testing.T) {
	var cur *AuthUser
	f := newPosFxUser(t, &cur)
	admin := cur
	if code, out := f.call("POST", "/api/v1/caisse/open", map[string]any{"opening_cash": 0}); code != http.StatusCreated {
		t.Fatalf("open: %d %v", code, out)
	}
	cashier := &AuthUser{ID: admin.ID, Username: "caisse", Role: "cashier", Active: true,
		Perms: EffectivePerms("cashier", "{}")}
	cashier.Perms["close_till"] = false
	cur = cashier
	code, out := f.call("GET", "/api/v1/caisse/report", nil)
	if code != http.StatusForbidden || out["needs_approval"] != true || out["action"] != "close_till" {
		t.Fatalf("X report without close_till: %d %v", code, out)
	}
	code, out = f.call("POST", "/api/v1/caisse/close", map[string]any{"counted_cash": 0})
	if code != http.StatusForbidden || out["action"] != "close_till" {
		t.Fatalf("Z without close_till: %d %v", code, out)
	}
	cashier.Perms["close_till"] = true
	if code, out := f.call("POST", "/api/v1/caisse/close", map[string]any{"counted_cash": 0}); code != http.StatusOK {
		t.Fatalf("Z with close_till: %d %v", code, out)
	}
}

func TestPosCheckoutPriceEditRight(t *testing.T) {
	var cur *AuthUser
	f := newPosFxUser(t, &cur)
	admin := cur
	if code, out := f.call("POST", "/api/v1/caisse/open", map[string]any{"opening_cash": 0}); code != http.StatusCreated {
		t.Fatalf("open: %d %v", code, out)
	}
	sid := ""
	f.db.QueryRow(`SELECT id FROM caisse_sessions WHERE status='open'`).Scan(&sid)
	cashier := &AuthUser{ID: admin.ID, Username: "caisse", Role: "cashier", Active: true,
		Perms: EffectivePerms("cashier", "{}")}
	cashier.Perms["price_edit"] = false
	cur = cashier
	cib := "cib"
	// The product's own price: fine.
	if code, out := f.checkoutPrice(sid, 100000, nil, &cib); code != http.StatusCreated {
		t.Fatalf("product price: %d %v", code, out)
	}
	// Another price: manager code.
	code, out := f.checkoutPrice(sid, 90000, nil, &cib)
	if code != http.StatusForbidden || out["needs_approval"] != true || out["action"] != "price_edit" {
		t.Fatalf("changed price without price_edit: %d %v", code, out)
	}
	cashier.Perms["price_edit"] = true
	if code, out := f.checkoutPrice(sid, 90000, nil, &cib); code != http.StatusCreated {
		t.Fatalf("changed price with price_edit: %d %v", code, out)
	}
}
