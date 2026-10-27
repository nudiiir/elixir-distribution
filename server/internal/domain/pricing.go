package domain

import (
	"database/sql"
	"fmt"
	"time"
)

// Pricing of customer orders (distribution). Resolution order of a line's
// unit price:
//
//  1. customer's special price (customer_prices.partner_id), the highest
//     minimum-quantity tier reached, within a valid period;
//  2. special price of the customer's group (customer_prices.group_id), same;
//  3. customer's price list (group if any, otherwise customer record):
//     wholesale (price_wholesale) or retail (price_retail), replaced by the
//     product's promo price when active and lower; the group discount
//     then applies (not on a special price nor on a promo price);
//  4. promotional rules (promo_rules) active for the channel (desk|web),
//     the audience (all / group / customer) and the date: quantity discount
//     (kept if higher than the discount already obtained) and free units « N achetés +
//     M gratuits » (the most generous rule).
//
// Product prices include VAT; special prices and line prices exclude VAT.

// Price sources reported on order lines.
const (
	PriceSpecialPartner = "special_partner"
	PriceSpecialGroup   = "special_group"
	PriceWholesale      = "wholesale"
	PriceRetail         = "retail"
	PricePromo          = "promo"
	PriceManual         = "manual"
	PriceWeb            = "web"
	PriceBackorder      = "backorder"
)

// PriceQuote is the resolved price of a product for a customer and quantity.
type PriceQuote struct {
	ProductID     string `json:"product_id"`
	ProductName   string `json:"product_name"`
	QtyMilli      int64  `json:"qty_milli"`
	UnitPrice     int64  `json:"unit_price"`   // centimes HT
	DiscountPct   int64  `json:"discount_pct"` // ×100
	VatRate       int64  `json:"vat_rate"`
	Source        string `json:"price_source"`
	SpecialID     string `json:"special_price_id,omitempty"`
	FreeQtyMilli  int64  `json:"qty_free_milli"`
	PromoRuleID   string `json:"promo_rule_id,omitempty"`
	PromoRuleName string `json:"promo_rule_name,omitempty"`
	BasePriceTTC  int64  `json:"base_price_ttc"` // product price the level started from
	LineHT        int64  `json:"line_ht"`
	LineTTC       int64  `json:"line_ttc"`
}

// UnitHTFromTTC converts a TTC unit price to HT (half-up), like the POS does.
func UnitHTFromTTC(ttc, vat int64) int64 {
	return (ttc*10000 + (10000+vat)/2) / (10000 + vat)
}

// ChannelOf maps an order source to the promo channel.
func ChannelOf(source string) string {
	if source == "web" || source == "portal" {
		return "web"
	}
	return "desk"
}

type productPricing struct {
	name, categoryID, brand string
	vat, retail             int64
	wholesale, promo        sql.NullInt64
	promoStart, promoEnd    sql.NullString
	kind                    string
	active                  int64
}

func loadProductPricing(q Querier, productID string) (productPricing, error) {
	var p productPricing
	var cat sql.NullString
	err := q.QueryRow(`SELECT name, COALESCE(category_id,''), brand, vat_rate, price_retail, price_wholesale,
			promo_price, promo_start, promo_end, kind, active
		FROM products WHERE id = ?`, productID).Scan(&p.name, &cat, &p.brand, &p.vat, &p.retail,
		&p.wholesale, &p.promo, &p.promoStart, &p.promoEnd, &p.kind, &p.active)
	p.categoryID = cat.String
	if cat.Valid {
		p.categoryID = cat.String
	}
	return p, err
}

