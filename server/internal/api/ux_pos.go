package api

import (
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// routesPosUX registers the pos routes added by the UX-benchmark work.
func (s *Server) routesPosUX(r chi.Router) {
	r.Post("/pos/checkout", s.posCheckout)
	r.Get("/pos/recent", s.posRecent)
	r.Get("/pos/documents/{id}/payments", s.posDocPayments)
}

// PosPayment is one row of a mixed payment.
type PosPayment struct {
	Method string `json:"method"`
	Amount int64  `json:"amount"`
}

type posCheckoutInput struct {
	WarehouseID     string         `json:"warehouse_id"`
	PartnerID       *string        `json:"partner_id"`
	CaisseSessionID *string        `json:"caisse_session_id"`
	DocDate         string         `json:"doc_date"`
	Notes           *string        `json:"notes"`
	Lines           []DocumentLine `json:"lines"`
	// Either one method for the whole ticket (cash/cib/edahabia/cheque/credit,
	// stamp duty on the whole total when cash) or several rows.
	PaymentMethod *string      `json:"payment_method"`
	Payments      []PosPayment `json:"payments"`
	// Ticket discount (pct × 100) applied to lines that carry none.
	DiscountPct int64 `json:"discount_pct"`
}

// posCheckout creates and posts a SALE_TICKET in one call. Same permission and
// discount rules as document creation; a refused posting leaves no draft.
func (s *Server) posCheckout(w http.ResponseWriter, r *http.Request) {
	var in posCheckoutInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if !docPermOK(authFrom(r), domain.SaleTicket) {
		forbid(w)
		return
	}
	if in.WarehouseID == "" {
		writeErr(w, http.StatusBadRequest, "dépôt obligatoire")
		return
	}
	if len(in.Lines) == 0 {
		writeErr(w, http.StatusBadRequest, "le ticket est vide")
		return
	}
	if in.DocDate == "" {
		in.DocDate = time.Now().Format("2006-01-02")
	}
	if len(in.DocDate) != 10 {
		writeErr(w, http.StatusBadRequest, "doc_date must be YYYY-MM-DD")
		return
	}
	if in.DiscountPct < 0 || in.DiscountPct > 10000 {
		writeErr(w, http.StatusBadRequest, "remise invalide")
		return
	}
	if in.DiscountPct > 0 {
		for i := range in.Lines {
			if in.Lines[i].DiscountPct == 0 {
				in.Lines[i].DiscountPct = in.DiscountPct
			}
		}
	}
	// The customer's group discount (Paramètres › Clients et fidélité) is the
	// shop's own rule, not the cashier's: lines carrying exactly it are not
	// checked against the cashier's discount right.
	checked := in.Lines
	if g := s.posGroupDiscount(in.PartnerID); g > 0 {
		checked = make([]DocumentLine, len(in.Lines))
		copy(checked, in.Lines)
		for i := range checked {
			if checked[i].DiscountPct == g {
				checked[i].DiscountPct = 0
			}
		}
	}

	conf := s.loadPosConf()
	// « rapport Z quotidien » rule: a till opened on a previous day
	// must be closed before any new sale.
	if conf.RequireDailyZ {
		if stale, err := s.posSessionStale(in.CaisseSessionID, time.Now()); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		} else if stale {
			writeJSON(w, http.StatusConflict, map[string]any{
				"error":   "Clôturez la caisse d'hier (rapport Z) avant de vendre.",
				"needs_z": true,
			})
			return
		}
	}

	// Goods total (before stamp duty), basis of the cash rounding.
	var goods int64
	for _, l := range in.Lines {
		_, _, t := domain.LineTotals(l.UnitPrice, l.QtyMilli, l.DiscountPct, l.VatRate)
		goods += t
	}
	timbreCash := domain.TimbreApplies(domain.SaleTicket, "cash")
	// Cash rounding: amount (positive or negative) added to the ticket
	// as an « Arrondi » line — the ticket total is then exactly
	// what goes into the drawer, and the reports stay correct.
	var rounding int64

	// Payments: merge same-method rows, validate, and collapse a single row
	// into the classic single-method form (except the gift card, which has no
	// documents.payment_method value).
	method := in.PaymentMethod
	var pays []PosPayment
	byMethod := map[string]int64{}
	if len(in.Payments) > 0 {
		if method != nil && *method != "" {
			writeErr(w, http.StatusBadRequest, "payment_method et payments sont exclusifs")
			return
		}
		order := []string{}
		for _, p := range in.Payments {
			if _, ok := domain.PaymentMethods[p.Method]; !ok {
				writeErr(w, http.StatusBadRequest, "moyen de paiement inconnu : "+p.Method)
				return
			}
			if p.Amount <= 0 {
				writeErr(w, http.StatusBadRequest, "chaque paiement doit avoir un montant positif")
				return
			}
			if _, seen := byMethod[p.Method]; !seen {
				order = append(order, p.Method)
			}
			byMethod[p.Method] += p.Amount
		}
		if _, credit := byMethod["credit"]; credit && (in.PartnerID == nil || *in.PartnerID == "") {
			writeErr(w, http.StatusConflict, "un paiement à crédit exige un client")
			return
		}
		if len(order) == 1 && order[0] != "gift" {
			m := order[0]
			// A single row is stored as a classic one-method ticket, so the
			// posting engine never sees its amount: check it here.
			ttc := goods
			if domain.TimbreApplies(domain.SaleTicket, m) {
				ttc += domain.Timbre(ttc)
			}
			if m == "cash" && byMethod[m] != ttc {
				// Amount rounded by the till: accepted if it matches
				// the configured rounding exactly.
				if d := cashRoundingDelta(goods, conf.CashRounding, timbreCash); d != 0 &&
					byMethod[m] == cashDue(goods+d, timbreCash) {
					rounding, ttc = d, byMethod[m]
				}
			}
			if byMethod[m] != ttc {
				writeErr(w, http.StatusConflict, fmt.Sprintf(
					"le paiement (%s DA) ne correspond pas au total du ticket (%s DA)",
					centimes(byMethod[m]), centimes(ttc)))
				return
			}
			method = &m
		} else {
			for _, m := range order {
				pays = append(pays, PosPayment{Method: m, Amount: byMethod[m]})
			}
			method = nil
			// Mixed payment: the rounding applies to the cash part.
			if cash, ok := byMethod["cash"]; ok {
				cashGoods := goods - (sumPayments(byMethod) - cash)
				if d := cashRoundingDelta(cashGoods, conf.CashRounding, timbreCash); d != 0 &&
					cash == cashDue(cashGoods+d, timbreCash) {
					rounding = d
				}
			}
		}
	} else if method != nil {
		if _, ok := domain.PaymentMethods[*method]; !ok || *method == "gift" {
			writeErr(w, http.StatusBadRequest, "moyen de paiement inconnu : "+*method)
			return
		}
		byMethod[*method] = goods
		if *method == "cash" {
			rounding = cashRoundingDelta(goods, conf.CashRounding, timbreCash)
		}
	}

	// Till rights — the shared sale checks of the roles work: discount
	// (+ max_discount_pct), credit (+ max_credit, + the customer's ceiling),
	// approval_above. A refusal answers 403 needs_approval and the till
	// replays the request with X-Approval (« Code du gérant »).
	if !s.checkSaleRights(w, r, SaleCheck{
		DocType:   domain.SaleTicket,
		DocDate:   in.DocDate,
		PartnerID: in.PartnerID,
		Lines:     checked,
		Credit:    byMethod["credit"],
		Total:     goods + rounding,
		Posting:   true,
	}) {
		return
	}
	// Price changed at the till: right price_edit, else the manager's code.
	if !s.posCheckPrices(w, r, in.Lines) {
		return
	}
	// Customers without their own ceiling: the shop's default one
	// (Paramètres › Clients et fidélité, default_credit_limit).
	if need := s.posCheckRights(r, &in, byMethod, conf); need != nil {
		writeJSON(w, http.StatusForbidden, map[string]any{
			"error":          need.msg,
			"needs_approval": true,
			"action":         need.action,
		})
		return
	}

	if rounding != 0 {
		in.Lines = append(in.Lines, DocumentLine{
			Description: posRoundingLabel,
			QtyMilli:    1000,
			UnitPrice:   rounding,
		})
	}

	id, now := domain.NewID(), domain.NowISO()
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT INTO documents (id, doc_type, status, doc_date, partner_id,
			warehouse_id, payment_method, caisse_session_id, notes, created_at, updated_at)
		VALUES (?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, domain.SaleTicket, in.DocDate, in.PartnerID, in.WarehouseID, method,
		in.CaisseSessionID, in.Notes, now, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if err := insertLines(tx, id, in.Lines, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	for _, p := range pays {
		if _, err := tx.Exec(`INSERT INTO document_payments (id, document_id, method, amount, created_at)
			VALUES (?, ?, ?, ?, ?)`, domain.NewID(), id, p.Method, p.Amount, now); err != nil {
			writeErr(w, http.StatusConflict, err.Error())
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	userID := ""
	if u := authFrom(r); u != nil {
		userID = u.ID
	}
	if _, err := domain.Post(s.db, id, userID); err != nil {
		s.posDropDraft(id)
		posWritePostErr(w, err)
		return
	}
	doc, err := s.posLoadDocument(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	payments, _ := s.posPaymentsOf(id)
	writeJSON(w, http.StatusCreated, map[string]any{"document": doc, "payments": payments})
}

// posDropDraft removes a checkout draft whose posting was refused: the cashier
// fixes the cart and retries, nothing is left behind.
func (s *Server) posDropDraft(id string) {
	tx, err := s.db.Begin()
	if err != nil {
		return
	}
	defer tx.Rollback()
	var status string
	if tx.QueryRow(`SELECT status FROM documents WHERE id=?`, id).Scan(&status) != nil || status != "draft" {
		return
	}
	tx.Exec(`DELETE FROM document_payments WHERE document_id=?`, id)
	tx.Exec(`DELETE FROM document_lines WHERE document_id=?`, id)
	tx.Exec(`DELETE FROM documents WHERE id=? AND status='draft'`, id)
	tx.Commit()
}

func posWritePostErr(w http.ResponseWriter, err error) {
	var pe *domain.PostError
	switch {
	case errors.Is(err, domain.ErrNotFound):
		writeErr(w, http.StatusNotFound, err.Error())
	case errors.As(err, &pe):
		writeErr(w, http.StatusConflict, pe.Msg)
	case errors.Is(err, domain.ErrNoPartner):
		writeErr(w, http.StatusConflict, "un paiement à crédit exige un client")
	case errors.Is(err, domain.ErrNotDraft), errors.Is(err, domain.ErrNoLines),
		errors.Is(err, domain.ErrNoWarehouse), errors.Is(err, domain.ErrBadAmount):
		writeErr(w, http.StatusConflict, err.Error())
	default:
		writeErr(w, http.StatusInternalServerError, err.Error())
	}
}

// posLoadDocument reads a document with its lines (same shape as GET /documents/{id}).
func (s *Server) posLoadDocument(id string) (Document, error) {
	d, err := scanDocument(s.db.QueryRow(`SELECT `+docCols+` FROM documents WHERE id = ?`, id))
	if err != nil {
		return d, err
	}
	rows, err := s.db.Query(`SELECT id, position, product_id, lot_id, description, qty_milli,
			unit_price, discount_pct, vat_rate, line_ht, line_vat, line_ttc, unit_cost,
			qty_free_milli, lot_number, expiry_date, pack_factor_milli, new_sale_price,
			qty_received_milli, qty_cancelled_milli
		FROM document_lines WHERE document_id = ? ORDER BY position, created_at`, id)
	if err != nil {
		return d, err
	}
	defer rows.Close()
	d.Lines = []DocumentLine{}
	for rows.Next() {
		var l DocumentLine
		if err := rows.Scan(&l.ID, &l.Position, &l.ProductID, &l.LotID, &l.Description,
			&l.QtyMilli, &l.UnitPrice, &l.DiscountPct, &l.VatRate,
			&l.LineHT, &l.LineVAT, &l.LineTTC, &l.UnitCost,
			&l.QtyFreeMilli, &l.LotNumber, &l.ExpiryDate, &l.PackFactorMilli,
			&l.NewSalePrice, &l.QtyReceivedMilli, &l.QtyCancelledMilli); err != nil {
			return d, err
		}
		d.Lines = append(d.Lines, l)
	}
	return d, rows.Err()
}

func (s *Server) posPaymentsOf(id string) ([]PosPayment, error) {
	out := []PosPayment{}
	rows, err := s.db.Query(`SELECT method, amount FROM document_payments
		WHERE document_id = ? ORDER BY created_at, rowid`, id)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var p PosPayment
		if err := rows.Scan(&p.Method, &p.Amount); err != nil {
			return out, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Server) posDocPayments(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") && !s.can(r, "sales") {
		forbid(w)
		return
	}
	p, err := s.posPaymentsOf(chi.URLParam(r, "id"))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": p})
}

// PosRecentTicket is one line of the « Derniers tickets » panel.
type PosRecentTicket struct {
	ID            string       `json:"id"`
	Number        *string      `json:"number"`
	PostedAt      *string      `json:"posted_at"`
	TotalTTC      int64        `json:"total_ttc"`
	PaymentMethod *string      `json:"payment_method"`
	PartnerID     *string      `json:"partner_id"`
	PartnerName   *string      `json:"partner_name"`
	Status        string       `json:"status"`
	Payments      []PosPayment `json:"payments"`
}

// posRecent lists the last tickets of a till session (default: the open one).
func (s *Server) posRecent(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") {
		forbid(w)
		return
	}
	sessionID := r.URL.Query().Get("session_id")
	if sessionID == "" {
		c, err := s.openSessionRow()
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if c == nil {
			writeJSON(w, http.StatusOK, map[string]any{"items": []PosRecentTicket{}})
			return
		}
		sessionID = c.ID
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	rows, err := s.db.Query(`SELECT d.id, d.number, d.posted_at, d.total_ttc, d.payment_method,
			d.partner_id, p.name, d.status
		FROM documents d LEFT JOIN partners p ON p.id = d.partner_id
		WHERE d.doc_type = 'SALE_TICKET' AND d.status IN ('posted','cancelled')
		  AND d.number IS NOT NULL AND d.caisse_session_id = ?
		ORDER BY d.posted_at DESC LIMIT ?`, sessionID, limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	items := []PosRecentTicket{}
	for rows.Next() {
		var t PosRecentTicket
		var name sql.NullString
		if err := rows.Scan(&t.ID, &t.Number, &t.PostedAt, &t.TotalTTC, &t.PaymentMethod,
			&t.PartnerID, &name, &t.Status); err != nil {
			rows.Close()
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if name.Valid {
			t.PartnerName = &name.String
		}
		items = append(items, t)
	}
	rows.Close()
	for i := range items {
		items[i].Payments, _ = s.posPaymentsOf(items[i].ID)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// ---- Paramètres › Caisse: rules enforced by the server ----------------

// posRoundingLabel is the description of the cash-rounding line.
const posRoundingLabel = "Arrondi"

// posConf is the part of the shop-wide till settings the server enforces.
type posConf struct {
	CashRounding       int64 // centimes: 0 (none), 50, 100, 500
	RequireDailyZ      bool  // a till opened on a previous day blocks new sales
	DefaultCreditLimit int64 // centimes, 0 = no ceiling (customers without their own)
}

func (s *Server) loadPosConf() posConf {
	c := posConf{RequireDailyZ: true} // same defaults as the app (features.dart)
	rows, err := s.db.Query(`SELECT key, value FROM settings
		WHERE key IN ('pos_cash_rounding','pos_require_daily_z','default_credit_limit')`)
	if err != nil {
		return c
	}
	defer rows.Close()
	for rows.Next() {
		var k, v string
		if rows.Scan(&k, &v) != nil {
			continue
		}
		n, _ := strconv.ParseInt(v, 10, 64)
		switch k {
		case "pos_cash_rounding":
			if n > 0 {
				c.CashRounding = n
			}
		case "pos_require_daily_z":
			c.RequireDailyZ = v != "0"
		case "default_credit_limit":
			if n > 0 {
				c.DefaultCreditLimit = n
			}
		}
	}
	return c
}

// sessionFromPreviousDay reports whether a till opened at openedAt (RFC 3339,
// UTC) was opened on an earlier calendar day than now, in now's time zone.
func sessionFromPreviousDay(openedAt string, now time.Time) bool {
	t, err := time.Parse(time.RFC3339, openedAt)
	if err != nil {
		return false
	}
	return t.In(now.Location()).Format("2006-01-02") < now.Format("2006-01-02")
}

// posSessionStale: the session the ticket is rung on (or the open one) was
// opened on a previous day and is still open.
func (s *Server) posSessionStale(sessionID *string, now time.Time) (bool, error) {
	var openedAt string
	var err error
	if sessionID != nil && *sessionID != "" {
		err = s.db.QueryRow(`SELECT opened_at FROM caisse_sessions WHERE id=? AND status='open'`,
			*sessionID).Scan(&openedAt)
	} else {
		err = s.db.QueryRow(`SELECT opened_at FROM caisse_sessions WHERE status='open'
			ORDER BY opened_at DESC LIMIT 1`).Scan(&openedAt)
	}
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return sessionFromPreviousDay(openedAt, now), nil
}

// cashDue is the cash to take for goods paid in cash (stamp duty included when due).
func cashDue(cashGoods int64, timbre bool) int64 {
	if timbre && cashGoods > 0 {
		return cashGoods + domain.Timbre(cashGoods)
	}
	return cashGoods
}

func absI(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

// cashRoundingDelta returns the « Arrondi » amount d (centimes, may be < 0) to
// add to the goods paid in cash so that the cash to take — goods + d + the
// stamp duty on (goods + d) — is a multiple of step, as close as possible to the
// unrounded amount (nearest step, half up). 0 when no rounding applies.
func cashRoundingDelta(cashGoods, step int64, timbre bool) int64 {
	if step <= 0 || cashGoods <= 0 {
		return 0
	}
	base := cashDue(cashGoods, timbre)
	if base%step == 0 {
		return 0
	}
	near := ((base + step/2) / step) * step
	// The stamp duty moves by whole DA, so the nearest multiple may be out of
	// reach: then the next nearest one (below or above, closest first).
	other := []int64{near + step, near - step}
	if absI(near-step-base) < absI(near+step-base) {
		other[0], other[1] = other[1], other[0]
	}
	for _, target := range []int64{near, other[0], other[1]} {
		if target <= 0 {
			continue
		}
		best, found := int64(0), false
		for d := -2 * step; d <= 2*step; d++ {
			if cashGoods+d <= 0 || cashDue(cashGoods+d, timbre) != target {
				continue
			}
			if !found || absI(d) < absI(best) {
				best, found = d, true
			}
		}
		if found {
			return best
		}
	}
	return 0
}

func sumPayments(m map[string]int64) int64 {
	var t int64
	for _, v := range m {
		t += v
	}
	return t
}

type posNeed struct {
	action string
	msg    string
}

// posCheckRights applies the shop's default credit ceiling to customers who
// have none of their own (checkSaleRights covers the customer's own ceiling).
// A manager approval (X-Approval, right credit_limit) lifts it.
func (s *Server) posCheckRights(r *http.Request, in *posCheckoutInput,
	byMethod map[string]int64, conf posConf) *posNeed {
	credit := byMethod["credit"]
	if credit <= 0 || conf.DefaultCreditLimit <= 0 || in.PartnerID == nil || *in.PartnerID == "" {
		return nil
	}
	var limit sql.NullInt64
	if err := s.db.QueryRow(`SELECT credit_limit FROM partners WHERE id=?`, *in.PartnerID).
		Scan(&limit); err != nil || (limit.Valid && limit.Int64 > 0) {
		return nil
	}
	var balance int64
	s.db.QueryRow(`SELECT COALESCE(SUM(amount),0) FROM partner_ledger WHERE partner_id=?`,
		*in.PartnerID).Scan(&balance)
	ceiling := conf.DefaultCreditLimit
	if balance+credit <= ceiling || s.rightOrApproval(r, "credit_limit", balance+credit) {
		return nil
	}
	return &posNeed{"credit_limit", fmt.Sprintf(
		"le plafond de crédit du client (%s DA) serait dépassé : %s DA dus après cette vente",
		centimes(ceiling), centimes(balance+credit))}
}

// posGroupDiscount is the discount of the customer's group (pct × 100), 0 when
// the customer has no group (or the groups table is not there yet).
func (s *Server) posGroupDiscount(partnerID *string) int64 {
	if partnerID == nil || *partnerID == "" {
		return 0
	}
	var pct sql.NullInt64
	if err := s.db.QueryRow(`SELECT g.discount_pct FROM partners p
		JOIN customer_groups g ON g.id = p.group_id WHERE p.id = ?`, *partnerID).Scan(&pct); err != nil {
		return 0
	}
	return pct.Int64
}

// unitHTOf mirrors the app's incl. VAT → excl. VAT unit price conversion (CartLine.unitHT).
func unitHTOf(ttc, vat int64) int64 {
	return (ttc*10000 + (10000+vat)/2) / (10000 + vat)
}

// posCheckPrices: a product line sold at another price than the product's
// own (retail, semi-wholesale, promo) needs the price_edit right, or a manager
// code. Lines without a product (Arrondi, Points fidélité) are not prices.
func (s *Server) posCheckPrices(w http.ResponseWriter, r *http.Request, lines []DocumentLine) bool {
	for _, l := range lines {
		if l.ProductID == nil || *l.ProductID == "" {
			continue
		}
		var retail int64
		var wholesale, promo sql.NullInt64
		var vat int64
		if err := s.db.QueryRow(`SELECT price_retail, price_wholesale, promo_price, vat_rate
			FROM products WHERE id = ?`, *l.ProductID).Scan(&retail, &wholesale, &promo, &vat); err != nil {
			continue // unknown product: the posting engine refuses it
		}
		ok := false
		for _, ttc := range []sql.NullInt64{{Int64: retail, Valid: true}, wholesale, promo} {
			if ttc.Valid && ttc.Int64 > 0 &&
				(l.UnitPrice == unitHTOf(ttc.Int64, vat) || l.UnitPrice == unitHTOf(ttc.Int64, l.VatRate)) {
				ok = true
				break
			}
		}
		if ok {
			continue
		}
		return s.requireRight(w, r, "price_edit", 0,
			"prix de « "+l.Description+" » changé à la caisse : vous n'avez pas le droit de changer un prix")
	}
	return true
}
