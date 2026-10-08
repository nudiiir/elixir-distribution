package analytics

import (
	"sort"
	"strings"
)

// GalleryItem : une question prête à l'emploi, avec sa spécification. Sert
// à la fois de galerie dans l'explorateur et de repli hors ligne pour
// l'assistant (appariement par mots-clés quand le cloud est injoignable).
type GalleryItem struct {
	Theme     string   `json:"theme"`
	Title     string   `json:"title"`
	Keywords  []string `json:"keywords"`
	ChartType string   `json:"chart_type"`
	Spec      Request  `json:"spec"`
}

var gallery = []GalleryItem{
	// ---------------------------------------------------------------- Ventes
	{Theme: "Ventes", Title: "Chiffre d'affaires par jour ce mois", Keywords: []string{"ca", "chiffre", "affaires", "jour", "mois", "ventes", "evolution"}, ChartType: "line",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"doc_date:day"}, Measures: []Measure{{Name: "ca_ttc"}}, Range: Range{Type: "this_month"}, Compare: "previous_period"}}},
	{Theme: "Ventes", Title: "Ventes des 6 derniers mois", Keywords: []string{"ventes", "mois", "six", "6", "tendance", "annee"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"doc_date:month"}, Measures: []Measure{{Name: "ca_ttc"}, {Name: "sales_count"}}, Range: Range{Type: "last_n_months", N: 6}}}},
	{Theme: "Ventes", Title: "Ventes par catégorie", Keywords: []string{"categorie", "categories", "rayon", "famille", "ventes", "ca"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"category_name"}, Measures: []Measure{{Name: "ca_ttc"}, {Name: "margin_pct"}}, Range: Range{Type: "this_month"}, Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 12}}},
	{Theme: "Ventes", Title: "Top 15 produits vendus", Keywords: []string{"top", "meilleurs", "plus", "vendus", "produits", "classement", "best"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"product_name"}, Measures: []Measure{{Name: "qty"}, {Name: "ca_ttc"}}, Range: Range{Type: "this_month"}, Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 15}}},
	{Theme: "Ventes", Title: "Top marques", Keywords: []string{"marque", "marques", "brand", "top"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"brand"}, Measures: []Measure{{Name: "qty"}, {Name: "ca_ttc"}}, Filters: []Filter{{Field: "brand", Op: "is_not_null"}}, Range: Range{Type: "this_month"}, Sort: []Sort{{Field: "m1", Dir: "desc"}}, Limit: 15}}},
	{Theme: "Ventes", Title: "Panier moyen et nombre de ventes", Keywords: []string{"panier", "moyen", "ticket", "moyenne", "nombre", "ventes"}, ChartType: "stat",
		Spec: Request{Spec: Spec{Source: "sale_lines", Measures: []Measure{{Name: "sales_count"}, {Name: "avg_basket"}, {Name: "ca_ttc"}}, Range: Range{Type: "this_month"}, Compare: "previous_period"}}},
	{Theme: "Ventes", Title: "Activité par heure de la journée", Keywords: []string{"heure", "heures", "horaire", "journee", "affluence", "ouverture"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"posted_at:hour"}, Measures: []Measure{{Name: "sales_count"}}, Range: Range{Type: "last_n_days", N: 30}}}},
	{Theme: "Ventes", Title: "Activité par jour de la semaine", Keywords: []string{"semaine", "jour", "lundi", "vendredi", "samedi", "dimanche", "hebdo"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"doc_date:dow"}, Measures: []Measure{{Name: "ca_ttc"}, {Name: "sales_count"}}, Range: Range{Type: "last_n_days", N: 90}}}},
	{Theme: "Ventes", Title: "Répartition par catégorie", Keywords: []string{"categorie", "categories", "rayon", "rayons", "repartition", "part"}, ChartType: "donut",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"category_name"}, Measures: []Measure{{Name: "ca_ttc"}}, Range: Range{Type: "this_month"}}}},
	{Theme: "Ventes", Title: "Ventes par vendeur", Keywords: []string{"vendeur", "vendeurs", "caissier", "employe", "equipe", "personnel"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"cashier_name"}, Measures: []Measure{{Name: "ca_ttc"}, {Name: "sales_count"}}, Range: Range{Type: "this_month"}, Sort: []Sort{{Field: "m0", Dir: "desc"}}}}},
	{Theme: "Ventes", Title: "Marge par catégorie", Keywords: []string{"marge", "marges", "categorie", "categories", "rayon", "rentabilite", "benefice"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"category_name"}, Measures: []Measure{{Name: "margin"}, {Name: "margin_pct"}, {Name: "ca_ht"}}, Range: Range{Type: "last_n_months", N: 3}, Sort: []Sort{{Field: "m0", Dir: "desc"}}}}},
	{Theme: "Ventes", Title: "Produits les plus rentables", Keywords: []string{"rentable", "rentables", "marge", "benefice", "gagne", "produit", "produits"}, ChartType: "table",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"product_name"}, Measures: []Measure{{Name: "margin"}, {Name: "margin_pct"}, {Name: "qty"}}, Range: Range{Type: "last_n_months", N: 3}, Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 20}}},
	{Theme: "Ventes", Title: "Meilleurs clients", Keywords: []string{"client", "clients", "meilleur", "meilleurs", "fidele", "fideles", "achete", "achetent"}, ChartType: "table",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"partner_name"}, Measures: []Measure{{Name: "ca_ttc"}, {Name: "sales_count"}}, Filters: []Filter{{Field: "partner_name", Op: "is_not_null"}}, Range: Range{Type: "last_n_months", N: 6}, Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 20}}},
	{Theme: "Ventes", Title: "Ventes par mode de paiement", Keywords: []string{"paiement", "espece", "especes", "carte", "cib", "edahabia", "cheque", "credit", "mode"}, ChartType: "donut",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"payment_method"}, Measures: []Measure{{Name: "ca_ttc"}}, Range: Range{Type: "this_month"}}}},
	{Theme: "Ventes", Title: "Marge par marque", Keywords: []string{"marge", "marque", "marques", "rentable"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"brand"}, Measures: []Measure{{Name: "margin"}, {Name: "margin_pct"}}, Filters: []Filter{{Field: "brand", Op: "is_not_null"}}, Range: Range{Type: "this_quarter"}, Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 15}}},
	{Theme: "Ventes", Title: "Retours et avoirs", Keywords: []string{"retour", "retours", "avoir", "avoirs", "rembourse"}, ChartType: "table",
		Spec: Request{Spec: Spec{Source: "sale_lines", Dimensions: []string{"doc_date:day", "product_name"}, Measures: []Measure{{Name: "qty"}, {Name: "ca_ttc"}}, Filters: []Filter{{Field: "doc_kind", Op: "eq", Value: "return"}}, Range: Range{Type: "last_n_days", N: 30}, Sort: []Sort{{Field: "d0", Dir: "desc"}}, ZeroFill: boolPtr(false)}}},
	// ---------------------------------------------------------------- Stock
	{Theme: "Stock", Title: "Produits périmant sous 90 jours", Keywords: []string{"perime", "peremption", "expire", "expiration", "dlc", "90", "jours"}, ChartType: "table",
		Spec: Request{Spec: Spec{Source: "stock_snapshot", Dimensions: []string{"product_name", "nearest_expiry"}, Measures: []Measure{{Field: "qty_expiring", Agg: "sum"}, {Name: "value_expiring"}}, Filters: []Filter{{Field: "is_expiring", Op: "eq", Value: true}}, Range: Range{Type: "all"}, Sort: []Sort{{Field: "d1", Dir: "asc"}}, Limit: 200, Params: map[string]int{"expiry_days": 90}}}},
	{Theme: "Stock", Title: "Produits déjà périmés en stock", Keywords: []string{"perimes", "perime", "expires", "depasse"}, ChartType: "table",
		Spec: Request{Spec: Spec{Source: "stock_snapshot", Dimensions: []string{"product_name", "nearest_expiry"}, Measures: []Measure{{Name: "qty"}, {Name: "value_expired"}}, Filters: []Filter{{Field: "is_expired", Op: "eq", Value: true}}, Range: Range{Type: "all"}, Sort: []Sort{{Field: "m1", Dir: "desc"}}, Limit: 200}}},
	{Theme: "Stock", Title: "Valeur du stock par catégorie", Keywords: []string{"valeur", "stock", "categorie", "repartition", "inventaire"}, ChartType: "donut",
		Spec: Request{Spec: Spec{Source: "stock_snapshot", Dimensions: []string{"category_name"}, Measures: []Measure{{Name: "stock_value"}}, Range: Range{Type: "all"}, Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 8}}},
	{Theme: "Stock", Title: "Produits sous le stock minimum", Keywords: []string{"minimum", "rupture", "alerte", "reapprovisionner", "manque", "faible"}, ChartType: "table",
		Spec: Request{Spec: Spec{Source: "stock_snapshot", Dimensions: []string{"product_name"}, Measures: []Measure{{Name: "qty"}, {Field: "min_stock_milli", Agg: "sum"}}, Filters: []Filter{{Field: "below_min", Op: "eq", Value: true}}, Range: Range{Type: "all"}, Sort: []Sort{{Field: "m0", Dir: "asc"}}, Limit: 100}}},
	{Theme: "Stock", Title: "Stock dormant (jamais vendu sur 90 jours)", Keywords: []string{"dormant", "mort", "invendu", "jamais", "vendu", "bouge", "pas"}, ChartType: "table",
		Spec: Request{Spec: Spec{Source: "product_performance", Dimensions: []string{"product_name", "days_since_last_sale"}, Measures: []Measure{{Name: "qty_on_hand"}, {Name: "stock_value"}}, Filters: []Filter{{Field: "never_sold", Op: "eq", Value: true}, {Field: "has_stock", Op: "eq", Value: true}}, Range: Range{Type: "last_n_days", N: 90}, Sort: []Sort{{Field: "m1", Dir: "desc"}}, Limit: 100}}},
	{Theme: "Stock", Title: "Rotation : jours de stock restants", Keywords: []string{"rotation", "jours", "restants", "couverture", "ecoulement", "autonomie"}, ChartType: "table",
		Spec: Request{Spec: Spec{Source: "product_performance", Dimensions: []string{"product_name"}, Measures: []Measure{{Name: "qty_sold"}, {Name: "qty_on_hand"}, {Field: "days_of_stock", Agg: "avg"}}, Filters: []Filter{{Field: "has_stock", Op: "eq", Value: true}}, Range: Range{Type: "last_n_days", N: 90}, Sort: []Sort{{Field: "m2", Dir: "asc"}}, Limit: 50}}},
	{Theme: "Stock", Title: "Entrées et sorties de stock par semaine", Keywords: []string{"mouvements", "entrees", "sorties", "semaine", "flux"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "stock_movements", Dimensions: []string{"movement_date:week"}, Measures: []Measure{{Name: "qty_in"}, {Name: "qty_out"}}, Range: Range{Type: "last_n_months", N: 3}}}},
	// ---------------------------------------------------------------- Achats
	{Theme: "Achats", Title: "Achats par fournisseur", Keywords: []string{"fournisseur", "fournisseurs", "grossiste", "achats", "repartition"}, ChartType: "donut",
		Spec: Request{Spec: Spec{Source: "purchase_lines", Dimensions: []string{"supplier_name"}, Measures: []Measure{{Name: "total_ht"}}, Range: Range{Type: "last_n_months", N: 3}, Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 8}}},
	{Theme: "Achats", Title: "Achats par mois", Keywords: []string{"achats", "mois", "evolution", "depenses"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "purchase_lines", Dimensions: []string{"doc_date:month"}, Measures: []Measure{{Name: "total_ht"}, {Name: "receipts_count"}}, Range: Range{Type: "last_n_months", N: 6}}}},
	{Theme: "Achats", Title: "Écoulement par catégorie (ventes vs achats)", Keywords: []string{"ecoulement", "ventes", "achats", "compare", "comparaison", "categorie"}, ChartType: "bar",
		Spec: Request{Combo: true, Spec: Spec{Range: Range{Type: "this_quarter"}, Limit: 20},
			Sources: []ComboSource{
				{Name: "ventes", Source: "sale_lines", Measures: []Measure{{Name: "qty", As: "qty_vendue"}}, Filters: []Filter{{Field: "doc_kind", Op: "eq", Value: "sale"}}},
				{Name: "achats", Source: "purchase_lines", Measures: []Measure{{Name: "qty", As: "qty_achetee"}}},
			},
			JoinOn:           []string{"category_name"},
			CombinedMeasures: []CombinedMeasure{{As: "ecoulement", Expr: "ventes.qty_vendue / nullif(achats.qty_achetee, 0)", Format: "percent"}}}},
	{Theme: "Achats", Title: "Gratuités reçues par fournisseur", Keywords: []string{"gratuit", "gratuites", "ug", "bonus", "fournisseur"}, ChartType: "bar",
		Spec: Request{Spec: Spec{Source: "purchase_lines", Dimensions: []string{"supplier_name"}, Measures: []Measure{{Name: "free_qty"}, {Name: "qty"}}, Range: Range{Type: "last_n_months", N: 6}, Sort: []Sort{{Field: "m0", Dir: "desc"}}}}},
	// ---------------------------------------------------------------- Créances
	{Theme: "Créances", Title: "Crédits clients en cours", Keywords: []string{"credit", "credits", "clients", "doit", "doivent", "debiteur", "debiteurs", "dette", "impaye", "impayes", "creance", "creances", "solde"}, ChartType: "table",
		Spec: Request{Spec: Spec{Source: "partner_ledger", Dimensions: []string{"partner_name"}, Measures: []Measure{{Name: "balance"}}, Filters: []Filter{{Field: "partner_kind", Op: "in", Value: []any{"customer", "both"}}}, Having: []Having{{Measure: "m0", Op: "gt", Value: 0}}, Range: Range{Type: "all"}, Sort: []Sort{{Field: "m0", Dir: "desc"}}, Limit: 30}}},
	{Theme: "Créances", Title: "Dettes fournisseurs", Keywords: []string{"dette", "dettes", "fournisseur", "fournisseurs", "devons", "dois", "doit", "payer", "reste", "reglement"}, ChartType: "table",
		Spec: Request{Spec: Spec{Source: "partner_ledger", Dimensions: []string{"partner_name"}, Measures: []Measure{{Name: "balance"}}, Filters: []Filter{{Field: "partner_kind", Op: "in", Value: []any{"supplier", "both"}}}, Having: []Having{{Measure: "m0", Op: "lt", Value: 0}}, Range: Range{Type: "all"}, Sort: []Sort{{Field: "m0", Dir: "asc"}}, Limit: 30}}},
}

