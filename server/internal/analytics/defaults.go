package analytics

import (
	"database/sql"
	"encoding/json"
	"time"

	"elixir/server/internal/domain"
)

// defaultReport : vue livrée avec le logiciel (is_default=1, partagée).
type defaultReport struct {
	Name     string
	Chart    string
	Encoding map[string]any
	Spec     Request
	W, H     int
}

var defaultReports = []defaultReport{
	// ---- rangée de chiffres (l'ancien bandeau du tableau de bord)
	{Name: "Ventes aujourd'hui", Chart: "stat", W: 2, H: 2,
		Spec: Request{Spec: Spec{Source: "sale_lines", Measures: []Measure{{Name: "ca_ttc"}}, Range: Range{Type: "today"}, Compare: "previous_period"}}},
	{Name: "Tickets aujourd'hui", Chart: "stat", W: 2, H: 2,
		Spec: Request{Spec: Spec{Source: "sale_lines", Measures: []Measure{{Name: "sales_count"}}, Range: Range{Type: "today"}, Compare: "previous_period"}}},
	{Name: "Marge aujourd'hui", Chart: "stat", W: 2, H: 2,
		Spec: Request{Spec: Spec{Source: "sale_lines", Measures: []Measure{{Name: "margin"}}, Range: Range{Type: "today"}, Compare: "previous_period"}}},
	{Name: "Créances clients", Chart: "stat", W: 2, H: 2,
		Spec: Request{Spec: Spec{Source: "partner_ledger", Measures: []Measure{{Name: "balance"}},
			Filters: []Filter{{Field: "partner_kind", Op: "ne", Value: "supplier"}}, Range: Range{Type: "all"}}}},
	{Name: "Valeur du stock", Chart: "stat", W: 2, H: 2,
		Spec: Request{Spec: Spec{Source: "stock_snapshot", Measures: []Measure{{Name: "stock_value"}}, Range: Range{Type: "all"}}}},
	{Name: "Alertes stock faible", Chart: "stat", W: 2, H: 2,
		Spec: Request{Spec: Spec{Source: "stock_snapshot", Measures: []Measure{{Name: "below_min_count"}, {Name: "out_count"}}, Range: Range{Type: "all"}}}},
	// ---- graphiques principaux
	{Name: "Chiffre d'affaires par jour", Chart: "line", W: 8, H: 4,
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"doc_date:day"},
			Measures: []Measure{{Name: "ca_ttc"}}, Range: Range{Type: "this_month"}, Compare: "previous_period"}}},
	{Name: "Répartition du stock", Chart: "donut", W: 4, H: 4,
		Spec: Request{Spec: Spec{Source: "stock_snapshot", Dimensions: []string{"category_name"},
			Measures: []Measure{{Name: "stock_value"}}, Range: Range{Type: "all"}, Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 8}}},
	{Name: "Ventes — 6 derniers mois", Chart: "bar", W: 6, H: 4,
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"doc_date:month"},
			Measures: []Measure{{Name: "ca_ttc"}, {Name: "margin"}}, Range: Range{Type: "last_n_months", N: 6}}}},
	{Name: "Crédits clients", Chart: "table", W: 6, H: 4,
		Spec: Request{Spec: Spec{Source: "partner_ledger", Dimensions: []string{"partner_name"},
			Measures: []Measure{{Name: "balance"}}, Filters: []Filter{{Field: "partner_kind", Op: "in", Value: []any{"customer", "both"}}},
			Having: []Having{{Measure: "m0", Op: "gt", Value: 0}}, Range: Range{Type: "all"}, Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 20}}},
	{Name: "Produits sous le stock minimum", Chart: "table", W: 6, H: 4,
		Spec: Request{Spec: Spec{Source: "stock_snapshot", Dimensions: []string{"product_name"},
			Measures: []Measure{{Name: "qty"}, {Field: "min_stock_milli", Agg: "sum"}}, Filters: []Filter{{Field: "below_min", Op: "eq", Value: true}},
			Range: Range{Type: "all"}, Sort: []Sort{{Field: "m0", Dir: "asc"}}, Limit: 50}}},
	{Name: "Mouvements de stock récents", Chart: "table", W: 6, H: 4,
		Spec: Request{Spec: Spec{Source: "stock_movements", Dimensions: []string{"movement_date:day", "product_name", "doc_type"},
			Measures: []Measure{{Name: "net_qty"}}, Range: Range{Type: "last_n_days", N: 7}, Sort: []Sort{{Field: "d0", Dir: "desc"}}, Limit: 30,
			ZeroFill: boolPtr(false)}}},
	// ---- analyses du magasin
	{Name: "Ventes par catégorie", Chart: "bar", W: 6, H: 4,
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"category_name"},
			Measures: []Measure{{Name: "ca_ttc"}, {Name: "margin_pct"}}, Range: Range{Type: "this_month"},
			Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 12}}},
	{Name: "Top marques", Chart: "bar", W: 6, H: 4,
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"brand"},
			Measures: []Measure{{Name: "qty"}, {Name: "ca_ttc"}}, Filters: []Filter{{Field: "brand", Op: "is_not_null"}},
			Range: Range{Type: "this_month"}, Sort: []Sort{{Field: "m1", Dir: "desc"}}, Limit: 12}}},
	{Name: "Activité par heure", Chart: "bar", W: 6, H: 4,
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"posted_at:hour"},
			Measures: []Measure{{Name: "sales_count"}}, Range: Range{Type: "last_n_days", N: 30}}}},
	{Name: "Activité par jour de semaine", Chart: "bar", W: 6, H: 4,
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"doc_date:dow"},
			Measures: []Measure{{Name: "ca_ttc"}, {Name: "sales_count"}}, Range: Range{Type: "last_n_days", N: 90}}}},
	{Name: "Péremptions sous 90 jours", Chart: "table", W: 6, H: 5,
		Spec: Request{Spec: Spec{Source: "stock_snapshot", Dimensions: []string{"product_name", "nearest_expiry"},
			Measures: []Measure{{Field: "qty_expiring", Agg: "sum"}, {Name: "value_expiring"}}, Filters: []Filter{{Field: "is_expiring", Op: "eq", Value: true}},
			Range: Range{Type: "all"}, Sort: []Sort{{Field: "d1", Dir: "asc"}}, Limit: 200, Params: map[string]int{"expiry_days": 90}}}},
	{Name: "Stock dormant (jamais vendu sur 90 j)", Chart: "table", W: 6, H: 5,
		Spec: Request{Spec: Spec{Source: "product_performance", Dimensions: []string{"product_name", "days_since_last_sale"},
			Measures: []Measure{{Name: "qty_on_hand"}, {Name: "stock_value"}}, Filters: []Filter{{Field: "never_sold", Op: "eq", Value: true}, {Field: "has_stock", Op: "eq", Value: true}},
			Range: Range{Type: "last_n_days", N: 90}, Sort: []Sort{{Field: "m1", Dir: "desc"}}, Limit: 100}}},
	{Name: "Top produits — CA et marge", Chart: "table", W: 6, H: 5,
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"product_name"},
			Measures: []Measure{{Name: "qty"}, {Name: "ca_ttc"}, {Name: "margin"}},
			Range: Range{Type: "this_month"}, Sort: []Sort{{Field: "m1", Dir: "desc"}}, Limit: 30}}},
	{Name: "Achats par fournisseur", Chart: "donut", W: 6, H: 4,
		Spec: Request{Spec: Spec{Source: "purchase_lines", Dimensions: []string{"supplier_name"},
			Measures: []Measure{{Name: "total_ht"}}, Range: Range{Type: "last_n_months", N: 3}, Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 8}}},
	{Name: "Écoulement par catégorie (ventes vs achats)", Chart: "bar", W: 12, H: 4,
		Spec: Request{Combo: true, Spec: Spec{Range: Range{Type: "this_quarter"}, Limit: 20},
			Sources: []ComboSource{
				{Name: "ventes", Source: "sale_lines", Measures: []Measure{{Name: "qty", As: "qty_vendue"}}, Filters: []Filter{{Field: "doc_kind", Op: "eq", Value: "sale"}}},
				{Name: "achats", Source: "purchase_lines", Measures: []Measure{{Name: "qty", As: "qty_achetee"}}},
			},
			JoinOn:           []string{"category_name"},
			CombinedMeasures: []CombinedMeasure{{As: "ecoulement", Expr: "ventes.qty_vendue / nullif(achats.qty_achetee, 0)", Format: "percent"}}}},
}

