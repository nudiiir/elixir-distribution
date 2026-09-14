package analytics

import (
	"context"
	"database/sql"
	"fmt"
	"math/rand"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"elixir/server/internal/domain"
	"elixir/server/internal/store"
)

// ---- base de test : schéma réel (migrations) + jeu minimal déterministe ----

func testDB(t *testing.T) (*sql.DB, *Engine) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "t.db")
	rw, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(rw); err != nil {
		t.Fatal(err)
	}
	if err := store.Seed(rw); err != nil {
		t.Fatal(err)
	}
	seedFixture(t, rw)
	ro, err := store.OpenReadOnly(path, 2)
	if err != nil {
		t.Fatal(err)
	}
	e := New(ro)
	e.Now = func() time.Time { return time.Date(2026, 3, 15, 12, 0, 0, 0, time.Local) }
	t.Cleanup(func() { ro.Close(); rw.Close() })
	return rw, e
}

// Jeu : 2 produits, 1 dépôt, ventes en février et mars 2026 (mars = période
// courante du test), un avoir, une réception avec lot.
func seedFixture(t *testing.T, db *sql.DB) {
	t.Helper()
	var wh string
	if err := db.QueryRow(`SELECT id FROM warehouses LIMIT 1`).Scan(&wh); err != nil {
		t.Fatal(err)
	}
	now := "2026-03-15T10:00:00Z"
	exec := func(q string, args ...any) {
		if _, err := db.Exec(q, args...); err != nil {
			t.Fatalf("%s: %v", q[:40], err)
		}
	}
	exec(`INSERT INTO products (id,name,unit,vat_rate,purchase_price,price_retail,active,created_at,updated_at,brand)
	      VALUES ('P1','ARGAN SHAMPOOING','pièce',0,4000,5000,1,?,?,'Alpha')`, now, now)
	exec(`INSERT INTO products (id,name,unit,vat_rate,purchase_price,price_retail,active,created_at,updated_at,brand)
	      VALUES ('P2','GEL DOUCHE','pièce',1900,10000,15000,1,?,?,'')`, now, now)
	exec(`INSERT INTO partners (id,kind,name,active,created_at,updated_at) VALUES ('CLI1','customer','Client Fidèle',1,?,?)`, now, now)
	exec(`INSERT INTO partners (id,kind,name,active,created_at,updated_at) VALUES ('SUP','supplier','GROSSISTE',1,?,?)`, now, now)

	doc := func(id, typ, date string, ttc, _ int64, _ string) {
		exec(`INSERT INTO documents (id,doc_type,number,status,doc_date,partner_id,warehouse_id,payment_method,total_ht,total_ttc,posted_at,created_at,updated_at)
		      VALUES (?,?,?,'posted',?,?,?, 'cash', ?, ?, ?, ?, ?)`,
			id, typ, id, date, "CLI1", wh, ttc, ttc, date+"T09:30:00Z", date+"T09:30:00Z", date+"T09:30:00Z")
	}
	line := func(id, doc, prod string, qty, price, cost, ht int64) {
		exec(`INSERT INTO document_lines (id,document_id,position,product_id,description,qty_milli,unit_price,discount_pct,vat_rate,line_ht,line_vat,line_ttc,unit_cost,created_at)
		      VALUES (?,?,0,?,?,?,?,0,0,?,0,?,?,?)`, id, doc, prod, prod, qty, price, ht, ht, cost, now)
	}
	// mars (période courante) : 3 ventes ARGAN + 1 retour ; février : 2 ventes
	doc("S1", "SALE_TICKET", "2026-03-02", 10000, 8000, "Ali B")
	line("L1", "S1", "P1", 2000, 5000, 4000, 10000)
	doc("S2", "SALE_TICKET", "2026-03-02", 5000, 0, "Ali B")
	line("L2", "S2", "P1", 1000, 5000, 4000, 5000)
	doc("S3", "SALE_TICKET", "2026-03-10", 15000, 0, "Sara K")
	line("L3", "S3", "P2", 1000, 15000, 10000, 15000)
	doc("R1", "SALE_CREDIT_NOTE", "2026-03-11", 5000, 0, "Ali B")
	line("L4", "R1", "P1", 1000, 5000, 4000, 5000)
	doc("F1", "SALE_TICKET", "2026-02-03", 5000, 0, "Omar T")
	line("L5", "F1", "P1", 1000, 5000, 4000, 5000)
	doc("F2", "SALE_TICKET", "2026-02-20", 15000, 0, "Omar T")
	line("L6", "F2", "P2", 1000, 15000, 10000, 15000)
	// réception avec lot, stock
	exec(`INSERT INTO documents (id,doc_type,number,status,doc_date,partner_id,warehouse_id,total_ht,total_ttc,posted_at,created_at,updated_at)
	      VALUES ('B1','PURCHASE_RECEIPT','B1','posted','2026-02-01','SUP',?,40000,40000,'2026-02-01T08:00:00Z','2026-02-01T08:00:00Z','2026-02-01T08:00:00Z')`, wh)
	line("L7", "B1", "P1", 10000, 4000, 4000, 40000)
	exec(`INSERT INTO lots (id,product_id,lot_number,expiry_date,qty_milli,created_at) VALUES ('LOT1','P1','A1','2026-05-01',10000,?)`, now)
	exec(`INSERT INTO stock_ledger (id,product_id,warehouse_id,lot_id,qty_delta_milli,unit_cost,document_id,line_id,created_at)
	      VALUES ('SL1','P1',?, 'LOT1', 10000, 4000, 'B1','L7',?)`, wh, now)
	exec(`INSERT INTO stock_ledger (id,product_id,warehouse_id,qty_delta_milli,unit_cost,document_id,line_id,created_at)
	      VALUES ('SL2','P1',?, -3000, 4000, 'S1','L1',?)`, wh, now)
	exec(`INSERT INTO stock_levels (product_id,warehouse_id,qty_milli,avg_cost,updated_at) VALUES ('P1',?,7000,4000,?)`, wh, now)
	exec(`INSERT INTO stock_levels (product_id,warehouse_id,qty_milli,avg_cost,updated_at) VALUES ('P2',?,0,10000,?)`, wh, now)
	exec(`INSERT INTO partner_ledger (id,partner_id,amount,kind,document_id,created_at) VALUES ('PL1','CLI1',8000,'invoice','S1',?)`, now)
	_ = domain.NowISO()
}