// Gallery retourne la galerie (copie).
func Gallery() []GalleryItem {
	out := make([]GalleryItem, len(gallery))
	copy(out, gallery)
	return out
}

var stopwords = map[string]bool{"le": true, "la": true, "les": true, "de": true, "des": true, "du": true, "un": true, "une": true, "et": true, "en": true, "par": true,
	"pour": true, "sur": true, "ce": true, "cette": true, "mes": true, "mon": true, "ma": true, "quel": true, "quels": true, "quelle": true, "quelles": true, "est": true,
	"sont": true, "combien": true, "montre": true, "moi": true, "donne": true, "affiche": true, "voir": true, "je": true, "veux": true, "a": true, "au": true, "aux": true,
	"plus": true, "me": true, "nous": true, "qui": true, "que": true, "quoi": true, "avec": true, "dans": true, "il": true, "ils": true, "y": true, "on": true, "ai": true, "fait": true}

func normalize(s string) []string {
	s = strings.ToLower(s)
	repl := strings.NewReplacer("é", "e", "è", "e", "ê", "e", "ë", "e", "à", "a", "â", "a", "ù", "u", "û", "u", "ô", "o", "î", "i", "ï", "i", "ç", "c", "'", " ", "’", " ", "-", " ", "?", " ", ",", " ", ".", " ")
	s = repl.Replace(s)
	var out []string
	for _, w := range strings.Fields(s) {
		if len(w) < 2 || stopwords[w] {
			continue
		}
		if strings.HasSuffix(w, "s") && len(w) > 4 {
			w = strings.TrimSuffix(w, "s")
		}
		out = append(out, w)
	}
	return out
}

// MatchGallery : repli hors ligne — la question la plus proche par
// recouvrement de mots-clés. Retourne nil sous un score minimal.
func MatchGallery(question string) *GalleryItem {
	words := normalize(question)
	if len(words) == 0 {
		return nil
	}
	type scored struct {
		item  *GalleryItem
		score int
	}
	var best []scored
	for i := range gallery {
		it := &gallery[i]
		keys := map[string]bool{}
		for _, k := range it.Keywords {
			for _, w := range normalize(k) {
				keys[w] = true
			}
		}
		for _, w := range normalize(it.Title) {
			keys[w] = true
		}
		score := 0
		for _, w := range words {
			if keys[w] {
				score += 2
				continue
			}
			for k := range keys {
				if len(w) >= 4 && (strings.HasPrefix(k, w) || strings.HasPrefix(w, k)) {
					score++
					break
				}
			}
		}
		if score > 0 {
			best = append(best, scored{it, score})
		}
	}
	if len(best) == 0 {
		return nil
	}
	sort.SliceStable(best, func(a, b int) bool { return best[a].score > best[b].score })
	if best[0].score < 2 {
		return nil
	}
	return best[0].item
}
