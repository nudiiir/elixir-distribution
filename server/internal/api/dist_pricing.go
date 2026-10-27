package api

import (
	"database/sql"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

func (s *Server) routesPricing(r chi.Router) {
	r.Get("/pricing/resolve", s.resolvePrice)

	r.Get("/customer-prices", s.listCustomerPrices)
	r.Post("/customer-prices", s.createCustomerPrice)
	r.Put("/customer-prices/{id}", s.updateCustomerPrice)
	r.Delete("/customer-prices/{id}", s.deleteCustomerPrice)

	r.Get("/promo-rules", s.listPromoRules)
	r.Get("/promo-rules/web", s.webPromoRules)
	r.Post("/promo-rules", s.createPromoRule)
	r.Put("/promo-rules/{id}", s.updatePromoRule)
	r.Delete("/promo-rules/{id}", s.deletePromoRule)

	r.Get("/product-quotas", s.listQuotas)
	r.Get("/product-quotas/usage", s.quotaUsage)
	r.Post("/product-quotas", s.createQuota)
	r.Put("/product-quotas/{id}", s.updateQuota)
	r.Delete("/product-quotas/{id}", s.deleteQuota)
}

func validDate(v *string) bool {
	if v == nil || *v == "" {
		return true
	}
	_, err := time.Parse("2006-01-02", *v)
	return err == nil
}

func emptyNil(v *string) any {
	if v == nil || strings.TrimSpace(*v) == "" {
		return nil
	}
	return strings.TrimSpace(*v)
}

// resolvePrice: GET /pricing/resolve?partner_id&product_id&qty_milli&date&channel.
func (s *Server) resolvePrice(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.view", "pricing.view") {
		return
	}
	qp := r.URL.Query()
	pid := qp.Get("product_id")
	if pid == "" {
		writeFieldErr(w, http.StatusBadRequest, "product_id", "produit obligatoire")
		return
	}
	qty, _ := strconv.ParseInt(qp.Get("qty_milli"), 10, 64)
	if qty <= 0 {
		qty = 1000
	}
	channel := qp.Get("channel")
	if channel != "web" {
		channel = "desk"
	}
	pq, err := domain.ResolvePrice(s.db, qp.Get("partner_id"), pid, qty, qp.Get("date"), channel)
	if err != nil {
		writeDomainErr(w, err)
		return
	}
	quotas := []domain.QuotaRow{}
	if p := qp.Get("partner_id"); p != "" {
		if q, err := domain.QuotasFor(s.db, p, pid, time.Now()); err == nil && q != nil {
			quotas = q
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"quote": pq, "quotas": quotas})
}

// ---- Special prices ----------------------------------------------------------------

type CustomerPrice struct {
	ID          string  `json:"id"`
	PartnerID   *string `json:"partner_id"`
	PartnerName *string `json:"partner_name"`
	GroupID     *string `json:"group_id"`
	GroupName   *string `json:"group_name"`
	ProductID   string  `json:"product_id"`
	ProductName string  `json:"product_name"`
	PriceHT     int64   `json:"price_ht"`
	MinQtyMilli int64   `json:"min_qty_milli"`
	StartDate   *string `json:"start_date"`
	EndDate     *string `json:"end_date"`
	Notes       string  `json:"notes"`
	CreatedAt   string  `json:"created_at"`
	UpdatedAt   string  `json:"updated_at"`
}

const customerPriceSelect = `SELECT cp.id, cp.partner_id, pa.name, cp.group_id, g.name, cp.product_id, p.name,
	cp.price_ht, cp.min_qty_milli, cp.start_date, cp.end_date, cp.notes, cp.created_at, cp.updated_at
FROM customer_prices cp JOIN products p ON p.id = cp.product_id
LEFT JOIN partners pa ON pa.id = cp.partner_id LEFT JOIN customer_groups g ON g.id = cp.group_id`

func scanCustomerPrice(row interface{ Scan(...any) error }) (CustomerPrice, error) {
	var c CustomerPrice
	err := row.Scan(&c.ID, &c.PartnerID, &c.PartnerName, &c.GroupID, &c.GroupName, &c.ProductID, &c.ProductName,
		&c.PriceHT, &c.MinQtyMilli, &c.StartDate, &c.EndDate, &c.Notes, &c.CreatedAt, &c.UpdatedAt)
	return c, err
}