var admin = Caller{UserID: "u", Role: "admin", Perms: map[string]bool{"reports": true, PermCost: true}}
var support = Caller{UserID: "s", Role: "support", Perms: map[string]bool{"reports": true}}

func run(t *testing.T, e *Engine, sp Spec, c Caller) *Result {
	t.Helper()
	res, err := e.Query(context.Background(), sp, c)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	return res
}

func cell(r *Result, row int, key string) any {
	for i, c := range r.Columns {
		if c.Key == key {
			return r.Rows[row][i]
		}
	}
	return nil
}

// ---- tests dorés : SQL exact --------------------------------------------------

func TestGoldenSQL(t *testing.T) {
	_, e := testDB(t)
	cp, err := e.compile(context.Background(), Spec{
		Source: "sale_lines", Dimensions: []string{"doc_date:month", "payment_method"},
		Measures: []Measure{{Name: "ca_ttc", As: "Revenu"}, {Field: "qty_milli", Agg: "sum"}},
		Filters:  []Filter{{Field: "brand", Op: "eq", Value: "Alpha"}},
		Having:   []Having{{Measure: "Revenu", Op: "gt", Value: 100}},
		Range:    Range{Type: "custom", From: "2026-03-01", To: "2026-03-31"},
		Sort:     []Sort{{Field: "Revenu", Dir: "desc"}}, Limit: 10,
	}, admin, nil)
	if err != nil {
		t.Fatal(err)
	}
	got, args := cp.SQL(true)
	want := "SELECT strftime('%Y-%m', doc_date) AS d0, payment_method AS d1, SUM(line_ttc) AS m0, SUM(qty_milli) AS m1 " +
		"FROM v_sale_lines WHERE doc_date BETWEEN ? AND ? AND brand = ? GROUP BY d0, d1 HAVING (SUM(line_ttc)) > ? ORDER BY m0 DESC LIMIT ?"
	if got != want {
		t.Fatalf("SQL doré différent :\n got: %s\nwant: %s", got, want)
	}
	if fmt.Sprint(args) != "[2026-03-01 2026-03-31 Alpha 100 11]" {
		t.Fatalf("args: %v", args)
	}
	// l'alias client n'apparaît jamais dans le SQL
	if strings.Contains(got, "Revenu") {
		t.Fatal("alias client dans le SQL")
	}
}

