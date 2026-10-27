// Package analytics is the query engine of the Analyses module: a
// whitelist of sources, dimensions and measures; a JSON specification from
// the client; an SQL query generated only from identifiers
// known to the server (client strings are only used for labels or
// bound parameters). Read-only, on a dedicated pool, never on the
// write connection.
package analytics

import "sort"

// SchemaVersion: incremented on every change to the whitelist; saved
// reports carry the version they were built with.
const SchemaVersion = 1

// renames: {version → {old field → new}} applied when loading a
// saved report built with an earlier version.
var renames = map[int]map[string]string{}

// Field describes a field exposed by a source.
type Field struct {
	Key        string   `json:"field"`
	LabelFR    string   `json:"label_fr"`
	LabelAR    string   `json:"label_ar"`
	Type       string   `json:"type"`   // string | number | date | datetime | bool | enum
	Unit       string   `json:"unit"`   // centimes | milli | percent | ratio | count | days | ""
	Format     string   `json:"format"` // currency | quantity | percent | ratio | integer | text | date | datetime | bool
	Group      string   `json:"group"`  // Time | Product | Partner | Document | Amounts | Stock
	Dimension  bool     `json:"dimension"`
	Measure    bool     `json:"measure"`
	Filterable bool     `json:"filterable"`
	Aggs       []string `json:"allowed_aggs,omitempty"`
	Ops        []string `json:"allowed_ops,omitempty"`
	GatedBy    string   `json:"gated_by,omitempty"`
	EnumValues []string `json:"enum_values,omitempty"`
	EnumSource string   `json:"enum_source,omitempty"`
	Buckets    []string `json:"buckets,omitempty"` // for dates
	expr       string   // SQL expression if different from the column
}

// NamedMeasure: predefined measure (expression fixed server-side).
type NamedMeasure struct {
	Key     string `json:"key"`
	LabelFR string `json:"label_fr"`
	LabelAR string `json:"label_ar"`
	Format  string `json:"format"`
	Unit    string `json:"unit"`
	GatedBy string `json:"gated_by,omitempty"`
	sql     string
}

// Param: parameter of a template (expiry horizon…).
type Param struct {
	Key     string `json:"key"`
	LabelFR string `json:"label_fr"`
	Default int    `json:"default"`
	Min     int    `json:"min"`
	Max     int    `json:"max"`
}

// Source: a view or a template, its whitelist and its measures.
type Source struct {
	Key       string         `json:"key"`
	LabelFR   string         `json:"label_fr"`
	LabelAR   string         `json:"label_ar"`
	Icon      string         `json:"icon"`
	DateField string         `json:"date_field"` // default period field
	Fields    []Field        `json:"fields"`
	Named     []NamedMeasure `json:"named_measures"`
	Params    []Param        `json:"params,omitempty"`
	Template  bool           `json:"template"`
	from      string         // view name (simple sources)
	fieldIx   map[string]*Field
	namedIx   map[string]*NamedMeasure
}

func (s *Source) field(key string) *Field       { return s.fieldIx[key] }
func (s *Source) named(key string) *NamedMeasure { return s.namedIx[key] }

var sources = map[string]*Source{}
var sourceOrder []string

func register(s *Source) {
	s.fieldIx = map[string]*Field{}
	for i := range s.Fields {
		f := &s.Fields[i]
		if f.expr == "" {
			f.expr = f.Key
		}
		if f.Ops == nil {
			f.Ops = defaultOps(f.Type)
		}
		if f.Measure && f.Aggs == nil {
			f.Aggs = []string{"sum", "avg", "min", "max"}
		}
		if (f.Type == "date" || f.Type == "datetime") && f.Buckets == nil {
			f.Buckets = []string{"day", "week", "month", "quarter", "year", "dow"}
			if f.Type == "datetime" {
				f.Buckets = append(f.Buckets, "hour")
			}
		}
		s.fieldIx[f.Key] = f
	}
	s.namedIx = map[string]*NamedMeasure{}
	for i := range s.Named {
		s.namedIx[s.Named[i].Key] = &s.Named[i]
	}
	sources[s.Key] = s
	sourceOrder = append(sourceOrder, s.Key)
}

