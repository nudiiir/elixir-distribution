package analytics

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// ---- specification ----------------------------------------------------------

// Measure: requested measure — either field + aggregate, or a named measure.
type Measure struct {
	Field      string `json:"field,omitempty"`
	Agg        string `json:"agg,omitempty"`
	Name       string `json:"name,omitempty"`
	As         string `json:"as,omitempty"`
	Share      bool   `json:"share,omitempty"`      // + share of total
	Cumulative bool   `json:"cumulative,omitempty"` // + running total (sorted date dimension)
}

type Filter struct {
	Field string `json:"field"`
	Op    string `json:"op"`
	Value any    `json:"value,omitempty"`
}

// Having: filter on a measure (after aggregation). Measure = engine alias
// (m0…), client alias or named-measure key.
type Having struct {
	Measure string  `json:"measure"`
	Op      string  `json:"op"`
	Value   float64 `json:"value"`
	Value2  float64 `json:"value2,omitempty"`
}

type Sort struct {
	Field string `json:"field"` // d0/m0, client alias, field key or named-measure key
	Dir   string `json:"dir"`   // asc | desc
}

// Spec: a simple query.
type Spec struct {
	Source     string         `json:"source"`
	Dimensions []string       `json:"dimensions"`
	Measures   []Measure      `json:"measures"`
	Filters    []Filter       `json:"filters"`
	Having     []Having       `json:"having"`
	Range      Range          `json:"range"`
	DateField  string         `json:"date_field,omitempty"`
	Sort       []Sort         `json:"sort"`
	Limit      int            `json:"limit"`
	Compare    string         `json:"compare,omitempty"` // previous_period | previous_year
	Params     map[string]int `json:"params,omitempty"`  // gabarits (expiry_days…)
	ZeroFill   *bool          `json:"zero_fill,omitempty"`
}

// ComboSource: one side of a cross query.
type ComboSource struct {
	Name     string    `json:"name"`
	Source   string    `json:"source"`
	Measures []Measure `json:"measures"`
	Filters  []Filter  `json:"filters"`
	Params   map[string]int `json:"params,omitempty"`
}

type CombinedMeasure struct {
	As     string `json:"as"`
	Expr   string `json:"expr"`
	Format string `json:"format"` // currency | quantity | percent | ratio | integer
}

// Request: simple or cross (combo=true).
type Request struct {
	Spec
	Combo            bool              `json:"combo,omitempty"`
	Sources          []ComboSource     `json:"sources,omitempty"`
	JoinOn           []string          `json:"join_on,omitempty"`
	CombinedMeasures []CombinedMeasure `json:"combined_measures,omitempty"`
}

// ---- result ------------------------------------------------------------

type Column struct {
	Key     string `json:"key"`   // d0, m0, m0_prev, m0_delta, m0_share, m0_cum, c0
	Kind    string `json:"kind"`  // dimension | measure
	Field   string `json:"field"` // source field or measure
	Bucket  string `json:"bucket,omitempty"`
	Label   string `json:"label"`
	Format  string `json:"format"`
	Unit    string `json:"unit,omitempty"`
	Derived string `json:"derived,omitempty"` // prev | delta | delta_pct | share | cum
}

type Result struct {
	Columns    []Column   `json:"columns"`
	Rows       [][]any    `json:"rows"`
	TotalRows  int        `json:"total_rows"`
	Truncated  bool       `json:"truncated"`
	Range      Resolved   `json:"range"`
	PrevRange  *Resolved  `json:"prev_range,omitempty"`
	Dropped    []string   `json:"dropped,omitempty"` // measures removed (permissions)
	DurationMs int64      `json:"duration_ms"`
	Cached     bool       `json:"cached"`
	Labels     map[string]map[string]string `json:"labels,omitempty"` // col → value → label (buckets)
}

// Error: explicit refusal (400/403) — never an « empty result ».
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Message }

func bad(msg string, a ...any) error      { return &Error{Code: "bad_request", Message: fmt.Sprintf(msg, a...)} }
func forbid(msg string, a ...any) error   { return &Error{Code: "forbidden", Message: fmt.Sprintf(msg, a...)} }
func timeoutErr() error                    { return &Error{Code: "timeout", Message: "la requête a dépassé le temps alloué — réduisez la période ou ajoutez un filtre"} }

// ---- moteur ---------------------------------------------------------------

type Engine struct {
	db      *sql.DB // read-only pool, separate from the write connection
	sem     chan struct{}
	timeout time.Duration
	cache   *lru
	Now     func() time.Time
}

func New(ro *sql.DB) *Engine {
	return &Engine{db: ro, sem: make(chan struct{}, 2), timeout: 5 * time.Second, cache: newLRU(200), Now: time.Now}
}

func (e *Engine) weekStart(ctx context.Context) int {
	var v string
	e.db.QueryRowContext(ctx, `SELECT value FROM settings WHERE key='week_start_day'`).Scan(&v)
	if n, ok := toInt(v); ok && n >= 0 && n <= 6 {
		return n
	}
	return 0 // dimanche
}

func (e *Engine) maxPostedAt(ctx context.Context) string {
	var v sql.NullString
	e.db.QueryRowContext(ctx, `SELECT MAX(posted_at) FROM documents`).Scan(&v)
	return v.String
}