// ---- résultats dorés ----------------------------------------------------------------

func TestReturnsNetting(t *testing.T) {
	_, e := testDB(t)
	r := run(t, e, Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}, {Name: "sales_count"}, {Name: "returns_count"}, {Name: "avg_basket"}},
		Range: Range{Type: "this_month"}}, admin)
	// 10000 + 5000 + 15000 - 5000 (avoir) = 25000
	if toF(cell(r, 0, "m0")) != 25000 {
		t.Fatalf("ca_ttc net = %v", cell(r, 0, "m0"))
	}
	if toF(cell(r, 0, "m1")) != 3 {
		t.Fatalf("sales_count doit ignorer l'avoir : %v", cell(r, 0, "m1"))
	}
	if toF(cell(r, 0, "m2")) != 1 {
		t.Fatalf("returns_count = %v", cell(r, 0, "m2"))
	}
	if toF(cell(r, 0, "m3")) != 10000 {
		t.Fatalf("avg_basket = 30000/3 attendu, %v", cell(r, 0, "m3"))
	}
}

func TestZeroFillCardinality(t *testing.T) {
	_, e := testDB(t)
	r := run(t, e, Spec{Source: "sale_lines", Dimensions: []string{"doc_date:day"}, Measures: []Measure{{Name: "ca_ttc"}}, Range: Range{Type: "this_month"}}, admin)
	if len(r.Rows) != 31 {
		t.Fatalf("mars = 31 seaux, %d", len(r.Rows))
	}
	r = run(t, e, Spec{Source: "sale_lines", Dimensions: []string{"doc_date:dow"}, Measures: []Measure{{Name: "ca_ttc"}}, Range: Range{Type: "last_n_days", N: 3}}, admin)
	if len(r.Rows) != 7 {
		t.Fatalf("dow = 7 seaux, %d", len(r.Rows))
	}
	r = run(t, e, Spec{Source: "sale_lines", Dimensions: []string{"posted_at:hour"}, Measures: []Measure{{Name: "ca_ttc"}}, Range: Range{Type: "this_month"}}, admin)
	if len(r.Rows) != 24 {
		t.Fatalf("hour = 24 seaux, %d", len(r.Rows))
	}
	// cartésien date × catégorie
	r = run(t, e, Spec{Source: "sale_lines", Dimensions: []string{"doc_date:month", "doc_kind"}, Measures: []Measure{{Name: "ca_ttc"}}, Range: Range{Type: "last_n_months", N: 2}}, admin)
	if len(r.Rows) != 4 {
		t.Fatalf("2 mois × 2 doc_kind = 4, %d", len(r.Rows))
	}
	// une date non période (péremption) ne génère pas de domaine
	r = run(t, e, Spec{Source: "stock_snapshot", Dimensions: []string{"product_name", "nearest_expiry"}, Measures: []Measure{{Name: "references"}}, Range: Range{Type: "all"}}, admin)
	if len(r.Rows) != 2 {
		t.Fatalf("pas de remplissage sur une date attribut : %d lignes", len(r.Rows))
	}
}

func TestPreviousPeriodAlignment(t *testing.T) {
	_, e := testDB(t)
	// mars (31 j) vs février (28 j) : alignement par position, pas par date
	r := run(t, e, Spec{Source: "sale_lines", Dimensions: []string{"doc_date:day"}, Measures: []Measure{{Name: "ca_ttc"}},
		Range: Range{Type: "this_month"}, Compare: "previous_period"}, admin)
	if r.PrevRange == nil || r.PrevRange.From != "2026-01-29" || r.PrevRange.To != "2026-02-28" {
		t.Fatalf("période précédente = 31 j finissant le 28/02, %v", r.PrevRange)
	}
	// 2 mars (position 1) doit être aligné sur la position 1 de la période précédente (30 janv.) : 0
	if toF(cell(r, 1, "m0")) != 15000 || cell(r, 1, "m0_prev") == nil || toF(cell(r, 1, "m0_prev")) != 0 {
		t.Fatalf("alignement : cur=%v prev=%v", cell(r, 1, "m0"), cell(r, 1, "m0_prev"))
	}
	// total de la période précédente = 20000 (ventes de février)
	var prevTotal float64
	for i := range r.Rows {
		prevTotal += toF(cell(r, i, "m0_prev"))
	}
	if prevTotal != 20000 {
		t.Fatalf("total période précédente = %v", prevTotal)
	}
}

