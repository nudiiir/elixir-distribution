package domain

import (
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Commandes clients (distribution). Une commande n'est pas un document : elle
// vit dans customer_orders / customer_order_lines et ne touche ni le stock ni
// le compte client. Ce sont le BL (DELIVERY_NOTE), la facture (SALE_INVOICE)
// et les encaissements (PAYMENT_IN) qu'elle génère qui passent par le moteur
// de validation (PostTx), dans la même transaction que le changement de
// statut. Chaque opération écrit un événement (customer_order_events) et
// marque web_status_dirty quand la commande vient de la boutique web.

// CustomerOrder is the numbering key of customer orders (settings
// number_CUSTOMER_ORDER_prefix|year|digits|reset, prefix CC by default).
const CustomerOrder = "CUSTOMER_ORDER"

// Order statuses.
const (
	OrderNew       = "new"
	OrderValidated = "validated"
	OrderPreparing = "preparing"
	OrderReady     = "ready"
	OrderShipping  = "shipping"
	OrderDelivered = "delivered"
	OrderInvoiced  = "invoiced"
	OrderCancelled = "cancelled"
)

// OrderStatuses is the kanban order.
var OrderStatuses = []string{OrderNew, OrderValidated, OrderPreparing, OrderReady,
	OrderShipping, OrderDelivered, OrderInvoiced, OrderCancelled}

// OrderStatusLabels names each status in plain French.
var OrderStatusLabels = map[string]string{
	OrderNew: "Nouvelle", OrderValidated: "Validée", OrderPreparing: "En préparation",
	OrderReady: "Prête", OrderShipping: "En livraison", OrderDelivered: "Livrée",
	OrderInvoiced: "Facturée", OrderCancelled: "Annulée",
}

// OrderTransitions lists the allowed status changes.
var OrderTransitions = map[string][]string{
	OrderNew:       {OrderValidated, OrderCancelled},
	OrderValidated: {OrderNew, OrderPreparing, OrderReady, OrderCancelled},
	OrderPreparing: {OrderReady, OrderCancelled},
	OrderReady:     {OrderPreparing, OrderShipping, OrderDelivered, OrderCancelled},
	OrderShipping:  {OrderReady, OrderDelivered, OrderCancelled},
	OrderDelivered: {OrderInvoiced},
	OrderInvoiced:  {},
	OrderCancelled: {},
}

// OrderSources accepted on orders.
var OrderSources = []string{"manual", "phone", "whatsapp", "rep", "web", "portal"}

func canTransition(from, to string) bool {
	for _, s := range OrderTransitions[from] {
		if s == to {
			return true
		}
	}
	return false
}

// OrderBlock is a validation refused by the credit / account checks: the
// caller may retry with an override when the user holds orders.override_credit.
type OrderBlock struct {
	Msg      string
	Warnings []string
}

func (e *OrderBlock) Error() string { return e.Msg }

// ---- Numbering ------------------------------------------------------------------

func loadOrderNumberFormat(q Querier) NumberFormat {
	f := NumberFormat{Prefix: "CC", IncludeYear: true, Digits: 6, ResetYearly: true}
	if v, ok := Setting(q, NumberSettingKey(CustomerOrder, "prefix")); ok {
		f.Prefix = strings.TrimSpace(v)
	}
	f.IncludeYear = SettingBool(q, NumberSettingKey(CustomerOrder, "year"), true)
	if d := SettingInt(q, NumberSettingKey(CustomerOrder, "digits"), 6); d >= 4 && d <= 8 {
		f.Digits = int(d)
	}
	f.ResetYearly = SettingBool(q, NumberSettingKey(CustomerOrder, "reset"), true)
	return f.Normalized()
}

// nextOrderNumber draws the next customer order number (never reused).
func nextOrderNumber(tx *sql.Tx, date string) (string, error) {
	year := 0
	if len(date) >= 4 {
		year, _ = strconv.Atoi(date[:4])
	}
	if year == 0 {
		year = time.Now().Year()
	}
	f := loadOrderNumberFormat(tx)
	key := f.SeqYear(year)
	if _, err := tx.Exec(`INSERT INTO sequences (doc_type, year, next_number) VALUES (?, ?, 1)
		ON CONFLICT (doc_type, year) DO NOTHING`, CustomerOrder, key); err != nil {
		return "", err
	}
	var n int64
	if err := tx.QueryRow(`SELECT next_number FROM sequences WHERE doc_type=? AND year=?`,
		CustomerOrder, key).Scan(&n); err != nil {
		return "", err
	}
	if n < 1 {
		n = 1
	}
	number := f.Format(year, n)
	for tries := 0; tries < 100000; tries++ {
		var taken int
		tx.QueryRow(`SELECT COUNT(*) FROM customer_orders WHERE number = ?`, number).Scan(&taken)
		if taken == 0 {
			break
		}
		n++
		number = f.Format(year, n)
	}
	_, err := tx.Exec(`UPDATE sequences SET next_number = ? WHERE doc_type=? AND year=?`, n+1, CustomerOrder, key)
	return number, err
}

// ---- Rows ---------------------------------------------------------------------------

type orderHead struct {
	id, number, status, partnerID, source, warehouseID, orderDate string
	externalRef                                                   sql.NullString
	deliveryNoteID, invoiceID, paymentID                          sql.NullString
	shippingFee, extraDiscount, totalTTC                          int64
	paymentMode, promoCode                                        string
}

func loadOrderHead(tx Queryer, id string) (*orderHead, error) {
	var o orderHead
	err := tx.QueryRow(`SELECT id, number, status, partner_id, source, warehouse_id, order_date,
			external_ref, delivery_note_id, invoice_id, payment_id, shipping_fee, extra_discount, total_ttc,
			payment_mode, promo_code
		FROM customer_orders WHERE id = ?`, id).Scan(&o.id, &o.number, &o.status, &o.partnerID,
		&o.source, &o.warehouseID, &o.orderDate, &o.externalRef, &o.deliveryNoteID, &o.invoiceID,
		&o.paymentID, &o.shippingFee, &o.extraDiscount, &o.totalTTC, &o.paymentMode, &o.promoCode)
	if err == sql.ErrNoRows {
		return nil, &NotFoundError{"commande introuvable"}
	}
	if err != nil {
		return nil, err
	}
	return &o, nil
}

// NotFoundError is a 404 with a French message.
type NotFoundError struct{ Msg string }

func (e *NotFoundError) Error() string { return e.Msg }

type orderLine struct {
	id, productID, description, priceSource                  string
	ordered, validated, prepared, delivered, backorder, free int64
	unitPrice, discount, vat                                 int64
	productName                                              string
	isService                                                bool
}

func loadOrderLines(tx Queryer, orderID string) ([]orderLine, error) {
	rows, err := tx.Query(`SELECT l.id, l.product_id, l.description, l.price_source,
			l.qty_ordered_milli, l.qty_validated_milli, l.qty_prepared_milli, l.qty_delivered_milli,
			l.qty_backorder_milli, l.qty_free_milli, l.unit_price, l.discount_pct, l.vat_rate,
			p.name, p.kind = 'service'
		FROM customer_order_lines l JOIN products p ON p.id = l.product_id
		WHERE l.order_id = ? ORDER BY l.position, l.created_at`, orderID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []orderLine
	for rows.Next() {
		var l orderLine
		if err := rows.Scan(&l.id, &l.productID, &l.description, &l.priceSource, &l.ordered,
			&l.validated, &l.prepared, &l.delivered, &l.backorder, &l.free, &l.unitPrice,
			&l.discount, &l.vat, &l.productName, &l.isService); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// OrderEvent writes one history row (and flags the storefront sync when the
// status of a web order changed).
func OrderEvent(tx *sql.Tx, orderID, action, from, to, userID, note string) error {
	var fromV, toV any
	if from != "" {
		fromV = from
	}
	if to != "" {
		toV = to
	}
	_, err := tx.Exec(`INSERT INTO customer_order_events (id, order_id, action, from_status, to_status, user_id, note, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, NewID(), orderID, action, fromV, toV, nullIfEmpty(userID), note, NowISO())
	return err
}

// setOrderStatus moves an order and records the event.
func setOrderStatus(tx *sql.Tx, o *orderHead, to, action, userID, note string) error {
	if o.status == to {
		return OrderEvent(tx, o.id, action, "", "", userID, note)
	}
	if !canTransition(o.status, to) {
		return &PostError{fmt.Sprintf("la commande %s est « %s » : passage à « %s » impossible",
			o.number, OrderStatusLabels[o.status], OrderStatusLabels[to])}
	}
	dirty := ""
	if o.source == "web" || o.source == "portal" {
		dirty = ", web_status_dirty = 1"
	}
	if _, err := tx.Exec(`UPDATE customer_orders SET status = ?, updated_at = ?`+dirty+` WHERE id = ?`,
		to, NowISO(), o.id); err != nil {
		return err
	}
	from := o.status
	o.status = to
	return OrderEvent(tx, o.id, action, from, to, userID, note)
}

// RecalcOrder recomputes line and order totals and the backorder flag. The
// billed quantity of a line is the ordered one while the order is « new »,
// the validated one afterwards (after the BL: the paid part that left).
func RecalcOrder(tx *sql.Tx, orderID string) error {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	lines, err := loadOrderLines(tx, orderID)
	if err != nil {
		return err
	}
	var ht, vat, ttc, disc int64
	anyBackorder := false
	for _, l := range lines {
		qty := l.validated
		if o.status == OrderNew {
			qty = l.ordered
		}
		h, v, t := LineTotals(l.unitPrice, qty, l.discount, l.vat)
		ht, vat, ttc = ht+h, vat+v, ttc+t
		disc += LineDiscount(l.unitPrice, qty, l.discount)
		if l.backorder > 0 {
			anyBackorder = true
		}
		if _, err := tx.Exec(`UPDATE customer_order_lines SET line_ht=?, line_vat=?, line_ttc=? WHERE id=?`,
			h, v, t, l.id); err != nil {
			return err
		}
	}
	ttc += o.shippingFee - o.extraDiscount
	_, err = tx.Exec(`UPDATE customer_orders SET total_ht=?, total_vat=?, total_discount=?, total_ttc=?,
		has_backorder=?, updated_at=? WHERE id=?`, ht, vat, disc, ttc, b2iDom(anyBackorder), NowISO(), orderID)
	return err
}

func b2iDom(b bool) int {
	if b {
		return 1
	}
	return 0
}

// ---- Create / update ---------------------------------------------------------------

// OrderInput is a customer order as typed (desk, phone, rep) or imported.
type OrderInput struct {
	PartnerID       string
	Source          string
	OrderDate       string
	WarehouseID     string
	RepUserID       *string
	RouteID         *string
	Priority        int64
	PaymentMode     string
	RequestedDate   *string
	DeliveryAddress *string
	Wilaya          *string
	Commune         *string
	ContactName     *string
	ContactPhone    *string
	Notes           string
	InternalNotes   string
	ExternalRef     *string
	ExternalNumber  *string
	ShippingFee     int64
	ExtraDiscount   int64
	PromoCode       string
	Lines           []OrderLineInput
}

// OrderLineInput is one line; nil price/discount/free = resolved.
type OrderLineInput struct {
	ProductID           string
	QtyMilli            int64
	UnitPrice           *int64 // HT
	DiscountPct         *int64
	QtyFreeMilli        *int64
	Notes               string
	PriceSource         string // forced source (web, backorder)
	BackorderFromLineID string
	SubstitutedFromLine string
	SubstitutedFromProd string
}

func validSource(s string) bool {
	for _, v := range OrderSources {
		if v == s {
			return true
		}
	}
	return false
}

// CreateOrder inserts a new order (status « new ») with resolved prices.
func CreateOrder(tx *sql.Tx, in OrderInput, userID string) (string, string, error) {
	if in.Source == "" {
		in.Source = "manual"
	}
	if !validSource(in.Source) {
		return "", "", &PostError{"origine de commande invalide"}
	}
	if in.OrderDate == "" {
		in.OrderDate = time.Now().Format("2006-01-02")
	}
	var kind, pAddress, pWilaya, pCommune string
	var pPhone, pRep, pRoute sql.NullString
	var active int
	err := tx.QueryRow(`SELECT kind, active, COALESCE(address,''), wilaya, commune, phone, rep_user_id, route_id
		FROM partners WHERE id = ?`, in.PartnerID).Scan(&kind, &active, &pAddress, &pWilaya, &pCommune,
		&pPhone, &pRep, &pRoute)
	if err == sql.ErrNoRows || in.PartnerID == "" {
		return "", "", &PostError{"client introuvable"}
	}
	if err != nil {
		return "", "", err
	}
	if kind == "supplier" {
		return "", "", &PostError{"ce partenaire est un fournisseur : choisissez un client"}
	}
	if in.WarehouseID == "" {
		tx.QueryRow(`SELECT id FROM warehouses WHERE active = 1 ORDER BY is_default DESC, created_at LIMIT 1`).
			Scan(&in.WarehouseID)
	} else {
		var n int
		tx.QueryRow(`SELECT COUNT(*) FROM warehouses WHERE id = ?`, in.WarehouseID).Scan(&n)
		if n == 0 {
			return "", "", &PostError{"dépôt introuvable"}
		}
	}
	if in.PaymentMode == "" {
		in.PaymentMode = "account"
	}
	if in.PaymentMode != "account" && in.PaymentMode != "cod" {
		return "", "", &PostError{"mode de paiement invalide (account ou cod)"}
	}
	if in.Priority < 0 || in.Priority > 2 {
		return "", "", &PostError{"priorité invalide (0, 1 ou 2)"}
	}
	rep := pRep.String
	if in.RepUserID != nil {
		rep = *in.RepUserID
	}
	route := pRoute.String
	if in.RouteID != nil {
		route = *in.RouteID
	}
	str := func(p *string, def string) string {
		if p != nil {
			return strings.TrimSpace(*p)
		}
		return def
	}
	number, err := nextOrderNumber(tx, in.OrderDate)
	if err != nil {
		return "", "", err
	}
	id, now := NewID(), NowISO()
	var reqDate, extRef, extNum any
	if in.RequestedDate != nil && *in.RequestedDate != "" {
		reqDate = *in.RequestedDate
	}
	if in.ExternalRef != nil && strings.TrimSpace(*in.ExternalRef) != "" {
		extRef = strings.TrimSpace(*in.ExternalRef)
	}
	if in.ExternalNumber != nil && *in.ExternalNumber != "" {
		extNum = *in.ExternalNumber
	}
	if _, err := tx.Exec(`INSERT INTO customer_orders (id, number, order_date, partner_id, source, external_ref,
			external_number, status, warehouse_id, rep_user_id, route_id, priority, payment_mode, requested_date,
			delivery_address, wilaya, commune, contact_name, contact_phone, notes, internal_notes,
			shipping_fee, extra_discount, promo_code, web_status_dirty, created_by, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, 'new', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, number, in.OrderDate, in.PartnerID, in.Source, extRef, extNum, in.WarehouseID,
		nullIfEmpty(rep), nullIfEmpty(route), in.Priority, in.PaymentMode, reqDate,
		str(in.DeliveryAddress, pAddress), str(in.Wilaya, pWilaya), str(in.Commune, pCommune),
		str(in.ContactName, ""), str(in.ContactPhone, pPhone.String), in.Notes, in.InternalNotes,
		in.ShippingFee, in.ExtraDiscount, in.PromoCode, 0, nullIfEmpty(userID), now, now); err != nil {
		return "", "", err
	}
	if err := insertOrderLines(tx, id, in.PartnerID, in.OrderDate, ChannelOf(in.Source), 0, in.Lines); err != nil {
		return "", "", err
	}
	if err := RecalcOrder(tx, id); err != nil {
		return "", "", err
	}
	note := "commande créée"
	if in.Source != "manual" {
		note += " (" + in.Source + ")"
	}
	if err := OrderEvent(tx, id, "create", "", OrderNew, userID, note); err != nil {
		return "", "", err
	}
	return id, number, nil
}

// insertOrderLines resolves prices and inserts lines from position `pos`.
func insertOrderLines(tx *sql.Tx, orderID, partnerID, date, channel string, pos int, lines []OrderLineInput) error {
	now := NowISO()
	for i, l := range lines {
		if l.QtyMilli <= 0 {
			return &PostError{fmt.Sprintf("ligne %d : la quantité doit être positive", pos+i+1)}
		}
		var active int
		if err := tx.QueryRow(`SELECT active FROM products WHERE id = ?`, l.ProductID).Scan(&active); err != nil {
			return &PostError{fmt.Sprintf("ligne %d : produit introuvable", pos+i+1)}
		}
		pq, err := ResolvePrice(tx, partnerID, l.ProductID, l.QtyMilli, date, channel)
		if err != nil {
			return err
		}
		if active == 0 {
			return &PostError{fmt.Sprintf("« %s » est désactivé", pq.ProductName)}
		}
		src := pq.Source
		if l.UnitPrice != nil {
			if *l.UnitPrice < 0 {
				return &PostError{fmt.Sprintf("« %s » : prix négatif", pq.ProductName)}
			}
			if *l.UnitPrice != pq.UnitPrice {
				src = PriceManual
				pq.DiscountPct = 0
			}
			pq.UnitPrice = *l.UnitPrice
		}
		if l.DiscountPct != nil {
			if *l.DiscountPct < 0 || *l.DiscountPct > 10000 {
				return &PostError{fmt.Sprintf("« %s » : remise invalide", pq.ProductName)}
			}
			pq.DiscountPct = *l.DiscountPct
		}
		if l.QtyFreeMilli != nil {
			if *l.QtyFreeMilli < 0 {
				return &PostError{fmt.Sprintf("« %s » : quantité gratuite négative", pq.ProductName)}
			}
			pq.FreeQtyMilli = *l.QtyFreeMilli
		}
		if l.PriceSource != "" {
			src = l.PriceSource
		}
		if _, err := tx.Exec(`INSERT INTO customer_order_lines (id, order_id, position, product_id, description,
				qty_ordered_milli, qty_free_milli, unit_price, discount_pct, vat_rate, price_source, promo_rule_id,
				substituted_from_line_id, substituted_from_product_id, backorder_from_line_id, notes, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			NewID(), orderID, pos+i, l.ProductID, pq.ProductName, l.QtyMilli, pq.FreeQtyMilli,
			pq.UnitPrice, pq.DiscountPct, pq.VatRate, src, nullIfEmpty(pq.PromoRuleID),
			nullIfEmpty(l.SubstitutedFromLine), nullIfEmpty(l.SubstitutedFromProd),
			nullIfEmpty(l.BackorderFromLineID), l.Notes, now, now); err != nil {
			return err
		}
	}
	return nil
}

// UpdateOrder replaces the header (and the lines when in.Lines != nil) of an
// order still « new » or « validated ». Changing the lines of a validated
// order sends it back to « new » (it must be validated again).
func UpdateOrder(tx *sql.Tx, orderID string, in OrderInput, replaceLines bool, userID string) error {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	if o.status != OrderNew && o.status != OrderValidated {
		return &PostError{fmt.Sprintf("la commande %s est « %s » : seules les commandes nouvelles ou validées se modifient",
			o.number, OrderStatusLabels[o.status])}
	}
	if in.PaymentMode == "" {
		in.PaymentMode = o.paymentMode
	}
	if in.PaymentMode != "account" && in.PaymentMode != "cod" {
		return &PostError{"mode de paiement invalide (account ou cod)"}
	}
	if in.Priority < 0 || in.Priority > 2 {
		return &PostError{"priorité invalide (0, 1 ou 2)"}
	}
	if in.WarehouseID == "" {
		in.WarehouseID = o.warehouseID
	}
	if in.OrderDate == "" {
		in.OrderDate = o.orderDate
	}
	sets := []string{"order_date=?", "warehouse_id=?", "priority=?", "payment_mode=?", "notes=?",
		"internal_notes=?", "shipping_fee=?", "extra_discount=?", "promo_code=?", "updated_at=?"}
	args := []any{in.OrderDate, in.WarehouseID, in.Priority, in.PaymentMode, in.Notes, in.InternalNotes,
		in.ShippingFee, in.ExtraDiscount, in.PromoCode, NowISO()}
	opt := func(col string, v *string) {
		if v != nil {
			sets = append(sets, col+"=?")
			if col == "rep_user_id" || col == "route_id" || col == "requested_date" {
				args = append(args, nullIfEmpty(strings.TrimSpace(*v)))
			} else {
				args = append(args, strings.TrimSpace(*v))
			}
		}
	}
	opt("rep_user_id", in.RepUserID)
	opt("route_id", in.RouteID)
	opt("requested_date", in.RequestedDate)
	opt("delivery_address", in.DeliveryAddress)
	opt("wilaya", in.Wilaya)
	opt("commune", in.Commune)
	opt("contact_name", in.ContactName)
	opt("contact_phone", in.ContactPhone)
	if in.PartnerID != "" && in.PartnerID != o.partnerID {
		if o.status != OrderNew {
			return &PostError{"le client d'une commande validée ne peut pas changer"}
		}
		var kind string
		if err := tx.QueryRow(`SELECT kind FROM partners WHERE id = ?`, in.PartnerID).Scan(&kind); err != nil {
			return &PostError{"client introuvable"}
		}
		if kind == "supplier" {
			return &PostError{"ce partenaire est un fournisseur : choisissez un client"}
		}
		sets = append(sets, "partner_id=?")
		args = append(args, in.PartnerID)
		o.partnerID = in.PartnerID
	}
	args = append(args, orderID)
	if _, err := tx.Exec(`UPDATE customer_orders SET `+strings.Join(sets, ", ")+` WHERE id=?`, args...); err != nil {
		return err
	}
	note := "en-tête modifié"
	if replaceLines {
		var picks int
		tx.QueryRow(`SELECT COUNT(*) FROM customer_order_picks WHERE order_id = ?`, orderID).Scan(&picks)
		if picks > 0 {
			return &PostError{"des articles ont déjà été préparés : modifiez les lignes une à une"}
		}
		if _, err := tx.Exec(`DELETE FROM customer_order_lines WHERE order_id = ? AND id NOT IN
			(SELECT substituted_from_line_id FROM customer_order_lines WHERE substituted_from_line_id IS NOT NULL)
			AND id NOT IN (SELECT backorder_from_line_id FROM customer_order_lines WHERE backorder_from_line_id IS NOT NULL)`,
			orderID); err != nil {
			return err
		}
		var left int
		tx.QueryRow(`SELECT COUNT(*) FROM customer_order_lines WHERE order_id = ?`, orderID).Scan(&left)
		if left > 0 {
			// Lines referenced by a substitution or a backorder order stay (as
			// zero-quantity history) so the links remain valid.
			tx.Exec(`UPDATE customer_order_lines SET qty_ordered_milli=0, qty_validated_milli=0,
				qty_backorder_milli=0, qty_free_milli=0 WHERE order_id = ?`, orderID)
		}
		if err := insertOrderLines(tx, orderID, o.partnerID, in.OrderDate, ChannelOf(o.source), left, in.Lines); err != nil {
			return err
		}
		note = "commande modifiée"
		if o.status == OrderValidated {
			if err := reopenOrder(tx, o, userID, "lignes modifiées : la commande doit être validée à nouveau"); err != nil {
				return err
			}
		}
	}
	if err := RecalcOrder(tx, orderID); err != nil {
		return err
	}
	return OrderEvent(tx, orderID, "update", "", "", userID, note)
}

// reopenOrder sends a validated order back to « new »: validated quantities
// and backorders are cleared (they are recomputed at the next validation).
func reopenOrder(tx *sql.Tx, o *orderHead, userID, note string) error {
	if _, err := tx.Exec(`UPDATE customer_order_lines SET qty_validated_milli=0, qty_backorder_milli=0
		WHERE order_id=?`, o.id); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE customer_orders SET validated_by=NULL, validated_at=NULL, is_partial=0,
		credit_override=0 WHERE id=?`, o.id); err != nil {
		return err
	}
	return setOrderStatus(tx, o, OrderNew, "reopen", userID, note)
}

// ReopenOrder: POST /orders/{id}/reopen — validated → new.
func ReopenOrder(tx *sql.Tx, orderID, userID string) error {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	if o.status != OrderValidated {
		return &PostError{"seule une commande validée (non préparée) peut être rouverte"}
	}
	if err := reopenOrder(tx, o, userID, "commande rouverte pour modification"); err != nil {
		return err
	}
	return RecalcOrder(tx, orderID)
}

// LinePatch edits one line (nil = unchanged).
type LinePatch struct {
	QtyMilli     *int64
	UnitPrice    *int64
	DiscountPct  *int64
	QtyFreeMilli *int64
	Notes        *string
}

// PatchOrderLine edits a line of a new/validated order. On a validated order,
// a new quantity is re-validated at once against the available stock (the
// remainder goes to backorder).
func PatchOrderLine(tx *sql.Tx, orderID, lineID string, p LinePatch, userID string) error {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	if o.status != OrderNew && o.status != OrderValidated {
		return &PostError{fmt.Sprintf("la commande %s est « %s » : la ligne ne peut plus être modifiée",
			o.number, OrderStatusLabels[o.status])}
	}
	var productID, name, source string
	var ordered, validated, price, disc, free, prepared int64
	err = tx.QueryRow(`SELECT product_id, description, price_source, qty_ordered_milli, qty_validated_milli,
			unit_price, discount_pct, qty_free_milli, qty_prepared_milli
		FROM customer_order_lines WHERE id = ? AND order_id = ?`, lineID, orderID).
		Scan(&productID, &name, &source, &ordered, &validated, &price, &disc, &free, &prepared)
	if err == sql.ErrNoRows {
		return &NotFoundError{"ligne introuvable"}
	}
	if err != nil {
		return err
	}
	changes := []string{}
	if p.QtyMilli != nil && *p.QtyMilli != ordered {
		if *p.QtyMilli < 0 {
			return &PostError{"la quantité ne peut pas être négative"}
		}
		changes = append(changes, fmt.Sprintf("quantité %s → %s", fmtQtyMilli(ordered), fmtQtyMilli(*p.QtyMilli)))
		ordered = *p.QtyMilli
		if p.QtyFreeMilli == nil {
			f, rule, err := FreeGoodsFor(tx, o.partnerID, productID, ordered, o.orderDate, ChannelOf(o.source))
			if err != nil {
				return err
			}
			free = f
			tx.Exec(`UPDATE customer_order_lines SET promo_rule_id = ? WHERE id = ?`, nullIfEmpty(rule), lineID)
		}
	}
	if p.UnitPrice != nil && *p.UnitPrice != price {
		if *p.UnitPrice < 0 {
			return &PostError{"le prix ne peut pas être négatif"}
		}
		changes = append(changes, fmt.Sprintf("prix %s → %s", fmtDA(price), fmtDA(*p.UnitPrice)))
		price, source = *p.UnitPrice, PriceManual
	}
	if p.DiscountPct != nil && *p.DiscountPct != disc {
		if *p.DiscountPct < 0 || *p.DiscountPct > 10000 {
			return &PostError{"remise invalide"}
		}
		changes = append(changes, fmt.Sprintf("remise %d,%02d %%", *p.DiscountPct/100, *p.DiscountPct%100))
		disc = *p.DiscountPct
	}
	if p.QtyFreeMilli != nil {
		if *p.QtyFreeMilli < 0 {
			return &PostError{"quantité gratuite négative"}
		}
		free = *p.QtyFreeMilli
		changes = append(changes, "UG "+fmtQtyMilli(free))
	}
	notesSet, notesArg := "", []any{}
	if p.Notes != nil {
		notesSet, notesArg = ", notes = ?", []any{*p.Notes}
	}
	backorder := int64(0)
	if o.status == OrderValidated {
		avail := AvailableQty(tx, productID, o.warehouseID, orderID)
		if allowNegativeStock(tx) || productIsService(tx, productID) {
			avail = ordered
		}
		validated = min(ordered, max(0, avail))
		backorder = ordered - validated
		free = min(free, max(0, avail-validated))
	}
	args := append([]any{ordered, validated, backorder, price, disc, free, source}, notesArg...)
	args = append(args, NowISO(), lineID)
	if _, err := tx.Exec(`UPDATE customer_order_lines SET qty_ordered_milli=?, qty_validated_milli=?,
			qty_backorder_milli=?, unit_price=?, discount_pct=?, qty_free_milli=?, price_source=?`+notesSet+`,
			updated_at=? WHERE id=?`, args...); err != nil {
		return err
	}
	if err := RecalcOrder(tx, orderID); err != nil {
		return err
	}
	if len(changes) == 0 {
		changes = append(changes, "note")
	}
	return OrderEvent(tx, orderID, "edit_line", "", "", userID, name+" : "+strings.Join(changes, ", "))
}

// AddOrderLines appends lines to a new/validated order (validated: the new
// lines are validated at once against the available stock).
func AddOrderLines(tx *sql.Tx, orderID string, lines []OrderLineInput, userID string) error {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	if o.status != OrderNew && o.status != OrderValidated {
		return &PostError{fmt.Sprintf("la commande %s est « %s » : impossible d'ajouter une ligne",
			o.number, OrderStatusLabels[o.status])}
	}
	var pos int
	tx.QueryRow(`SELECT COALESCE(MAX(position)+1, 0) FROM customer_order_lines WHERE order_id = ?`, orderID).Scan(&pos)
	if err := insertOrderLines(tx, orderID, o.partnerID, o.orderDate, ChannelOf(o.source), pos, lines); err != nil {
		return err
	}
	if o.status == OrderValidated {
		if err := validateNewLines(tx, o, pos); err != nil {
			return err
		}
	}
	if err := RecalcOrder(tx, orderID); err != nil {
		return err
	}
	return OrderEvent(tx, orderID, "add_line", "", "", userID, fmt.Sprintf("%d ligne(s) ajoutée(s)", len(lines)))
}

// validateNewLines validates the lines from position `from` of a validated order.
func validateNewLines(tx *sql.Tx, o *orderHead, from int) error {
	lines, err := loadOrderLines(tx, o.id)
	if err != nil {
		return err
	}
	var ids []string
	rows, err := tx.Query(`SELECT id FROM customer_order_lines WHERE order_id = ? AND position >= ?`, o.id, from)
	if err != nil {
		return err
	}
	for rows.Next() {
		var id string
		rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()
	isNew := map[string]bool{}
	for _, id := range ids {
		isNew[id] = true
	}
	neg := allowNegativeStock(tx)
	for _, l := range lines {
		if !isNew[l.id] {
			continue
		}
		avail := AvailableQty(tx, l.productID, o.warehouseID, o.id)
		if neg || l.isService {
			avail = l.ordered + l.free
		}
		v := min(l.ordered, max(0, avail))
		f := min(l.free, max(0, avail-v))
		if _, err := tx.Exec(`UPDATE customer_order_lines SET qty_validated_milli=?, qty_backorder_milli=?, qty_free_milli=?
			WHERE id=?`, v, l.ordered-v, f, l.id); err != nil {
			return err
		}
	}
	return nil
}

// DeleteOrderLine removes a line of a new/validated order (no picks).
func DeleteOrderLine(tx *sql.Tx, orderID, lineID, userID string) error {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	if o.status != OrderNew && o.status != OrderValidated {
		return &PostError{fmt.Sprintf("la commande %s est « %s » : la ligne ne peut plus être supprimée",
			o.number, OrderStatusLabels[o.status])}
	}
	var name string
	if err := tx.QueryRow(`SELECT description FROM customer_order_lines WHERE id=? AND order_id=?`, lineID, orderID).
		Scan(&name); err != nil {
		return &NotFoundError{"ligne introuvable"}
	}
	var refs int
	tx.QueryRow(`SELECT COUNT(*) FROM customer_order_lines WHERE substituted_from_line_id = ? OR backorder_from_line_id = ?`,
		lineID, lineID).Scan(&refs)
	if refs > 0 {
		// Keep the row for the links, at zero quantity.
		if _, err := tx.Exec(`UPDATE customer_order_lines SET qty_ordered_milli=0, qty_validated_milli=0,
			qty_backorder_milli=0, qty_free_milli=0, updated_at=? WHERE id=?`, NowISO(), lineID); err != nil {
			return err
		}
	} else if _, err := tx.Exec(`DELETE FROM customer_order_lines WHERE id=?`, lineID); err != nil {
		return err
	}
	if err := RecalcOrder(tx, orderID); err != nil {
		return err
	}
	return OrderEvent(tx, orderID, "delete_line", "", "", userID, name+" : ligne supprimée")
}

// SubstituteLine replaces the product of a line (rupture → équivalent). The
// old line keeps its history at zero quantity; the new one points back to it.
func SubstituteLine(tx *sql.Tx, orderID, lineID, newProductID string, qty int64, keepPrice bool, userID string) (string, error) {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return "", err
	}
	if o.status != OrderNew && o.status != OrderValidated && o.status != OrderPreparing {
		return "", &PostError{fmt.Sprintf("la commande %s est « %s » : substitution impossible",
			o.number, OrderStatusLabels[o.status])}
	}
	var oldProduct, oldName string
	var ordered, price, disc, prepared, pos int64
	if err := tx.QueryRow(`SELECT product_id, description, qty_ordered_milli, unit_price, discount_pct,
			qty_prepared_milli, position FROM customer_order_lines WHERE id=? AND order_id=?`, lineID, orderID).
		Scan(&oldProduct, &oldName, &ordered, &price, &disc, &prepared, &pos); err != nil {
		return "", &NotFoundError{"ligne introuvable"}
	}
	if prepared > 0 {
		return "", &PostError{"cette ligne a déjà été préparée : retirez d'abord les prélèvements"}
	}
	if newProductID == oldProduct {
		return "", &PostError{"choisissez un autre produit pour la substitution"}
	}
	if qty <= 0 {
		qty = ordered
	}
	in := OrderLineInput{ProductID: newProductID, QtyMilli: qty, SubstitutedFromLine: lineID,
		SubstitutedFromProd: oldProduct}
	if keepPrice {
		in.UnitPrice, in.DiscountPct = &price, &disc
		in.PriceSource = PriceManual
	}
	if _, err := tx.Exec(`UPDATE customer_order_lines SET qty_ordered_milli=0, qty_validated_milli=0,
		qty_backorder_milli=0, qty_free_milli=0, updated_at=? WHERE id=?`, NowISO(), lineID); err != nil {
		return "", err
	}
	var maxPos int
	tx.QueryRow(`SELECT COALESCE(MAX(position)+1,0) FROM customer_order_lines WHERE order_id=?`, orderID).Scan(&maxPos)
	if err := insertOrderLines(tx, orderID, o.partnerID, o.orderDate, ChannelOf(o.source), maxPos, []OrderLineInput{in}); err != nil {
		return "", err
	}
	if o.status != OrderNew {
		if err := validateNewLines(tx, o, maxPos); err != nil {
			return "", err
		}
	}
	var newID, newName string
	tx.QueryRow(`SELECT id, description FROM customer_order_lines WHERE order_id=? AND position=?`, orderID, maxPos).
		Scan(&newID, &newName)
	if err := RecalcOrder(tx, orderID); err != nil {
		return "", err
	}
	return newID, OrderEvent(tx, orderID, "substitute", "", "", userID,
		fmt.Sprintf("%s remplacé par %s (%s)", oldName, newName, fmtQtyMilli(qty)))
}

// ---- Availability -------------------------------------------------------------------

// ReservedQty is what validated orders not yet shipped (no BL) hold of a
// product in a warehouse — paid and free units.
func ReservedQty(q Querier, productID, warehouseID, excludeOrderID string) int64 {
	var n sql.NullInt64
	q.QueryRow(`SELECT SUM(l.qty_validated_milli + l.qty_free_milli) FROM customer_order_lines l
		JOIN customer_orders o ON o.id = l.order_id
		WHERE l.product_id = ? AND o.warehouse_id = ? AND o.id <> ?
		  AND o.status IN ('validated','preparing','ready') AND o.delivery_note_id IS NULL`,
		productID, warehouseID, excludeOrderID).Scan(&n)
	return n.Int64
}

// StockQty is the level of a product in a warehouse.
func StockQty(q Querier, productID, warehouseID string) int64 {
	var n int64
	q.QueryRow(`SELECT qty_milli FROM stock_levels WHERE product_id=? AND warehouse_id=?`, productID, warehouseID).Scan(&n)
	return n
}

// AvailableQty = stock − what other open orders reserved (« disponible à la vente »).
func AvailableQty(q Querier, productID, warehouseID, excludeOrderID string) int64 {
	return StockQty(q, productID, warehouseID) - ReservedQty(q, productID, warehouseID, excludeOrderID)
}

// ---- Validation -----------------------------------------------------------------------

// ValidateOptions drive the validation of an order.
type ValidateOptions struct {
	OverrideCredit bool             // the user holds orders.override_credit and chose to pass
	NoPartial      bool             // refuse instead of moving shortages to backorder
	Lines          map[string]int64 // explicit validated quantity per line id
}

// ValidateResult reports what validation did.
type ValidateResult struct {
	Warnings   []string        `json:"warnings"`
	Backorders []BackorderInfo `json:"backorders"`
	Partial    bool            `json:"partial"`
}

// BackorderInfo is one line put (partly) in backorder.
type BackorderInfo struct {
	LineID      string `json:"line_id"`
	ProductID   string `json:"product_id"`
	ProductName string `json:"product_name"`
	QtyMilli    int64  `json:"qty_backorder_milli"`
}

// CreditWarnings lists the account problems of a customer for an order of
// `amount` TTC on top of what he already owes and has on order.
func CreditWarnings(tx Queryer, partnerID, orderID string, amount int64) ([]string, error) {
	var out []string
	var status, name string
	tx.QueryRow(`SELECT crm_status, name FROM partners WHERE id = ?`, partnerID).Scan(&status, &name)
	if status == "blocked" {
		out = append(out, "le client est bloqué (statut CRM « bloqué »)")
	}
	balance := PartnerBalance(tx, partnerID)
	var open sql.NullInt64
	tx.QueryRow(`SELECT SUM(total_ttc) FROM customer_orders WHERE partner_id = ? AND id <> ?
		AND status IN ('validated','preparing','ready','shipping','delivered')`, partnerID, orderID).Scan(&open)
	if limit := CreditLimitOf(tx, partnerID); limit > 0 && balance+open.Int64+amount > limit {
		out = append(out, fmt.Sprintf(
			"plafond de crédit dépassé : %s DA engagés (solde %s DA + commandes en cours %s DA + cette commande %s DA) pour un plafond de %s DA",
			fmtDA(balance+open.Int64+amount), fmtDA(balance), fmtDA(open.Int64), fmtDA(amount), fmtDA(limit)))
	}
	amt, n, err := OverdueOf(tx, partnerID)
	if err != nil {
		return nil, err
	}
	if n > 0 {
		out = append(out, fmt.Sprintf("%d facture(s) échue(s) impayée(s) : %s DA en retard", n, fmtDA(amt)))
	}
	return out, nil
}

// ValidateOrder validates a « new » order: availability (partial → backorder),
// free goods on the validated quantity, quotas (never overridable), then the
// credit / account check (overridable).
func ValidateOrder(tx *sql.Tx, orderID, userID string, opt ValidateOptions) (*ValidateResult, error) {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return nil, err
	}
	if o.status != OrderNew {
		return nil, &PostError{fmt.Sprintf("la commande %s est « %s » : elle ne peut pas être validée",
			o.number, OrderStatusLabels[o.status])}
	}
	lines, err := loadOrderLines(tx, orderID)
	if err != nil {
		return nil, err
	}
	res := &ValidateResult{Warnings: []string{}, Backorders: []BackorderInfo{}}
	neg := allowNegativeStock(tx)
	avail := map[string]int64{}
	perProduct := map[string]int64{}
	var shortages []string
	anyValid := false
	for i := range lines {
		l := &lines[i]
		if l.ordered <= 0 {
			l.validated, l.backorder, l.free = 0, 0, 0
			continue
		}
		a, seen := avail[l.productID]
		if !seen {
			a = AvailableQty(tx, l.productID, o.warehouseID, orderID)
		}
		if neg || l.isService {
			a = 1 << 50
		}
		want := l.ordered
		if v, ok := opt.Lines[l.id]; ok {
			if v < 0 || v > l.ordered {
				return nil, &PostError{fmt.Sprintf("« %s » : la quantité validée doit être entre 0 et la quantité commandée", l.productName)}
			}
			want = v
		}
		v := min(want, max(0, a))
		if v < want {
			shortages = append(shortages, fmt.Sprintf("« %s » : disponible %s, commandé %s",
				l.productName, fmtQtyMilli(max(0, a)), fmtQtyMilli(want)))
		}
		l.validated = v
		l.backorder = l.ordered - v
		f, _, err := FreeGoodsFor(tx, o.partnerID, l.productID, v, o.orderDate, ChannelOf(o.source))
		if err != nil {
			return nil, err
		}
		if l.priceSource == PriceManual || l.priceSource == PriceWeb {
			// A free quantity typed by hand (or sent by the storefront) is kept,
			// within what the validated quantity entitles to.
			if l.free > 0 && f == 0 {
				f = l.free
			}
		}
		f = min(f, max(0, a-v))
		l.free = f
		avail[l.productID] = a - v - f
		perProduct[l.productID] += v
		if v > 0 {
			anyValid = true
		}
		if l.backorder > 0 {
			res.Partial = true
			res.Backorders = append(res.Backorders, BackorderInfo{LineID: l.id, ProductID: l.productID,
				ProductName: l.productName, QtyMilli: l.backorder})
		}
	}
	if len(lines) == 0 {
		return nil, &PostError{"la commande n'a aucune ligne"}
	}
	if opt.NoPartial && len(shortages) > 0 {
		return nil, &PostError{"stock insuffisant : " + strings.Join(shortages, " ; ")}
	}
	if !anyValid {
		return nil, &PostError{"rien n'est disponible pour cette commande : " + strings.Join(shortages, " ; ")}
	}
	if err := checkQuotas(tx, o.partnerID, orderID, perProduct, time.Now()); err != nil {
		return nil, err
	}
	for _, l := range lines {
		if _, err := tx.Exec(`UPDATE customer_order_lines SET qty_validated_milli=?, qty_backorder_milli=?,
			qty_free_milli=?, updated_at=? WHERE id=?`, l.validated, l.backorder, l.free, NowISO(), l.id); err != nil {
			return nil, err
		}
	}
	// Totals on the validated quantities, then the account check.
	if _, err := tx.Exec(`UPDATE customer_orders SET status='validated' WHERE id=?`, orderID); err != nil {
		return nil, err
	}
	if err := RecalcOrder(tx, orderID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`UPDATE customer_orders SET status='new' WHERE id=?`, orderID); err != nil {
		return nil, err
	}
	var total int64
	tx.QueryRow(`SELECT total_ttc FROM customer_orders WHERE id=?`, orderID).Scan(&total)
	warnings, err := CreditWarnings(tx, o.partnerID, orderID, total)
	if err != nil {
		return nil, err
	}
	res.Warnings = append(res.Warnings, warnings...)
	if len(warnings) > 0 && !opt.OverrideCredit {
		return res, &OrderBlock{Msg: "validation bloquée : " + strings.Join(warnings, " ; "), Warnings: warnings}
	}
	now := NowISO()
	if _, err := tx.Exec(`UPDATE customer_orders SET validated_by=?, validated_at=?, is_partial=?,
		credit_override=?, updated_at=? WHERE id=?`, nullIfEmpty(userID), now, b2iDom(res.Partial),
		b2iDom(len(warnings) > 0), now, orderID); err != nil {
		return nil, err
	}
	note := "commande validée"
	if len(res.Backorders) > 0 {
		parts := []string{}
		for _, b := range res.Backorders {
			parts = append(parts, fmt.Sprintf("%s ×%s", b.ProductName, fmtQtyMilli(b.QtyMilli)))
		}
		note += " — reliquat : " + strings.Join(parts, ", ")
	}
	if len(warnings) > 0 {
		note += " — malgré : " + strings.Join(warnings, " ; ")
		auditTx(tx, userID, "order.credit_override", "customer_order", orderID,
			o.number+" validée malgré : "+strings.Join(warnings, " ; "))
	}
	if err := setOrderStatus(tx, o, OrderValidated, "validate", userID, note); err != nil {
		return nil, err
	}
	return res, RecalcOrder(tx, orderID)
}