func (s *Server) listCustomerPrices(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.view", "orders.view") {
		return
	}
	qp := r.URL.Query()
	where, args := " WHERE 1=1", []any{}
	for param, col := range map[string]string{"partner_id": "cp.partner_id", "group_id": "cp.group_id", "product_id": "cp.product_id"} {
		if v := qp.Get(param); v != "" {
			where += " AND " + col + " = ?"
			args = append(args, v)
		}
	}
	if q := strings.TrimSpace(qp.Get("q")); q != "" {
		where += " AND (p.name LIKE ? OR COALESCE(pa.name,'') LIKE ? OR COALESCE(g.name,'') LIKE ?)"
		like := "%" + q + "%"
		args = append(args, like, like, like)
	}
	rows, err := s.db.Query(customerPriceSelect+where+` ORDER BY p.name, cp.min_qty_milli LIMIT 2000`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []CustomerPrice{}
	for rows.Next() {
		c, err := scanCustomerPrice(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, c)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type customerPriceInput struct {
	PartnerID   *string `json:"partner_id"`
	GroupID     *string `json:"group_id"`
	ProductID   string  `json:"product_id"`
	PriceHT     int64   `json:"price_ht"`
	MinQtyMilli int64   `json:"min_qty_milli"`
	StartDate   *string `json:"start_date"`
	EndDate     *string `json:"end_date"`
	Notes       string  `json:"notes"`
}

func (in *customerPriceInput) validate() (string, string) {
	hasP := in.PartnerID != nil && *in.PartnerID != ""
	hasG := in.GroupID != nil && *in.GroupID != ""
	if hasP == hasG {
		return "partner_id", "indiquez un client OU un groupe de clients"
	}
	if in.ProductID == "" {
		return "product_id", "produit obligatoire"
	}
	if in.PriceHT < 0 {
		return "price_ht", "le prix ne peut pas être négatif"
	}
	if in.MinQtyMilli < 0 {
		return "min_qty_milli", "quantité minimale invalide"
	}
	if !validDate(in.StartDate) || !validDate(in.EndDate) {
		return "start_date", "date au format AAAA-MM-JJ"
	}
	if in.StartDate != nil && in.EndDate != nil && *in.StartDate != "" && *in.EndDate != "" && *in.EndDate < *in.StartDate {
		return "end_date", "la date de fin précède la date de début"
	}
	return "", ""
}

func (s *Server) createCustomerPrice(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.edit") {
		return
	}
	var in customerPriceInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if f, msg := in.validate(); msg != "" {
		writeFieldErr(w, http.StatusBadRequest, f, msg)
		return
	}
	id, now := domain.NewID(), domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO customer_prices (id, partner_id, group_id, product_id, price_ht, min_qty_milli,
			start_date, end_date, notes, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, emptyNil(in.PartnerID), emptyNil(in.GroupID), in.ProductID, in.PriceHT, in.MinQtyMilli,
		emptyNil(in.StartDate), emptyNil(in.EndDate), in.Notes, now, now); err != nil {
		writeDomainErr(w, err)
		return
	}
	s.audit(r, "pricing.special_price", "customer_price", id, "prix spécial "+centimes(in.PriceHT)+" DA HT")
	s.respondCustomerPrice(w, id, http.StatusCreated)
}

func (s *Server) updateCustomerPrice(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.edit") {
		return
	}
	id := chi.URLParam(r, "id")
	var in customerPriceInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if f, msg := in.validate(); msg != "" {
		writeFieldErr(w, http.StatusBadRequest, f, msg)
		return
	}
	res, err := s.db.Exec(`UPDATE customer_prices SET partner_id=?, group_id=?, product_id=?, price_ht=?, min_qty_milli=?,
			start_date=?, end_date=?, notes=?, updated_at=? WHERE id=?`,
		emptyNil(in.PartnerID), emptyNil(in.GroupID), in.ProductID, in.PriceHT, in.MinQtyMilli,
		emptyNil(in.StartDate), emptyNil(in.EndDate), in.Notes, domain.NowISO(), id)
	if err != nil {
		writeDomainErr(w, err)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "prix spécial introuvable")
		return
	}
	s.audit(r, "pricing.special_price", "customer_price", id, "prix spécial modifié : "+centimes(in.PriceHT)+" DA HT")
	s.respondCustomerPrice(w, id, http.StatusOK)
}