func TestUnitArithmetic(t *testing.T) {
	_, e := testDB(t)
	r := run(t, e, Spec{Source: "stock_snapshot", Dimensions: []string{"product_name"}, Measures: []Measure{{Name: "stock_value"}, {Name: "value_expiring"}},
		Filters: []Filter{{Field: "product_name", Op: "eq", Value: "ARGAN SHAMPOOING"}}, Range: Range{Type: "all"}, Params: map[string]int{"expiry_days": 90}}, admin)
	// 7 boîtes × 40,00 DA = 280,00 DA = 28000 centimes (pas 28 000 000)
	if toF(cell(r, 0, "m0")) != 28000 {
		t.Fatalf("stock_value en centimes = 28000, %v", cell(r, 0, "m0"))
	}
	// lot A1 : 10 boîtes reçues, périme le 01/05 (< 15/03 + 90 j) → 10 × 40 DA = 40000 c
	if toF(cell(r, 0, "m1")) != 40000 {
		t.Fatalf("value_expiring = %v", cell(r, 0, "m1"))
	}
}

func TestProductPerformanceTemplate(t *testing.T) {
	_, e := testDB(t)
	r := run(t, e, Spec{Source: "product_performance", Dimensions: []string{"product_name"},
		Measures: []Measure{{Name: "qty_sold"}, {Name: "qty_on_hand"}, {Name: "sell_through"}},
		Range: Range{Type: "this_month"}, Sort: []Sort{{Field: "d0", Dir: "asc"}}}, admin)
	if len(r.Rows) != 2 {
		t.Fatalf("2 produits, %d", len(r.Rows))
	}
	// ARGAN : vendu 3 (retour exclu par doc_kind='sale'), stock 7 → 3/(3+7) = 0.3
	if toF(cell(r, 0, "m0")) != 3000 || toF(cell(r, 0, "m1")) != 7000 {
		t.Fatalf("qty_sold=%v qty_on_hand=%v", cell(r, 0, "m0"), cell(r, 0, "m1"))
	}
	if st := toF(cell(r, 0, "m2")); st < 0.29 || st > 0.31 {
		t.Fatalf("sell_through = %v", st)
	}
}

// ---- droits ----------------------------------------------------------------------

func TestPermissions(t *testing.T) {
	_, e := testDB(t)
	// schéma : champs gardés absents
	for _, s := range VisibleSchema(support) {
		if s["key"] == "sale_lines" {
			for _, f := range s["fields"].([]Field) {
				if f.GatedBy != "" {
					t.Fatalf("champ gardé visible : %s", f.Key)
				}
			}
			for _, n := range s["named_measures"].([]NamedMeasure) {
				if n.GatedBy != "" {
					t.Fatalf("mesure gardée visible : %s", n.Key)
				}
			}
		}
	}
	// mesure gardée dans la liste : retirée, signalée
	r := run(t, e, Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}, {Name: "margin"}}, Range: Range{Type: "this_month"}}, support)
	if len(r.Columns) != 1 || len(r.Dropped) != 1 {
		t.Fatalf("la marge doit être retirée et signalée : cols=%d dropped=%v", len(r.Columns), r.Dropped)
	}
	// HAVING sur une mesure gardée : refus, pas d'omission silencieuse
	_, err := e.Query(context.Background(), Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}},
		Having: []Having{{Measure: "margin_pct", Op: "lt", Value: 0}}, Range: Range{Type: "this_month"}}, support)
	var ae *Error
	if err == nil || !asErr(err, &ae) || ae.Code != "forbidden" {
		t.Fatalf("HAVING gardé doit être refusé : %v", err)
	}
	// mesure gardée par view_cost : retirée pour le support, pas refusée
	r = run(t, e, Spec{Source: "sale_lines", Measures: []Measure{{Name: "margin"}, {Name: "ca_ttc"}}, Range: Range{Type: "this_month"}}, support)
	if len(r.Columns) != 1 {
		t.Fatal("margin doit être retirée pour le support")
	}
	// cache : deux rôles ne partagent jamais une entrée
	ra := run(t, e, Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}, {Name: "margin"}}, Range: Range{Type: "this_month"}}, admin)
	rs := run(t, e, Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}, {Name: "margin"}}, Range: Range{Type: "this_month"}}, support)
	if len(ra.Columns) == len(rs.Columns) {
		t.Fatal("le cache a servi le résultat admin au support")
	}
}