var aliasRe = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_ ]{0,63}$`)

// ---- compiling a simple query ----------------------------------------

type dimC struct {
	field    *Field
	bucket   string
	expr     string
	key      string // d0…
	isPeriod bool   // bucket on the period axis (generated domain → zero fill)
}
type measC struct {
	key    string // m0…
	sqlExp string
	label  string
	format string
	unit   string
	field  string
	as     string
	share  bool
	cum    bool
}

type compiled struct {
	src      *Source
	dims     []dimC
	meas     []measC
	where    []string
	args     []any
	fromSQL  string
	fromArgs []any
	having   []string
	hargs    []any
	orderBy  string
	limit    int
	rs       Resolved
	ws       int
	dropped  []string
	dateDim  int // index of the first date-bucket dimension, -1 otherwise
	zeroFill bool
}

func (e *Engine) compile(ctx context.Context, sp Spec, c Caller, rsOverride *Resolved) (*compiled, error) {
	src := sources[sp.Source]
	if src == nil {
		return nil, bad("source inconnue : %s", sp.Source)
	}
	ws := e.weekStart(ctx)
	now := e.Now()
	var rs Resolved
	var err error
	if rsOverride != nil {
		rs = *rsOverride
	} else {
		rs, err = sp.Range.Resolve(now, ws)
		if err != nil {
			return nil, bad("%v", err)
		}
	}
	cp := &compiled{src: src, rs: rs, ws: ws, dateDim: -1}

	// ---- FROM (view or template)
	if src.Template {
		sqlT, args, err := templateSQL(src.Key, rs, sp.Params)
		if err != nil {
			return nil, err
		}
		cp.fromSQL = "(" + sqlT + ") AS t"
		cp.fromArgs = args
	} else {
		cp.fromSQL = src.from
	}

	// ---- period field (before the dimensions: it decides zero filling)
	dateField := sp.DateField
	if dateField == "" {
		dateField = src.DateField
	}

	// ---- dimensions
	if len(sp.Dimensions) > 4 {
		return nil, bad("4 dimensions au maximum")
	}
	seen := map[string]bool{}
	for i, d := range sp.Dimensions {
		key, bucket := d, ""
		if k := strings.Index(d, ":"); k > 0 {
			key, bucket = d[:k], d[k+1:]
		}
		f := src.field(key)
		if f == nil || !f.Dimension {
			return nil, bad("dimension inconnue : %s", key)
		}
		if !c.allowed(f.GatedBy) {
			return nil, forbid("« %s » n'est pas disponible pour votre rôle", f.LabelFR)
		}
		if bucket != "" {
			if f.Type != "date" && f.Type != "datetime" {
				return nil, bad("%s n'est pas une date", key)
			}
			if !validBuckets[bucket] || (bucket == "hour" && f.Type != "datetime") {
				return nil, bad("granularité inconnue : %s", bucket)
			}
		} else if f.Type == "date" || f.Type == "datetime" {
			bucket = "day"
		}
		if seen[d] {
			return nil, bad("dimension en double : %s", d)
		}
		seen[d] = true
		expr := f.expr
		isPeriod := false
		if bucket != "" {
			expr = bucketExpr(f.expr, f.Type, bucket, ws)
			// Only the period axis (or a fixed dow/hour domain) has a generated
			// domain; any other date (expiry, last sale) keeps its observed
			// values, otherwise we would invent rows.
			isPeriod = bucket == "dow" || bucket == "hour" || (f.Key == dateField && !rs.All)
			if isPeriod && cp.dateDim < 0 {
				cp.dateDim = i
			}
		}
		cp.dims = append(cp.dims, dimC{field: f, bucket: bucket, expr: expr, key: fmt.Sprintf("d%d", i), isPeriod: isPeriod})
	}

	// ---- mesures
	if len(sp.Measures) == 0 {
		return nil, bad("ajoutez au moins une mesure")
	}
	if len(sp.Measures) > 12 {
		return nil, bad("12 mesures au maximum")
	}
	for _, m := range sp.Measures {
		if m.As != "" && !aliasRe.MatchString(m.As) {
			return nil, bad("alias invalide : %q", m.As)
		}
		mc := measC{key: fmt.Sprintf("m%d", len(cp.meas)), as: m.As, share: m.Share, cum: m.Cumulative}
		switch {
		case m.Name != "":
			n := src.named(m.Name)
			if n == nil {
				return nil, bad("mesure inconnue : %s", m.Name)
			}
			if !c.allowed(n.GatedBy) {
				cp.dropped = append(cp.dropped, n.LabelFR)
				continue
			}
			mc.sqlExp, mc.label, mc.format, mc.unit, mc.field = n.sql, n.LabelFR, n.Format, n.Unit, n.Key
		case m.Field != "":
			f := src.field(m.Field)
			if f == nil || !f.Measure {
				return nil, bad("champ non mesurable : %s", m.Field)
			}
			if !c.allowed(f.GatedBy) {
				cp.dropped = append(cp.dropped, f.LabelFR)
				continue
			}
			agg := strings.ToLower(m.Agg)
			if agg == "" {
				agg = "sum"
			}
			ok := false
			for _, a := range f.Aggs {
				if a == agg {
					ok = true
				}
			}
			if agg == "count" || agg == "count_distinct" {
				ok = true
			}
			if !ok {
				return nil, bad("agrégat %s non autorisé sur %s", agg, m.Field)
			}
			switch agg {
			case "count":
				mc.sqlExp = fmt.Sprintf("COUNT(%s)", f.expr)
				mc.format, mc.unit = "integer", "count"
			case "count_distinct":
				mc.sqlExp = fmt.Sprintf("COUNT(DISTINCT %s)", f.expr)
				mc.format, mc.unit = "integer", "count"
			case "avg":
				mc.sqlExp = fmt.Sprintf("AVG(%s)", f.expr)
				mc.format, mc.unit = f.Format, f.Unit
			default:
				mc.sqlExp = fmt.Sprintf("%s(%s)", strings.ToUpper(agg), f.expr)
				mc.format, mc.unit = f.Format, f.Unit
			}
			mc.label = aggLabel(agg) + f.LabelFR
			mc.field = f.Key
		default:
			return nil, bad("mesure vide")
		}
		if m.As != "" {
			mc.label = m.As
		}
		cp.meas = append(cp.meas, mc)
	}
	if len(cp.meas) == 0 {
		return nil, forbid("aucune des mesures demandées n'est disponible pour votre rôle")
	}

	// ---- period
	if dateField != "" && !rs.All {
		f := src.field(dateField)
		if f == nil || (f.Type != "date" && f.Type != "datetime") {
			return nil, bad("champ de période invalide : %s", dateField)
		}
		col := f.expr
		if f.Type == "datetime" {
			col = fmt.Sprintf("date(%s,'localtime')", col)
		}
		cp.where = append(cp.where, fmt.Sprintf("%s BETWEEN ? AND ?", col))
		cp.args = append(cp.args, rs.From, rs.To)
	}

	// ---- filtres
	if len(sp.Filters) > 20 {
		return nil, bad("20 filtres au maximum")
	}
	for _, fl := range sp.Filters {
		f := src.field(fl.Field)
		if f == nil || !f.Filterable {
			return nil, bad("filtre inconnu : %s", fl.Field)
		}
		if !c.allowed(f.GatedBy) {
			return nil, forbid("« %s » n'est pas disponible pour votre rôle", f.LabelFR)
		}
		clause, args, err := filterSQL(f, fl)
		if err != nil {
			return nil, err
		}
		cp.where = append(cp.where, clause)
		cp.args = append(cp.args, args...)
	}

	// ---- having
	for _, h := range sp.Having {
		mc := cp.findMeasure(h.Measure)
		if mc == nil {
			// guarded named measure? explicit refusal rather than an ignored filter
			if n := src.named(h.Measure); n != nil && !c.allowed(n.GatedBy) {
				return nil, forbid("filtre sur « %s » : non disponible pour votre rôle", n.LabelFR)
			}
			if f := src.field(h.Measure); f != nil && !c.allowed(f.GatedBy) {
				return nil, forbid("filtre sur « %s » : non disponible pour votre rôle", f.LabelFR)
			}
			return nil, bad("filtre sur une mesure absente de la requête : %s", h.Measure)
		}
		clause, args, err := havingSQL(mc.sqlExp, h)
		if err != nil {
			return nil, err
		}
		cp.having = append(cp.having, clause)
		cp.hargs = append(cp.hargs, args...)
	}

	// ---- tri
	var order []string
	for _, s := range sp.Sort {
		dir := "ASC"
		if strings.EqualFold(s.Dir, "desc") {
			dir = "DESC"
		}
		if d := cp.findDim(s.Field); d != nil {
			order = append(order, d.key+" "+dir)
		} else if m := cp.findMeasure(s.Field); m != nil {
			order = append(order, m.key+" "+dir)
		} else {
			return nil, bad("tri sur un champ absent de la requête : %s", s.Field)
		}
	}
	if len(order) == 0 {
		if cp.dateDim >= 0 {
			order = append(order, cp.dims[cp.dateDim].key+" ASC")
		} else if len(cp.meas) > 0 {
			order = append(order, cp.meas[0].key+" DESC")
		}
	}
	cp.orderBy = strings.Join(order, ", ")

	cp.limit = sp.Limit
	if cp.limit <= 0 {
		cp.limit = 500
	}
	if cp.limit > 5000 {
		cp.limit = 5000
	}
	cp.zeroFill = cp.dateDim >= 0 && (sp.ZeroFill == nil || *sp.ZeroFill)
	return cp, nil
}

func aggLabel(agg string) string {
	switch agg {
	case "avg":
		return "Moyenne · "
	case "min":
		return "Min · "
	case "max":
		return "Max · "
	case "count":
		return "Nombre · "
	case "count_distinct":
		return "Distincts · "
	}
	return ""
}

func (cp *compiled) findMeasure(ref string) *measC {
	for i := range cp.meas {
		m := &cp.meas[i]
		if ref == m.key || (m.as != "" && ref == m.as) || ref == m.field {
			return m
		}
	}
	return nil
}
func (cp *compiled) findDim(ref string) *dimC {
	for i := range cp.dims {
		d := &cp.dims[i]
		if ref == d.key || ref == d.field.Key || ref == d.field.Key+":"+d.bucket {
			return d
		}
	}
	return nil
}

func escapeLike(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `%`, `\%`)
	s = strings.ReplaceAll(s, `_`, `\_`)
	return s
}

func filterSQL(f *Field, fl Filter) (string, []any, error) {
	op := strings.ToLower(fl.Op)
	allowed := false
	for _, o := range f.Ops {
		if o == op {
			allowed = true
		}
	}
	if !allowed {
		return "", nil, bad("opérateur %s non autorisé sur %s", op, f.Key)
	}
	col := f.expr
	if f.Type == "datetime" {
		col = fmt.Sprintf("date(%s,'localtime')", col)
	}
	scalar := func(v any) (any, error) {
		switch f.Type {
		case "number":
			switch x := v.(type) {
			case float64:
				return x, nil
			case string:
				var n float64
				if _, err := fmt.Sscanf(strings.TrimSpace(x), "%g", &n); err == nil {
					return n, nil
				}
			}
			return nil, bad("valeur numérique attendue pour %s", f.Key)
		case "bool":
			switch x := v.(type) {
			case bool:
				if x {
					return 1, nil
				}
				return 0, nil
			case float64:
				return int(x), nil
			case string:
				if x == "1" || strings.EqualFold(x, "true") || strings.EqualFold(x, "oui") {
					return 1, nil
				}
				return 0, nil
			}
			return nil, bad("valeur booléenne attendue pour %s", f.Key)
		case "date", "datetime":
			s, ok := v.(string)
			if !ok || len(s) != 10 {
				return nil, bad("date YYYY-MM-DD attendue pour %s", f.Key)
			}
			return s, nil
		default:
			s, ok := v.(string)
			if !ok {
				s = fmt.Sprint(v)
			}
			if len(s) > 200 {
				return nil, bad("valeur trop longue pour %s", f.Key)
			}
			if f.Type == "enum" && len(f.EnumValues) > 0 {
				ok := false
				for _, ev := range f.EnumValues {
					if ev == s {
						ok = true
					}
				}
				if !ok {
					return nil, bad("valeur inconnue pour %s : %s", f.Key, s)
				}
			}
			return s, nil
		}
	}
	switch op {
	case "is_null":
		return fmt.Sprintf("(%s IS NULL OR %s = '')", col, col), nil, nil
	case "is_not_null":
		return fmt.Sprintf("(%s IS NOT NULL AND %s <> '')", col, col), nil, nil
	case "eq", "ne", "gt", "gte", "lt", "lte":
		v, err := scalar(fl.Value)
		if err != nil {
			return "", nil, err
		}
		sym := map[string]string{"eq": "=", "ne": "<>", "gt": ">", "gte": ">=", "lt": "<", "lte": "<="}[op]
		return fmt.Sprintf("%s %s ?", col, sym), []any{v}, nil
	case "between":
		arr, ok := fl.Value.([]any)
		if !ok || len(arr) != 2 {
			return "", nil, bad("between attend deux valeurs")
		}
		a, err := scalar(arr[0])
		if err != nil {
			return "", nil, err
		}
		b, err := scalar(arr[1])
		if err != nil {
			return "", nil, err
		}
		return fmt.Sprintf("%s BETWEEN ? AND ?", col), []any{a, b}, nil
	case "in", "not_in":
		arr, ok := fl.Value.([]any)
		if !ok || len(arr) == 0 {
			return "", nil, bad("liste de valeurs attendue")
		}
		if len(arr) > 500 {
			return "", nil, bad("500 valeurs au maximum")
		}
		var args []any
		ph := make([]string, 0, len(arr))
		for _, v := range arr {
			x, err := scalar(v)
			if err != nil {
				return "", nil, err
			}
			args = append(args, x)
			ph = append(ph, "?")
		}
		kw := "IN"
		if op == "not_in" {
			kw = "NOT IN"
		}
		return fmt.Sprintf("%s %s (%s)", col, kw, strings.Join(ph, ",")), args, nil
	case "contains", "starts_with", "ends_with":
		s, ok := fl.Value.(string)
		if !ok || s == "" {
			return "", nil, bad("texte attendu")
		}
		if len(s) > 200 {
			return "", nil, bad("texte trop long")
		}
		esc := escapeLike(s)
		switch op {
		case "contains":
			esc = "%" + esc + "%"
		case "starts_with":
			esc = esc + "%"
		default:
			esc = "%" + esc
		}
		return fmt.Sprintf(`%s LIKE ? ESCAPE '\'`, col), []any{esc}, nil
	}
	return "", nil, bad("opérateur inconnu : %s", op)
}

