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

type Partner struct {
	ID             string  `json:"id"`
	Kind           string  `json:"kind"`
	Name           string  `json:"name"`
	Phone          *string `json:"phone"`
	Email          *string `json:"email"`
	Address        *string `json:"address"`
	NIF            *string `json:"nif"`
	NIS            *string `json:"nis"`
	RC             *string `json:"rc"`
	AI             *string `json:"ai"`
	CreditLimit    *int64  `json:"credit_limit"`
	Notes          *string `json:"notes"`
	PriceLevel     string  `json:"price_level"`      // retail | wholesale
	MinShelfDays   int64   `json:"min_shelf_days"`   // durée de vie restante minimale (jours)
	OverReceiptPct int64   `json:"over_receipt_pct"` // tolérance de sur-réception, pct x100
	Active         bool    `json:"active"`
	Balance        int64   `json:"balance"` // positive = the partner owes us
	// Groupe de clients : tarif et remise appliqués quand le client est choisi.
	GroupID          *string `json:"group_id"`
	GroupName        *string `json:"group_name"`
	GroupPriceLevel  *string `json:"group_price_level"`  // retail | wholesale, nil = no group
	GroupDiscountPct int64   `json:"group_discount_pct"` // pct x100, 0 = none
	CreatedAt        string  `json:"created_at"`
	UpdatedAt      string  `json:"updated_at"`
}

const partnerCols = `p.id, p.kind, p.name, p.phone, p.email, p.address, p.nif, p.nis, p.rc, p.ai,
	p.credit_limit, p.notes, p.price_level, p.min_shelf_days, p.over_receipt_pct, p.active,
	COALESCE((SELECT SUM(amount) FROM partner_ledger pl WHERE pl.partner_id = p.id), 0),
	p.group_id, (SELECT g.name FROM customer_groups g WHERE g.id = p.group_id),
	(SELECT g.price_level FROM customer_groups g WHERE g.id = p.group_id),
	COALESCE((SELECT g.discount_pct FROM customer_groups g WHERE g.id = p.group_id), 0),
	p.created_at, p.updated_at`

func scanPartner(row interface{ Scan(...any) error }) (Partner, error) {
	var p Partner
	var active int
	err := row.Scan(&p.ID, &p.Kind, &p.Name, &p.Phone, &p.Email, &p.Address,
		&p.NIF, &p.NIS, &p.RC, &p.AI, &p.CreditLimit, &p.Notes, &p.PriceLevel,
		&p.MinShelfDays, &p.OverReceiptPct, &active,
		&p.Balance, &p.GroupID, &p.GroupName, &p.GroupPriceLevel, &p.GroupDiscountPct,
		&p.CreatedAt, &p.UpdatedAt)
	p.Active = active == 1
	return p, err
}