func (s *Server) deleteCustomerPrice(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.edit") {
		return
	}
	s.deleteRow(w, r, "customer_prices", "prix spécial introuvable", "pricing.special_price")
}

func (s *Server) respondCustomerPrice(w http.ResponseWriter, id string, status int) {
	c, err := scanCustomerPrice(s.db.QueryRow(customerPriceSelect+` WHERE cp.id = ?`, id))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, c)
}

// deleteRow deletes /{id} from a table and answers {deleted: id}.
func (s *Server) deleteRow(w http.ResponseWriter, r *http.Request, table, notFound, action string) {
	id := chi.URLParam(r, "id")
	res, err := s.db.Exec(`DELETE FROM `+table+` WHERE id = ?`, id)
	if err != nil {
		writeDomainErr(w, err)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, notFound)
		return
	}
	if action != "" {
		s.audit(r, action, table, id, "supprimé")
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": id})
}

// ---- Promotions -----------------------------------------------------------------------

type PromoRuleOut struct {
	ID           string  `json:"id"`
	Name         string  `json:"name"`
	Scope        string  `json:"scope"`
	ProductID    *string `json:"product_id"`
	ProductName  *string `json:"product_name"`
	CategoryID   *string `json:"category_id"`
	CategoryName *string `json:"category_name"`
	Brand        string  `json:"brand"`
	Type         string  `json:"type"`
	MinQtyMilli  int64   `json:"min_qty_milli"`
	FreeQtyMilli int64   `json:"free_qty_milli"`
	DiscountPct  int64   `json:"discount_pct"`
	StartDate    *string `json:"start_date"`
	EndDate      *string `json:"end_date"`
	Audience     string  `json:"audience"`
	GroupID      *string `json:"group_id"`
	PartnerID    *string `json:"partner_id"`
	Channel      string  `json:"channel"`
	Active       bool    `json:"active"`
	Notes        string  `json:"notes"`
	Label        string  `json:"label"` // « 10 + 1 gratuit », « −5 % dès 20 »
	CreatedAt    string  `json:"created_at"`
	UpdatedAt    string  `json:"updated_at"`
}

const promoSelect = `SELECT r.id, r.name, r.scope, r.product_id, p.name, r.category_id, c.name, r.brand, r.type,
	r.min_qty_milli, r.free_qty_milli, r.discount_pct, r.start_date, r.end_date, r.audience, r.group_id,
	r.partner_id, r.channel, r.active, r.notes, r.created_at, r.updated_at
FROM promo_rules r LEFT JOIN products p ON p.id = r.product_id
LEFT JOIN product_categories c ON c.id = r.category_id`

func qtyText(m int64) string {
	s := strconv.FormatFloat(float64(m)/1000, 'f', 3, 64)
	s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	return strings.Replace(s, ".", ",", 1)
}

func scanPromo(row interface{ Scan(...any) error }) (PromoRuleOut, error) {
	var p PromoRuleOut
	var active int
	err := row.Scan(&p.ID, &p.Name, &p.Scope, &p.ProductID, &p.ProductName, &p.CategoryID, &p.CategoryName,
		&p.Brand, &p.Type, &p.MinQtyMilli, &p.FreeQtyMilli, &p.DiscountPct, &p.StartDate, &p.EndDate,
		&p.Audience, &p.GroupID, &p.PartnerID, &p.Channel, &active, &p.Notes, &p.CreatedAt, &p.UpdatedAt)
	p.Active = active == 1
	if p.Type == "free_goods" {
		p.Label = qtyText(p.MinQtyMilli) + " + " + qtyText(p.FreeQtyMilli) + " gratuit(s)"
	} else {
		p.Label = "−" + pctText(p.DiscountPct) + " % dès " + qtyText(p.MinQtyMilli)
	}
	return p, err
}