// ResolvePrice computes the price of `qty` units of a product for a customer
// on `date` (YYYY-MM-DD, "" = today) through `channel` (desk|web).
func ResolvePrice(q Queryer, partnerID, productID string, qty int64, date, channel string) (PriceQuote, error) {
	if date == "" {
		date = time.Now().Format("2006-01-02")
	}
	if channel == "" {
		channel = "desk"
	}
	p, err := loadProductPricing(q, productID)
	if err == sql.ErrNoRows {
		return PriceQuote{}, &PostError{"produit introuvable"}
	}
	if err != nil {
		return PriceQuote{}, err
	}
	pq := PriceQuote{ProductID: productID, ProductName: p.name, QtyMilli: qty, VatRate: p.vat}

	var groupID, partnerLevel string
	var groupLevel sql.NullString
	var groupPct int64
	if partnerID != "" {
		var g sql.NullString
		q.QueryRow(`SELECT p.group_id, p.price_level, g.price_level, COALESCE(g.discount_pct,0)
			FROM partners p LEFT JOIN customer_groups g ON g.id = p.group_id WHERE p.id = ?`, partnerID).
			Scan(&g, &partnerLevel, &groupLevel, &groupPct)
		groupID = g.String
	}

	special := func(col, owner string) (string, int64, bool) {
		var id string
		var price int64
		err := q.QueryRow(`SELECT id, price_ht FROM customer_prices
			WHERE `+col+` = ? AND product_id = ? AND min_qty_milli <= ?
			  AND (start_date IS NULL OR start_date = '' OR start_date <= ?)
			  AND (end_date IS NULL OR end_date = '' OR end_date >= ?)
			ORDER BY min_qty_milli DESC, price_ht ASC LIMIT 1`, owner, productID, qty, date, date).
			Scan(&id, &price)
		return id, price, err == nil
	}
	if id, price, ok := special("partner_id", partnerID); partnerID != "" && ok {
		pq.UnitPrice, pq.Source, pq.SpecialID = price, PriceSpecialPartner, id
	} else if id, price, ok := special("group_id", groupID); groupID != "" && ok {
		pq.UnitPrice, pq.Source, pq.SpecialID = price, PriceSpecialGroup, id
	} else {
		level := partnerLevel
		if groupLevel.Valid {
			level = groupLevel.String
		}
		base, src := p.retail, PriceRetail
		if level == "wholesale" && p.wholesale.Valid && p.wholesale.Int64 > 0 {
			base, src = p.wholesale.Int64, PriceWholesale
		}
		pq.BasePriceTTC = base
		promoOn := p.promo.Valid && p.promo.Int64 > 0 && p.promo.Int64 < base &&
			(!p.promoStart.Valid || p.promoStart.String == "" || p.promoStart.String <= date) &&
			(!p.promoEnd.Valid || p.promoEnd.String == "" || p.promoEnd.String >= date)
		if promoOn {
			base, src = p.promo.Int64, PricePromo
		} else {
			pq.DiscountPct = groupPct
		}
		pq.UnitPrice, pq.Source = UnitHTFromTTC(base, p.vat), src
	}

	if err := applyPromoRules(q, &pq, partnerID, groupID, p, qty, date, channel, true); err != nil {
		return pq, err
	}
	pq.LineHT, _, pq.LineTTC = LineTotals(pq.UnitPrice, qty, pq.DiscountPct, pq.VatRate)
	return pq, nil
}

// PromoRule is one row of promo_rules.
type PromoRule struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Scope        string `json:"scope"`
	ProductID    string `json:"product_id"`
	CategoryID   string `json:"category_id"`
	Brand        string `json:"brand"`
	Type         string `json:"type"`
	MinQtyMilli  int64  `json:"min_qty_milli"`
	FreeQtyMilli int64  `json:"free_qty_milli"`
	DiscountPct  int64  `json:"discount_pct"`
}

// FreeGoods returns the free units a free_goods rule gives for qty.
func (r PromoRule) FreeGoods(qty int64) int64 {
	if r.Type != "free_goods" || r.MinQtyMilli <= 0 || qty < r.MinQtyMilli {
		return 0
	}
	return (qty / r.MinQtyMilli) * r.FreeQtyMilli
}

