package domain

import (
	"database/sql"
	"time"
)

// Queryer is what both *sql.DB and *sql.Tx offer: the distribution code runs
// the same reads inside an order transaction or on the plain pool.
type Queryer interface {
	Querier
	Query(query string, args ...any) (*sql.Rows, error)
	Exec(query string, args ...any) (sql.Result, error)
}

// OpenItem is one invoice-like ledger entry with what is still open on it.
type OpenItem struct {
	DocumentID  string `json:"document_id"`
	Number      string `json:"number"`
	DocDate     string `json:"doc_date"`
	DueDate     string `json:"due_date"`
	Total       int64  `json:"total"`
	Outstanding int64  `json:"outstanding"`
	AgeDays     int    `json:"age_days"`
	Overdue     bool   `json:"overdue"`
	// SettledOn is the date (YYYY-MM-DD) of the settlement that cleared the
	// item, "" while something is still open. Used for the payment delay KPI.
	SettledOn string `json:"-"`
}

// LedgerFIFO matches payments and credit notes to the oldest invoices first
// (FIFO) and returns EVERY invoice entry with what is still open on it, plus
// the credit left unallocated. A settlement recorded before any open invoice
// (prepayment) is carried and consumed by the next invoices. Cancelled
// documents (and their void rows) are ignored entirely. sgn = +1 reads the
// ledger as a receivable (customer), -1 as a payable (supplier).
func LedgerFIFO(q Queryer, partnerID string, sgn int64) ([]*OpenItem, int64, error) {
	rows, err := q.Query(`SELECT pl.amount, COALESCE(pl.document_id,''), COALESCE(d.number,''),
			COALESCE(d.doc_date,''), COALESCE(d.due_date,''), pl.created_at
		FROM partner_ledger pl LEFT JOIN documents d ON d.id = pl.document_id
		WHERE pl.partner_id = ? AND COALESCE(d.status,'posted') <> 'cancelled'
		ORDER BY pl.created_at, pl.id`, partnerID)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var items []*OpenItem
	var credit int64 // settlements not (yet) allocated to an invoice
	for rows.Next() {
		var amt int64
		var doc, num, date, due, at string
		if err := rows.Scan(&amt, &doc, &num, &date, &due, &at); err != nil {
			return nil, 0, err
		}
		day := date
		if day == "" && len(at) >= 10 {
			day = at[:10]
		}
		amt *= sgn
		if amt > 0 {
			it := &OpenItem{DocumentID: doc, Number: num, DocDate: date,
				DueDate: due, Total: amt, Outstanding: amt}
			if credit > 0 {
				take := min(credit, amt)
				it.Outstanding -= take
				credit -= take
				if it.Outstanding == 0 {
					it.SettledOn = day
				}
			}
			items = append(items, it)
			continue
		}
		settle := -amt
		for _, it := range items {
			if settle == 0 {
				break
			}
			if it.Outstanding == 0 {
				continue
			}
			take := min(it.Outstanding, settle)
			it.Outstanding -= take
			settle -= take
			if it.Outstanding == 0 {
				it.SettledOn = day
			}
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

// PartnerBalance is the sum of a partner's ledger (positive = owes us).
func PartnerBalance(q Querier, partnerID string) int64 {
	var b sql.NullInt64
	q.QueryRow(`SELECT SUM(amount) FROM partner_ledger WHERE partner_id = ?`, partnerID).Scan(&b)
	return b.Int64
}

// OverdueOf returns the amount still open on overdue invoices and how many.
func OverdueOf(q Queryer, partnerID string) (amount int64, count int, err error) {
	items, _, err := LedgerFIFO(q, partnerID, 1)
	if err != nil {
		return 0, 0, err
	}
	for _, it := range items {
		if it.Overdue {
			amount += it.Outstanding
			count++
		}
	}
	return amount, count, nil
}

// CreditLimitOf is the customer's own ceiling, else the shop default
// (`default_credit_limit`); 0 = no ceiling.
func CreditLimitOf(q Querier, partnerID string) int64 {
	var limit sql.NullInt64
	q.QueryRow(`SELECT credit_limit FROM partners WHERE id = ?`, partnerID).Scan(&limit)
	if limit.Valid && limit.Int64 > 0 {
		return limit.Int64
	}
	if d := SettingInt(q, "default_credit_limit", 0); d > 0 {
		return d
	}
	return 0
}
