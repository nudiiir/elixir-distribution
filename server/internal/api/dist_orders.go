package api

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

func (s *Server) routesOrders(r chi.Router) {
	r.Get("/orders", s.listOrders)
	r.Post("/orders", s.createOrder)
	r.Get("/orders/statuses", s.orderStatuses)
	r.Get("/orders/backorders", s.listBackorders)
	r.Post("/orders/backorders/new-order", s.backorderNewOrder)
	r.Get("/orders/picking-list", s.batchPickingList)
	r.Post("/orders/import-web", s.importWebOrder)
	r.Get("/orders/web-sync", s.webSyncList)
	r.Post("/orders/web-sync/ack", s.webSyncAck)
	r.Get("/orders/{id}", s.getOrder)
	r.Put("/orders/{id}", s.updateOrder)
	r.Post("/orders/{id}/lines", s.addOrderLines)
	r.Patch("/orders/{id}/lines/{lineId}", s.patchOrderLine)
	r.Delete("/orders/{id}/lines/{lineId}", s.deleteOrderLine)
	r.Post("/orders/{id}/lines/{lineId}/substitute", s.substituteOrderLine)
	r.Post("/orders/{id}/validate", s.validateOrder)
	r.Post("/orders/{id}/reopen", s.reopenOrder)
	r.Post("/orders/{id}/start-preparation", s.startPreparation)
	r.Get("/orders/{id}/picking-list", s.pickingList)
	r.Post("/orders/{id}/picks", s.addPick)
	r.Delete("/orders/{id}/picks/{pickId}", s.deletePick)
	r.Post("/orders/{id}/scan", s.scanPick)
	r.Post("/orders/{id}/ready", s.markReady)
	r.Post("/orders/{id}/delivery-note", s.orderDeliveryNote)
	r.Post("/orders/{id}/ship", s.shipOrder)
	r.Post("/orders/{id}/deliver", s.deliverOrder)
	r.Post("/orders/{id}/invoice", s.invoiceOrder)
	r.Post("/orders/{id}/cancel", s.cancelOrder)
	r.Post("/orders/{id}/release-backorder", s.releaseBackorder)
	r.Get("/products/{id}/waiting-customers", s.waitingCustomers)
}

// ---- JSON shapes ---------------------------------------------------------------

type CustomerOrder struct {
	ID                 string  `json:"id"`
	Number             string  `json:"number"`
	OrderDate          string  `json:"order_date"`
	PartnerID          string  `json:"partner_id"`
	PartnerName        string  `json:"partner_name"`
	PartnerPhone       string  `json:"partner_phone"`
	PartnerClientType  string  `json:"partner_client_type"`
	Source             string  `json:"source"`
	ExternalRef        *string `json:"external_ref"`
	ExternalNumber     *string `json:"external_number"`
	Status             string  `json:"status"`
	StatusLabel        string  `json:"status_label"`
	IsPartial          bool    `json:"is_partial"`
	HasBackorder       bool    `json:"has_backorder"`
	WarehouseID        string  `json:"warehouse_id"`
	WarehouseName      string  `json:"warehouse_name"`
	RepUserID          *string `json:"rep_user_id"`
	RepName            string  `json:"rep_name"`
	RouteID            *string `json:"route_id"`
	RouteName          string  `json:"route_name"`
	Priority           int64   `json:"priority"`
	PaymentMode        string  `json:"payment_mode"`
	RequestedDate      *string `json:"requested_date"`
	DeliveryAddress    string  `json:"delivery_address"`
	Wilaya             string  `json:"wilaya"`
	Commune            string  `json:"commune"`
	ContactName        string  `json:"contact_name"`
	ContactPhone       string  `json:"contact_phone"`
	Notes              string  `json:"notes"`
	InternalNotes      string  `json:"internal_notes"`
	TotalHT            int64   `json:"total_ht"`
	TotalVAT           int64   `json:"total_vat"`
	TotalDiscount      int64   `json:"total_discount"`
	ShippingFee        int64   `json:"shipping_fee"`
	ExtraDiscount      int64   `json:"extra_discount"`
	PromoCode          string  `json:"promo_code"`
	TotalTTC           int64   `json:"total_ttc"`
	CancelReason       string  `json:"cancel_reason"`
	CreditOverride     bool    `json:"credit_override"`
	DeliveryNoteID     *string `json:"delivery_note_id"`
	DeliveryNoteNumber *string `json:"delivery_note_number"`
	InvoiceID          *string `json:"invoice_id"`
	InvoiceNumber      *string `json:"invoice_number"`
	PaymentID          *string `json:"payment_id"`
	PaymentNumber      *string `json:"payment_number"`
	WebStatusDirty     bool    `json:"web_status_dirty"`
	CreatedBy          *string `json:"created_by"`
	CreatedByName      string  `json:"created_by_name"`
	ValidatedBy        *string `json:"validated_by"`
	ValidatedAt        *string `json:"validated_at"`
	DeliveredAt        *string `json:"delivered_at"`
	CreatedAt          string  `json:"created_at"`
	UpdatedAt          string  `json:"updated_at"`
	LinesCount         int     `json:"lines_count"`
	// Detail only (GET /orders/{id}).
	Lines              []OrderLineOut  `json:"lines,omitempty"`
	Events             []OrderEventOut `json:"events,omitempty"`
	Picks              []OrderPickOut  `json:"picks,omitempty"`
	AllowedTransitions []string        `json:"allowed_transitions,omitempty"`
}

const orderSelect = `SELECT o.id, o.number, o.order_date, o.partner_id, p.name, COALESCE(p.phone,''), p.client_type,
	o.source, o.external_ref, o.external_number, o.status, o.is_partial, o.has_backorder, o.warehouse_id,
	COALESCE(w.name,''), o.rep_user_id, COALESCE(NULLIF(ru.full_name,''), ru.username, ''), o.route_id,
	COALESCE(rt.name,''), o.priority, o.payment_mode, o.requested_date, o.delivery_address, o.wilaya, o.commune,
	o.contact_name, o.contact_phone, o.notes, o.internal_notes, o.total_ht, o.total_vat, o.total_discount,
	o.shipping_fee, o.extra_discount, o.promo_code, o.total_ttc, o.cancel_reason, o.credit_override,
	o.delivery_note_id, bl.number, o.invoice_id, inv.number, o.payment_id, pay.number, o.web_status_dirty,
	o.created_by, COALESCE(NULLIF(cu.full_name,''), cu.username, ''), o.validated_by, o.validated_at,
	o.delivered_at, o.created_at, o.updated_at,
	(SELECT COUNT(*) FROM customer_order_lines l WHERE l.order_id = o.id AND l.qty_ordered_milli > 0)
FROM customer_orders o
JOIN partners p ON p.id = o.partner_id
LEFT JOIN warehouses w ON w.id = o.warehouse_id
LEFT JOIN users ru ON ru.id = o.rep_user_id
LEFT JOIN users cu ON cu.id = o.created_by
LEFT JOIN delivery_routes rt ON rt.id = o.route_id
LEFT JOIN documents bl ON bl.id = o.delivery_note_id
LEFT JOIN documents inv ON inv.id = o.invoice_id
LEFT JOIN documents pay ON pay.id = o.payment_id`