func havingSQL(expr string, h Having) (string, []any, error) {
	switch strings.ToLower(h.Op) {
	case "eq":
		return "(" + expr + ") = ?", []any{h.Value}, nil
	case "ne":
		return "(" + expr + ") <> ?", []any{h.Value}, nil
	case "gt":
		return "(" + expr + ") > ?", []any{h.Value}, nil
	case "gte":
		return "(" + expr + ") >= ?", []any{h.Value}, nil
	case "lt":
		return "(" + expr + ") < ?", []any{h.Value}, nil
	case "lte":
		return "(" + expr + ") <= ?", []any{h.Value}, nil
	case "between":
		return "(" + expr + ") BETWEEN ? AND ?", []any{h.Value, h.Value2}, nil
	}
	return "", nil, bad("opérateur de filtre sur mesure inconnu : %s", h.Op)
}

// SQL returns the aggregated query (without LIMIT if withLimit=false) and its arguments.
func (cp *compiled) SQL(withLimit bool) (string, []any) {
	var sel []string
	for _, d := range cp.dims {
		sel = append(sel, d.expr+" AS "+d.key)
	}
	for _, m := range cp.meas {
		sel = append(sel, m.sqlExp+" AS "+m.key)
	}
	var b strings.Builder
	var args []any
	b.WriteString("SELECT " + strings.Join(sel, ", ") + " FROM " + cp.fromSQL)
	args = append(args, cp.fromArgs...)
	if len(cp.where) > 0 {
		b.WriteString(" WHERE " + strings.Join(cp.where, " AND "))
		args = append(args, cp.args...)
	}
	if len(cp.dims) > 0 {
		var g []string
		for _, d := range cp.dims {
			g = append(g, d.key)
		}
		b.WriteString(" GROUP BY " + strings.Join(g, ", "))
	}
	if len(cp.having) > 0 {
		b.WriteString(" HAVING " + strings.Join(cp.having, " AND "))
		args = append(args, cp.hargs...)
	}
	if cp.orderBy != "" {
		b.WriteString(" ORDER BY " + cp.orderBy)
	}
	if withLimit {
		b.WriteString(" LIMIT ?")
		args = append(args, cp.limit+1)
	}
	return b.String(), args
}

