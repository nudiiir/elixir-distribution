package api

import (
	"fmt"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
)

// routesShellUX: what the top bar needs (alerts bell).
func (s *Server) routesShellUX(r chi.Router) {
	r.Get("/alerts", s.alerts)
}

type alertItem struct {
	Kind     string   `json:"kind"`     // rupture | below_min | lot_expired | lot_expiring | overdue_invoice | overdue_installment
	Severity string   `json:"severity"` // critical | warning
	Title    string   `json:"title"`
	Count    int      `json:"count"`
	Examples []string `json:"examples"` // up to 5 names
	Target   string   `json:"target"`   // module key the bell opens
}

// alerts summarises what needs attention today, filtered by the caller's
// permissions. Cheap enough to poll every couple of minutes.
func (s *Server) alerts(w http.ResponseWriter, r *http.Request) {
	items := []alertItem{}
	today := time.Now().Format("2006-01-02")
	soon := time.Now().AddDate(0, 0, 15).Format("2006-01-02")

	collect := func(kind, severity, title, target, query string, args ...any) {
		rows, err := s.db.Query(query, args...)
		if err != nil {
			return
		}
		defer rows.Close()
		a := alertItem{Kind: kind, Severity: severity, Title: title, Target: target, Examples: []string{}}
		for rows.Next() {
			var name string
			if rows.Scan(&name) == nil {
				a.Count++
				if len(a.Examples) < 5 {
					a.Examples = append(a.Examples, name)
				}
			}
		}
		if a.Count > 0 {
			a.Title = fmt.Sprintf(title, a.Count)
			items = append(items, a)
		}
	}

	if s.can(r, "stock") || s.can(r, "products") {
		// Only products that are stocked: a min is set or they have moved.
		const stocked = `p.active = 1 AND p.kind <> 'service' AND
			(p.min_stock_milli > 0 OR EXISTS (SELECT 1 FROM stock_ledger sl WHERE sl.product_id = p.id))`
		collect("rupture", "critical", "%d produit(s) en rupture", "stock",
			`SELECT p.name FROM products p
			 WHERE `+stocked+` AND COALESCE((SELECT SUM(qty_milli) FROM stock_levels WHERE product_id = p.id), 0) <= 0
			 ORDER BY p.name`)
		collect("below_min", "warning", "%d produit(s) sous le stock minimum", "stock",
			`SELECT p.name FROM products p
			 WHERE p.active = 1 AND p.kind <> 'service' AND p.min_stock_milli > 0
			   AND COALESCE((SELECT SUM(qty_milli) FROM stock_levels WHERE product_id = p.id), 0) > 0
			   AND COALESCE((SELECT SUM(qty_milli) FROM stock_levels WHERE product_id = p.id), 0) < p.min_stock_milli
			 ORDER BY p.name`)
		collect("lot_expired", "critical", "%d lot(s) périmé(s) encore en stock", "stock",
			`SELECT p.name || ' — lot ' || l.lot_number FROM lots l JOIN products p ON p.id = l.product_id
			 WHERE l.qty_milli > 0 AND l.expiry_date IS NOT NULL AND l.expiry_date <> '' AND l.expiry_date < ?
			 ORDER BY l.expiry_date`, today)
		collect("lot_expiring", "warning", "%d lot(s) périment dans les 15 jours", "stock",
			`SELECT p.name || ' — ' || l.expiry_date FROM lots l JOIN products p ON p.id = l.product_id
			 WHERE l.qty_milli > 0 AND l.expiry_date >= ? AND l.expiry_date <= ?
			 ORDER BY l.expiry_date`, today, soon)
	}
	if s.can(r, "sales") || s.can(r, "partners") {
		// A credit invoice past its due date whose customer still owes money.
		collect("overdue_invoice", "warning", "%d facture(s) à crédit en retard de paiement", "sales",
			`SELECT COALESCE(d.number, '') || ' — ' || pa.name FROM documents d
			 JOIN partners pa ON pa.id = d.partner_id
			 WHERE d.status = 'posted' AND d.doc_type = 'SALE_INVOICE' AND d.payment_method = 'credit'
			   AND d.due_date IS NOT NULL AND d.due_date <> '' AND d.due_date < ?
			   AND (SELECT COALESCE(SUM(amount), 0) FROM partner_ledger WHERE partner_id = d.partner_id) > 0
			 ORDER BY d.due_date`, today)
	}
	if s.can(r, "partners") {
		collect("overdue_installment", "warning", "%d échéance(s) de paiement échelonné en retard", "partners",
			`SELECT pa.name || ' — ' || d.due_date FROM installment_dues d
			 JOIN installment_plans ip ON ip.id = d.plan_id
			 JOIN partners pa ON pa.id = ip.partner_id
			 WHERE d.paid < d.amount AND d.due_date < ?
			 ORDER BY d.due_date`, today)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}
