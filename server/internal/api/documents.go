package api

import (
	"database/sql"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

type DocumentLine struct {
	ID          string  `json:"id,omitempty"`
	Position    int     `json:"position"`
	ProductID   *string `json:"product_id"`
	LotID       *string `json:"lot_id"`
	Description string  `json:"description"`
	QtyMilli    int64   `json:"qty_milli"`
	UnitPrice   int64   `json:"unit_price"`
	DiscountPct int64   `json:"discount_pct"`
	VatRate     int64   `json:"vat_rate"`
	LineHT      int64   `json:"line_ht"`
	LineVAT     int64   `json:"line_vat"`
	LineTTC     int64   `json:"line_ttc"`
	UnitCost    *int64  `json:"unit_cost"`
	// Réception pro (spécification septembre 2026)
	QtyFreeMilli      int64   `json:"qty_free_milli"`
	LotNumber         *string `json:"lot_number"`
	ExpiryDate        *string `json:"expiry_date"`
	PackFactorMilli   int64   `json:"pack_factor_milli"`
	NewSalePrice      *int64  `json:"new_sale_price"`
	QtyReceivedMilli  int64   `json:"qty_received_milli"`
	QtyCancelledMilli int64   `json:"qty_cancelled_milli"`
	// Inventaire : quantité théorique affichée au moment du comptage
	ExpectedMilli *int64 `json:"expected_milli,omitempty"`
}

type Document struct {
	ID              string         `json:"id"`
	DocType         string         `json:"doc_type"`
	Number          *string        `json:"number"`
	Status          string         `json:"status"`
	DocDate         string         `json:"doc_date"`
	PartnerID       *string        `json:"partner_id"`
	WarehouseID     *string        `json:"warehouse_id"`
	DestWarehouseID *string        `json:"dest_warehouse_id"`
	RefDocumentID   *string        `json:"ref_document_id"`
	TotalHT         int64          `json:"total_ht"`
	TotalVAT        int64          `json:"total_vat"`
	TotalDiscount   int64          `json:"total_discount"`
	Timbre          int64          `json:"timbre"`
	TotalTTC        int64          `json:"total_ttc"`
	Amount          int64          `json:"amount"`
	PaymentMethod   *string        `json:"payment_method"`
	CaisseSessionID *string        `json:"caisse_session_id"`
	Notes           *string        `json:"notes"`
	PostedAt        *string        `json:"posted_at"`
	CreatedAt       string         `json:"created_at"`
	UpdatedAt       string         `json:"updated_at"`
	SupplierRef     *string        `json:"supplier_ref"`
	DueDate         *string        `json:"due_date"`
	FreightCost     int64          `json:"freight_cost"`
	Reason          *string        `json:"reason"`
	OrderStatus     *string        `json:"order_status"`
	AcceptShort     bool           `json:"accept_short_dated"`
	AcceptOver      bool           `json:"accept_over_receipt"`
	Lines           []DocumentLine `json:"lines,omitempty"`
}

const docCols = `id, doc_type, number, status, doc_date, partner_id, warehouse_id,
	dest_warehouse_id, ref_document_id, total_ht, total_vat, total_discount, timbre,
	total_ttc, amount, payment_method, caisse_session_id, notes, posted_at, created_at, updated_at,
	supplier_ref, due_date, freight_cost, reason, order_status, accept_short_dated, accept_over_receipt`

func scanDocument(row interface{ Scan(...any) error }) (Document, error) {
	var d Document
	var short, over int
	err := row.Scan(&d.ID, &d.DocType, &d.Number, &d.Status, &d.DocDate, &d.PartnerID,
		&d.WarehouseID, &d.DestWarehouseID, &d.RefDocumentID, &d.TotalHT, &d.TotalVAT,
		&d.TotalDiscount, &d.Timbre, &d.TotalTTC, &d.Amount, &d.PaymentMethod,
		&d.CaisseSessionID, &d.Notes, &d.PostedAt, &d.CreatedAt, &d.UpdatedAt,
		&d.SupplierRef, &d.DueDate, &d.FreightCost, &d.Reason, &d.OrderStatus, &short, &over)
	d.AcceptShort, d.AcceptOver = short == 1, over == 1
	return d, err
}

type documentInput struct {
	DocType         string         `json:"doc_type"`
	DocDate         string         `json:"doc_date"`
	PartnerID       *string        `json:"partner_id"`
	WarehouseID     *string        `json:"warehouse_id"`
	DestWarehouseID *string        `json:"dest_warehouse_id"`
	RefDocumentID   *string        `json:"ref_document_id"`
	Amount          int64          `json:"amount"`
	PaymentMethod   *string        `json:"payment_method"`
	CaisseSessionID *string        `json:"caisse_session_id"`
	Notes           *string        `json:"notes"`
	SupplierRef     *string        `json:"supplier_ref"`
	DueDate         *string        `json:"due_date"`
	FreightCost     int64          `json:"freight_cost"`
	Reason          *string        `json:"reason"`
	AcceptShort     bool           `json:"accept_short_dated"`
	AcceptOver      bool           `json:"accept_over_receipt"`
	Lines           []DocumentLine `json:"lines"`
}

func (s *Server) createDocument(w http.ResponseWriter, r *http.Request) {
	var in documentInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if _, ok := domain.NumberPrefix[in.DocType]; !ok {
		writeErr(w, http.StatusBadRequest, "invalid doc_type")
		return
	}
	if !docPermOK(authFrom(r), in.DocType) {
		forbid(w)
		return
	}
	if len(in.DocDate) != 10 {
		writeErr(w, http.StatusBadRequest, "doc_date must be YYYY-MM-DD")
		return
	}
	if msg := s.checkDiscounts(r, in.DocType, in.Lines); msg != "" {
		writeErr(w, http.StatusForbidden, msg)
		return
	}
	id, now := domain.NewID(), domain.NowISO()

	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`INSERT INTO documents (id, doc_type, status, doc_date, partner_id,
			warehouse_id, dest_warehouse_id, ref_document_id, amount, payment_method,
			caisse_session_id, notes, supplier_ref, due_date, freight_cost, reason,
			accept_short_dated, accept_over_receipt, created_at, updated_at)
		VALUES (?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, in.DocType, in.DocDate, in.PartnerID, in.WarehouseID, in.DestWarehouseID,
		in.RefDocumentID, in.Amount, in.PaymentMethod, in.CaisseSessionID, in.Notes,
		in.SupplierRef, in.DueDate, in.FreightCost, in.Reason,
		b2i(in.AcceptShort), b2i(in.AcceptOver), now, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if err := insertLines(tx, id, in.Lines, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.respondDocument(w, id, http.StatusCreated)
}

// updateDocument replaces the header fields and all lines of a draft.
func (s *Server) updateDocument(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var in documentInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}

	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()

	var status, docType string
	err = tx.QueryRow(`SELECT status, doc_type FROM documents WHERE id = ?`, id).
		Scan(&status, &docType)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "document not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if status != "draft" {
		writeErr(w, http.StatusConflict, "only draft documents can be edited")
		return
	}
	if !docPermOK(authFrom(r), docType) {
		forbid(w)
		return
	}
	if msg := s.checkDiscounts(r, docType, in.Lines); msg != "" {
		writeErr(w, http.StatusForbidden, msg)
		return
	}

	now := domain.NowISO()
	if _, err := tx.Exec(`UPDATE documents SET doc_date=?, partner_id=?, warehouse_id=?,
			dest_warehouse_id=?, ref_document_id=?, amount=?, payment_method=?,
			caisse_session_id=?, notes=?, supplier_ref=?, due_date=?, freight_cost=?,
			reason=?, accept_short_dated=?, accept_over_receipt=?, updated_at=?
		WHERE id=?`,
		in.DocDate, in.PartnerID, in.WarehouseID, in.DestWarehouseID, in.RefDocumentID,
		in.Amount, in.PaymentMethod, in.CaisseSessionID, in.Notes,
		in.SupplierRef, in.DueDate, in.FreightCost, in.Reason,
		b2i(in.AcceptShort), b2i(in.AcceptOver), now, id); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if _, err := tx.Exec(`DELETE FROM document_lines WHERE document_id = ?`, id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := insertLines(tx, id, in.Lines, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.respondDocument(w, id, http.StatusOK)
}

// checkDiscounts refuses sale-side discounts from users without the right.
func (s *Server) checkDiscounts(r *http.Request, docType string, lines []DocumentLine) string {
	if !strings.HasPrefix(docType, "SALE") && docType != domain.Quote &&
		docType != domain.DeliveryNote {
		return ""
	}
	if s.can(r, "discount") {
		return ""
	}
	for _, l := range lines {
		if l.DiscountPct != 0 {
			return "vous n'êtes pas autorisé à accorder des remises"
		}
	}
	return ""
}

func insertLines(tx *sql.Tx, docID string, lines []DocumentLine, now string) error {
	for i, l := range lines {
		ht, vat, ttc := domain.LineTotals(l.UnitPrice, l.QtyMilli, l.DiscountPct, l.VatRate)
		pack := l.PackFactorMilli
		if pack <= 0 {
			pack = 1000
		}
		if _, err := tx.Exec(`INSERT INTO document_lines (id, document_id, position, product_id,
				lot_id, description, qty_milli, unit_price, discount_pct, vat_rate,
				line_ht, line_vat, line_ttc, qty_free_milli, lot_number, expiry_date,
				pack_factor_milli, new_sale_price, expected_milli, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			domain.NewID(), docID, i, l.ProductID, l.LotID, l.Description,
			l.QtyMilli, l.UnitPrice, l.DiscountPct, l.VatRate, ht, vat, ttc,
			l.QtyFreeMilli, l.LotNumber, l.ExpiryDate, pack, l.NewSalePrice, l.ExpectedMilli, now); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) listDocuments(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))

	where := "WHERE 1=1"
	args := []any{}
	if t := r.URL.Query().Get("type"); t != "" {
		if !docPermOK(authFrom(r), t) {
			forbid(w)
			return
		}
		where += " AND doc_type = ?"
		args = append(args, t)
	} else if !s.can(r, "purchases") {
		// Without the purchases right, purchase documents stay invisible.
		where += " AND doc_type NOT LIKE 'PURCHASE%'"
	}
	if st := r.URL.Query().Get("status"); st != "" {
		where += " AND status = ?"
		args = append(args, st)
	}
	if p := r.URL.Query().Get("partner_id"); p != "" {
		where += " AND partner_id = ?"
		args = append(args, p)
	}
	if from := r.URL.Query().Get("from"); from != "" {
		where += " AND doc_date >= ?"
		args = append(args, from)
	}
	if to := r.URL.Query().Get("to"); to != "" {
		where += " AND doc_date <= ?"
		args = append(args, to)
	}
	args = append(args, limit, offset)

	rows, err := s.db.Query(`SELECT `+docCols+` FROM documents `+where+
		` ORDER BY doc_date DESC, created_at DESC LIMIT ? OFFSET ?`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Document{}
	for rows.Next() {
		d, err := scanDocument(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, d)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) getDocument(w http.ResponseWriter, r *http.Request) {
	s.respondDocument(w, chi.URLParam(r, "id"), http.StatusOK)
}

func (s *Server) respondDocument(w http.ResponseWriter, id string, status int) {
	d, err := scanDocument(s.db.QueryRow(`SELECT `+docCols+` FROM documents WHERE id = ?`, id))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "document not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	rows, err := s.db.Query(`SELECT id, position, product_id, lot_id, description, qty_milli,
			unit_price, discount_pct, vat_rate, line_ht, line_vat, line_ttc, unit_cost,
			qty_free_milli, lot_number, expiry_date, pack_factor_milli, new_sale_price,
			qty_received_milli, qty_cancelled_milli
		FROM document_lines WHERE document_id = ? ORDER BY position, created_at`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
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
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		d.Lines = append(d.Lines, l)
	}
	writeJSON(w, status, d)
}

func (s *Server) postDocument(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var docType string
	if err := s.db.QueryRow(`SELECT doc_type FROM documents WHERE id = ?`, id).
		Scan(&docType); err == nil {
		if !docPermOK(authFrom(r), docType) {
			forbid(w)
			return
		}
	}
	user := authFrom(r)
	userID := ""
	if user != nil {
		userID = user.ID
	}
	number, err := domain.Post(s.db, id, userID)
	if err != nil {
		var pe *domain.PostError
		switch {
		case errors.Is(err, domain.ErrNotFound):
			writeErr(w, http.StatusNotFound, err.Error())
		case errors.As(err, &pe):
			writeErr(w, http.StatusConflict, pe.Msg)
		case errors.Is(err, domain.ErrNotDraft), errors.Is(err, domain.ErrNoLines),
			errors.Is(err, domain.ErrNoWarehouse), errors.Is(err, domain.ErrNoDestWare),
			errors.Is(err, domain.ErrNoPartner), errors.Is(err, domain.ErrBadAmount),
			errors.Is(err, domain.ErrNoReason), errors.Is(err, domain.ErrNotImplemented):
			writeErr(w, http.StatusConflict, err.Error())
		default:
			writeErr(w, http.StatusInternalServerError, err.Error())
		}
		return
	}
	_ = number
	s.respondDocument(w, id, http.StatusOK)
}

// voidDocument reverses a posted document (contrepassation). The number stays,
// the reversing movements are written, the error remains visible.
func (s *Server) voidDocument(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var docType string
	if err := s.db.QueryRow(`SELECT doc_type FROM documents WHERE id = ?`, id).
		Scan(&docType); err == nil {
		if !docPermOK(authFrom(r), docType) {
			forbid(w)
			return
		}
	}
	var in struct {
		Reason string `json:"reason"`
	}
	decode(r, &in) // body optional
	user := authFrom(r)
	userID := ""
	if user != nil {
		userID = user.ID
	}
	if err := domain.Void(s.db, id, userID, in.Reason); err != nil {
		var pe *domain.PostError
		switch {
		case errors.Is(err, domain.ErrNotFound):
			writeErr(w, http.StatusNotFound, err.Error())
		case errors.As(err, &pe):
			writeErr(w, http.StatusConflict, pe.Msg)
		case errors.Is(err, domain.ErrNotPosted):
			writeErr(w, http.StatusConflict, err.Error())
		default:
			writeErr(w, http.StatusInternalServerError, err.Error())
		}
		return
	}
	s.respondDocument(w, id, http.StatusOK)
}

// closeOrder short-closes a purchase order: the outstanding quantity of every
// line becomes qty_cancelled, with a reason. The normal ending for most orders
// in this market, since suppliers routinely under-deliver.
func (s *Server) closeOrder(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "purchases") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in struct {
		Reason string `json:"reason"`
	}
	decode(r, &in)

	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()

	var docType, status string
	err = tx.QueryRow(`SELECT doc_type, status FROM documents WHERE id = ?`, id).
		Scan(&docType, &status)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "document not found")
		return
	}
	if docType != domain.PurchaseOrder || status != "posted" {
		writeErr(w, http.StatusConflict, "seul un bon de commande validé peut être clôturé")
		return
	}
	if _, err := tx.Exec(`UPDATE document_lines
		SET qty_cancelled_milli = MAX(qty_milli - qty_received_milli, 0)
		WHERE document_id = ? AND product_id IS NOT NULL`, id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if _, err := tx.Exec(`UPDATE documents SET order_status='closed', reason=?, updated_at=?
		WHERE id=?`, in.Reason, domain.NowISO(), id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.audit(r, "order.close", "document", id, "clôture du reliquat — "+in.Reason)
	s.respondDocument(w, id, http.StatusOK)
}

// MatchException is one open three-way-match exception on a purchase invoice
// (against its reception) or on a reception (against its order).
type MatchException struct {
	Kind      string `json:"kind"` // price | qty | missing_line | extra_line
	ProductID string `json:"product_id,omitempty"`
	Product   string `json:"product"`
	This      int64  `json:"this_value"`
	Ref       int64  `json:"ref_value"`
	Detail    string `json:"detail"`
}

// matchDocument compares a document with its ref document line by line.
// Tolerances per the spec: 2 % or 50 DA on unit price (whichever is greater),
// zero on quantities.
func (s *Server) matchDocument(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "purchases") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var refID sql.NullString
	if err := s.db.QueryRow(`SELECT ref_document_id FROM documents WHERE id = ?`, id).
		Scan(&refID); err != nil {
		writeErr(w, http.StatusNotFound, "document not found")
		return
	}
	if !refID.Valid {
		writeJSON(w, http.StatusOK, map[string]any{"items": []MatchException{}, "linked": false})
		return
	}

	type agg struct {
		qty, value int64
		name       string
	}
	load := func(docID string) (map[string]*agg, error) {
		rows, err := s.db.Query(`SELECT l.product_id, p.name,
				l.qty_milli * l.pack_factor_milli / 1000 + l.qty_free_milli * l.pack_factor_milli / 1000,
				l.line_ht
			FROM document_lines l JOIN products p ON p.id = l.product_id
			WHERE l.document_id = ? AND l.product_id IS NOT NULL`, docID)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		out := map[string]*agg{}
		for rows.Next() {
			var pid, name string
			var qty, ht int64
			if err := rows.Scan(&pid, &name, &qty, &ht); err != nil {
				return nil, err
			}
			a := out[pid]
			if a == nil {
				a = &agg{name: name}
				out[pid] = a
			}
			a.qty += qty
			a.value += ht
		}
		return out, nil
	}

	mine, err := load(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	ref, err := load(refID.String)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	items := []MatchException{}
	for pid, a := range mine {
		b, ok := ref[pid]
		if !ok {
			items = append(items, MatchException{Kind: "extra_line", ProductID: pid, Product: a.name,
				Detail: "ligne absente du document lié"})
			continue
		}
		if a.qty != b.qty {
			items = append(items, MatchException{Kind: "qty", ProductID: pid, Product: a.name,
				This: a.qty, Ref: b.qty, Detail: "écart de quantité"})
		}
		// Prix unitaire effectif : valeur / quantité, en centimes par unité.
		if a.qty > 0 && b.qty > 0 {
			pa := a.value * 1000 / a.qty
			pb := b.value * 1000 / b.qty
			diff := pa - pb
			if diff < 0 {
				diff = -diff
			}
			tol := pb * 2 / 100
			if tol < 5000 {
				tol = 5000 // 50 DA
			}
			if diff > tol {
				items = append(items, MatchException{Kind: "price", ProductID: pid, Product: a.name,
					This: pa, Ref: pb, Detail: "écart de prix au-delà de la tolérance"})
			}
		}
	}
	for pid, b := range ref {
		if _, ok := mine[pid]; !ok {
			items = append(items, MatchException{Kind: "missing_line", ProductID: pid, Product: b.name,
				Detail: "ligne du document lié non reprise"})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "linked": true})
}

func (s *Server) cancelDocument(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	res, err := s.db.Exec(`UPDATE documents SET status='cancelled', updated_at=?
		WHERE id=? AND status='draft'`, domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusConflict, "document not found or not a draft (posted documents are reversed with a credit note)")
		return
	}
	s.audit(r, "document.cancel", "document", id, "annulation d'un brouillon")
	s.respondDocument(w, id, http.StatusOK)
}