func scanOrder(row interface{ Scan(...any) error }) (CustomerOrder, error) {
	var o CustomerOrder
	var partial, backorder, override, dirty int
	err := row.Scan(&o.ID, &o.Number, &o.OrderDate, &o.PartnerID, &o.PartnerName, &o.PartnerPhone,
		&o.PartnerClientType, &o.Source, &o.ExternalRef, &o.ExternalNumber, &o.Status, &partial, &backorder,
		&o.WarehouseID, &o.WarehouseName, &o.RepUserID, &o.RepName, &o.RouteID, &o.RouteName, &o.Priority,
		&o.PaymentMode, &o.RequestedDate, &o.DeliveryAddress, &o.Wilaya, &o.Commune, &o.ContactName,
		&o.ContactPhone, &o.Notes, &o.InternalNotes, &o.TotalHT, &o.TotalVAT, &o.TotalDiscount,
		&o.ShippingFee, &o.ExtraDiscount, &o.PromoCode, &o.TotalTTC, &o.CancelReason, &override,
		&o.DeliveryNoteID, &o.DeliveryNoteNumber, &o.InvoiceID, &o.InvoiceNumber, &o.PaymentID,
		&o.PaymentNumber, &dirty, &o.CreatedBy, &o.CreatedByName, &o.ValidatedBy, &o.ValidatedAt,
		&o.DeliveredAt, &o.CreatedAt, &o.UpdatedAt, &o.LinesCount)
	o.IsPartial, o.HasBackorder, o.CreditOverride, o.WebStatusDirty = partial == 1, backorder == 1, override == 1, dirty == 1
	o.StatusLabel = domain.OrderStatusLabels[o.Status]
	return o, err
}

type OrderLineOut struct {
	ID                       string  `json:"id"`
	Position                 int     `json:"position"`
	ProductID                string  `json:"product_id"`
	ProductName              string  `json:"product_name"`
	Barcode                  *string `json:"barcode"`
	IsService                bool    `json:"is_service"`
	TrackLots                bool    `json:"track_lots"`
	QtyOrderedMilli          int64   `json:"qty_ordered_milli"`
	QtyValidatedMilli        int64   `json:"qty_validated_milli"`
	QtyPreparedMilli         int64   `json:"qty_prepared_milli"`
	QtyDeliveredMilli        int64   `json:"qty_delivered_milli"`
	QtyBackorderMilli        int64   `json:"qty_backorder_milli"`
	QtyFreeMilli             int64   `json:"qty_free_milli"`
	QtyToPrepareMilli        int64   `json:"qty_to_prepare_milli"`
	UnitPrice                int64   `json:"unit_price"`
	DiscountPct              int64   `json:"discount_pct"`
	VatRate                  int64   `json:"vat_rate"`
	LineHT                   int64   `json:"line_ht"`
	LineVAT                  int64   `json:"line_vat"`
	LineTTC                  int64   `json:"line_ttc"`
	PriceSource              string  `json:"price_source"`
	PromoRuleID              *string `json:"promo_rule_id"`
	SubstitutedFromLineID    *string `json:"substituted_from_line_id"`
	SubstitutedFromProductID *string `json:"substituted_from_product_id"`
	BackorderFromLineID      *string `json:"backorder_from_line_id"`
	Notes                    string  `json:"notes"`
	StockMilli               int64   `json:"stock_milli"`     // in the order's warehouse
	AvailableMilli           int64   `json:"available_milli"` // stock − other open orders
}

type OrderEventOut struct {
	ID         string  `json:"id"`
	Action     string  `json:"action"`
	FromStatus *string `json:"from_status"`
	ToStatus   *string `json:"to_status"`
	UserID     *string `json:"user_id"`
	UserName   string  `json:"user_name"`
	Note       string  `json:"note"`
	CreatedAt  string  `json:"created_at"`
}

type OrderPickOut struct {
	ID           string  `json:"id"`
	LineID       string  `json:"line_id"`
	ProductID    string  `json:"product_id"`
	LotID        *string `json:"lot_id"`
	LotNumber    *string `json:"lot_number"`
	ExpiryDate   *string `json:"expiry_date"`
	QtyMilli     int64   `json:"qty_milli"`
	Barcode      string  `json:"barcode"`
	PickedBy     *string `json:"picked_by"`
	PickedByName string  `json:"picked_by_name"`
	CreatedAt    string  `json:"created_at"`
}

func (s *Server) loadOrder(id string, detail bool) (CustomerOrder, error) {
	o, err := scanOrder(s.db.QueryRow(orderSelect+` WHERE o.id = ?`, id))
	if err != nil || !detail {
		return o, err
	}
	rows, err := s.db.Query(`SELECT l.id, l.position, l.product_id, l.description, p.barcode, p.kind = 'service',
			(p.track_lots + p.track_expiry) > 0, l.qty_ordered_milli, l.qty_validated_milli, l.qty_prepared_milli,
			l.qty_delivered_milli, l.qty_backorder_milli, l.qty_free_milli, l.unit_price, l.discount_pct,
			l.vat_rate, l.line_ht, l.line_vat, l.line_ttc, l.price_source, l.promo_rule_id,
			l.substituted_from_line_id, l.substituted_from_product_id, l.backorder_from_line_id, l.notes
		FROM customer_order_lines l JOIN products p ON p.id = l.product_id
		WHERE l.order_id = ? ORDER BY l.position, l.created_at`, id)
	if err != nil {
		return o, err
	}
	o.Lines = []OrderLineOut{}
	for rows.Next() {
		var l OrderLineOut
		if err := rows.Scan(&l.ID, &l.Position, &l.ProductID, &l.ProductName, &l.Barcode, &l.IsService,
			&l.TrackLots, &l.QtyOrderedMilli, &l.QtyValidatedMilli, &l.QtyPreparedMilli, &l.QtyDeliveredMilli,
			&l.QtyBackorderMilli, &l.QtyFreeMilli, &l.UnitPrice, &l.DiscountPct, &l.VatRate, &l.LineHT,
			&l.LineVAT, &l.LineTTC, &l.PriceSource, &l.PromoRuleID, &l.SubstitutedFromLineID,
			&l.SubstitutedFromProductID, &l.BackorderFromLineID, &l.Notes); err != nil {
			rows.Close()
			return o, err
		}
		l.QtyToPrepareMilli = l.QtyValidatedMilli + l.QtyFreeMilli
		o.Lines = append(o.Lines, l)
	}
	rows.Close()
	for i := range o.Lines {
		l := &o.Lines[i]
		l.StockMilli = domain.StockQty(s.db, l.ProductID, o.WarehouseID)
		l.AvailableMilli = domain.AvailableQty(s.db, l.ProductID, o.WarehouseID, o.ID)
	}
	erows, err := s.db.Query(`SELECT e.id, e.action, e.from_status, e.to_status, e.user_id,
			COALESCE(NULLIF(u.full_name,''), u.username, ''), e.note, e.created_at
		FROM customer_order_events e LEFT JOIN users u ON u.id = e.user_id
		WHERE e.order_id = ? ORDER BY e.created_at, e.id`, id)
	if err != nil {
		return o, err
	}
	o.Events = []OrderEventOut{}
	for erows.Next() {
		var e OrderEventOut
		if err := erows.Scan(&e.ID, &e.Action, &e.FromStatus, &e.ToStatus, &e.UserID, &e.UserName, &e.Note, &e.CreatedAt); err != nil {
			erows.Close()
			return o, err
		}
		o.Events = append(o.Events, e)
	}
	erows.Close()
	o.Picks, err = s.orderPicks(id)
	if err != nil {
		return o, err
	}
	o.AllowedTransitions = append([]string{}, domain.OrderTransitions[o.Status]...)
	return o, nil
}