func boolPtr(b bool) *bool { return &b }

// EnsureDefaults crée les vues et le tableau de bord par défaut s'ils
// n'existent pas encore. Idempotent ; ne touche jamais les vues des
// utilisateurs.
func EnsureDefaults(db *sql.DB) error {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM saved_reports WHERE is_default = 1`).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	now := time.Now().UTC().Format(time.RFC3339)
	type tile struct {
		ReportID string `json:"report_id"`
		X, Y     int
		W, H     int
	}
	var layout []map[string]any
	x, y, rowH := 0, 0, 0
	for _, d := range defaultReports {
		id := domain.NewID()
		specJS, _ := json.Marshal(d.Spec)
		enc := d.Encoding
		if enc == nil {
			enc = map[string]any{}
		}
		encJS, _ := json.Marshal(enc)
		if _, err := db.Exec(`INSERT INTO saved_reports (id, name, spec_json, spec_version, chart_type, encoding_json, owner_id, is_shared, is_default, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, NULL, 1, 1, ?, ?)`, id, d.Name, string(specJS), SchemaVersion, d.Chart, string(encJS), now, now); err != nil {
			return err
		}
		if x+d.W > 12 {
			x = 0
			y += rowH
			rowH = 0
		}
		layout = append(layout, map[string]any{"report_id": id, "x": x, "y": y, "w": d.W, "h": d.H})
		x += d.W
		if d.H > rowH {
			rowH = d.H
		}
	}
	layoutJS, _ := json.Marshal(layout)
	_, err := db.Exec(`INSERT INTO dashboards (id, name, owner_id, is_shared, is_default, layout_json, global_range_json, created_at, updated_at)
		VALUES (?, 'Tableau de bord du magasin', NULL, 1, 1, ?, '{"type":"this_month"}', ?, ?)`,
		domain.NewID(), string(layoutJS), now, now)
	return err
}