func defaultOps(t string) []string {
	switch t {
	case "number":
		return []string{"eq", "ne", "gt", "gte", "lt", "lte", "between", "is_null", "is_not_null"}
	case "date", "datetime":
		return []string{"eq", "gt", "gte", "lt", "lte", "between", "is_null", "is_not_null"}
	case "bool":
		return []string{"eq"}
	case "enum":
		return []string{"eq", "ne", "in", "not_in", "is_null", "is_not_null"}
	default:
		return []string{"eq", "ne", "in", "not_in", "contains", "starts_with", "ends_with", "is_null", "is_not_null"}
	}
}

// ---- declaration helpers -------------------------------------------------

func dim(key, fr, ar, typ, group string) Field {
	return Field{Key: key, LabelFR: fr, LabelAR: ar, Type: typ, Group: group, Dimension: true, Filterable: true, Format: fmtFor(typ)}
}
func fmtFor(typ string) string {
	switch typ {
	case "date":
		return "date"
	case "datetime":
		return "datetime"
	case "bool":
		return "bool"
	case "number":
		return "integer"
	}
	return "text"
}
func enumDim(key, fr, ar, group string, values ...string) Field {
	f := dim(key, fr, ar, "enum", group)
	f.EnumValues = values
	return f
}
func lookupDim(key, fr, ar, group, endpoint string) Field {
	f := dim(key, fr, ar, "enum", group)
	f.EnumSource = endpoint
	return f
}
func money(key, fr, ar string, gated string) Field {
	return Field{Key: key, LabelFR: fr, LabelAR: ar, Type: "number", Unit: "centimes", Format: "currency",
		Group: "Montants", Measure: true, Filterable: true, GatedBy: gated}
}
func qty(key, fr, ar string) Field {
	return Field{Key: key, LabelFR: fr, LabelAR: ar, Type: "number", Unit: "milli", Format: "quantity",
		Group: "Montants", Measure: true, Filterable: true}
}
func num(key, fr, ar, group string) Field {
	return Field{Key: key, LabelFR: fr, LabelAR: ar, Type: "number", Unit: "count", Format: "integer",
		Group: group, Measure: true, Filterable: true, Dimension: true}
}
func nm(key, fr, ar, format, unit, sqlExpr, gated string) NamedMeasure {
	return NamedMeasure{Key: key, LabelFR: fr, LabelAR: ar, Format: format, Unit: unit, sql: sqlExpr, GatedBy: gated}
}

// PermCost: permission guarding the cost / margin fields.
const (
	PermCost    = "view_cost"
)