func (cp *compiled) countSQL() (string, []any) {
	inner, args := cp.SQL(false)
	// strip the final ORDER BY for the count
	if i := strings.LastIndex(inner, " ORDER BY "); i > 0 {
		inner = inner[:i]
	}
	return "SELECT COUNT(*) FROM (" + inner + ")", args
}

// ---- gabarits -------------------------------------------------------------

func templateSQL(key string, rs Resolved, params map[string]int) (string, []any, error) {
	switch key {
	case "stock_snapshot":
		days := 90
		if v, ok := params["expiry_days"]; ok {
			if v < 1 || v > 3650 {
				return "", nil, bad("expiry_days doit être entre 1 et 3650")
			}
			days = v
		}
		mod := fmt.Sprintf("+%d days", days)
		return `SELECT s.*,
       exp.nearest_expiry,
       COALESCE(exp.qty_expiring, 0)   AS qty_expiring,
       COALESCE(exp.value_expiring, 0) AS value_expiring,
       COALESCE(exp.value_expired, 0)  AS value_expired,
       (exp.nearest_expiry IS NOT NULL AND exp.nearest_expiry <= date('now','localtime', ?)) AS is_expiring,
       (exp.nearest_expiry IS NOT NULL AND exp.nearest_expiry < date('now','localtime')) AS is_expired
  FROM v_stock_snapshot s
  LEFT JOIN (
    SELECT lot.product_id, lot.warehouse_id,
           MIN(lots.expiry_date) AS nearest_expiry,
           SUM(CASE WHEN lots.expiry_date <= date('now','localtime', ?) THEN lot.qty_milli ELSE 0 END) AS qty_expiring,
           SUM(CASE WHEN lots.expiry_date <= date('now','localtime', ?) THEN lot.qty_milli * lot.unit_cost / 1000 ELSE 0 END) AS value_expiring,
           SUM(CASE WHEN lots.expiry_date <  date('now','localtime')    THEN lot.qty_milli * lot.unit_cost / 1000 ELSE 0 END) AS value_expired
      FROM (SELECT product_id, warehouse_id, lot_id,
                   SUM(qty_delta_milli) AS qty_milli,
                   SUM(qty_delta_milli*unit_cost) / NULLIF(SUM(qty_delta_milli),0) AS unit_cost
              FROM stock_ledger WHERE lot_id IS NOT NULL
             GROUP BY product_id, warehouse_id, lot_id) lot
      JOIN lots ON lots.id = lot.lot_id
     WHERE lot.qty_milli > 0 AND lots.expiry_date IS NOT NULL AND lots.expiry_date <> ''
     GROUP BY lot.product_id, lot.warehouse_id
  ) exp ON exp.product_id = s.product_id AND exp.warehouse_id = s.warehouse_id`, []any{mod, mod, mod}, nil
	case "product_performance":
		from, to := "0000-01-01", "9999-12-31"
		if !rs.All {
			from, to = rs.From, rs.To
		}
		return `SELECT p.id AS product_id, p.name AS product_name, p.category_id, COALESCE(c.name,'') AS category_name,
       p.brand,
       COALESCE(s.qty,0) AS qty_sold, COALESCE(s.rev,0) AS revenue, COALESCE(s.marg,0) AS margin,
       s.last_sale AS last_sale_date,
       CASE WHEN s.last_sale IS NOT NULL THEN CAST(julianday(date('now','localtime')) - julianday(s.last_sale) AS INTEGER) END AS days_since_last_sale,
       COALESCE(b.qty,0) AS qty_purchased, b.last_purchase AS last_purchase_date,
       COALESCE(sl.qty,0) AS qty_on_hand, COALESCE(sl.avg_cost,0) AS avg_cost,
       COALESCE(sl.qty,0) * COALESCE(sl.avg_cost,0) / 1000 AS stock_value,
       (COALESCE(sl.qty,0) > 0) AS has_stock,
       -- écoulement = vendu / (stock initial + reçu) = vendu / (vendu + stock restant)
       CASE WHEN COALESCE(s.qty,0) + COALESCE(sl.qty,0) > 0
            THEN 1.0 * COALESCE(s.qty,0) / (COALESCE(s.qty,0) + COALESCE(sl.qty,0)) END AS sell_through,
       CASE WHEN COALESCE(s.qty,0) > 0
            THEN CAST(COALESCE(sl.qty,0) * 1.0 / (COALESCE(s.qty,0) / MAX(1.0, (julianday(?) - julianday(?) + 1))) AS INTEGER) END AS days_of_stock,
       (s.last_sale IS NULL) AS never_sold
  FROM products p
  LEFT JOIN product_categories c ON c.id = p.category_id
  LEFT JOIN (SELECT product_id, SUM(qty_milli) qty, SUM(line_ht) rev, SUM(margin_ht) marg, MAX(doc_date) last_sale
               FROM v_sale_lines WHERE doc_kind='sale' AND doc_date BETWEEN ? AND ?
              GROUP BY product_id) s ON s.product_id = p.id
  LEFT JOIN (SELECT product_id, SUM(qty_milli) qty, MAX(doc_date) last_purchase
               FROM v_purchase_lines WHERE doc_kind='purchase' AND doc_date BETWEEN ? AND ?
              GROUP BY product_id) b ON b.product_id = p.id
  LEFT JOIN (SELECT product_id, SUM(qty_milli) qty,
                    SUM(qty_milli*avg_cost)/NULLIF(SUM(qty_milli),0) AS avg_cost
               FROM stock_levels GROUP BY product_id) sl ON sl.product_id = p.id
 WHERE p.active = 1`, []any{to, from, from, to, from, to}, nil
	}
	return "", nil, bad("gabarit inconnu : %s", key)
}

// ---- execution ---------------------------------------------------------------

func (e *Engine) acquire(ctx context.Context) (func(), error) {
	select {
	case e.sem <- struct{}{}:
		return func() { <-e.sem }, nil
	case <-ctx.Done():
		return nil, timeoutErr()
	}
}

