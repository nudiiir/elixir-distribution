package api

import (
	"database/sql"
	"net/http"
	"time"

	"elixir/server/internal/domain"
)

type CaisseSession struct {
	ID           string  `json:"id"`
	UserID       string  `json:"user_id"`
	UserName     string  `json:"user_name"`
	Status       string  `json:"status"`
	OpenedAt     string  `json:"opened_at"`
	ClosedAt     *string `json:"closed_at"`
	OpeningCash  int64   `json:"opening_cash"`
	ExpectedCash *int64  `json:"expected_cash"`
	CountedCash  *int64  `json:"counted_cash"`
	Notes        *string `json:"notes"`
}

// CaisseReport is the X/Z content: what happened since opening.
type CaisseReport struct {
	OpeningCash  int64 `json:"opening_cash"`
	TicketCount  int64 `json:"ticket_count"`
	TotalSales   int64 `json:"total_sales"`
	CashSales    int64 `json:"cash_sales"`
	CardSales    int64 `json:"card_sales"`
	CreditSales  int64 `json:"credit_sales"`
	OtherSales   int64 `json:"other_sales"`
	CashIn       int64 `json:"cash_in"`      // encaissements espèces
	CashOut      int64 `json:"cash_out"`     // règlements espèces
	CashRefunds  int64 `json:"cash_refunds"` // avoirs remboursés en espèces
	ExpectedCash int64 `json:"expected_cash"`
}

const sessionCols = `cs.id, cs.user_id, COALESCE(u.full_name, u.username, ''), cs.status,
	cs.opened_at, cs.closed_at, cs.opening_cash, cs.expected_cash, cs.counted_cash, cs.notes`

func scanSession(row interface{ Scan(...any) error }) (CaisseSession, error) {
	var c CaisseSession
	err := row.Scan(&c.ID, &c.UserID, &c.UserName, &c.Status, &c.OpenedAt,
		&c.ClosedAt, &c.OpeningCash, &c.ExpectedCash, &c.CountedCash, &c.Notes)
	return c, err
}

func (s *Server) openSessionRow() (*CaisseSession, error) {
	c, err := scanSession(s.db.QueryRow(`SELECT ` + sessionCols + `
		FROM caisse_sessions cs LEFT JOIN users u ON u.id = cs.user_id
		WHERE cs.status = 'open' ORDER BY cs.opened_at DESC LIMIT 1`))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &c, nil
}

func (s *Server) caisseCurrent(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") {
		forbid(w)
		return
	}
	c, err := s.openSessionRow()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	// needs_z: the open till dates from a previous day and the shop requires
	// a daily Z (Paramètres › Caisse) — new sales are refused until closed.
	needsZ := c != nil && s.loadPosConf().RequireDailyZ &&
		sessionFromPreviousDay(c.OpenedAt, time.Now())
	writeJSON(w, http.StatusOK, map[string]any{"session": c, "needs_z": needsZ})
}

// tillCloseAllowed: X/Z reports and closing need the close_till right; a
// manager approval (X-Approval) also works (needs_approval 403 otherwise).
func (s *Server) tillCloseAllowed(w http.ResponseWriter, r *http.Request) bool {
	return s.requireRight(w, r, "close_till", 0,
		"vous n'avez pas le droit de faire le rapport de caisse ni de la clôturer")
}

func (s *Server) caisseOpen(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") {
		forbid(w)
		return
	}
	var in struct {
		OpeningCash int64 `json:"opening_cash"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if existing, err := s.openSessionRow(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	} else if existing != nil {
		writeErr(w, http.StatusConflict, "une session de caisse est déjà ouverte")
		return
	}
	u := authFrom(r)
	id, now := domain.NewID(), domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO caisse_sessions
		(id, user_id, status, opened_at, opening_cash) VALUES (?, ?, 'open', ?, ?)`,
		id, u.ID, now, in.OpeningCash); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	c, err := s.openSessionRow()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.audit(r, "caisse.open", "caisse_session", id,
		"ouverture de caisse, fond "+centimes(in.OpeningCash)+" DA")
	writeJSON(w, http.StatusCreated, map[string]any{"session": c})
}