func asErr(err error, target **Error) bool {
	e, ok := err.(*Error)
	if ok {
		*target = e
	}
	return ok
}

// ---- propriété : toute spec valide aléatoire s'exécute --------------------------

func TestPropertyRandomSpecs(t *testing.T) {
	_, e := testDB(t)
	rnd := rand.New(rand.NewSource(7))
	ranges := []string{"today", "this_week", "this_month", "previous_month", "this_quarter", "this_year", "year_to_date", "last_n_days", "last_n_months", "all"}
	for i := 0; i < 400; i++ {
		src := Sources()[rnd.Intn(len(Sources()))]
		var dims []string
		var filters []Filter
		for _, f := range src.Fields {
			if f.Dimension && rnd.Intn(6) == 0 && len(dims) < 3 {
				d := f.Key
				if (f.Type == "date" || f.Type == "datetime") && rnd.Intn(2) == 0 {
					d += ":" + f.Buckets[rnd.Intn(len(f.Buckets))]
				}
				dims = append(dims, d)
			}
			if f.Filterable && rnd.Intn(8) == 0 {
				var fl Filter
				switch f.Type {
				case "number":
					fl = Filter{Field: f.Key, Op: "gte", Value: float64(rnd.Intn(1000))}
				case "bool":
					fl = Filter{Field: f.Key, Op: "eq", Value: rnd.Intn(2) == 0}
				case "date", "datetime":
					fl = Filter{Field: f.Key, Op: "gte", Value: "2026-01-01"}
				case "enum":
					if len(f.EnumValues) > 0 {
						fl = Filter{Field: f.Key, Op: "in", Value: []any{f.EnumValues[rnd.Intn(len(f.EnumValues))]}}
					} else {
						fl = Filter{Field: f.Key, Op: "is_not_null"}
					}
				default:
					fl = Filter{Field: f.Key, Op: "contains", Value: "a%b_c"}
				}
				filters = append(filters, fl)
			}
		}
		var meas []Measure
		for _, n := range src.Named {
			if rnd.Intn(4) == 0 {
				meas = append(meas, Measure{Name: n.Key, Share: rnd.Intn(3) == 0, Cumulative: rnd.Intn(3) == 0})
			}
		}
		for _, f := range src.Fields {
			if f.Measure && rnd.Intn(6) == 0 {
				meas = append(meas, Measure{Field: f.Key, Agg: f.Aggs[rnd.Intn(len(f.Aggs))], As: fmt.Sprintf("Alias %d", i)})
			}
		}
		if len(meas) == 0 {
			meas = append(meas, Measure{Name: src.Named[0].Key})
		}
		if len(meas) > 12 {
			meas = meas[:12]
		}
		sp := Spec{Source: src.Key, Dimensions: dims, Measures: meas, Filters: filters, Range: Range{Type: ranges[rnd.Intn(len(ranges))], N: 1 + rnd.Intn(60)}, Limit: 50}
		if len(dims) > 0 && rnd.Intn(3) == 0 && sp.Range.Type != "all" {
			sp.Compare = "previous_period"
		}
		if _, err := e.Query(context.Background(), sp, admin); err != nil {
			var ae *Error
			if asErr(err, &ae) {
				continue // refus métier (ex. comparaison sans borne) : acceptable
			}
			t.Fatalf("spec aléatoire #%d a échoué en SQL : %v\n%+v", i, err, sp)
		}
	}
}

// ---- injection : les chaînes client n'atteignent jamais le SQL ------------------