func (e *Engine) runRows(ctx context.Context, q string, args []any) ([][]any, error) {
	rows, err := e.db.QueryContext(ctx, q, args...)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, timeoutErr()
		}
		return nil, fmt.Errorf("requête : %w", err)
	}
	defer rows.Close()
	cols, _ := rows.Columns()
	var out [][]any
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		for i, v := range vals {
			if b, ok := v.([]byte); ok {
				vals[i] = string(b)
			}
		}
		out = append(out, vals)
	}
	if err := rows.Err(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, timeoutErr()
		}
		return nil, err
	}
	return out, nil
}

// Query runs a simple query.
func (e *Engine) Query(ctx context.Context, sp Spec, c Caller) (*Result, error) {
	start := time.Now()
	cp, err := e.compile(ctx, sp, c, nil)
	if err != nil {
		return nil, err
	}
	key := e.cacheKey(ctx, "q", sp, cp.rs, c)
	if r, ok := e.cache.get(key); ok {
		rc := *r
		rc.Cached = true
		return &rc, nil
	}
	release, err := e.acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	tctx, cancel := context.WithTimeout(ctx, e.timeout)
	defer cancel()

	res, err := e.execute(tctx, cp, sp, c)
	if err != nil {
		return nil, err
	}
	res.DurationMs = time.Since(start).Milliseconds()
	e.cache.put(key, res)
	return res, nil
}

func (e *Engine) execute(ctx context.Context, cp *compiled, sp Spec, c Caller) (*Result, error) {
	res := &Result{Range: cp.rs, Dropped: cp.dropped, Labels: map[string]map[string]string{}}
	for _, d := range cp.dims {
		label := d.field.LabelFR
		format := d.field.Format
		if d.bucket != "" {
			label += " (" + bucketFR(d.bucket) + ")"
			format = "text"
		}
		res.Columns = append(res.Columns, Column{Key: d.key, Kind: "dimension", Field: d.field.Key, Bucket: d.bucket, Label: label, Format: format})
	}
	for _, m := range cp.meas {
		res.Columns = append(res.Columns, Column{Key: m.key, Kind: "measure", Field: m.field, Label: m.label, Format: m.format, Unit: m.unit})
	}

	var rows [][]any
	if cp.zeroFill {
		q, args := cp.SQL(false)
		var err error
		rows, err = e.runRows(ctx, q, args)
		if err != nil {
			return nil, err
		}
		if len(rows) > 50000 {
			rows = rows[:50000]
		}
		rows = e.zeroFill(cp, rows)
		sortRows(rows, cp)
		res.TotalRows = len(rows)
		if len(rows) > cp.limit {
			rows = rows[:cp.limit]
			res.Truncated = true
		}
	} else {
		q, args := cp.SQL(true)
		var err error
		rows, err = e.runRows(ctx, q, args)
		if err != nil {
			return nil, err
		}
		if len(rows) > cp.limit {
			rows = rows[:cp.limit]
			res.Truncated = true
			cq, cargs := cp.countSQL()
			var n int
			if err := e.db.QueryRowContext(ctx, cq, cargs...).Scan(&n); err == nil {
				res.TotalRows = n
			} else {
				res.TotalRows = len(rows)
			}
		} else {
			res.TotalRows = len(rows)
		}
	}

	// ---- bucket labels
	for i, d := range cp.dims {
		if d.bucket == "dow" || d.bucket == "hour" || d.bucket == "month" || d.bucket == "week" {
			m := map[string]string{}
			for _, r := range rows {
				m[fmt.Sprint(r[i])] = bucketLabel(d.bucket, r[i])
			}
			res.Labels[d.key] = m
		}
	}

	// ---- comparison with the previous period
	if sp.Compare == "previous_period" || sp.Compare == "previous_year" {
		if cp.rs.All {
			return nil, bad("la comparaison exige une période bornée")
		}
		var prev Resolved
		if sp.Compare == "previous_year" {
			a, _ := time.Parse(dayFmt, cp.rs.From)
			b, _ := time.Parse(dayFmt, cp.rs.To)
			prev = Resolved{From: a.AddDate(-1, 0, 0).Format(dayFmt), To: b.AddDate(-1, 0, 0).Format(dayFmt)}
		} else {
			prev = cp.rs.Previous(e.Now().Location())
		}
		pcp, err := e.compile(ctx, sp, c, &prev)
		if err != nil {
			return nil, err
		}
		pq, pargs := pcp.SQL(false)
		prows, err := e.runRows(ctx, pq, pargs)
		if err != nil {
			return nil, err
		}
		if pcp.zeroFill {
			prows = e.zeroFill(pcp, prows)
			sortRows(prows, pcp)
		}
		rows = alignCompare(cp, pcp, rows, prows)
		res.PrevRange = &prev
		for _, m := range cp.meas {
			res.Columns = append(res.Columns,
				Column{Key: m.key + "_prev", Kind: "measure", Field: m.field, Label: m.label + " (période préc.)", Format: m.format, Unit: m.unit, Derived: "prev"},
				Column{Key: m.key + "_delta", Kind: "measure", Field: m.field, Label: "Δ " + m.label, Format: m.format, Unit: m.unit, Derived: "delta"},
				Column{Key: m.key + "_delta_pct", Kind: "measure", Field: m.field, Label: "Δ% " + m.label, Format: "percent", Unit: "percent", Derived: "delta_pct"},
			)
		}
	}

	// ---- share of total / running total
	nd := len(cp.dims)
	for i, m := range cp.meas {
		col := nd + i
		if m.share {
			var total float64
			for _, r := range rows {
				total += toF(r[col])
			}
			for ri := range rows {
				var v any
				if total != 0 {
					v = toF(rows[ri][col]) / total
				}
				rows[ri] = append(rows[ri], v)
			}
			res.Columns = append(res.Columns, Column{Key: m.key + "_share", Kind: "measure", Field: m.field, Label: m.label + " (part)", Format: "percent", Unit: "percent", Derived: "share"})
		}
		if m.cum {
			var acc float64
			for ri := range rows {
				acc += toF(rows[ri][col])
				rows[ri] = append(rows[ri], acc)
			}
			res.Columns = append(res.Columns, Column{Key: m.key + "_cum", Kind: "measure", Field: m.field, Label: m.label + " (cumul)", Format: m.format, Unit: m.unit, Derived: "cum"})
		}
	}
	if rows == nil {
		rows = [][]any{}
	}
	res.Rows = rows
	return res, nil
}

func bucketFR(b string) string {
	return map[string]string{"day": "jour", "week": "semaine", "month": "mois", "quarter": "trimestre", "year": "année", "dow": "jour de semaine", "hour": "heure"}[b]
}

func toF(v any) float64 {
	switch x := v.(type) {
	case nil:
		return 0
	case int64:
		return float64(x)
	case int:
		return float64(x)
	case float64:
		return x
	case string:
		var f float64
		fmt.Sscanf(x, "%g", &f)
		return f
	}
	return 0
}

func keyOf(v any) string {
	switch x := v.(type) {
	case nil:
		return "\x00"
	case int64:
		return fmt.Sprintf("%d", x)
	case float64:
		if x == float64(int64(x)) {
			return fmt.Sprintf("%d", int64(x))
		}
		return fmt.Sprintf("%g", x)
	}
	return fmt.Sprint(v)
}