func (s *Server) queryPromos(where string, args ...any) ([]PromoRuleOut, error) {
	rows, err := s.db.Query(promoSelect+where+` ORDER BY r.active DESC, r.name`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []PromoRuleOut{}
	for rows.Next() {
		p, err := scanPromo(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, p)
	}
	return items, rows.Err()
}

func (s *Server) listPromoRules(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.view", "orders.view") {
		return
	}
	qp := r.URL.Query()
	where, args := " WHERE 1=1", []any{}
	if qp.Get("active") == "1" {
		where += " AND r.active = 1"
	}
	if v := qp.Get("product_id"); v != "" {
		where += " AND r.product_id = ?"
		args = append(args, v)
	}
	if v := qp.Get("type"); v != "" {
		where += " AND r.type = ?"
		args = append(args, v)
	}
	items, err := s.queryPromos(where, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// webPromoRules: GET /promo-rules/web — what the storefront may show: active
// today, channel all|web, audience all.
func (s *Server) webPromoRules(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.view", "orders.view", "webstore.view") {
		return
	}
	d := time.Now().Format("2006-01-02")
	items, err := s.queryPromos(` WHERE r.active = 1 AND r.channel IN ('all','web') AND r.audience = 'all'
		AND (r.start_date IS NULL OR r.start_date = '' OR r.start_date <= ?)
		AND (r.end_date IS NULL OR r.end_date = '' OR r.end_date >= ?)`, d, d)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "date": d})
}

type promoInput struct {
	Name         string  `json:"name"`
	Scope        string  `json:"scope"`
	ProductID    *string `json:"product_id"`
	CategoryID   *string `json:"category_id"`
	Brand        string  `json:"brand"`
	Type         string  `json:"type"`
	MinQtyMilli  int64   `json:"min_qty_milli"`
	FreeQtyMilli int64   `json:"free_qty_milli"`
	DiscountPct  int64   `json:"discount_pct"`
	StartDate    *string `json:"start_date"`
	EndDate      *string `json:"end_date"`
	Audience     string  `json:"audience"`
	GroupID      *string `json:"group_id"`
	PartnerID    *string `json:"partner_id"`
	Channel      string  `json:"channel"`
	Active       *bool   `json:"active"`
	Notes        string  `json:"notes"`
}

func (in *promoInput) validate() (string, string) {
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		return "name", "le nom de la promotion est obligatoire"
	}
	set := func(p *string) bool { return p != nil && *p != "" }
	switch in.Scope {
	case "product":
		if !set(in.ProductID) {
			return "product_id", "choisissez le produit"
		}
	case "category":
		if !set(in.CategoryID) {
			return "category_id", "choisissez la catégorie"
		}
	case "brand":
		if strings.TrimSpace(in.Brand) == "" {
			return "brand", "indiquez la marque"
		}
	case "all":
	default:
		return "scope", "portée invalide (product, category, brand ou all)"
	}
	switch in.Type {
	case "free_goods":
		if in.FreeQtyMilli <= 0 {
			return "free_qty_milli", "indiquez le nombre d'unités gratuites"
		}
	case "qty_discount":
		if in.DiscountPct <= 0 || in.DiscountPct > 10000 {
			return "discount_pct", "la remise va de 0,01 à 100 %"
		}
	default:
		return "type", "type invalide (free_goods ou qty_discount)"
	}
	if in.MinQtyMilli <= 0 {
		return "min_qty_milli", "la quantité minimale doit être positive"
	}
	if in.Audience == "" {
		in.Audience = "all"
	}
	switch in.Audience {
	case "all":
	case "group":
		if !set(in.GroupID) {
			return "group_id", "choisissez le groupe de clients"
		}
	case "partner":
		if !set(in.PartnerID) {
			return "partner_id", "choisissez le client"
		}
	default:
		return "audience", "public invalide (all, group ou partner)"
	}
	if in.Channel == "" {
		in.Channel = "all"
	}
	if in.Channel != "all" && in.Channel != "desk" && in.Channel != "web" {
		return "channel", "canal invalide (all, desk ou web)"
	}
	if !validDate(in.StartDate) || !validDate(in.EndDate) {
		return "start_date", "date au format AAAA-MM-JJ"
	}
	return "", ""
}

