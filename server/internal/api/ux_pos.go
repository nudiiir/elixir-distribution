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
	// timbre on the whole total when cash) or several rows.
	PaymentMethod *string      `json:"payment_method"`
	Payments      []PosPayment `json:"payments"`
	// Remise ticket (pct × 100) appliquée aux lignes qui n'en portent pas.
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
	if msg := s.checkDiscounts(r, domain.SaleTicket, in.Lines); msg != "" {
		writeErr(w, http.StatusForbidden, msg)
		return
	}

	// Payments: merge same-method rows, validate, and collapse a single row
	// into the classic single-method form (except the gift card, which has no
	// documents.payment_method value).
	method := in.PaymentMethod
	var pays []PosPayment
	if len(in.Payments) > 0 {
		if method != nil && *method != "" {
			writeErr(w, http.StatusBadRequest, "payment_method et payments sont exclusifs")
			return
		}
		byMethod := map[string]int64{}
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
			var ttc int64
			for _, l := range in.Lines {
				_, _, t := domain.LineTotals(l.UnitPrice, l.QtyMilli, l.DiscountPct, l.VatRate)
				ttc += t
			}
			if domain.TimbreApplies(domain.SaleTicket, m) {
				ttc += domain.Timbre(ttc)
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
		}
	} else if method != nil {
		if _, ok := domain.PaymentMethods[*method]; !ok || *method == "gift" {
			writeErr(w, http.StatusBadRequest, "moyen de paiement inconnu : "+*method)
			return
		}
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

// posRecent lists the last tickets of a caisse session (default: the open one).
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
