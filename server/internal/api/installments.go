package api

import (
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// Payment plan (« Facilité de paiement »): a plan splits a sale's total into monthly dues. The
// debt itself lives in the partner ledger (the sale was posted on credit);
// dues only schedule it, and each collection is a normal PAYMENT_IN the
// app posts alongside marking the due paid.

type InstallmentDue struct {
	ID      string  `json:"id"`
	DueDate string  `json:"due_date"`
	Amount  int64   `json:"amount"`
	Paid    int64   `json:"paid"`
	PaidAt  *string `json:"paid_at"`
}

type InstallmentPlan struct {
	ID          string           `json:"id"`
	PartnerID   string           `json:"partner_id"`
	PartnerName string           `json:"partner_name"`
	DocumentID  *string          `json:"document_id"`
	DocNumber   *string          `json:"doc_number"`
	Total       int64            `json:"total"`
	Months      int64            `json:"months"`
	StartDate   string           `json:"start_date"`
	Notes       *string          `json:"notes"`
	CreatedAt   string           `json:"created_at"`
	Dues        []InstallmentDue `json:"dues"`
}

func (s *Server) listInstallmentPlans(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "partners") && !s.can(r, "pos") {
		forbid(w)
		return
	}
	where, args := "WHERE 1=1", []any{}
	if p := r.URL.Query().Get("partner_id"); p != "" {
		where += " AND ip.partner_id = ?"
		args = append(args, p)
	}
	rows, err := s.db.Query(`SELECT ip.id, ip.partner_id, pa.name, ip.document_id, d.number,
			ip.total, ip.months, ip.start_date, ip.notes, ip.created_at
		FROM installment_plans ip
		JOIN partners pa ON pa.id = ip.partner_id
		LEFT JOIN documents d ON d.id = ip.document_id `+where+
		` ORDER BY ip.created_at DESC LIMIT 200`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []InstallmentPlan{}
	for rows.Next() {
		var p InstallmentPlan
		if err := rows.Scan(&p.ID, &p.PartnerID, &p.PartnerName, &p.DocumentID,
			&p.DocNumber, &p.Total, &p.Months, &p.StartDate, &p.Notes, &p.CreatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		p.Dues = []InstallmentDue{}
		items = append(items, p)
	}
	for i := range items {
		dr, err := s.db.Query(`SELECT id, due_date, amount, paid, paid_at
			FROM installment_dues WHERE plan_id = ? ORDER BY due_date`, items[i].ID)
		if err != nil {
			continue
		}
		for dr.Next() {
			var d InstallmentDue
			if dr.Scan(&d.ID, &d.DueDate, &d.Amount, &d.Paid, &d.PaidAt) == nil {
				items[i].Dues = append(items[i].Dues, d)
			}
		}
		dr.Close()
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) createInstallmentPlan(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "partners") {
		forbid(w)
		return
	}
	var in struct {
		PartnerID  string  `json:"partner_id"`
		DocumentID *string `json:"document_id"`
		Total      int64   `json:"total"`
		Months     int64   `json:"months"`
		StartDate  string  `json:"start_date"`
		Notes      *string `json:"notes"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.PartnerID == "" || in.Total <= 0 || in.Months < 1 || in.Months > 60 ||
		len(in.StartDate) != 10 {
		writeErr(w, http.StatusBadRequest,
			"partner_id, total > 0, months 1..60 et start_date sont obligatoires")
		return
	}
	start, err := time.Parse("2006-01-02", in.StartDate)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "start_date must be YYYY-MM-DD")
		return
	}

	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()

	id, now := domain.NewID(), domain.NowISO()
	if _, err := tx.Exec(`INSERT INTO installment_plans
		(id, partner_id, document_id, total, months, start_date, notes, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		id, in.PartnerID, in.DocumentID, in.Total, in.Months, in.StartDate,
		in.Notes, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	// Equal monthly dues; the last one absorbs the rounding remainder so the
	// schedule always sums exactly to the total.
	per := in.Total / in.Months
	for i := int64(0); i < in.Months; i++ {
		amount := per
		if i == in.Months-1 {
			amount = in.Total - per*(in.Months-1)
		}
		due := start.AddDate(0, int(i), 0).Format("2006-01-02")
		if _, err := tx.Exec(`INSERT INTO installment_dues (id, plan_id, due_date, amount)
			VALUES (?, ?, ?, ?)`, domain.NewID(), id, due, amount); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) deleteInstallmentPlan(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "partners") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var paid int64
	s.db.QueryRow(`SELECT COALESCE(SUM(paid),0) FROM installment_dues WHERE plan_id = ?`, id).
		Scan(&paid)
	if paid > 0 {
		writeErr(w, http.StatusConflict,
			"des échéances ont déjà été encaissées — le plan ne peut plus être supprimé")
		return
	}
	res, err := s.db.Exec(`DELETE FROM installment_plans WHERE id = ?`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "plan not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// payDue records a payment against one due (the app posts the matching
// PAYMENT_IN through the normal document flow).
func (s *Server) payInstallmentDue(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "partners") && !s.can(r, "pos") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in struct {
		Amount *int64 `json:"amount"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	var amount, paid int64
	if err := s.db.QueryRow(`SELECT amount, paid FROM installment_dues WHERE id = ?`, id).
		Scan(&amount, &paid); err != nil {
		writeErr(w, http.StatusNotFound, "échéance introuvable")
		return
	}
	pay := amount - paid
	if in.Amount != nil {
		pay = *in.Amount
	}
	if pay <= 0 || paid+pay > amount {
		writeErr(w, http.StatusBadRequest, "montant invalide pour cette échéance")
		return
	}
	newPaid := paid + pay
	var paidAt any
	if newPaid >= amount {
		paidAt = domain.NowISO()
	}
	if _, err := s.db.Exec(`UPDATE installment_dues SET paid = ?, paid_at = ? WHERE id = ?`,
		newPaid, paidAt, id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"paid": newPaid, "amount": amount})
}

// overdueInstallments lists unpaid dues past their date — the follow-up list.
func (s *Server) overdueInstallments(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "partners") {
		forbid(w)
		return
	}
	today := domain.NowISO()[:10]
	rows, err := s.db.Query(`SELECT d.id, d.due_date, d.amount, d.paid, pa.name, pa.phone
		FROM installment_dues d
		JOIN installment_plans ip ON ip.id = d.plan_id
		JOIN partners pa ON pa.id = ip.partner_id
		WHERE d.paid < d.amount AND d.due_date < ?
		ORDER BY d.due_date LIMIT 200`, today)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	type row struct {
		ID          string  `json:"id"`
		DueDate     string  `json:"due_date"`
		Amount      int64   `json:"amount"`
		Paid        int64   `json:"paid"`
		PartnerName string  `json:"partner_name"`
		Phone       *string `json:"phone"`
	}
	items := []row{}
	for rows.Next() {
		var x row
		if rows.Scan(&x.ID, &x.DueDate, &x.Amount, &x.Paid, &x.PartnerName, &x.Phone) == nil {
			items = append(items, x)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}