func (s *Server) listPartners(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	kind := r.URL.Query().Get("kind")
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))

	where := "WHERE active = 1"
	args := []any{}
	if q != "" {
		where += " AND (name LIKE ? OR phone LIKE ?)"
		like := "%" + q + "%"
		args = append(args, like, like)
	}
	if kind == "customer" || kind == "supplier" {
		where += " AND kind IN (?, 'both')"
		args = append(args, kind)
	}
	if g := r.URL.Query().Get("group_id"); g != "" {
		where += " AND p.group_id = ?"
		args = append(args, g)
	}
	args = append(args, limit, offset)

	rows, err := s.db.Query(`SELECT `+partnerCols+` FROM partners p `+where+
		` ORDER BY name LIMIT ? OFFSET ?`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Partner{}
	for rows.Next() {
		p, err := scanPartner(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, p)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type partnerInput struct {
	Kind           string  `json:"kind"`
	Name           string  `json:"name"`
	Phone          *string `json:"phone"`
	Email          *string `json:"email"`
	Address        *string `json:"address"`
	NIF            *string `json:"nif"`
	NIS            *string `json:"nis"`
	RC             *string `json:"rc"`
	AI             *string `json:"ai"`
	CreditLimit    *int64  `json:"credit_limit"`
	Notes          *string `json:"notes"`
	PriceLevel     string  `json:"price_level"`
	MinShelfDays   *int64  `json:"min_shelf_days"`
	OverReceiptPct *int64  `json:"over_receipt_pct"`
	Active         *bool   `json:"active"`
	// GroupID: absent = unchanged (update) / none (create); "" = leave the group.
	GroupID *string `json:"group_id"`
}

func orInt(v *int64, def int64) int64 {
	if v == nil {
		return def
	}
	return *v
}

func (in *partnerInput) validate() string {
	if strings.TrimSpace(in.Name) == "" {
		return "name is required"
	}
	if in.PriceLevel == "" {
		in.PriceLevel = "retail"
	}
	if in.PriceLevel != "retail" && in.PriceLevel != "wholesale" {
		return "price_level must be retail or wholesale"
	}
	switch in.Kind {
	case "customer", "supplier", "both":
		return ""
	default:
		return "kind must be customer, supplier or both"
	}
}

func (s *Server) createPartner(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "partners") && !s.can(r, "pos") {
		forbid(w)
		return
	}
	var in partnerInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	id, now := domain.NewID(), domain.NowISO()
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	// Plafond de crédit : un client sans plafond propre (NULL ou 0) suit le
	// plafond par défaut du magasin (`default_credit_limit`, lu à la caisse) —
	// changer ce réglage vaut donc pour tous ces clients, nouveaux compris.
	groupID, msg := s.partnerGroup(in.GroupID)
	if msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	_, err := s.db.Exec(`INSERT INTO partners (id, kind, name, phone, email, address,
			nif, nis, rc, ai, credit_limit, notes, price_level, min_shelf_days,
			over_receipt_pct, active, group_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, in.Kind, in.Name, in.Phone, in.Email, in.Address,
		in.NIF, in.NIS, in.RC, in.AI, in.CreditLimit, in.Notes, in.PriceLevel,
		orInt(in.MinShelfDays, 0), orInt(in.OverReceiptPct, 500),
		b2i(active), groupID, now, now)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	s.getPartnerByID(w, id)
}

func (s *Server) getPartner(w http.ResponseWriter, r *http.Request) {
	s.getPartnerByID(w, chi.URLParam(r, "id"))
}

func (s *Server) getPartnerByID(w http.ResponseWriter, id string) {
	p, err := scanPartner(s.db.QueryRow(`SELECT `+partnerCols+` FROM partners p WHERE p.id = ?`, id))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "partner not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, p)
}

func (s *Server) updatePartner(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "partners") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in partnerInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	res, err := s.db.Exec(`UPDATE partners SET kind=?, name=?, phone=?, email=?, address=?,
			nif=?, nis=?, rc=?, ai=?, credit_limit=?, notes=?, price_level=?,
			min_shelf_days=?, over_receipt_pct=?, active=?, updated_at=?
		WHERE id=?`,
		in.Kind, in.Name, in.Phone, in.Email, in.Address,
		in.NIF, in.NIS, in.RC, in.AI, in.CreditLimit, in.Notes, in.PriceLevel,
		orInt(in.MinShelfDays, 0), orInt(in.OverReceiptPct, 500), b2i(active),
		domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "partner not found")
		return
	}
	if in.GroupID != nil { // absent = unchanged
		groupID, msg := s.partnerGroup(in.GroupID)
		if msg != "" {
			writeErr(w, http.StatusBadRequest, msg)
			return
		}
		if _, err := s.db.Exec(`UPDATE partners SET group_id = ? WHERE id = ?`, groupID, id); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	s.getPartnerByID(w, id)
}

// partnerGroup checks a group id sent by the form: nil/"" = no group.
func (s *Server) partnerGroup(id *string) (any, string) {
	if id == nil || strings.TrimSpace(*id) == "" {
		return nil, ""
	}
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM customer_groups WHERE id = ?`, *id).Scan(&n)
	if n == 0 {
		return nil, "groupe de clients introuvable"
	}
	return *id, ""
}

// partnerBalance returns the partner's current balance from the ledger.
// Positive = the partner owes us.
func (s *Server) partnerBalance(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var balance sql.NullInt64
	if err := s.db.QueryRow(`SELECT SUM(amount) FROM partner_ledger WHERE partner_id = ?`, id).
		Scan(&balance); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"partner_id": id, "balance": balance.Int64})
}

// openItem is one invoice-like ledger entry with what is still open on it.
type openItem struct {
	DocumentID  string `json:"document_id"`
	Number      string `json:"number"`
	DocDate     string `json:"doc_date"`
	DueDate     string `json:"due_date"`
	Total       int64  `json:"total"`
	Outstanding int64  `json:"outstanding"`
	AgeDays     int    `json:"age_days"`
	Overdue     bool   `json:"overdue"`
}

// partnerSign: +1 reads the ledger as a receivable (customer), -1 as a
// payable (supplier).
func partnerSign(kind string) int64 {
	if kind == "supplier" {
		return -1
	}
	return 1
}