// report computes cash and sales activity between two instants.
func (s *Server) buildReport(openingCash int64, from string, to string) (*CaisseReport, error) {
	rep := &CaisseReport{OpeningCash: openingCash}
	// Single-method documents count under documents.payment_method; a mixed
	// payment (rows in document_payments) counts each row under its method —
	// the cash row already includes the timbre, like a cash-only total_ttc.
	if err := s.db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(total_ttc),0)
		FROM documents
		WHERE status='posted' AND doc_type IN ('SALE_TICKET','SALE_INVOICE')
		  AND posted_at >= ? AND posted_at <= ?`, from, to).
		Scan(&rep.TicketCount, &rep.TotalSales); err != nil {
		return nil, err
	}
	rows, err := s.db.Query(`SELECT method, COALESCE(SUM(amount),0) FROM (
			SELECT COALESCE(d.payment_method,'') AS method, d.total_ttc AS amount
			FROM documents d
			WHERE d.status='posted' AND d.doc_type IN ('SALE_TICKET','SALE_INVOICE')
			  AND d.posted_at >= ? AND d.posted_at <= ?
			  AND NOT EXISTS (SELECT 1 FROM document_payments p WHERE p.document_id = d.id)
			UNION ALL
			SELECT p.method, p.amount
			FROM document_payments p JOIN documents d ON d.id = p.document_id
			WHERE d.status='posted' AND d.doc_type IN ('SALE_TICKET','SALE_INVOICE')
			  AND d.posted_at >= ? AND d.posted_at <= ?
		) GROUP BY method`, from, to, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var method string
		var sum int64
		if err := rows.Scan(&method, &sum); err != nil {
			return nil, err
		}
		switch method {
		case "cash":
			rep.CashSales += sum
		case "cib", "edahabia":
			rep.CardSales += sum
		case "credit":
			rep.CreditSales += sum
		default:
			rep.OtherSales += sum
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	q := func(docType string) (int64, error) {
		var v int64
		err := s.db.QueryRow(`SELECT COALESCE(SUM(amount),0) FROM documents
			WHERE status='posted' AND doc_type=? AND payment_method='cash'
			  AND posted_at >= ? AND posted_at <= ?`, docType, from, to).Scan(&v)
		return v, err
	}
	if rep.CashIn, err = q("PAYMENT_IN"); err != nil {
		return nil, err
	}
	if rep.CashOut, err = q("PAYMENT_OUT"); err != nil {
		return nil, err
	}
	// Cash refunds (avoirs) leave the drawer too.
	if err := s.db.QueryRow(`SELECT COALESCE(SUM(total_ttc),0) FROM documents
		WHERE status='posted' AND doc_type='SALE_CREDIT_NOTE' AND payment_method='cash'
		  AND posted_at >= ? AND posted_at <= ?`, from, to).Scan(&rep.CashRefunds); err != nil {
		return nil, err
	}
	rep.ExpectedCash = openingCash + rep.CashSales + rep.CashIn - rep.CashOut - rep.CashRefunds
	return rep, nil
}

// caisseReport returns the X report of the currently open session.
func (s *Server) caisseReport(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") {
		forbid(w)
		return
	}
	if !s.tillCloseAllowed(w, r) {
		return
	}
	c, err := s.openSessionRow()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if c == nil {
		writeErr(w, http.StatusConflict, "aucune session de caisse ouverte")
		return
	}
	rep, err := s.buildReport(c.OpeningCash, c.OpenedAt, domain.NowISO())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"session": c, "report": rep})
}

func (s *Server) caisseClose(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") {
		forbid(w)
		return
	}
	var in struct {
		CountedCash int64   `json:"counted_cash"`
		Notes       *string `json:"notes"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if !s.tillCloseAllowed(w, r) {
		return
	}
	c, err := s.openSessionRow()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if c == nil {
		writeErr(w, http.StatusConflict, "aucune session de caisse ouverte")
		return
	}
	now := domain.NowISO()
	rep, err := s.buildReport(c.OpeningCash, c.OpenedAt, now)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if _, err := s.db.Exec(`UPDATE caisse_sessions
		SET status='closed', closed_at=?, expected_cash=?, counted_cash=?, notes=?
		WHERE id=?`,
		now, rep.ExpectedCash, in.CountedCash, in.Notes, c.ID); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	closed, err := scanSession(s.db.QueryRow(`SELECT `+sessionCols+`
		FROM caisse_sessions cs LEFT JOIN users u ON u.id = cs.user_id
		WHERE cs.id = ?`, c.ID))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.audit(r, "caisse.close", "caisse_session", c.ID,
		"clôture Z : attendu "+centimes(rep.ExpectedCash)+
			" DA, compté "+centimes(in.CountedCash)+" DA")
	writeJSON(w, http.StatusOK, map[string]any{"session": closed, "report": rep})
}

// caisseSessions lists past sessions (Z history).
func (s *Server) caisseSessions(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") {
		forbid(w)
		return
	}
	rows, err := s.db.Query(`SELECT ` + sessionCols + `
		FROM caisse_sessions cs LEFT JOIN users u ON u.id = cs.user_id
		ORDER BY cs.opened_at DESC LIMIT 60`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []CaisseSession{}
	for rows.Next() {
		c, err := scanSession(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, c)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}