// zeroFill: Cartesian product of all dimensions (full domain for
// date buckets, observed values for the others), measures at zero.
func (e *Engine) zeroFill(cp *compiled, rows [][]any) [][]any {
	nd := len(cp.dims)
	if nd == 0 {
		return rows
	}
	domains := make([][]any, nd)
	for i, d := range cp.dims {
		if d.isPeriod {
			dom := bucketDomain(d.bucket, cp.rs, cp.ws, e.Now().Location())
			if dom != nil {
				domains[i] = dom
				continue
			}
		}
		seen := map[string]bool{}
		for _, r := range rows {
			k := keyOf(r[i])
			if !seen[k] {
				seen[k] = true
				domains[i] = append(domains[i], r[i])
			}
		}
	}
	// add observed values outside the domain (out-of-range dates should not exist)
	total := 1
	for _, dom := range domains {
		total *= len(dom)
		if total > 50000 {
			return rows // too large: no fill
		}
	}
	index := map[string][]any{}
	for _, r := range rows {
		var kb strings.Builder
		for i := 0; i < nd; i++ {
			kb.WriteString(keyOf(r[i]))
			kb.WriteByte('|')
		}
		index[kb.String()] = r
	}
	nm := len(cp.meas)
	var out [][]any
	var rec func(i int, prefix []any, key string)
	rec = func(i int, prefix []any, key string) {
		if i == nd {
			if r, ok := index[key]; ok {
				out = append(out, r)
				return
			}
			r := make([]any, nd+nm)
			copy(r, prefix)
			for j := 0; j < nm; j++ {
				r[nd+j] = int64(0)
			}
			out = append(out, r)
			return
		}
		for _, v := range domains[i] {
			rec(i+1, append(prefix, v), key+keyOf(v)+"|")
		}
	}
	rec(0, nil, "")
	return out
}

func sortRows(rows [][]any, cp *compiled) {
	if cp.orderBy == "" {
		return
	}
	type ord struct {
		col  int
		desc bool
	}
	var ords []ord
	for _, part := range strings.Split(cp.orderBy, ", ") {
		f := strings.Fields(part)
		if len(f) != 2 {
			continue
		}
		col := -1
		for i, d := range cp.dims {
			if d.key == f[0] {
				col = i
			}
		}
		for i, m := range cp.meas {
			if m.key == f[0] {
				col = len(cp.dims) + i
			}
		}
		if col >= 0 {
			ords = append(ords, ord{col, f[1] == "DESC"})
		}
	}
	sort.SliceStable(rows, func(a, b int) bool {
		for _, o := range ords {
			va, vb := rows[a][o.col], rows[b][o.col]
			c := compareAny(va, vb)
			if c == 0 {
				continue
			}
			if o.desc {
				return c > 0
			}
			return c < 0
		}
		return false
	})
}

func compareAny(a, b any) int {
	sa, aStr := a.(string)
	sb, bStr := b.(string)
	if aStr && bStr {
		return strings.Compare(sa, sb)
	}
	if aStr != bStr {
		if a == nil {
			return -1
		}
		if b == nil {
			return 1
		}
		return strings.Compare(fmt.Sprint(a), fmt.Sprint(b))
	}
	fa, fb := toF(a), toF(b)
	switch {
	case fa < fb:
		return -1
	case fa > fb:
		return 1
	}
	return 0
}

// alignCompare: aligns the previous period on the current one — by bucket
// position when the first dimension is a date bucket, by value otherwise.
func alignCompare(cp, pcp *compiled, rows, prows [][]any) [][]any {
	nd, nm := len(cp.dims), len(cp.meas)
	rest := func(r []any, from int) string {
		var b strings.Builder
		for i := from; i < nd; i++ {
			b.WriteString(keyOf(r[i]))
			b.WriteByte('|')
		}
		return b.String()
	}
	prevIx := map[string][]any{}
	if cp.dateDim == 0 && nd > 0 {
		// bucket position in the domain
		curDom := bucketDomain(cp.dims[0].bucket, cp.rs, cp.ws, time.Local)
		prevDom := bucketDomain(pcp.dims[0].bucket, pcp.rs, pcp.ws, time.Local)
		pos := map[string]int{}
		for i, v := range prevDom {
			pos[keyOf(v)] = i
		}
		curPos := map[string]int{}
		for i, v := range curDom {
			curPos[keyOf(v)] = i
		}
		for _, r := range prows {
			if i, ok := pos[keyOf(r[0])]; ok {
				prevIx[fmt.Sprintf("%d|", i)+rest(r, 1)] = r
			}
		}
		for ri, r := range rows {
			var pr []any
			if i, ok := curPos[keyOf(r[0])]; ok {
				pr = prevIx[fmt.Sprintf("%d|", i)+rest(r, 1)]
			}
			rows[ri] = appendCompare(r, pr, nd, nm)
		}
		return rows
	}
	for _, r := range prows {
		prevIx[rest(r, 0)] = r
	}
	for ri, r := range rows {
		rows[ri] = appendCompare(r, prevIx[rest(r, 0)], nd, nm)
	}
	return rows
}

func appendCompare(r, pr []any, nd, nm int) []any {
	for j := 0; j < nm; j++ {
		cur := toF(r[nd+j])
		var prev any
		var delta, pct any
		if pr != nil {
			pv := toF(pr[nd+j])
			prev = pv
			delta = cur - pv
			if pv != 0 {
				pct = (cur - pv) / pv
			}
		}
		r = append(r, prev, delta, pct)
	}
	return r
}

// ---- cross queries -----------------------------------------------------------