func TestInjectionNeverReachesSQL(t *testing.T) {
	_, e := testDB(t)
	payloads := []string{`'; DROP TABLE products; --`, `" OR 1=1 --`, `%`, `_`, `\`, `x' UNION SELECT password_hash FROM users --`, `); DELETE FROM documents; --`}
	for _, p := range payloads {
		// valeur de filtre texte
		cp, err := e.compile(context.Background(), Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}},
			Filters: []Filter{{Field: "product_name", Op: "contains", Value: p}}, Range: Range{Type: "all"}}, admin, nil)
		if err != nil {
			t.Fatal(err)
		}
		q, args := cp.SQL(true)
		if strings.Contains(q, "DROP") || strings.Contains(q, "UNION") || strings.Contains(q, "DELETE") || (len(p) > 2 && strings.Contains(q, p)) {
			t.Fatalf("charge utile dans le SQL : %s", q)
		}
		if len(args) == 0 {
			t.Fatal("la valeur doit être un paramètre lié")
		}
		if _, err := e.Query(context.Background(), Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}},
			Filters: []Filter{{Field: "product_name", Op: "contains", Value: p}}, Range: Range{Type: "all"}}, admin); err != nil {
			t.Fatalf("exécution avec charge utile : %v", err)
		}
		// alias, tri, having, noms de source combo : refusés ou jamais dans le SQL
		if _, err := e.Query(context.Background(), Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc", As: p}}, Range: Range{Type: "all"}}, admin); err == nil {
			t.Fatalf("alias %q accepté", p)
		}
		if _, err := e.Query(context.Background(), Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}}, Sort: []Sort{{Field: p}}, Range: Range{Type: "all"}}, admin); err == nil {
			t.Fatalf("tri %q accepté", p)
		}
		if _, err := e.Query(context.Background(), Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}}, Having: []Having{{Measure: p, Op: "gt"}}, Range: Range{Type: "all"}}, admin); err == nil {
			t.Fatalf("having %q accepté", p)
		}
		if _, err := e.Query(context.Background(), Spec{Source: p, Measures: []Measure{{Name: "ca_ttc"}}}, admin); err == nil {
			t.Fatalf("source %q acceptée", p)
		}
		if _, err := e.Query(context.Background(), Spec{Source: "sale_lines", Dimensions: []string{p}, Measures: []Measure{{Name: "ca_ttc"}}}, admin); err == nil {
			t.Fatalf("dimension %q acceptée", p)
		}
		_, err = e.Combo(context.Background(), Request{Combo: true, Spec: Spec{Range: Range{Type: "this_month"}},
			Sources: []ComboSource{{Name: p, Source: "sale_lines", Measures: []Measure{{Name: "qty"}}}, {Name: "b", Source: "purchase_lines", Measures: []Measure{{Name: "qty"}}}},
			JoinOn: []string{"product_id"}}, admin)
		if err == nil {
			t.Fatalf("nom de source combo %q accepté", p)
		}
		_, err = e.Combo(context.Background(), Request{Combo: true, Spec: Spec{Range: Range{Type: "this_month"}},
			Sources: []ComboSource{{Name: "a", Source: "sale_lines", Measures: []Measure{{Name: "qty"}}}, {Name: "b", Source: "purchase_lines", Measures: []Measure{{Name: "qty"}}}},
			JoinOn: []string{"product_id"}, CombinedMeasures: []CombinedMeasure{{As: "x", Expr: p}}}, admin)
		if err == nil {
			t.Fatalf("expression combinée %q acceptée", p)
		}
	}
	// LIKE : % et _ tapés par l'utilisateur sont littéraux
	r := run(t, e, Spec{Source: "sale_lines", Measures: []Measure{{Name: "lines_count"}},
		Filters: []Filter{{Field: "product_name", Op: "contains", Value: "%"}}, Range: Range{Type: "all"}}, admin)
	if toF(cell(r, 0, "m0")) != 0 {
		t.Fatalf("'%%' doit être littéral, %v lignes", cell(r, 0, "m0"))
	}
}

// ---- combo ---------------------------------------------------------------------------

func TestComboSellThrough(t *testing.T) {
	_, e := testDB(t)
	r, err := e.Combo(context.Background(), Request{Combo: true, Spec: Spec{Range: Range{Type: "custom", From: "2026-02-01", To: "2026-03-31"}},
		Sources: []ComboSource{
			{Name: "ventes", Source: "sale_lines", Measures: []Measure{{Name: "qty", As: "vendu"}}, Filters: []Filter{{Field: "doc_kind", Op: "eq", Value: "sale"}}},
			{Name: "achats", Source: "purchase_lines", Measures: []Measure{{Name: "qty", As: "achete"}}},
		},
		JoinOn:           []string{"product_name"},
		CombinedMeasures: []CombinedMeasure{{As: "ecoulement", Expr: "ventes.vendu / nullif(achats.achete, 0)", Format: "percent"}},
	}, admin)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Rows) != 2 {
		t.Fatalf("union des clés : 2 produits attendus, %d", len(r.Rows))
	}
	for _, row := range r.Rows {
		if row[0] == "ARGAN SHAMPOOING" {
			// vendu 4 (fév 1 + mars 3), acheté 10 → 0.4
			if v := toF(row[len(row)-1]); v < 0.39 || v > 0.41 {
				t.Fatalf("écoulement ARGAN = %v", v)
			}
		}
		if row[0] == "GEL DOUCHE" && row[len(row)-1] != nil {
			t.Fatalf("division par zéro doit donner NULL, %v", row[len(row)-1])
		}
	}
}