func init() {
	// ------------------------------------------------------------ sales
	register(&Source{
		Key: "sale_lines", LabelFR: "Ventes", LabelAR: "المبيعات", Icon: "sell", from: "v_sale_lines", DateField: "doc_date",
		Fields: []Field{
			dim("doc_date", "Date de vente", "تاريخ البيع", "date", "Temps"),
			dim("posted_at", "Horodatage", "الوقت", "datetime", "Temps"),
			enumDim("doc_kind", "Vente / retour", "بيع / إرجاع", "Document", "sale", "return"),
			enumDim("doc_type", "Type de document", "نوع الوثيقة", "Document", "SALE_TICKET", "SALE_INVOICE", "SALE_CREDIT_NOTE"),
			enumDim("payment_method", "Mode de paiement", "طريقة الدفع", "Document", "cash", "cib", "edahabia", "cheque", "transfer", "credit"),
			lookupDim("warehouse_id", "Dépôt", "المستودع", "Document", "/api/v1/warehouses"),
			dim("warehouse_name", "Dépôt (nom)", "المستودع", "string", "Document"),
			lookupDim("created_by", "Vendeur", "البائع", "Document", "/api/v1/users"),
			dim("cashier_name", "Vendeur (nom)", "البائع", "string", "Document"),
			dim("document_number", "N° document", "رقم الوثيقة", "string", "Document"),
			lookupDim("product_id", "Produit", "المنتج", "Produit", "/api/v1/products"),
			dim("product_name", "Produit (nom)", "المنتج", "string", "Produit"),
			lookupDim("category_id", "Catégorie", "الفئة", "Produit", "/api/v1/categories"),
			dim("category_name", "Catégorie (nom)", "الفئة", "string", "Produit"),
			dim("brand", "Marque", "العلامة التجارية", "string", "Produit"),
			dim("lot_id", "Lot", "الحصة", "string", "Produit"),
			dim("expiry_date", "Péremption", "تاريخ الانتهاء", "date", "Produit"),
			lookupDim("partner_id", "Client", "الزبون", "Partenaire", "/api/v1/partners?kind=customer"),
			dim("partner_name", "Client (nom)", "الزبون", "string", "Partenaire"),
			num("vat_rate", "Taux TVA (x100)", "نسبة الضريبة", "Montants"),
			num("discount_pct", "Remise % (x100)", "نسبة الخصم", "Montants"),
			qty("qty_milli", "Quantité", "الكمية"),
			money("unit_price", "Prix unitaire HT", "سعر الوحدة", ""),
			money("unit_cost", "Coût unitaire", "تكلفة الوحدة", PermCost),
			money("discount_amount", "Remise", "الخصم", ""),
			money("line_ht", "Montant HT", "المبلغ دون رسم", ""),
			money("line_vat", "TVA", "الضريبة", ""),
			money("line_ttc", "Montant TTC", "المبلغ الإجمالي", ""),
			money("margin_ht", "Marge HT", "الهامش", PermCost),
		},
		Named: []NamedMeasure{
			nm("ca_ttc", "Chiffre d'affaires TTC", "رقم الأعمال", "currency", "centimes", "SUM(line_ttc)", ""),
			nm("ca_ht", "Chiffre d'affaires HT", "رقم الأعمال دون رسم", "currency", "centimes", "SUM(line_ht)", ""),
			nm("qty", "Quantité vendue", "الكمية المباعة", "quantity", "milli", "SUM(qty_milli)", ""),
			nm("margin", "Marge", "الهامش", "currency", "centimes", "SUM(margin_ht)", PermCost),
			nm("margin_pct", "Marge %", "نسبة الهامش", "percent", "percent", "1.0*SUM(margin_ht)/NULLIF(SUM(line_ht),0)", PermCost),
			nm("sales_count", "Nombre de ventes", "عدد المبيعات", "integer", "count",
				"COUNT(DISTINCT CASE WHEN doc_kind='sale' THEN document_id END)", ""),
			nm("returns_count", "Nombre de retours", "عدد الإرجاعات", "integer", "count",
				"COUNT(DISTINCT CASE WHEN doc_kind='return' THEN document_id END)", ""),
			nm("avg_basket", "Panier moyen", "متوسط السلة", "currency", "centimes",
				"1.0*SUM(CASE WHEN doc_kind='sale' THEN line_ttc ELSE 0 END)/NULLIF(COUNT(DISTINCT CASE WHEN doc_kind='sale' THEN document_id END),0)", ""),
			nm("products_count", "Produits distincts", "عدد المنتجات", "integer", "count", "COUNT(DISTINCT product_id)", ""),
			nm("discount_total", "Remises accordées", "الخصومات", "currency", "centimes", "SUM(discount_amount)", ""),
			nm("avg_unit_price", "Prix unitaire moyen", "متوسط السعر", "currency", "centimes", "AVG(unit_price)", ""),
			nm("lines_count", "Lignes", "الأسطر", "integer", "count", "COUNT(*)", ""),
		},
	})

	// ------------------------------------------------------------ purchases
	register(&Source{
		Key: "purchase_lines", LabelFR: "Achats", LabelAR: "المشتريات", Icon: "local_shipping", from: "v_purchase_lines", DateField: "doc_date",
		Fields: []Field{
			dim("doc_date", "Date de réception", "تاريخ الاستلام", "date", "Temps"),
			dim("posted_at", "Horodatage", "الوقت", "datetime", "Temps"),
			enumDim("doc_kind", "Achat / retour", "شراء / إرجاع", "Document", "purchase", "return"),
			enumDim("doc_type", "Type de document", "نوع الوثيقة", "Document", "PURCHASE_RECEIPT", "PURCHASE_INVOICE", "PURCHASE_CREDIT_NOTE"),
			dim("document_number", "N° document", "رقم الوثيقة", "string", "Document"),
			dim("supplier_ref", "N° facture fournisseur", "رقم فاتورة المورد", "string", "Document"),
			lookupDim("supplier_id", "Fournisseur", "المورد", "Partenaire", "/api/v1/partners?kind=supplier"),
			dim("supplier_name", "Fournisseur (nom)", "المورد", "string", "Partenaire"),
			lookupDim("warehouse_id", "Dépôt", "المستودع", "Document", "/api/v1/warehouses"),
			lookupDim("product_id", "Produit", "المنتج", "Produit", "/api/v1/products"),
			dim("product_name", "Produit (nom)", "المنتج", "string", "Produit"),
			lookupDim("category_id", "Catégorie", "الفئة", "Produit", "/api/v1/categories"),
			dim("category_name", "Catégorie (nom)", "الفئة", "string", "Produit"),
			dim("brand", "Marque", "العلامة التجارية", "string", "Produit"),
			dim("lot_id", "Lot", "الحصة", "string", "Produit"),
			dim("expiry_date", "Péremption", "تاريخ الانتهاء", "date", "Produit"),
			qty("qty_milli", "Quantité reçue", "الكمية المستلمة"),
			qty("qty_free_milli", "Gratuités", "المجانيات"),
			money("unit_cost", "Coût unitaire", "تكلفة الوحدة", PermCost),
			money("line_ht", "Montant HT", "المبلغ دون رسم", PermCost),
			money("line_ttc", "Montant TTC", "المبلغ الإجمالي", PermCost),
		},
		Named: []NamedMeasure{
			nm("total_ht", "Achats HT", "المشتريات", "currency", "centimes", "SUM(line_ht)", PermCost),
			nm("total_ttc", "Achats TTC", "المشتريات الإجمالية", "currency", "centimes", "SUM(line_ttc)", PermCost),
			nm("qty", "Quantité reçue", "الكمية", "quantity", "milli", "SUM(qty_milli)", ""),
			nm("free_qty", "Gratuités", "المجانيات", "quantity", "milli", "SUM(qty_free_milli)", ""),
			nm("receipts_count", "Nombre de réceptions", "عدد الاستلامات", "integer", "count", "COUNT(DISTINCT document_id)", ""),
			nm("products_count", "Produits distincts", "عدد المنتجات", "integer", "count", "COUNT(DISTINCT product_id)", ""),
			nm("suppliers_count", "Fournisseurs distincts", "عدد الموردين", "integer", "count", "COUNT(DISTINCT supplier_id)", ""),
			nm("avg_unit_cost", "Coût unitaire moyen", "متوسط التكلفة", "currency", "centimes", "AVG(unit_cost)", PermCost),
			nm("lines_count", "Lignes", "الأسطر", "integer", "count", "COUNT(*)", ""),
		},
	})

	// ------------------------------------------------------------ stock movements
	register(&Source{
		Key: "stock_movements", LabelFR: "Mouvements de stock", LabelAR: "حركات المخزون", Icon: "swap_vert", from: "v_stock_movements", DateField: "movement_date",
		Fields: []Field{
			dim("movement_date", "Date", "التاريخ", "date", "Temps"),
			dim("movement_at", "Horodatage", "الوقت", "datetime", "Temps"),
			enumDim("direction", "Sens", "الاتجاه", "Document", "in", "out"),
			enumDim("doc_type", "Type de document", "نوع الوثيقة", "Document",
				"SALE_TICKET", "SALE_INVOICE", "SALE_CREDIT_NOTE", "DELIVERY_NOTE", "PURCHASE_RECEIPT", "PURCHASE_INVOICE",
				"PURCHASE_CREDIT_NOTE", "STOCK_ADJUSTMENT", "STOCK_TRANSFER", "INVENTORY_COUNT"),
			dim("document_number", "N° document", "رقم الوثيقة", "string", "Document"),
			lookupDim("warehouse_id", "Dépôt", "المستودع", "Document", "/api/v1/warehouses"),
			dim("warehouse_name", "Dépôt (nom)", "المستودع", "string", "Document"),
			lookupDim("product_id", "Produit", "المنتج", "Produit", "/api/v1/products"),
			dim("product_name", "Produit (nom)", "المنتج", "string", "Produit"),
			lookupDim("category_id", "Catégorie", "الفئة", "Produit", "/api/v1/categories"),
			dim("category_name", "Catégorie (nom)", "الفئة", "string", "Produit"),
			dim("brand", "Marque", "العلامة التجارية", "string", "Produit"),
			dim("lot_id", "Lot", "الحصة", "string", "Produit"),
			dim("expiry_date", "Péremption", "تاريخ الانتهاء", "date", "Produit"),
			qty("qty_delta_milli", "Variation de quantité", "تغير الكمية"),
			money("unit_cost", "Coût unitaire", "تكلفة الوحدة", PermCost),
			money("movement_value", "Valeur du mouvement", "قيمة الحركة", PermCost),
		},
		Named: []NamedMeasure{
			nm("qty_in", "Entrées", "الداخل", "quantity", "milli", "SUM(CASE WHEN qty_delta_milli>0 THEN qty_delta_milli ELSE 0 END)", ""),
			nm("qty_out", "Sorties", "الخارج", "quantity", "milli", "SUM(CASE WHEN qty_delta_milli<0 THEN -qty_delta_milli ELSE 0 END)", ""),
			nm("net_qty", "Variation nette", "الصافي", "quantity", "milli", "SUM(qty_delta_milli)", ""),
			nm("value_in", "Valeur entrée", "قيمة الداخل", "currency", "centimes", "SUM(CASE WHEN qty_delta_milli>0 THEN movement_value ELSE 0 END)", PermCost),
			nm("value_out", "Valeur sortie", "قيمة الخارج", "currency", "centimes", "SUM(CASE WHEN qty_delta_milli<0 THEN -movement_value ELSE 0 END)", PermCost),
			nm("net_value", "Variation de valeur", "صافي القيمة", "currency", "centimes", "SUM(movement_value)", PermCost),
			nm("movements_count", "Mouvements", "الحركات", "integer", "count", "COUNT(*)", ""),
			nm("products_count", "Produits distincts", "عدد المنتجات", "integer", "count", "COUNT(DISTINCT product_id)", ""),
		},
	})

	// ------------------------------------------------------------ current stock (template: expiry horizon)
	register(&Source{
		Key: "stock_snapshot", LabelFR: "Stock actuel", LabelAR: "المخزون الحالي", Icon: "inventory_2", Template: true, DateField: "",
		Params: []Param{{Key: "expiry_days", LabelFR: "Péremption sous N jours", Default: 90, Min: 1, Max: 3650}},
		Fields: []Field{
			lookupDim("product_id", "Produit", "المنتج", "Produit", "/api/v1/products"),
			dim("product_name", "Produit (nom)", "المنتج", "string", "Produit"),
			lookupDim("category_id", "Catégorie", "الفئة", "Produit", "/api/v1/categories"),
			dim("category_name", "Catégorie (nom)", "الفئة", "string", "Produit"),
			dim("brand", "Marque", "العلامة التجارية", "string", "Produit"),
			lookupDim("supplier_id", "Fournisseur habituel", "المورد", "Partenaire", "/api/v1/partners?kind=supplier"),
			dim("supplier_name", "Fournisseur (nom)", "المورد", "string", "Partenaire"),
			lookupDim("warehouse_id", "Dépôt", "المستودع", "Stock", "/api/v1/warehouses"),
			dim("warehouse_name", "Dépôt (nom)", "المستودع", "string", "Stock"),
			dim("below_min", "Sous le minimum", "تحت الحد الأدنى", "bool", "Stock"),
			dim("out_of_stock", "En rupture", "نفاد", "bool", "Stock"),
			dim("nearest_expiry", "Prochaine péremption", "أقرب انتهاء", "date", "Stock"),
			dim("is_expiring", "Périme sous N jours", "ينتهي خلال N يوم", "bool", "Stock"),
			dim("is_expired", "Périmé", "منتهي الصلاحية", "bool", "Stock"),
			qty("qty_milli", "Quantité en stock", "الكمية"),
			qty("min_stock_milli", "Stock minimum", "الحد الأدنى"),
			money("avg_cost", "Coût moyen (CMUP)", "التكلفة المتوسطة", PermCost),
			money("stock_value", "Valeur du stock (coût)", "قيمة المخزون", PermCost),
			money("price_retail", "Prix de vente", "سعر البيع", ""),
			money("retail_value", "Valeur au prix de vente", "القيمة بسعر البيع", ""),
			qty("qty_expiring", "Quantité périmant sous N j", "الكمية المنتهية"),
			money("value_expiring", "Valeur périmant sous N j", "القيمة المنتهية", PermCost),
			money("value_expired", "Valeur périmée", "قيمة المنتهي", PermCost),
		},
		Named: []NamedMeasure{
			nm("references", "Références", "المراجع", "integer", "count", "COUNT(*)", ""),
			nm("qty", "Quantité", "الكمية", "quantity", "milli", "SUM(qty_milli)", ""),
			nm("stock_value", "Valeur du stock (coût)", "قيمة المخزون", "currency", "centimes", "SUM(stock_value)", PermCost),
			nm("retail_value", "Valeur au prix de vente", "القيمة بسعر البيع", "currency", "centimes", "SUM(retail_value)", ""),
			nm("below_min_count", "Références sous le minimum", "تحت الحد الأدنى", "integer", "count", "SUM(below_min)", ""),
			nm("out_count", "Références en rupture", "نفاد", "integer", "count", "SUM(out_of_stock)", ""),
			nm("expiring_count", "Références périmant sous N j", "تنتهي قريبا", "integer", "count", "SUM(is_expiring)", ""),
			nm("value_expiring", "Valeur périmant sous N j", "القيمة المنتهية", "currency", "centimes", "SUM(value_expiring)", PermCost),
			nm("value_expired", "Valeur périmée", "قيمة المنتهي", "currency", "centimes", "SUM(value_expired)", PermCost),
		},
	})

	// ------------------------------------------------------------ receivables / payables
	register(&Source{
		Key: "partner_ledger", LabelFR: "Créances & dettes", LabelAR: "الديون", Icon: "account_balance_wallet", from: "v_partner_ledger", DateField: "movement_date",
		Fields: []Field{
			dim("movement_date", "Date", "التاريخ", "date", "Temps"),
			lookupDim("partner_id", "Partenaire", "الشريك", "Partenaire", "/api/v1/partners"),
			dim("partner_name", "Partenaire (nom)", "الشريك", "string", "Partenaire"),
			enumDim("partner_kind", "Type de partenaire", "نوع الشريك", "Partenaire", "customer", "supplier", "both"),
			enumDim("ledger_kind", "Nature", "الطبيعة", "Document", "invoice", "payment", "credit_note", "adjustment"),
			enumDim("doc_type", "Type de document", "نوع الوثيقة", "Document",
				"SALE_TICKET", "SALE_INVOICE", "SALE_CREDIT_NOTE", "PURCHASE_INVOICE", "PURCHASE_CREDIT_NOTE", "PAYMENT_IN", "PAYMENT_OUT"),
			dim("document_number", "N° document", "رقم الوثيقة", "string", "Document"),
			money("amount", "Montant (signé)", "المبلغ", ""),
		},
		Named: []NamedMeasure{
			nm("balance", "Solde (positif = nous doit)", "الرصيد", "currency", "centimes", "SUM(amount)", ""),
			nm("invoiced", "Facturé", "المفوتر", "currency", "centimes", "SUM(CASE WHEN ledger_kind='invoice' THEN amount ELSE 0 END)", ""),
			nm("paid", "Réglé", "المدفوع", "currency", "centimes", "SUM(CASE WHEN ledger_kind='payment' THEN -amount ELSE 0 END)", ""),
			nm("movements_count", "Mouvements", "الحركات", "integer", "count", "COUNT(*)", ""),
			nm("partners_count", "Partenaires distincts", "عدد الشركاء", "integer", "count", "COUNT(DISTINCT partner_id)", ""),
		},
	})

	// ------------------------------------------------------------ product performance (template: period)
	register(&Source{
		Key: "product_performance", LabelFR: "Performance produit", LabelAR: "أداء المنتج", Icon: "insights", Template: true, DateField: "",
		Fields: []Field{
			lookupDim("product_id", "Produit", "المنتج", "Produit", "/api/v1/products"),
			dim("product_name", "Produit (nom)", "المنتج", "string", "Produit"),
			lookupDim("category_id", "Catégorie", "الفئة", "Produit", "/api/v1/categories"),
			dim("category_name", "Catégorie (nom)", "الفئة", "string", "Produit"),
			dim("brand", "Marque", "العلامة التجارية", "string", "Produit"),
			dim("never_sold", "Jamais vendu sur la période", "لم يبع", "bool", "Stock"),
			dim("has_stock", "En stock", "متوفر", "bool", "Stock"),
			dim("last_sale_date", "Dernière vente", "آخر بيع", "date", "Temps"),
			dim("last_purchase_date", "Dernier achat", "آخر شراء", "date", "Temps"),
			num("days_since_last_sale", "Jours depuis la dernière vente", "أيام منذ آخر بيع", "Stock"),
			qty("qty_sold", "Quantité vendue (période)", "الكمية المباعة"),
			money("revenue", "CA HT (période)", "رقم الأعمال", ""),
			money("margin", "Marge (période)", "الهامش", PermCost),
			qty("qty_purchased", "Quantité achetée (période)", "الكمية المشتراة"),
			qty("qty_on_hand", "Quantité en stock", "الكمية في المخزون"),
			money("avg_cost", "Coût moyen", "التكلفة", PermCost),
			money("stock_value", "Valeur du stock", "قيمة المخزون", PermCost),
			Field{Key: "sell_through", LabelFR: "Taux d'écoulement", LabelAR: "معدل التصريف", Type: "number", Unit: "ratio", Format: "percent",
				Group: "Stock", Measure: true, Filterable: true, Aggs: []string{"avg", "min", "max"}},
			Field{Key: "days_of_stock", LabelFR: "Jours de stock restants", LabelAR: "أيام المخزون", Type: "number", Unit: "days", Format: "integer",
				Group: "Stock", Measure: true, Filterable: true, Aggs: []string{"avg", "min", "max"}},
		},
		Named: []NamedMeasure{
			nm("products_count", "Produits", "المنتجات", "integer", "count", "COUNT(*)", ""),
			nm("qty_sold", "Quantité vendue", "الكمية المباعة", "quantity", "milli", "SUM(qty_sold)", ""),
			nm("revenue", "CA HT", "رقم الأعمال", "currency", "centimes", "SUM(revenue)", ""),
			nm("margin", "Marge", "الهامش", "currency", "centimes", "SUM(margin)", PermCost),
			nm("qty_purchased", "Quantité achetée", "الكمية المشتراة", "quantity", "milli", "SUM(qty_purchased)", ""),
			nm("qty_on_hand", "Quantité en stock", "المخزون", "quantity", "milli", "SUM(qty_on_hand)", ""),
			nm("stock_value", "Valeur du stock", "قيمة المخزون", "currency", "centimes", "SUM(stock_value)", PermCost),
			nm("sell_through", "Taux d'écoulement global", "معدل التصريف", "percent", "percent",
				"1.0*SUM(qty_sold)/NULLIF(SUM(qty_sold)+SUM(qty_on_hand),0)", ""),
			nm("never_sold_count", "Jamais vendus", "لم تبع", "integer", "count", "SUM(never_sold)", ""),
			nm("dead_stock_value", "Valeur du stock dormant", "قيمة المخزون الراكد", "currency", "centimes",
				"SUM(CASE WHEN never_sold AND qty_on_hand>0 THEN stock_value ELSE 0 END)", PermCost),
		},
	})
}