func (e *Engine) Combo(ctx context.Context, rq Request, c Caller) (*Result, error) {
	start := time.Now()
	if len(rq.Sources) != 2 {
		return nil, bad("une requête croisée porte sur exactement deux sources")
	}
	a, b := rq.Sources[0], rq.Sources[1]
	for _, s := range rq.Sources {
		if !aliasRe.MatchString(s.Name) {
			return nil, bad("nom de source invalide : %q", s.Name)
		}
	}
	if a.Name == b.Name {
		return nil, bad("les deux sources doivent porter des noms différents")
	}
	allowed, ok := comboPairs[comboKey(a.Source, b.Source)]
	if !ok {
		return nil, bad("combinaison non prise en charge : %s + %s", a.Source, b.Source)
	}
	if len(rq.JoinOn) == 0 || len(rq.JoinOn) > 2 {
		return nil, bad("join_on : une ou deux dimensions communes")
	}
	// common dimensions: same fields on both sides; dates must carry
	// the same bucket and map to each source's date field.
	dimsA, dimsB := make([]string, 0), make([]string, 0)
	for _, j := range rq.JoinOn {
		key, bucket := j, ""
		if k := strings.Index(j, ":"); k > 0 {
			key, bucket = j[:k], j[k+1:]
		}
		isDate := key == "date"
		permitted := false
		for _, p := range allowed {
			if p == key {
				permitted = true
			}
		}
		if !permitted {
			return nil, bad("jointure sur %s non autorisée pour cette combinaison", key)
		}
		if isDate {
			if bucket == "" {
				bucket = "month"
			}
			dimsA = append(dimsA, sources[a.Source].DateField+":"+bucket)
			dimsB = append(dimsB, sources[b.Source].DateField+":"+bucket)
		} else {
			dimsA = append(dimsA, key)
			dimsB = append(dimsB, key)
		}
	}
	rs, err := rq.Range.Resolve(e.Now(), e.weekStart(ctx))
	if err != nil {
		return nil, bad("%v", err)
	}
	specA := Spec{Source: a.Source, Dimensions: dimsA, Measures: a.Measures, Filters: a.Filters, Params: a.Params, Limit: 5000}
	specB := Spec{Source: b.Source, Dimensions: dimsB, Measures: b.Measures, Filters: b.Filters, Params: b.Params, Limit: 5000}
	cpA, err := e.compile(ctx, specA, c, &rs)
	if err != nil {
		return nil, err
	}
	cpB, err := e.compile(ctx, specB, c, &rs)
	if err != nil {
		return nil, err
	}
	// client alias → engine alias (never in SQL)
	names := map[string]string{} // "src.alias" → "sX.mY"
	for si, cp := range []*compiled{cpA, cpB} {
		sname := rq.Sources[si].Name
		for _, m := range cp.meas {
			if m.as != "" {
				names[sname+"."+m.as] = fmt.Sprintf("s%d.%s", si, m.key)
			}
			names[sname+"."+m.field] = fmt.Sprintf("s%d.%s", si, m.key)
			names[sname+"."+m.key] = fmt.Sprintf("s%d.%s", si, m.key)
		}
	}
	type cm struct {
		node   exprNode
		format string
		as     string
	}
	var combined []cm
	for _, cmr := range rq.CombinedMeasures {
		if !aliasRe.MatchString(cmr.As) {
			return nil, bad("alias invalide : %q", cmr.As)
		}
		if len(cmr.Expr) > 300 {
			return nil, bad("expression trop longue")
		}
		node, idents, err := parseExpr(cmr.Expr)
		if err != nil {
			return nil, bad("expression « %s » : %v", cmr.As, err)
		}
		for _, id := range idents {
			if _, ok := names[id]; !ok {
				return nil, bad("expression « %s » : mesure inconnue %s", cmr.As, id)
			}
		}
		format := cmr.Format
		switch format {
		case "currency", "quantity", "percent", "ratio", "integer":
		case "":
			format = "ratio"
		default:
			return nil, bad("format inconnu : %s", cmr.Format)
		}
		combined = append(combined, cm{node, format, cmr.As})
	}

	key := e.cacheKey(ctx, "c", rq, rs, c)
	if r, ok := e.cache.get(key); ok {
		rc := *r
		rc.Cached = true
		return &rc, nil
	}
	release, err := e.acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	tctx, cancel := context.WithTimeout(ctx, e.timeout)
	defer cancel()

	run := func(cp *compiled) ([][]any, error) {
		q, args := cp.SQL(false)
		rows, err := e.runRows(tctx, q, args)
		if err != nil {
			return nil, err
		}
		if len(rows) > 50000 {
			rows = rows[:50000]
		}
		if cp.zeroFill {
			rows = e.zeroFill(cp, rows)
		}
		return rows, nil
	}
	rowsA, err := run(cpA)
	if err != nil {
		return nil, err
	}
	rowsB, err := run(cpB)
	if err != nil {
		return nil, err
	}
	nd := len(cpA.dims)
	keyFn := func(r []any) string {
		var b strings.Builder
		for i := 0; i < nd; i++ {
			b.WriteString(keyOf(r[i]))
			b.WriteByte('|')
		}
		return b.String()
	}
	// union of keys, zero fill on both sides
	type merged struct {
		dims []any
		a, b []any
	}
	order := []string{}
	m := map[string]*merged{}
	for _, r := range rowsA {
		k := keyFn(r)
		m[k] = &merged{dims: r[:nd], a: r[nd:]}
		order = append(order, k)
	}
	for _, r := range rowsB {
		k := keyFn(r)
		if x, ok := m[k]; ok {
			x.b = r[nd:]
		} else {
			m[k] = &merged{dims: r[:nd], b: r[nd:]}
			order = append(order, k)
		}
	}
	res := &Result{Range: rs, Labels: map[string]map[string]string{}, Dropped: append(cpA.dropped, cpB.dropped...)}
	for i, d := range cpA.dims {
		label := d.field.LabelFR
		if d.bucket != "" {
			label += " (" + bucketFR(d.bucket) + ")"
		}
		res.Columns = append(res.Columns, Column{Key: fmt.Sprintf("d%d", i), Kind: "dimension", Field: d.field.Key, Bucket: d.bucket, Label: label, Format: "text"})
	}
	for si, cp := range []*compiled{cpA, cpB} {
		for _, mm := range cp.meas {
			res.Columns = append(res.Columns, Column{Key: fmt.Sprintf("s%d_%s", si, mm.key), Kind: "measure", Field: mm.field,
				Label: rq.Sources[si].Name + " · " + mm.label, Format: mm.format, Unit: mm.unit})
		}
	}
	for i, cmb := range combined {
		res.Columns = append(res.Columns, Column{Key: fmt.Sprintf("c%d", i), Kind: "measure", Field: cmb.as, Label: cmb.as, Format: cmb.format, Derived: "combined"})
	}
	nA, nB := len(cpA.meas), len(cpB.meas)
	var rows [][]any
	for _, k := range order {
		x := m[k]
		row := append([]any{}, x.dims...)
		vars := map[string]*float64{}
		for j := 0; j < nA; j++ {
			var v any = int64(0)
			if x.a != nil {
				v = x.a[j]
			}
			row = append(row, v)
			f := toF(v)
			vars[fmt.Sprintf("s0.m%d", j)] = &f
		}
		for j := 0; j < nB; j++ {
			var v any = int64(0)
			if x.b != nil {
				v = x.b[j]
			}
			row = append(row, v)
			f := toF(v)
			vars[fmt.Sprintf("s1.m%d", j)] = &f
		}
		// client → engine namespace
		cvars := map[string]*float64{}
		for cname, ename := range names {
			cvars[cname] = vars[ename]
		}
		for _, cmb := range combined {
			v, err := cmb.node.eval(cvars)
			if err != nil {
				return nil, bad("%v", err)
			}
			if v == nil {
				row = append(row, nil)
			} else {
				row = append(row, *v)
			}
		}
		rows = append(rows, row)
	}
	// sort: first combined measure desc, else dimension
	sortCol := nd
	desc := true
	if len(combined) > 0 {
		sortCol = nd + nA + nB
	} else if cpA.dateDim == 0 {
		sortCol, desc = 0, false
	}
	if len(rq.Sort) > 0 {
		for i, col := range res.Columns {
			if col.Key == rq.Sort[0].Field || col.Field == rq.Sort[0].Field {
				sortCol = i
				desc = strings.EqualFold(rq.Sort[0].Dir, "desc")
			}
		}
	}
	sort.SliceStable(rows, func(i, j int) bool {
		cmp := compareAny(rows[i][sortCol], rows[j][sortCol])
		if desc {
			return cmp > 0
		}
		return cmp < 0
	})
	for i, d := range cpA.dims {
		if d.bucket == "dow" || d.bucket == "hour" || d.bucket == "month" || d.bucket == "week" {
			lm := map[string]string{}
			for _, r := range rows {
				lm[fmt.Sprint(r[i])] = bucketLabel(d.bucket, r[i])
			}
			res.Labels[fmt.Sprintf("d%d", i)] = lm
		}
	}
	res.TotalRows = len(rows)
	limit := rq.Limit
	if limit <= 0 {
		limit = 500
	}
	if len(rows) > limit {
		rows = rows[:limit]
		res.Truncated = true
	}
	if rows == nil {
		rows = [][]any{}
	}
	res.Rows = rows
	res.DurationMs = time.Since(start).Milliseconds()
	e.cache.put(key, res)
	return res, nil
}