// matchingPromoRules lists the active rules of a product for a customer,
// date and channel.
func matchingPromoRules(q Queryer, partnerID, groupID string, p productPricing, productID, date, channel string) ([]PromoRule, error) {
	rows, err := q.Query(`SELECT id, name, scope, COALESCE(product_id,''), COALESCE(category_id,''), brand,
			type, min_qty_milli, free_qty_milli, discount_pct
		FROM promo_rules
		WHERE active = 1
		  AND (start_date IS NULL OR start_date = '' OR start_date <= ?)
		  AND (end_date IS NULL OR end_date = '' OR end_date >= ?)
		  AND (channel = 'all' OR channel = ?)
		  AND (scope = 'all' OR (scope = 'product' AND product_id = ?)
		       OR (scope = 'category' AND category_id = ? AND ? <> '')
		       OR (scope = 'brand' AND brand <> '' AND LOWER(brand) = LOWER(?)))
		  AND (audience = 'all' OR (audience = 'group' AND group_id = ? AND ? <> '')
		       OR (audience = 'partner' AND partner_id = ? AND ? <> ''))
		ORDER BY created_at`, date, date, channel, productID, p.categoryID, p.categoryID, p.brand,
		groupID, groupID, partnerID, partnerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PromoRule
	for rows.Next() {
		var r PromoRule
		if err := rows.Scan(&r.ID, &r.Name, &r.Scope, &r.ProductID, &r.CategoryID, &r.Brand,
			&r.Type, &r.MinQtyMilli, &r.FreeQtyMilli, &r.DiscountPct); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// applyPromoRules adds the best quantity discount (when withDiscount) and the
// most generous free goods for qty.
func applyPromoRules(q Queryer, pq *PriceQuote, partnerID, groupID string, p productPricing,
	qty int64, date, channel string, withDiscount bool) error {
	rules, err := matchingPromoRules(q, partnerID, groupID, p, pq.ProductID, date, channel)
	if err != nil {
		return err
	}
	var bestFree int64
	for _, r := range rules {
		switch r.Type {
		case "qty_discount":
			if withDiscount && qty >= r.MinQtyMilli && r.DiscountPct > pq.DiscountPct {
				pq.DiscountPct = r.DiscountPct
				pq.PromoRuleID, pq.PromoRuleName = r.ID, r.Name
			}
		case "free_goods":
			if f := r.FreeGoods(qty); f > bestFree {
				bestFree = f
				pq.PromoRuleID, pq.PromoRuleName = r.ID, r.Name
			}
		}
	}
	pq.FreeQtyMilli = bestFree
	return nil
}

// FreeGoodsFor returns the free units the promo rules give for qty (used when
// the quantity changes at validation / preparation).
func FreeGoodsFor(q Queryer, partnerID, productID string, qty int64, date, channel string) (int64, string, error) {
	p, err := loadProductPricing(q, productID)
	if err != nil {
		return 0, "", nil
	}
	var g sql.NullString
	if partnerID != "" {
		q.QueryRow(`SELECT group_id FROM partners WHERE id = ?`, partnerID).Scan(&g)
	}
	pq := PriceQuote{ProductID: productID}
	if err := applyPromoRules(q, &pq, partnerID, g.String, p, qty, date, channel, false); err != nil {
		return 0, "", err
	}
	return pq.FreeQtyMilli, pq.PromoRuleID, nil
}

// ---- Quotas -------------------------------------------------------------------

// PeriodStart returns the first day (YYYY-MM-DD, local) of the quota period
// containing `now`.
func PeriodStart(period string, now time.Time) string {
	d := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	switch period {
	case "week":
		wd := int(d.Weekday())
		if wd == 0 {
			wd = 7
		}
		d = d.AddDate(0, 0, -(wd - 1))
	case "month":
		d = time.Date(d.Year(), d.Month(), 1, 0, 0, 0, 0, d.Location())
	}
	return d.Format("2006-01-02")
}

// QuotaRow is one quota applying to a customer, with its current usage.
type QuotaRow struct {
	ID          string `json:"id"`
	ProductID   string `json:"product_id"`
	ProductName string `json:"product_name"`
	PartnerID   string `json:"partner_id"` // "" = every customer
	MaxQtyMilli int64  `json:"max_qty_milli"`
	Period      string `json:"period"`
	PeriodStart string `json:"period_start"`
	UsedMilli   int64  `json:"used_milli"`
	RemainMilli int64  `json:"remaining_milli"`
}

var periodLabels = map[string]string{"day": "aujourd'hui", "week": "cette semaine", "month": "ce mois-ci"}

// QuotaUsage is what a customer already took of a product since `from`:
// the validated quantity of his orders past « new » (cancelled excluded).
func QuotaUsage(q Querier, partnerID, productID, from, excludeOrderID string) int64 {
	var used sql.NullInt64
	q.QueryRow(`SELECT SUM(l.qty_validated_milli) FROM customer_order_lines l
		JOIN customer_orders o ON o.id = l.order_id
		WHERE o.partner_id = ? AND l.product_id = ? AND o.order_date >= ? AND o.id <> ?
		  AND o.status NOT IN ('new','cancelled')`, partnerID, productID, from, excludeOrderID).Scan(&used)
	return used.Int64
}

// QuotasFor lists the active quotas applying to a customer (his own first,
// then the « every customer » ones), with usage.
func QuotasFor(q Queryer, partnerID, productID string, now time.Time) ([]QuotaRow, error) {
	where := `qu.active = 1 AND (qu.partner_id = ? OR qu.partner_id IS NULL)`
	args := []any{partnerID}
	if productID != "" {
		where += ` AND qu.product_id = ?`
		args = append(args, productID)
	}
	rows, err := q.Query(`SELECT qu.id, qu.product_id, p.name, COALESCE(qu.partner_id,''), qu.max_qty_milli, qu.period
		FROM product_quotas qu JOIN products p ON p.id = qu.product_id
		WHERE `+where+` ORDER BY p.name, qu.partner_id IS NULL`, args...)
	if err != nil {
		return nil, err
	}
	var out []QuotaRow
	seen := map[string]bool{}
	for rows.Next() {
		var r QuotaRow
		if err := rows.Scan(&r.ID, &r.ProductID, &r.ProductName, &r.PartnerID, &r.MaxQtyMilli, &r.Period); err != nil {
			rows.Close()
			return nil, err
		}
		// A customer-specific quota replaces the general one for the same period.
		k := r.ProductID + "|" + r.Period
		if seen[k] {
			continue
		}
		seen[k] = true
		out = append(out, r)
	}
	rows.Close()
	for i := range out {
		r := &out[i]
		r.PeriodStart = PeriodStart(r.Period, now)
		r.UsedMilli = QuotaUsage(q, partnerID, r.ProductID, r.PeriodStart, "")
		r.RemainMilli = max(0, r.MaxQtyMilli-r.UsedMilli)
	}
	return out, nil
}

// checkQuotas refuses a validation that would exceed a quota.
func checkQuotas(tx *sql.Tx, partnerID, orderID string, perProduct map[string]int64, now time.Time) error {
	for pid, qty := range perProduct {
		if qty <= 0 {
			continue
		}
		quotas, err := QuotasFor(tx, partnerID, pid, now)
		if err != nil {
			return err
		}
		for _, qu := range quotas {
			used := QuotaUsage(tx, partnerID, pid, qu.PeriodStart, orderID)
			if used+qty > qu.MaxQtyMilli {
				return &PostError{fmt.Sprintf(
					"quota dépassé pour « %s » : %s déjà commandé(s) %s, maximum %s par client — il reste %s",
					qu.ProductName, fmtQtyMilli(used), periodLabels[qu.Period],
					fmtQtyMilli(qu.MaxQtyMilli), fmtQtyMilli(max(0, qu.MaxQtyMilli-used)))}
			}
		}
	}
	return nil
}