// Sources returns the ordered list of sources.
func Sources() []*Source {
	out := make([]*Source, 0, len(sourceOrder))
	for _, k := range sourceOrder {
		out = append(out, sources[k])
	}
	return out
}

// Caller: identity and permissions of the requester, re-evaluated on every request.
type Caller struct {
	UserID string
	Role   string
	Perms  map[string]bool
}

func (c Caller) allowed(gate string) bool {
	if gate == "" {
		return true
	}
	if c.Role == "admin" {
		return true
	}
	return c.Perms != nil && c.Perms[gate]
}

// VisibleSchema: the whitelist filtered by the requester's permissions —
// guarded fields are absent, not disabled.
func VisibleSchema(c Caller) []map[string]any {
	out := []map[string]any{}
	for _, s := range Sources() {
		fields := []Field{}
		for _, f := range s.Fields {
			if c.allowed(f.GatedBy) {
				fields = append(fields, f)
			}
		}
		named := []NamedMeasure{}
		for _, n := range s.Named {
			if c.allowed(n.GatedBy) {
				named = append(named, n)
			}
		}
		out = append(out, map[string]any{
			"key": s.Key, "label_fr": s.LabelFR, "label_ar": s.LabelAR, "icon": s.Icon,
			"date_field": s.DateField, "template": s.Template, "params": s.Params,
			"fields": fields, "named_measures": named,
		})
	}
	return out
}

// allowed combo pairs (sorted key « a+b »).
var comboPairs = map[string][]string{
	"purchase_lines+sale_lines":      {"product_id", "product_name", "category_id", "category_name", "brand", "warehouse_id", "warehouse_name", "date"},
	"sale_lines+stock_snapshot":      {"product_id", "product_name", "category_id", "category_name", "brand", "warehouse_id", "warehouse_name"},
	"purchase_lines+stock_movements": {"product_id", "product_name", "category_id", "category_name", "brand", "warehouse_id", "warehouse_name", "date"},
	"sale_lines+stock_movements":     {"product_id", "product_name", "category_id", "category_name", "brand", "warehouse_id", "warehouse_name", "date"},
}

func comboKey(a, b string) string {
	k := []string{a, b}
	sort.Strings(k)
	return k[0] + "+" + k[1]
}