// Run dispatches simple / cross.
func (e *Engine) Run(ctx context.Context, rq Request, c Caller) (*Result, error) {
	if rq.Combo {
		return e.Combo(ctx, rq, c)
	}
	return e.Query(ctx, rq.Spec, c)
}

// ---- lot (tableau de bord) ----------------------------------------------------------

type BatchItem struct {
	ID      string  `json:"id"`
	Request Request `json:"request"`
}
type BatchRequest struct {
	Queries           []BatchItem `json:"queries"`
	GlobalRange       *Range      `json:"global_range,omitempty"`
	GlobalWarehouseID string      `json:"global_warehouse_id,omitempty"`
}
type BatchResult struct {
	ID     string            `json:"id"`
	OK     bool              `json:"ok"`
	Result *Result           `json:"result,omitempty"`
	Error  map[string]string `json:"error,omitempty"`
}

// Batch runs each tile under a global time budget; a failing tile
// never takes the others down.
func (e *Engine) Batch(ctx context.Context, br BatchRequest, c Caller) []BatchResult {
	if len(br.Queries) > 40 {
		br.Queries = br.Queries[:40]
	}
	bctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	out := make([]BatchResult, len(br.Queries))
	var wg sync.WaitGroup
	for i, item := range br.Queries {
		rq := item.Request
		if br.GlobalRange != nil {
			rq.Range = *br.GlobalRange
			if rq.Combo {
				rq.Spec.Range = *br.GlobalRange
			}
		}
		if br.GlobalWarehouseID != "" {
			f := Filter{Field: "warehouse_id", Op: "eq", Value: br.GlobalWarehouseID}
			if rq.Combo {
				for si := range rq.Sources {
					if sources[rq.Sources[si].Source] != nil && sources[rq.Sources[si].Source].field("warehouse_id") != nil {
						rq.Sources[si].Filters = append(rq.Sources[si].Filters, f)
					}
				}
			} else if s := sources[rq.Source]; s != nil && s.field("warehouse_id") != nil {
				rq.Filters = append(rq.Filters, f)
			}
		}
		wg.Add(1)
		go func(i int, id string, rq Request) {
			defer wg.Done()
			res, err := e.Run(bctx, rq, c)
			if err != nil {
				code, msg := "error", err.Error()
				var ae *Error
				if errors.As(err, &ae) {
					code, msg = ae.Code, ae.Message
				}
				if errors.Is(bctx.Err(), context.DeadlineExceeded) {
					code, msg = "budget_exceeded", "temps du tableau de bord dépassé — réessayez cette tuile"
				}
				out[i] = BatchResult{ID: id, OK: false, Error: map[string]string{"code": code, "message": msg}}
				return
			}
			out[i] = BatchResult{ID: id, OK: true, Result: res}
		}(i, item.ID, rq)
	}
	wg.Wait()
	return out
}

// ---- cache ------------------------------------------------------------------------

func (e *Engine) cacheKey(ctx context.Context, kind string, spec any, rs Resolved, c Caller) string {
	perms := make([]string, 0, len(c.Perms))
	for k, v := range c.Perms {
		if v {
			perms = append(perms, k)
		}
	}
	sort.Strings(perms)
	js, _ := json.Marshal(spec)
	h := sha256.Sum256([]byte(kind + "|" + string(js) + "|" + rs.From + "|" + rs.To + "|" + c.Role + "|" +
		strings.Join(perms, ",") + "|" + e.maxPostedAt(ctx)))
	return hex.EncodeToString(h[:])
}

type lru struct {
	mu   sync.Mutex
	cap  int
	m    map[string]*Result
	keys []string
	ttl  map[string]time.Time
}

func newLRU(n int) *lru { return &lru{cap: n, m: map[string]*Result{}, ttl: map[string]time.Time{}} }

func (l *lru) get(k string) (*Result, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	r, ok := l.m[k]
	if !ok {
		return nil, false
	}
	if time.Since(l.ttl[k]) > 10*time.Minute {
		delete(l.m, k)
		delete(l.ttl, k)
		return nil, false
	}
	return r, true
}

func (l *lru) put(k string, r *Result) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if _, ok := l.m[k]; !ok {
		l.keys = append(l.keys, k)
		if len(l.keys) > l.cap {
			old := l.keys[0]
			l.keys = l.keys[1:]
			delete(l.m, old)
			delete(l.ttl, old)
		}
	}
	l.m[k] = r
	l.ttl[k] = time.Now()
}

// MigrateSpec applies the rename table to saved reports built
// with an earlier version. Returns the updated spec and the list of
// fields that could not be found.
func MigrateSpec(raw json.RawMessage, fromVersion int) (json.RawMessage, []string) {
	if fromVersion >= SchemaVersion {
		return raw, nil
	}
	s := string(raw)
	for v := fromVersion + 1; v <= SchemaVersion; v++ {
		for old, nw := range renames[v] {
			s = strings.ReplaceAll(s, `"`+old+`"`, `"`+nw+`"`)
			s = strings.ReplaceAll(s, `"`+old+`:`, `"`+nw+`:`)
		}
	}
	var rq Request
	var missing []string
	if err := json.Unmarshal([]byte(s), &rq); err == nil {
		check := func(srcKey string, dims []string, meas []Measure, fils []Filter) {
			src := sources[srcKey]
			if src == nil {
				missing = append(missing, srcKey)
				return
			}
			for _, d := range dims {
				k := d
				if i := strings.Index(d, ":"); i > 0 {
					k = d[:i]
				}
				if src.field(k) == nil {
					missing = append(missing, k)
				}
			}
			for _, m := range meas {
				if m.Name != "" && src.named(m.Name) == nil {
					missing = append(missing, m.Name)
				}
				if m.Field != "" && src.field(m.Field) == nil {
					missing = append(missing, m.Field)
				}
			}
			for _, f := range fils {
				if src.field(f.Field) == nil {
					missing = append(missing, f.Field)
				}
			}
		}
		if rq.Combo {
			for _, cs := range rq.Sources {
				check(cs.Source, nil, cs.Measures, cs.Filters)
			}
		} else {
			check(rq.Source, rq.Dimensions, rq.Measures, rq.Filters)
		}
	}
	return json.RawMessage(s), missing
}