func TestBatchIsolatesErrors(t *testing.T) {
	_, e := testDB(t)
	out := e.Batch(context.Background(), BatchRequest{Queries: []BatchItem{
		{ID: "ok", Request: Request{Spec: Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}}, Range: Range{Type: "this_month"}}}},
		{ID: "ko", Request: Request{Spec: Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}}, Having: []Having{{Measure: "margin_pct", Op: "lt", Value: 0}}, Range: Range{Type: "this_month"}}}},
	}, GlobalRange: &Range{Type: "previous_month"}}, support)
	if !out[0].OK || out[1].OK || out[1].Error["code"] != "forbidden" {
		t.Fatalf("batch : %+v", out)
	}
	if out[0].Result.Range.From != "2026-02-01" {
		t.Fatalf("la période globale doit remplacer celle de la tuile : %v", out[0].Result.Range)
	}
}

func TestRelativeRanges(t *testing.T) {
	now := time.Date(2026, 3, 15, 12, 0, 0, 0, time.Local)
	cases := map[string][2]string{
		"today": {"2026-03-15", "2026-03-15"}, "yesterday": {"2026-03-14", "2026-03-14"},
		"this_week": {"2026-03-15", "2026-03-21"}, // 15/03/2026 est un dimanche, semaine débutant le dimanche
		"this_month": {"2026-03-01", "2026-03-31"}, "previous_month": {"2026-02-01", "2026-02-28"},
		"this_quarter": {"2026-01-01", "2026-03-31"}, "previous_quarter": {"2025-10-01", "2025-12-31"},
		"year_to_date": {"2026-01-01", "2026-03-15"},
	}
	for k, want := range cases {
		rs, err := Range{Type: k}.Resolve(now, 0)
		if err != nil || rs.From != want[0] || rs.To != want[1] {
			t.Fatalf("%s : %v %v", k, rs, err)
		}
	}
	rs, _ := Range{Type: "last_n_days", N: 45}.Resolve(now, 0)
	if rs.From != "2026-01-30" {
		t.Fatalf("last_45_days from %s", rs.From)
	}
	// semaine débutant le samedi (6) : le dimanche 15/03 appartient à la semaine du samedi 14/03
	rs, _ = Range{Type: "this_week"}.Resolve(now, 6)
	if rs.From != "2026-03-14" {
		t.Fatalf("this_week (samedi) from %s", rs.From)
	}
	// domaine dow tourné selon le début de semaine
	dom := bucketDomain("dow", Resolved{}, 6, time.Local)
	if dom[0] != int64(6) || dom[1] != int64(0) {
		t.Fatalf("dow doit commencer au jour configuré : %v", dom)
	}
}

func TestEvaluator(t *testing.T) {
	n, _, err := parseExpr("a.x / nullif(b.y, 0) * 100 + (2 - 1)")
	if err != nil {
		t.Fatal(err)
	}
	x, y := 3.0, 4.0
	v, err := n.eval(map[string]*float64{"a.x": &x, "b.y": &y})
	if err != nil || v == nil || *v != 76 {
		t.Fatalf("eval = %v %v", v, err)
	}
	z := 0.0
	v, _ = n.eval(map[string]*float64{"a.x": &x, "b.y": &z})
	if v != nil {
		t.Fatal("nullif(0,0) doit donner NULL")
	}
	for _, bad := range []string{"a.x ; drop", "select 1", "a.x + ", "sum(a.x)", "a.x --"} {
		if _, _, err := parseExpr(bad); err == nil {
			t.Fatalf("expression %q acceptée", bad)
		}
	}
}