// ledgerFIFO matches payments and credit notes to the oldest invoices first
// (FIFO) and returns EVERY invoice entry with what is still open on it, plus
// the credit left unallocated. A settlement recorded before any open invoice
// (prepayment) is carried and consumed by the next invoices. Cancelled
// documents (and their void rows) are ignored entirely. The ledger itself
// stays a plain running balance; this is the derived aging view.
func ledgerFIFO(db *sql.DB, partnerID string, sgn int64) ([]*openItem, int64, error) {
	rows, err := db.Query(`SELECT pl.amount, COALESCE(pl.document_id,''), COALESCE(d.number,''),
			COALESCE(d.doc_date,''), COALESCE(d.due_date,'')
		FROM partner_ledger pl LEFT JOIN documents d ON d.id = pl.document_id
		WHERE pl.partner_id = ? AND COALESCE(d.status,'posted') <> 'cancelled'
		ORDER BY pl.created_at, pl.id`, partnerID)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var items []*openItem
	var credit int64 // settlements not (yet) allocated to an invoice
	for rows.Next() {
		var amt int64
		var doc, num, date, due string
		if err := rows.Scan(&amt, &doc, &num, &date, &due); err != nil {
			return nil, 0, err
		}
		amt *= sgn
		if amt > 0 {
			it := &openItem{DocumentID: doc, Number: num, DocDate: date,
				DueDate: due, Total: amt, Outstanding: amt}
			if credit > 0 {
				take := min(credit, amt)
				it.Outstanding -= take
				credit -= take
			}
			items = append(items, it)
			continue
		}
		settle := -amt
		for _, it := range items {
			if settle == 0 {
				break
			}
			take := min(it.Outstanding, settle)
			it.Outstanding -= take
			settle -= take
		}
		credit += settle
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	today := time.Now()
	for _, it := range items {
		if t, err := time.Parse("2006-01-02", it.DocDate); err == nil {
			it.AgeDays = int(today.Sub(t).Hours() / 24)
		}
		if t, err := time.Parse("2006-01-02", it.DueDate); err == nil &&
			it.Outstanding > 0 && today.After(t.AddDate(0, 0, 1)) {
			it.Overdue = true
		}
	}
	return items, credit, nil
}

// settleDocuments fills paid / remaining / payment_status on posted
// receivable/payable documents: cash and card sales are paid at once; credit
// sales and supplier invoices are settled FIFO from the partner ledger,
// computed once per partner for the whole page.
func settleDocuments(db *sql.DB, docs []Document) error {
	type key struct {
		partner string
		sgn     int64
	}
	cache := map[key]map[string]*openItem{}
	for i := range docs {
		d := &docs[i]
		d.Paid, d.Remaining, d.PaymentStatus = 0, 0, ""
		if d.Status != "posted" {
			continue
		}
		var sgn int64
		switch d.DocType {
		case domain.SaleTicket, domain.SaleInvoice:
			if d.PaymentMethod == nil || *d.PaymentMethod != "credit" {
				d.Paid, d.PaymentStatus = d.TotalTTC, "paid"
				continue
			}
			sgn = 1
		case domain.PurchaseInvoice:
			sgn = -1
		default:
			continue
		}
		if d.PartnerID == nil || d.TotalTTC <= 0 {
			continue
		}
		k := key{*d.PartnerID, sgn}
		byDoc, ok := cache[k]
		if !ok {
			items, _, err := ledgerFIFO(db, *d.PartnerID, sgn)
			if err != nil {
				return err
			}
			byDoc = map[string]*openItem{}
			for _, it := range items {
				if prev := byDoc[it.DocumentID]; prev != nil {
					prev.Total += it.Total
					prev.Outstanding += it.Outstanding
				} else {
					c := *it
					byDoc[it.DocumentID] = &c
				}
			}
			cache[k] = byDoc
		}
		rem := int64(0)
		if it := byDoc[d.ID]; it != nil {
			rem = it.Outstanding
		}
		rem = max(0, min(rem, d.TotalTTC))
		d.Remaining = rem
		d.Paid = d.TotalTTC - rem
		switch {
		case rem == 0:
			d.PaymentStatus = "paid"
		case rem < d.TotalTTC:
			d.PaymentStatus = "partial"
		default:
			d.PaymentStatus = "due"
		}
	}
	return nil
}

// partnerOpenItems returns what is still open per invoice, with its age.
func (s *Server) partnerOpenItems(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var kind string
	if err := s.db.QueryRow(`SELECT kind FROM partners WHERE id = ?`, id).Scan(&kind); err != nil {
		writeErr(w, http.StatusNotFound, "partner not found")
		return
	}
	items, credit, err := ledgerFIFO(s.db, id, partnerSign(kind))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	open := []*openItem{}
	var totalOpen int64
	for _, it := range items {
		if it.Outstanding <= 0 {
			continue
		}
		totalOpen += it.Outstanding
		open = append(open, it)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"partner_id": id, "open_items": open, "total_open": totalOpen, "unallocated_credit": credit,
	})
}