func (in *promoInput) args() []any {
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	var prod, cat, grp, part any
	if in.Scope == "product" {
		prod = emptyNil(in.ProductID)
	}
	if in.Scope == "category" {
		cat = emptyNil(in.CategoryID)
	}
	if in.Audience == "group" {
		grp = emptyNil(in.GroupID)
	}
	if in.Audience == "partner" {
		part = emptyNil(in.PartnerID)
	}
	free, disc := in.FreeQtyMilli, in.DiscountPct
	if in.Type == "free_goods" {
		disc = 0
	} else {
		free = 0
	}
	return []any{in.Name, in.Scope, prod, cat, strings.TrimSpace(in.Brand), in.Type, in.MinQtyMilli, free, disc,
		emptyNil(in.StartDate), emptyNil(in.EndDate), in.Audience, grp, part, in.Channel, b2i(active), in.Notes}
}

func (s *Server) createPromoRule(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.edit") {
		return
	}
	var in promoInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if f, msg := in.validate(); msg != "" {
		writeFieldErr(w, http.StatusBadRequest, f, msg)
		return
	}
	id, now := domain.NewID(), domain.NowISO()
	args := append([]any{id}, in.args()...)
	args = append(args, now, now)
	if _, err := s.db.Exec(`INSERT INTO promo_rules (id, name, scope, product_id, category_id, brand, type,
			min_qty_milli, free_qty_milli, discount_pct, start_date, end_date, audience, group_id, partner_id,
			channel, active, notes, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, args...); err != nil {
		writeDomainErr(w, err)
		return
	}
	s.audit(r, "pricing.promo", "promo_rule", id, "promotion « "+in.Name+" »")
	s.respondPromo(w, id, http.StatusCreated)
}

func (s *Server) updatePromoRule(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.edit") {
		return
	}
	id := chi.URLParam(r, "id")
	var in promoInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if f, msg := in.validate(); msg != "" {
		writeFieldErr(w, http.StatusBadRequest, f, msg)
		return
	}
	args := append(in.args(), domain.NowISO(), id)
	res, err := s.db.Exec(`UPDATE promo_rules SET name=?, scope=?, product_id=?, category_id=?, brand=?, type=?,
			min_qty_milli=?, free_qty_milli=?, discount_pct=?, start_date=?, end_date=?, audience=?, group_id=?,
			partner_id=?, channel=?, active=?, notes=?, updated_at=? WHERE id=?`, args...)
	if err != nil {
		writeDomainErr(w, err)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "promotion introuvable")
		return
	}
	s.audit(r, "pricing.promo", "promo_rule", id, "promotion modifiée « "+in.Name+" »")
	s.respondPromo(w, id, http.StatusOK)
}

func (s *Server) deletePromoRule(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.edit") {
		return
	}
	s.deleteRow(w, r, "promo_rules", "promotion introuvable", "pricing.promo")
}

func (s *Server) respondPromo(w http.ResponseWriter, id string, status int) {
	p, err := scanPromo(s.db.QueryRow(promoSelect+` WHERE r.id = ?`, id))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, p)
}

// ---- Quotas -----------------------------------------------------------------------------

type QuotaOut struct {
	ID          string  `json:"id"`
	ProductID   string  `json:"product_id"`
	ProductName string  `json:"product_name"`
	PartnerID   *string `json:"partner_id"`
	PartnerName *string `json:"partner_name"`
	MaxQtyMilli int64   `json:"max_qty_milli"`
	Period      string  `json:"period"`
	Active      bool    `json:"active"`
	Notes       string  `json:"notes"`
	CreatedAt   string  `json:"created_at"`
	UpdatedAt   string  `json:"updated_at"`
}

const quotaSelect = `SELECT q.id, q.product_id, p.name, q.partner_id, pa.name, q.max_qty_milli, q.period, q.active,
	q.notes, q.created_at, q.updated_at
FROM product_quotas q JOIN products p ON p.id = q.product_id LEFT JOIN partners pa ON pa.id = q.partner_id`

func scanQuota(row interface{ Scan(...any) error }) (QuotaOut, error) {
	var q QuotaOut
	var active int
	err := row.Scan(&q.ID, &q.ProductID, &q.ProductName, &q.PartnerID, &q.PartnerName, &q.MaxQtyMilli,
		&q.Period, &active, &q.Notes, &q.CreatedAt, &q.UpdatedAt)
	q.Active = active == 1
	return q, err
}

func (s *Server) listQuotas(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.view", "orders.view") {
		return
	}
	where, args := " WHERE 1=1", []any{}
	if v := r.URL.Query().Get("product_id"); v != "" {
		where += " AND q.product_id = ?"
		args = append(args, v)
	}
	if v := r.URL.Query().Get("partner_id"); v != "" {
		where += " AND (q.partner_id = ? OR q.partner_id IS NULL)"
		args = append(args, v)
	}
	rows, err := s.db.Query(quotaSelect+where+` ORDER BY p.name, q.partner_id IS NOT NULL`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []QuotaOut{}
	for rows.Next() {
		q, err := scanQuota(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, q)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// quotaUsage: GET /product-quotas/usage?partner_id=&product_id= — quotas that
// apply to the customer, with what he already took this period.
func (s *Server) quotaUsage(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.view", "orders.view") {
		return
	}
	p := r.URL.Query().Get("partner_id")
	if p == "" {
		writeFieldErr(w, http.StatusBadRequest, "partner_id", "client obligatoire")
		return
	}
	items, err := domain.QuotasFor(s.db, p, r.URL.Query().Get("product_id"), time.Now())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if items == nil {
		items = []domain.QuotaRow{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type quotaInput struct {
	ProductID   string  `json:"product_id"`
	PartnerID   *string `json:"partner_id"`
	MaxQtyMilli int64   `json:"max_qty_milli"`
	Period      string  `json:"period"`
	Active      *bool   `json:"active"`
	Notes       string  `json:"notes"`
}

func (in *quotaInput) validate() (string, string) {
	if in.ProductID == "" {
		return "product_id", "produit obligatoire"
	}
	if in.MaxQtyMilli <= 0 {
		return "max_qty_milli", "la quantité maximale doit être positive"
	}
	if in.Period != "day" && in.Period != "week" && in.Period != "month" {
		return "period", "période invalide (day, week ou month)"
	}
	return "", ""
}

func (s *Server) createQuota(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.edit") {
		return
	}
	var in quotaInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if f, msg := in.validate(); msg != "" {
		writeFieldErr(w, http.StatusBadRequest, f, msg)
		return
	}
	active := in.Active == nil || *in.Active
	id, now := domain.NewID(), domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO product_quotas (id, product_id, partner_id, max_qty_milli, period, active,
		notes, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`, id, in.ProductID, emptyNil(in.PartnerID),
		in.MaxQtyMilli, in.Period, b2i(active), in.Notes, now, now); err != nil {
		writeDomainErr(w, err)
		return
	}
	s.audit(r, "pricing.quota", "product_quota", id, "quota "+qtyText(in.MaxQtyMilli)+" / "+in.Period)
	s.respondQuota(w, id, http.StatusCreated)
}

func (s *Server) updateQuota(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.edit") {
		return
	}
	id := chi.URLParam(r, "id")
	var in quotaInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if f, msg := in.validate(); msg != "" {
		writeFieldErr(w, http.StatusBadRequest, f, msg)
		return
	}
	active := in.Active == nil || *in.Active
	res, err := s.db.Exec(`UPDATE product_quotas SET product_id=?, partner_id=?, max_qty_milli=?, period=?, active=?,
		notes=?, updated_at=? WHERE id=?`, in.ProductID, emptyNil(in.PartnerID), in.MaxQtyMilli, in.Period,
		b2i(active), in.Notes, domain.NowISO(), id)
	if err != nil {
		writeDomainErr(w, err)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "quota introuvable")
		return
	}
	s.respondQuota(w, id, http.StatusOK)
}

func (s *Server) deleteQuota(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "pricing.edit") {
		return
	}
	s.deleteRow(w, r, "product_quotas", "quota introuvable", "pricing.quota")
}

func (s *Server) respondQuota(w http.ResponseWriter, id string, status int) {
	q, err := scanQuota(s.db.QueryRow(quotaSelect+` WHERE q.id = ?`, id))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "quota introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, q)
}