func (s *Server) orderPicks(orderID string) ([]OrderPickOut, error) {
	rows, err := s.db.Query(`SELECT k.id, k.line_id, l.product_id, k.lot_id, lt.lot_number, lt.expiry_date,
			k.qty_milli, k.barcode, k.picked_by, COALESCE(NULLIF(u.full_name,''), u.username, ''), k.created_at
		FROM customer_order_picks k JOIN customer_order_lines l ON l.id = k.line_id
		LEFT JOIN lots lt ON lt.id = k.lot_id LEFT JOIN users u ON u.id = k.picked_by
		WHERE k.order_id = ? ORDER BY k.created_at, k.id`, orderID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []OrderPickOut{}
	for rows.Next() {
		var k OrderPickOut
		if err := rows.Scan(&k.ID, &k.LineID, &k.ProductID, &k.LotID, &k.LotNumber, &k.ExpiryDate, &k.QtyMilli,
			&k.Barcode, &k.PickedBy, &k.PickedByName, &k.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

func (s *Server) respondOrder(w http.ResponseWriter, id string, status int, extra map[string]any) {
	o, err := s.loadOrder(id, true)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "commande introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if len(extra) == 0 {
		writeJSON(w, status, o)
		return
	}
	// Extra keys (warnings, numbers…) sit next to the order fields.
	b, _ := json.Marshal(o)
	m := map[string]any{}
	json.Unmarshal(b, &m)
	for k, v := range extra {
		m[k] = v
	}
	writeJSON(w, status, m)
}

// ---- List ------------------------------------------------------------------------

func (s *Server) orderFilters(r *http.Request, withStatus bool) (string, []any) {
	qp := r.URL.Query()
	where := " WHERE 1=1"
	args := []any{}
	if withStatus {
		if st := splitCSV(qp.Get("status")); len(st) > 0 {
			where += " AND o.status IN (" + placeholders(len(st)) + ")"
			for _, v := range st {
				args = append(args, v)
			}
		}
	}
	eq := func(param, col string) {
		if v := qp.Get(param); v != "" {
			where += " AND " + col + " = ?"
			args = append(args, v)
		}
	}
	eq("partner_id", "o.partner_id")
	eq("rep_user_id", "o.rep_user_id")
	eq("wilaya", "o.wilaya")
	eq("route_id", "o.route_id")
	eq("source", "o.source")
	eq("warehouse_id", "o.warehouse_id")
	eq("priority", "o.priority")
	if v := qp.Get("from"); v != "" {
		where += " AND o.order_date >= ?"
		args = append(args, v)
	}
	if v := qp.Get("to"); v != "" {
		where += " AND o.order_date <= ?"
		args = append(args, v)
	}
	if qp.Get("has_backorder") == "1" {
		where += " AND o.has_backorder = 1"
	}
	if q := strings.TrimSpace(qp.Get("q")); q != "" {
		like := "%" + q + "%"
		where += ` AND (o.number LIKE ? OR COALESCE(o.external_number,'') LIKE ? OR p.name LIKE ?
			OR COALESCE(p.phone,'') LIKE ? OR o.contact_phone LIKE ?)`
		args = append(args, like, like, like, like, like)
	}
	sw, sa := orderScopeWhere(authFrom(r))
	return where + sw, append(args, sa...)
}

// listOrders: GET /orders — filtered list + per-status counts (kanban).
func (s *Server) listOrders(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.view") {
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	where, args := s.orderFilters(r, true)
	sort := "o.order_date DESC, o.created_at DESC"
	if r.URL.Query().Get("sort") == "priority" {
		sort = "o.priority DESC, o.order_date, o.created_at"
	}
	rows, err := s.db.Query(orderSelect+where+` ORDER BY `+sort+` LIMIT ? OFFSET ?`,
		append(args, limit, offset)...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	items := []CustomerOrder{}
	for rows.Next() {
		o, err := scanOrder(rows)
		if err != nil {
			rows.Close()
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, o)
	}
	rows.Close()
	cwhere, cargs := s.orderFilters(r, false)
	counts := map[string]int{}
	for _, st := range domain.OrderStatuses {
		counts[st] = 0
	}
	crows, err := s.db.Query(`SELECT o.status, COUNT(*) FROM customer_orders o JOIN partners p ON p.id = o.partner_id`+
		cwhere+` GROUP BY o.status`, cargs...)
	if err == nil {
		for crows.Next() {
			var st string
			var n int
			crows.Scan(&st, &n)
			counts[st] = n
		}
		crows.Close()
	}
	var total int
	s.db.QueryRow(`SELECT COUNT(*) FROM customer_orders o JOIN partners p ON p.id = o.partner_id`+where, args...).Scan(&total)
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "counts": counts, "total": total})
}

// orderStatuses: GET /orders/statuses — labels and transitions for the UI.
func (s *Server) orderStatuses(w http.ResponseWriter, r *http.Request) {
	type st struct {
		Key         string   `json:"key"`
		Label       string   `json:"label"`
		Transitions []string `json:"transitions"`
	}
	items := []st{}
	for _, k := range domain.OrderStatuses {
		items = append(items, st{k, domain.OrderStatusLabels[k], append([]string{}, domain.OrderTransitions[k]...)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "sources": domain.OrderSources})
}

func (s *Server) getOrder(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.view") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	s.respondOrder(w, id, http.StatusOK, nil)
}

// ---- Create / update ------------------------------------------------------------------

type orderLineBody struct {
	ProductID    string `json:"product_id"`
	QtyMilli     int64  `json:"qty_milli"`
	UnitPrice    *int64 `json:"unit_price"`
	DiscountPct  *int64 `json:"discount_pct"`
	QtyFreeMilli *int64 `json:"qty_free_milli"`
	Notes        string `json:"notes"`
}

type orderBody struct {
	PartnerID       string          `json:"partner_id"`
	Source          string          `json:"source"`
	OrderDate       string          `json:"order_date"`
	WarehouseID     string          `json:"warehouse_id"`
	RepUserID       *string         `json:"rep_user_id"`
	RouteID         *string         `json:"route_id"`
	Priority        int64           `json:"priority"`
	PaymentMode     string          `json:"payment_mode"`
	RequestedDate   *string         `json:"requested_date"`
	DeliveryAddress *string         `json:"delivery_address"`
	Wilaya          *string         `json:"wilaya"`
	Commune         *string         `json:"commune"`
	ContactName     *string         `json:"contact_name"`
	ContactPhone    *string         `json:"contact_phone"`
	Notes           string          `json:"notes"`
	InternalNotes   string          `json:"internal_notes"`
	ExternalRef     *string         `json:"external_ref"`
	ExternalNumber  *string         `json:"external_number"`
	ShippingFee     int64           `json:"shipping_fee"`
	ExtraDiscount   int64           `json:"extra_discount"`
	PromoCode       string          `json:"promo_code"`
	Lines           []orderLineBody `json:"lines"`
}

func (b orderBody) lineInputs() []domain.OrderLineInput {
	out := []domain.OrderLineInput{}
	for _, l := range b.Lines {
		out = append(out, domain.OrderLineInput{ProductID: l.ProductID, QtyMilli: l.QtyMilli,
			UnitPrice: l.UnitPrice, DiscountPct: l.DiscountPct, QtyFreeMilli: l.QtyFreeMilli, Notes: l.Notes})
	}
	return out
}

func (b orderBody) input() domain.OrderInput {
	return domain.OrderInput{PartnerID: b.PartnerID, Source: b.Source, OrderDate: b.OrderDate,
		WarehouseID: b.WarehouseID, RepUserID: b.RepUserID, RouteID: b.RouteID, Priority: b.Priority,
		PaymentMode: b.PaymentMode, RequestedDate: b.RequestedDate, DeliveryAddress: b.DeliveryAddress,
		Wilaya: b.Wilaya, Commune: b.Commune, ContactName: b.ContactName, ContactPhone: b.ContactPhone,
		Notes: b.Notes, InternalNotes: b.InternalNotes, ExternalRef: b.ExternalRef,
		ExternalNumber: b.ExternalNumber, ShippingFee: b.ShippingFee, ExtraDiscount: b.ExtraDiscount,
		PromoCode: b.PromoCode, Lines: b.lineInputs()}
}

// checkOrderLineRights: a price other than the resolved one needs price_edit,
// a discount above the resolved one needs discount (manager code accepted).
func (s *Server) checkOrderLineRights(w http.ResponseWriter, r *http.Request, partnerID, date, source string,
	lines []orderLineBody) bool {
	for _, l := range lines {
		if l.UnitPrice == nil && l.DiscountPct == nil {
			continue
		}
		pq, err := domain.ResolvePrice(s.db, partnerID, l.ProductID, l.QtyMilli, date, domain.ChannelOf(source))
		if err != nil {
			continue // the domain answers it
		}
		if l.UnitPrice != nil && *l.UnitPrice != pq.UnitPrice && !s.requireRight(w, r, "price_edit", 0,
			"prix de « "+pq.ProductName+" » modifié : vous n'avez pas le droit de changer un prix") {
			return false
		}
		if l.DiscountPct != nil && *l.DiscountPct > pq.DiscountPct &&
			!s.requireRight(w, r, "discount", *l.DiscountPct, discountMsg(authFrom(r), *l.DiscountPct)) {
			return false
		}
	}
	return true
}

func (s *Server) createOrder(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	var in orderBody
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.PartnerID) == "" {
		writeFieldErr(w, http.StatusBadRequest, "partner_id", "le client est obligatoire")
		return
	}
	if in.Source == "web" || in.Source == "portal" {
		writeErr(w, http.StatusBadRequest, "les commandes web arrivent par POST /orders/import-web")
		return
	}
	if in.OrderDate != "" && len(in.OrderDate) != 10 {
		writeFieldErr(w, http.StatusBadRequest, "order_date", "date au format AAAA-MM-JJ")
		return
	}
	if len(in.Lines) == 0 {
		writeFieldErr(w, http.StatusBadRequest, "lines", "la commande doit contenir au moins une ligne")
		return
	}
	if !s.canSeePartner(r, in.PartnerID) {
		writeErr(w, http.StatusForbidden, "ce client n'est pas dans votre portefeuille")
		return
	}
	if !s.checkOrderLineRights(w, r, in.PartnerID, in.OrderDate, in.Source, in.Lines) {
		return
	}
	if in.RepUserID == nil && in.Source == "rep" {
		me := uidOf(r)
		in.RepUserID = &me
	}
	var id, number string
	if !s.inTx(w, func(tx *sql.Tx) error {
		var err error
		id, number, err = domain.CreateOrder(tx, in.input(), uidOf(r))
		return err
	}) {
		return
	}
	s.audit(r, "order.create", "customer_order", id, number)
	s.respondOrder(w, id, http.StatusCreated, nil)
}

// updateOrder: PUT /orders/{id} — header; lines replaced when "lines" is sent.
func (s *Server) updateOrder(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	var raw map[string]json.RawMessage
	var in orderBody
	body, err := readAllLimited(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := decodeStrict(body, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	_, replace := raw["lines"]
	if replace {
		var partner, date, source string
		s.db.QueryRow(`SELECT partner_id, order_date, source FROM customer_orders WHERE id = ?`, id).
			Scan(&partner, &date, &source)
		if in.PartnerID != "" {
			partner = in.PartnerID
		}
		if !s.checkOrderLineRights(w, r, partner, date, source, in.Lines) {
			return
		}
	}
	if !s.inTx(w, func(tx *sql.Tx) error {
		return domain.UpdateOrder(tx, id, in.input(), replace, uidOf(r))
	}) {
		return
	}
	s.respondOrder(w, id, http.StatusOK, nil)
}

func (s *Server) addOrderLines(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	var in struct {
		Lines []orderLineBody `json:"lines"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(in.Lines) == 0 {
		writeFieldErr(w, http.StatusBadRequest, "lines", "aucune ligne à ajouter")
		return
	}
	var partner, date, source string
	s.db.QueryRow(`SELECT partner_id, order_date, source FROM customer_orders WHERE id = ?`, id).Scan(&partner, &date, &source)
	if !s.checkOrderLineRights(w, r, partner, date, source, in.Lines) {
		return
	}
	if !s.inTx(w, func(tx *sql.Tx) error {
		return domain.AddOrderLines(tx, id, orderBody{Lines: in.Lines}.lineInputs(), uidOf(r))
	}) {
		return
	}
	s.respondOrder(w, id, http.StatusOK, nil)
}

func (s *Server) patchOrderLine(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	id, lineID := chi.URLParam(r, "id"), chi.URLParam(r, "lineId")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	var in struct {
		QtyMilli     *int64  `json:"qty_milli"`
		UnitPrice    *int64  `json:"unit_price"`
		DiscountPct  *int64  `json:"discount_pct"`
		QtyFreeMilli *int64  `json:"qty_free_milli"`
		Notes        *string `json:"notes"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	var price, disc int64
	s.db.QueryRow(`SELECT unit_price, discount_pct FROM customer_order_lines WHERE id = ?`, lineID).Scan(&price, &disc)
	if in.UnitPrice != nil && *in.UnitPrice != price && !s.requireRight(w, r, "price_edit", 0,
		"vous n'avez pas le droit de changer un prix") {
		return
	}
	if in.DiscountPct != nil && *in.DiscountPct > disc &&
		!s.requireRight(w, r, "discount", *in.DiscountPct, discountMsg(authFrom(r), *in.DiscountPct)) {
		return
	}
	if in.QtyFreeMilli != nil && !s.requireRight(w, r, "price_edit", 0,
		"vous n'avez pas le droit de changer les unités gratuites") {
		return
	}
	if !s.inTx(w, func(tx *sql.Tx) error {
		return domain.PatchOrderLine(tx, id, lineID, domain.LinePatch{QtyMilli: in.QtyMilli, UnitPrice: in.UnitPrice,
			DiscountPct: in.DiscountPct, QtyFreeMilli: in.QtyFreeMilli, Notes: in.Notes}, uidOf(r))
	}) {
		return
	}
	s.respondOrder(w, id, http.StatusOK, nil)
}

func (s *Server) deleteOrderLine(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	if !s.inTx(w, func(tx *sql.Tx) error {
		return domain.DeleteOrderLine(tx, id, chi.URLParam(r, "lineId"), uidOf(r))
	}) {
		return
	}
	s.respondOrder(w, id, http.StatusOK, nil)
}

func (s *Server) substituteOrderLine(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	var in struct {
		ProductID string `json:"product_id"`
		QtyMilli  int64  `json:"qty_milli"`
		KeepPrice bool   `json:"keep_price"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.ProductID == "" {
		writeFieldErr(w, http.StatusBadRequest, "product_id", "choisissez le produit de remplacement")
		return
	}
	if in.KeepPrice && !s.requireRight(w, r, "price_edit", 0, "garder l'ancien prix exige le droit de changer un prix") {
		return
	}
	var newLine string
	if !s.inTx(w, func(tx *sql.Tx) error {
		var err error
		newLine, err = domain.SubstituteLine(tx, id, chi.URLParam(r, "lineId"), in.ProductID, in.QtyMilli, in.KeepPrice, uidOf(r))
		return err
	}) {
		return
	}
	s.respondOrder(w, id, http.StatusOK, map[string]any{"new_line_id": newLine})
}

// ---- Status changes ---------------------------------------------------------------------

func (s *Server) validateOrder(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.validate") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	var in struct {
		OverrideCredit bool  `json:"override_credit"`
		Partial        *bool `json:"partial"`
		Lines          []struct {
			LineID            string `json:"line_id"`
			QtyValidatedMilli int64  `json:"qty_validated_milli"`
		} `json:"lines"`
	}
	if err := decodeOptional(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.OverrideCredit && !s.requireRight(w, r, "orders.override_credit", 0,
		"vous n'avez pas le droit de passer outre le contrôle de crédit") {
		return
	}
	opt := domain.ValidateOptions{OverrideCredit: in.OverrideCredit, Lines: map[string]int64{}}
	if in.Partial != nil && !*in.Partial {
		opt.NoPartial = true
	}
	for _, l := range in.Lines {
		opt.Lines[l.LineID] = l.QtyValidatedMilli
	}
	var res *domain.ValidateResult
	if !s.inTx(w, func(tx *sql.Tx) error {
		var err error
		res, err = domain.ValidateOrder(tx, id, uidOf(r), opt)
		return err
	}) {
		return
	}
	s.respondOrder(w, id, http.StatusOK, map[string]any{"validation": res})
}

// simple runs a domain step on one order and answers the order.
func (s *Server) simpleOrderStep(w http.ResponseWriter, r *http.Request, perm string, fn func(tx *sql.Tx, id, uid string) error) {
	if !s.need(w, r, perm) {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	if !s.inTx(w, func(tx *sql.Tx) error { return fn(tx, id, uidOf(r)) }) {
		return
	}
	s.respondOrder(w, id, http.StatusOK, nil)
}

func (s *Server) reopenOrder(w http.ResponseWriter, r *http.Request) {
	s.simpleOrderStep(w, r, "orders.manage", domain.ReopenOrder)
}

func (s *Server) startPreparation(w http.ResponseWriter, r *http.Request) {
	s.simpleOrderStep(w, r, "orders.manage", domain.StartPreparation)
}

func (s *Server) addPick(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	var in struct {
		LineID   string `json:"line_id"`
		LotID    string `json:"lot_id"`
		QtyMilli int64  `json:"qty_milli"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	var res *domain.PickResult
	if !s.inTx(w, func(tx *sql.Tx) error {
		var err error
		res, err = domain.AddPick(tx, id, in.LineID, in.LotID, in.QtyMilli, "", uidOf(r))
		return err
	}) {
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) deletePick(w http.ResponseWriter, r *http.Request) {
	s.simpleOrderStep(w, r, "orders.manage", func(tx *sql.Tx, id, uid string) error {
		return domain.RemovePick(tx, id, chi.URLParam(r, "pickId"), uid)
	})
}

func (s *Server) scanPick(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	var in struct {
		Barcode   string `json:"barcode"`
		QtyMilli  int64  `json:"qty_milli"`
		LotNumber string `json:"lot_number"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.Barcode) == "" {
		writeFieldErr(w, http.StatusBadRequest, "barcode", "code-barres vide")
		return
	}
	var res *domain.PickResult
	if !s.inTx(w, func(tx *sql.Tx) error {
		var err error
		res, err = domain.ScanPick(tx, id, in.Barcode, in.QtyMilli, in.LotNumber, uidOf(r))
		return err
	}) {
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) markReady(w http.ResponseWriter, r *http.Request) {
	var in struct {
		AcceptPartial bool `json:"accept_partial"`
		AutoPick      bool `json:"auto_pick"`
	}
	if err := decodeOptional(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	s.simpleOrderStep(w, r, "orders.manage", func(tx *sql.Tx, id, uid string) error {
		return domain.MarkReady(tx, id, uid, domain.ReadyOptions{AcceptPartial: in.AcceptPartial, AutoPick: in.AutoPick})
	})
}

func (s *Server) orderDeliveryNote(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	var docID, number string
	if !s.inTx(w, func(tx *sql.Tx) error {
		var err error
		docID, number, err = domain.GenerateDeliveryNote(tx, id, uidOf(r))
		return err
	}) {
		return
	}
	s.respondOrder(w, id, http.StatusOK, map[string]any{"document_id": docID, "document_number": number})
}

func (s *Server) shipOrder(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Note string `json:"note"`
	}
	if err := decodeOptional(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	s.simpleOrderStep(w, r, "orders.manage", func(tx *sql.Tx, id, uid string) error {
		return domain.ShipOrder(tx, id, uid, strings.TrimSpace(in.Note))
	})
}

func (s *Server) deliverOrder(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	var in struct {
		CODAmount     int64  `json:"cod_amount"`
		PaymentMethod string `json:"payment_method"`
		ReceiverName  string `json:"receiver_name"`
		Note          string `json:"note"`
	}
	if err := decodeOptional(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.CODAmount < 0 {
		writeFieldErr(w, http.StatusBadRequest, "cod_amount", "montant négatif")
		return
	}
	var payNumber string
	if !s.inTx(w, func(tx *sql.Tx) error {
		var err error
		payNumber, err = domain.DeliverOrder(tx, id, uidOf(r), domain.DeliverOptions{CODAmount: in.CODAmount,
			Method: in.PaymentMethod, Receiver: in.ReceiverName, Note: in.Note})
		return err
	}) {
		return
	}
	s.respondOrder(w, id, http.StatusOK, map[string]any{"payment_number": payNumber})
}

func (s *Server) invoiceOrder(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	var in struct {
		PaymentMethod string `json:"payment_method"`
	}
	if err := decodeOptional(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	var docID, number string
	if !s.inTx(w, func(tx *sql.Tx) error {
		var err error
		docID, number, err = domain.InvoiceOrder(tx, id, uidOf(r), in.PaymentMethod)
		return err
	}) {
		return
	}
	s.audit(r, "order.invoice", "customer_order", id, "facture "+number)
	s.respondOrder(w, id, http.StatusOK, map[string]any{"document_id": docID, "document_number": number})
}

func (s *Server) cancelOrder(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	var in struct {
		Reason string `json:"reason"`
	}
	if err := decodeOptional(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.Reason) == "" {
		writeFieldErr(w, http.StatusBadRequest, "reason", "le motif d'annulation est obligatoire")
		return
	}
	var blPosted int
	s.db.QueryRow(`SELECT COUNT(*) FROM customer_orders o JOIN documents d ON d.id = o.delivery_note_id
		WHERE o.id = ? AND d.status = 'posted'`, id).Scan(&blPosted)
	mayVoid := blPosted == 0 || s.rightOrApproval(r, "void_document", 0)
	if !mayVoid {
		writeNeedsApproval(w, "void_document", 0,
			"le BL de cette commande est validé : l'annuler exige le droit d'annuler un document validé")
		return
	}
	s.simpleOrderStep(w, r, "orders.manage", func(tx *sql.Tx, id, uid string) error {
		return domain.CancelOrder(tx, id, uid, in.Reason, mayVoid)
	})
}

func (s *Server) releaseBackorder(w http.ResponseWriter, r *http.Request) {
	var in struct {
		LineIDs []string `json:"line_ids"`
	}
	if err := decodeOptional(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	s.simpleOrderStep(w, r, "orders.manage", func(tx *sql.Tx, id, uid string) error {
		_, err := domain.ReleaseBackorder(tx, id, in.LineIDs, uid)
		return err
	})
}

// ---- Picking lists -------------------------------------------------------------------------

type stockByWarehouse struct {
	WarehouseID   string `json:"warehouse_id"`
	WarehouseName string `json:"warehouse_name"`
	QtyMilli      int64  `json:"qty_milli"`
}

type pickingLine struct {
	LineID         string                 `json:"line_id"`
	ProductID      string                 `json:"product_id"`
	ProductName    string                 `json:"product_name"`
	Barcode        *string                `json:"barcode"`
	CategoryName   string                 `json:"category_name"`
	Brand          string                 `json:"brand"`
	IsService      bool                   `json:"is_service"`
	TrackLots      bool                   `json:"track_lots"`
	QtyValidated   int64                  `json:"qty_validated_milli"`
	QtyFree        int64                  `json:"qty_free_milli"`
	QtyToPrepare   int64                  `json:"qty_to_prepare_milli"`
	QtyPrepared    int64                  `json:"qty_prepared_milli"`
	QtyRemaining   int64                  `json:"qty_remaining_milli"`
	Stock          []stockByWarehouse     `json:"stock"`
	LotSuggestions []domain.LotSuggestion `json:"lot_suggestions"`
	Orders         []pickingOrderRef      `json:"orders,omitempty"` // batch list only
}

type pickingOrderRef struct {
	OrderID      string `json:"order_id"`
	OrderNumber  string `json:"order_number"`
	PartnerName  string `json:"partner_name"`
	LineID       string `json:"line_id"`
	QtyRemaining int64  `json:"qty_remaining_milli"`
}

func (s *Server) stockByWarehouse(productID string) []stockByWarehouse {
	out := []stockByWarehouse{}
	rows, err := s.db.Query(`SELECT w.id, w.name, COALESCE(sl.qty_milli,0) FROM warehouses w
		LEFT JOIN stock_levels sl ON sl.warehouse_id = w.id AND sl.product_id = ?
		WHERE w.active = 1 ORDER BY w.is_default DESC, w.name`, productID)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var x stockByWarehouse
		rows.Scan(&x.WarehouseID, &x.WarehouseName, &x.QtyMilli)
		out = append(out, x)
	}
	return out
}

// pickingRows loads the lines to prepare of the given orders, sorted the way
// a preparer walks the shelves (category, then name — the products have no
// location field).
func (s *Server) pickingRows(orderIDs []string) ([]pickingLine, error) {
	args := []any{}
	for _, id := range orderIDs {
		args = append(args, id)
	}
	rows, err := s.db.Query(`SELECT l.id, l.order_id, o.number, pa.name, l.product_id, p.name, p.barcode,
			COALESCE(c.name,''), p.brand, p.kind = 'service', (p.track_lots + p.track_expiry) > 0,
			l.qty_validated_milli, l.qty_free_milli, l.qty_prepared_milli
		FROM customer_order_lines l
		JOIN customer_orders o ON o.id = l.order_id
		JOIN partners pa ON pa.id = o.partner_id
		JOIN products p ON p.id = l.product_id
		LEFT JOIN product_categories c ON c.id = p.category_id
		WHERE l.order_id IN (`+placeholders(len(orderIDs))+`) AND l.qty_validated_milli + l.qty_free_milli > 0
		ORDER BY COALESCE(c.name,'') = '', COALESCE(c.name,''), p.name, o.number`, args...)
	if err != nil {
		return nil, err
	}
	var out []pickingLine
	for rows.Next() {
		var l pickingLine
		var ref pickingOrderRef
		if err := rows.Scan(&l.LineID, &ref.OrderID, &ref.OrderNumber, &ref.PartnerName, &l.ProductID,
			&l.ProductName, &l.Barcode, &l.CategoryName, &l.Brand, &l.IsService, &l.TrackLots,
			&l.QtyValidated, &l.QtyFree, &l.QtyPrepared); err != nil {
			rows.Close()
			return nil, err
		}
		l.QtyToPrepare = l.QtyValidated + l.QtyFree
		l.QtyRemaining = max(0, l.QtyToPrepare-l.QtyPrepared)
		ref.LineID, ref.QtyRemaining = l.LineID, l.QtyRemaining
		l.Orders = []pickingOrderRef{ref}
		out = append(out, l)
	}
	rows.Close()
	return out, nil
}

// pickingList: GET /orders/{id}/picking-list.
func (s *Server) pickingList(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.view") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.canSeeOrder(r, id) {
		forbid(w)
		return
	}
	o, err := s.loadOrder(id, false)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "commande introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	lines, err := s.pickingRows([]string{id})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	for i := range lines {
		l := &lines[i]
		l.Orders = nil
		l.Stock = s.stockByWarehouse(l.ProductID)
		l.LotSuggestions = []domain.LotSuggestion{}
		if l.TrackLots && l.QtyRemaining > 0 {
			l.LotSuggestions, _ = domain.FEFOSuggestions(s.db, l.ProductID, l.QtyRemaining)
		}
	}
	if lines == nil {
		lines = []pickingLine{}
	}
	picks, _ := s.orderPicks(id)
	writeJSON(w, http.StatusOK, map[string]any{"order": o, "lines": lines, "picks": picks})
}

// batchPickingList: GET /orders/picking-list?ids=a,b — one consolidated list
// per product for several orders (« préparation groupée »).
func (s *Server) batchPickingList(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.view") {
		return
	}
	ids := splitCSV(r.URL.Query().Get("ids"))
	if len(ids) == 0 {
		writeFieldErr(w, http.StatusBadRequest, "ids", "indiquez les commandes (?ids=a,b)")
		return
	}
	for _, id := range ids {
		if !s.canSeeOrder(r, id) {
			forbid(w)
			return
		}
	}
	rows, err := s.pickingRows(ids)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	byProduct := map[string]*pickingLine{}
	order := []string{}
	for _, l := range rows {
		agg := byProduct[l.ProductID]
		if agg == nil {
			c := l
			c.LineID = ""
			c.Orders = []pickingOrderRef{}
			byProduct[l.ProductID] = &c
			agg = &c
			agg.QtyValidated, agg.QtyFree, agg.QtyToPrepare, agg.QtyPrepared, agg.QtyRemaining = 0, 0, 0, 0, 0
			order = append(order, l.ProductID)
		}
		agg.QtyValidated += l.QtyValidated
		agg.QtyFree += l.QtyFree
		agg.QtyToPrepare += l.QtyToPrepare
		agg.QtyPrepared += l.QtyPrepared
		agg.QtyRemaining += l.QtyRemaining
		agg.Orders = append(agg.Orders, l.Orders...)
	}
	items := []pickingLine{}
	for _, pid := range order {
		l := byProduct[pid]
		l.Stock = s.stockByWarehouse(pid)
		l.LotSuggestions = []domain.LotSuggestion{}
		if l.TrackLots && l.QtyRemaining > 0 {
			l.LotSuggestions, _ = domain.FEFOSuggestions(s.db, pid, l.QtyRemaining)
		}
		items = append(items, *l)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "order_ids": ids})
}

// ---- Backorders -----------------------------------------------------------------------------

type backorderRow struct {
	LineID       string `json:"line_id"`
	OrderID      string `json:"order_id"`
	OrderNumber  string `json:"order_number"`
	OrderStatus  string `json:"order_status"`
	OrderDate    string `json:"order_date"`
	PartnerID    string `json:"partner_id"`
	PartnerName  string `json:"partner_name"`
	PartnerPhone string `json:"partner_phone"`
	ProductID    string `json:"product_id"`
	ProductName  string `json:"product_name"`
	WarehouseID  string `json:"warehouse_id"`
	QtyBackorder int64  `json:"qty_backorder_milli"`
	UnitPrice    int64  `json:"unit_price"`
	Available    int64  `json:"available_milli"`
	Fulfillable  int64  `json:"fulfillable_milli"`
}

func (s *Server) backorderRows(r *http.Request, productID string) ([]backorderRow, error) {
	qp := r.URL.Query()
	where := ` WHERE l.qty_backorder_milli > 0 AND o.status <> 'cancelled'`
	args := []any{}
	if v := qp.Get("partner_id"); v != "" {
		where += ` AND o.partner_id = ?`
		args = append(args, v)
	}
	if productID == "" {
		productID = qp.Get("product_id")
	}
	if productID != "" {
		where += ` AND l.product_id = ?`
		args = append(args, productID)
	}
	if v := qp.Get("rep_user_id"); v != "" {
		where += ` AND o.rep_user_id = ?`
		args = append(args, v)
	}
	sw, sa := orderScopeWhere(authFrom(r))
	where += sw
	args = append(args, sa...)
	rows, err := s.db.Query(`SELECT l.id, o.id, o.number, o.status, o.order_date, o.partner_id, p.name,
			COALESCE(p.phone,''), l.product_id, pr.name, o.warehouse_id, l.qty_backorder_milli, l.unit_price
		FROM customer_order_lines l JOIN customer_orders o ON o.id = l.order_id
		JOIN partners p ON p.id = o.partner_id JOIN products pr ON pr.id = l.product_id`+where+
		` ORDER BY o.order_date, o.number, l.position`, args...)
	if err != nil {
		return nil, err
	}
	var out []backorderRow
	for rows.Next() {
		var b backorderRow
		if err := rows.Scan(&b.LineID, &b.OrderID, &b.OrderNumber, &b.OrderStatus, &b.OrderDate, &b.PartnerID,
			&b.PartnerName, &b.PartnerPhone, &b.ProductID, &b.ProductName, &b.WarehouseID, &b.QtyBackorder,
			&b.UnitPrice); err != nil {
			rows.Close()
			return nil, err
		}
		out = append(out, b)
	}
	rows.Close()
	// Fulfillable: first come, first served on what is available.
	left := map[string]int64{}
	for i := range out {
		b := &out[i]
		k := b.ProductID + "|" + b.WarehouseID
		a, ok := left[k]
		if !ok {
			a = domain.AvailableQty(s.db, b.ProductID, b.WarehouseID, "")
		}
		b.Available = max(0, a)
		b.Fulfillable = min(b.QtyBackorder, max(0, a))
		left[k] = a - b.Fulfillable
	}
	return out, nil
}

// listBackorders: GET /orders/backorders.
func (s *Server) listBackorders(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.view") {
		return
	}
	rows, err := s.backorderRows(r, "")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	items := []backorderRow{}
	onlyOK := r.URL.Query().Get("fulfillable") == "1"
	var total, fulfillable int
	for _, b := range rows {
		total++
		if b.Fulfillable > 0 {
			fulfillable++
		}
		if onlyOK && b.Fulfillable <= 0 {
			continue
		}
		items = append(items, b)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": total, "fulfillable_count": fulfillable})
}

// backorderNewOrder: POST /orders/backorders/new-order {partner_id, line_ids?}.
func (s *Server) backorderNewOrder(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	var in struct {
		PartnerID string   `json:"partner_id"`
		LineIDs   []string `json:"line_ids"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.PartnerID == "" {
		writeFieldErr(w, http.StatusBadRequest, "partner_id", "le client est obligatoire")
		return
	}
	if !s.canSeePartner(r, in.PartnerID) {
		forbid(w)
		return
	}
	var id, number string
	if !s.inTx(w, func(tx *sql.Tx) error {
		var err error
		id, number, err = domain.BackorderToNewOrder(tx, in.PartnerID, in.LineIDs, uidOf(r))
		return err
	}) {
		return
	}
	s.audit(r, "order.create", "customer_order", id, number+" (reliquat)")
	s.respondOrder(w, id, http.StatusCreated, nil)
}

// waitingCustomers: GET /products/{id}/waiting-customers — who waits for this
// product (backorders), to call them when the stock arrives.
func (s *Server) waitingCustomers(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.view") {
		return
	}
	pid := chi.URLParam(r, "id")
	var name string
	if err := s.db.QueryRow(`SELECT name FROM products WHERE id = ?`, pid).Scan(&name); err != nil {
		writeErr(w, http.StatusNotFound, "produit introuvable")
		return
	}
	rows, err := s.backorderRows(r, pid)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if rows == nil {
		rows = []backorderRow{}
	}
	var waiting int64
	for _, b := range rows {
		waiting += b.QtyBackorder
	}
	var stock int64
	s.db.QueryRow(`SELECT COALESCE(SUM(qty_milli),0) FROM stock_levels WHERE product_id = ?`, pid).Scan(&stock)
	writeJSON(w, http.StatusOK, map[string]any{"product_id": pid, "product_name": name, "stock_milli": stock,
		"total_backorder_milli": waiting, "items": rows})
}

// ---- Storefront import / status sync -------------------------------------------------------

type webOrderItem struct {
	ProductID     string   `json:"product_id"`
	Name          string   `json:"name"`
	QtyMilli      int64    `json:"qty_milli"`
	Qty           *float64 `json:"qty"`
	PriceCentimes *int64   `json:"price_centimes"` // TTC unit price shown on the storefront
}

type webOrderPayload struct {
	ID                  string         `json:"id"`
	Number              string         `json:"number"`
	CustomerName        string         `json:"customer_name"`
	Phone               string         `json:"phone"`
	Email               string         `json:"email"`
	CustomerType        string         `json:"customer_type"`
	BusinessName        string         `json:"business_name"`
	NIF                 string         `json:"nif"`
	Wilaya              string         `json:"wilaya"`
	Commune             string         `json:"commune"`
	Address             string         `json:"address"`
	Note                string         `json:"note"`
	Items               []webOrderItem `json:"items"`
	ShippingFeeCentimes int64          `json:"shipping_fee_centimes"`
	PromoCode           string         `json:"promo_code"`
	DiscountCentimes    int64          `json:"discount_centimes"`
	TotalCentimes       int64          `json:"total_centimes"`
	CreatedAt           string         `json:"created_at"`
}

// NormalizePhoneDZ returns an Algerian number as 0XXXXXXXXX (10 digits for
// mobiles, 9 for fixed lines), "" when it does not look like one. Accepts
// +213…, 00213…, 213…, spaces, dots and dashes.
func NormalizePhoneDZ(p string) string {
	digits := make([]byte, 0, len(p))
	for i := 0; i < len(p); i++ {
		if p[i] >= '0' && p[i] <= '9' {
			digits = append(digits, p[i])
		}
	}
	d := string(digits)
	switch {
	case strings.HasPrefix(d, "00213"):
		d = "0" + d[5:]
	case strings.HasPrefix(d, "213") && len(d) >= 11:
		d = "0" + d[3:]
	case len(d) == 9 && d[0] != '0':
		d = "0" + d
	}
	if len(d) < 9 || len(d) > 10 || d[0] != '0' {
		return ""
	}
	return d
}

// IntlPhoneDZ is the wa.me form: 213XXXXXXXXX.
func IntlPhoneDZ(p string) string {
	n := NormalizePhoneDZ(p)
	if n == "" {
		return ""
	}
	return "213" + n[1:]
}

func webClientType(t string) string {
	t = strings.ToLower(strings.TrimSpace(t))
	switch {
	case strings.Contains(t, "sup"):
		return "supermarket"
	case strings.Contains(t, "restau"):
		return "restaurant"
	case strings.Contains(t, "hotel") || strings.Contains(t, "hôtel"):
		return "hotel"
	case strings.Contains(t, "gross") || strings.Contains(t, "whole"):
		return "wholesaler"
	case strings.Contains(t, "detail") || strings.Contains(t, "détail") || strings.Contains(t, "retail") ||
		strings.Contains(t, "commer") || strings.Contains(t, "pro"):
		return "retailer"
	case t == "" || strings.Contains(t, "partic") || strings.Contains(t, "indiv") || strings.Contains(t, "client"):
		return "individual"
	}
	return "other"
}

// findPartnerByPhone matches a customer by normalized phone (partner phone,
// WhatsApp, or one of his contacts).
func findPartnerByPhone(tx *sql.Tx, phone string) string {
	want := NormalizePhoneDZ(phone)
	if want == "" {
		return ""
	}
	rows, err := tx.Query(`SELECT id, COALESCE(phone,''), whatsapp FROM partners
		WHERE kind IN ('customer','both') ORDER BY active DESC, created_at`)
	if err != nil {
		return ""
	}
	type cand struct{ id, a, b string }
	var cs []cand
	for rows.Next() {
		var c cand
		rows.Scan(&c.id, &c.a, &c.b)
		cs = append(cs, c)
	}
	rows.Close()
	for _, c := range cs {
		if NormalizePhoneDZ(c.a) == want || NormalizePhoneDZ(c.b) == want {
			return c.id
		}
	}
	crows, err := tx.Query(`SELECT c.partner_id, c.phone, c.whatsapp FROM partner_contacts c
		JOIN partners p ON p.id = c.partner_id WHERE p.kind IN ('customer','both')`)
	if err != nil {
		return ""
	}
	cs = cs[:0]
	for crows.Next() {
		var c cand
		crows.Scan(&c.id, &c.a, &c.b)
		cs = append(cs, c)
	}
	crows.Close()
	for _, c := range cs {
		if NormalizePhoneDZ(c.a) == want || NormalizePhoneDZ(c.b) == want {
			return c.id
		}
	}
	return ""
}

// importWebOrder: POST /orders/import-web — one storefront order becomes a
// customer order (source web, cash on delivery). Idempotent on the storefront
// id: a second import answers 200 with the existing order.
func (s *Server) importWebOrder(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	var in webOrderPayload
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil { // storefront payloads may carry extra keys
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	in.ID = strings.TrimSpace(in.ID)
	if in.ID == "" {
		writeFieldErr(w, http.StatusBadRequest, "id", "l'identifiant de la commande web est obligatoire")
		return
	}
	if len(in.Items) == 0 {
		writeFieldErr(w, http.StatusBadRequest, "items", "la commande web n'a aucun article")
		return
	}
	var existing string
	s.db.QueryRow(`SELECT id FROM customer_orders WHERE source = 'web' AND external_ref = ?`, in.ID).Scan(&existing)
	if existing != "" {
		s.respondOrder(w, existing, http.StatusOK, map[string]any{"created": false, "partner_created": false,
			"warnings": []string{}})
		return
	}
	var orderID, number, partnerID string
	partnerCreated := false
	warnings := []string{}
	if !s.inTx(w, func(tx *sql.Tx) error {
		partnerID = findPartnerByPhone(tx, in.Phone)
		if partnerID == "" {
			partnerID = domain.NewID()
			partnerCreated = true
			now := domain.NowISO()
			name := strings.TrimSpace(in.BusinessName)
			if name == "" {
				name = strings.TrimSpace(in.CustomerName)
			}
			if name == "" {
				name = "Client web " + in.Number
			}
			phone := NormalizePhoneDZ(in.Phone)
			if phone == "" {
				phone = strings.TrimSpace(in.Phone)
			}
			if _, err := tx.Exec(`INSERT INTO partners (id, kind, name, phone, email, address, nif, active,
					client_type, crm_status, wilaya, commune, source, created_at, updated_at)
				VALUES (?, 'customer', ?, ?, ?, ?, ?, 1, ?, 'active', ?, ?, 'web', ?, ?)`,
				partnerID, name, nullIfBlank(phone), nullIfBlank(in.Email), nullIfBlank(in.Address),
				nullIfBlank(in.NIF), webClientType(in.CustomerType), strings.TrimSpace(in.Wilaya),
				strings.TrimSpace(in.Commune), now, now); err != nil {
				return err
			}
			if strings.TrimSpace(in.BusinessName) != "" && strings.TrimSpace(in.CustomerName) != "" {
				if _, err := tx.Exec(`INSERT INTO partner_contacts (id, partner_id, name, phone, email, is_primary,
						created_at, updated_at) VALUES (?, ?, ?, ?, ?, 1, ?, ?)`, domain.NewID(), partnerID,
					strings.TrimSpace(in.CustomerName), phone, strings.TrimSpace(in.Email), now, now); err != nil {
					return err
				}
			}
		}
		zero := int64(0)
		var lines []domain.OrderLineInput
		for _, it := range in.Items {
			qty := it.QtyMilli
			if qty == 0 && it.Qty != nil {
				qty = int64(*it.Qty*1000 + 0.5)
			}
			var vat int64
			var active int
			if err := tx.QueryRow(`SELECT vat_rate, active FROM products WHERE id = ?`, it.ProductID).Scan(&vat, &active); err != nil {
				warnings = append(warnings, fmt.Sprintf("article « %s » inconnu (id %s) : ignoré", it.Name, it.ProductID))
				continue
			}
			if qty <= 0 {
				warnings = append(warnings, fmt.Sprintf("article « %s » sans quantité : ignoré", it.Name))
				continue
			}
			l := domain.OrderLineInput{ProductID: it.ProductID, QtyMilli: qty, PriceSource: domain.PriceWeb}
			if it.PriceCentimes != nil && *it.PriceCentimes >= 0 {
				ht := domain.UnitHTFromTTC(*it.PriceCentimes, vat)
				l.UnitPrice, l.DiscountPct = &ht, &zero
			}
			lines = append(lines, l)
		}
		if len(lines) == 0 {
			return &domain.PostError{Msg: "aucun article de la commande web n'est reconnu : " + strings.Join(warnings, " ; ")}
		}
		ext, extNum := in.ID, in.Number
		addr, wil, com, cname, cphone := in.Address, in.Wilaya, in.Commune, in.CustomerName, in.Phone
		internal := ""
		if len(warnings) > 0 {
			internal = "Import web : " + strings.Join(warnings, " ; ")
		}
		var err error
		orderID, number, err = domain.CreateOrder(tx, domain.OrderInput{PartnerID: partnerID, Source: "web",
			PaymentMode: "cod", ExternalRef: &ext, ExternalNumber: &extNum, DeliveryAddress: &addr,
			Wilaya: &wil, Commune: &com, ContactName: &cname, ContactPhone: &cphone, Notes: in.Note,
			InternalNotes: internal, ShippingFee: max(0, in.ShippingFeeCentimes),
			ExtraDiscount: max(0, in.DiscountCentimes), PromoCode: in.PromoCode, Lines: lines}, uidOf(r))
		if err != nil {
			return err
		}
		var total int64
		tx.QueryRow(`SELECT total_ttc FROM customer_orders WHERE id = ?`, orderID).Scan(&total)
		if in.TotalCentimes > 0 && total != in.TotalCentimes {
			warnings = append(warnings, fmt.Sprintf("total boutique %s DA ≠ total calculé %s DA",
				centimes(in.TotalCentimes), centimes(total)))
		}
		note := "importée de la boutique web"
		if in.Number != "" {
			note += " (n° " + in.Number + ")"
		}
		if partnerCreated {
			note += " — nouveau client créé"
		}
		return domain.OrderEvent(tx, orderID, "import", "", "", uidOf(r), note)
	}) {
		return
	}
	s.audit(r, "order.import_web", "customer_order", orderID, number+" ← web "+in.Number)
	s.respondOrder(w, orderID, http.StatusCreated, map[string]any{"created": true,
		"partner_created": partnerCreated, "warnings": warnings})
}

func nullIfBlank(v string) any {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	return strings.TrimSpace(v)
}

// webSyncList: GET /orders/web-sync — web orders whose status changed since
// the last push to the storefront.
func (s *Server) webSyncList(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.view") {
		return
	}
	rows, err := s.db.Query(`SELECT o.id, o.number, COALESCE(o.external_ref,''), COALESCE(o.external_number,''),
			o.status, o.updated_at, o.cancel_reason,
			COALESCE((SELECT e.note FROM customer_order_events e WHERE e.order_id = o.id AND e.to_status IS NOT NULL
			          ORDER BY e.created_at DESC, e.id DESC LIMIT 1), ''),
			COALESCE((SELECT e.created_at FROM customer_order_events e WHERE e.order_id = o.id AND e.to_status IS NOT NULL
			          ORDER BY e.created_at DESC, e.id DESC LIMIT 1), '')
		FROM customer_orders o WHERE o.web_status_dirty = 1 ORDER BY o.updated_at`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	type item struct {
		ID             string `json:"id"`
		Number         string `json:"number"`
		ExternalRef    string `json:"external_ref"`
		ExternalNumber string `json:"external_number"`
		Status         string `json:"status"`
		StatusLabel    string `json:"status_label"`
		UpdatedAt      string `json:"updated_at"`
		CancelReason   string `json:"cancel_reason"`
		LastEventNote  string `json:"last_event_note"`
		LastEventAt    string `json:"last_event_at"`
	}
	items := []item{}
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Number, &it.ExternalRef, &it.ExternalNumber, &it.Status, &it.UpdatedAt,
			&it.CancelReason, &it.LastEventNote, &it.LastEventAt); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		it.StatusLabel = domain.OrderStatusLabels[it.Status]
		items = append(items, it)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// webSyncAck: POST /orders/web-sync/ack {items:[{id, status}]} — clears the
// flag of the orders pushed, only if their status did not change meanwhile.
func (s *Server) webSyncAck(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.manage") {
		return
	}
	var in struct {
		Items []struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		} `json:"items"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	cleared := 0
	if !s.inTx(w, func(tx *sql.Tx) error {
		for _, it := range in.Items {
			res, err := tx.Exec(`UPDATE customer_orders SET web_status_dirty = 0 WHERE id = ? AND status = ?`, it.ID, it.Status)
			if err != nil {
				return err
			}
			n, _ := res.RowsAffected()
			cleared += int(n)
		}
		return nil
	}) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"cleared": cleared})
}

// ---- small decoding helpers ------------------------------------------------------------------

func readAllLimited(r *http.Request) ([]byte, error) {
	var raw json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&raw); err != nil {
		return nil, err
	}
	return raw, nil
}

func decodeStrict(body []byte, v any) error {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

// decodeOptional decodes a body that may be empty.
func decodeOptional(r *http.Request, v any) error {
	if r.Body == nil {
		return nil
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil && err.Error() != "EOF" {
		return err
	}
	return nil
}
