package api

import (
	"net/http"
)

// Sales reporting. All queries cover posted SALE_TICKET + SALE_INVOICE between
// from/to (doc_date, inclusive); avoirs are surfaced separately as refunds.

func reportRange(r *http.Request) (string, string) {
	from := r.URL.Query().Get("from")
	to := r.URL.Query().Get("to")
	if from == "" {
		from = "0000-01-01"
	}
	if to == "" {
		to = "9999-12-31"
	}
	return from, to
}

func halfUp1000(n int64) int64 {
	if n >= 0 {
		return (n + 500) / 1000
	}
	return -((-n + 500) / 1000)
}

func (s *Server) reportSummary(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "reports") {
		forbid(w)
		return
	}
	from, to := reportRange(r)

	out := map[string]any{}
	var caTTC, caHT, vat, timbre, tickets int64
	s.db.QueryRow(`SELECT COALESCE(SUM(total_ttc),0), COALESCE(SUM(total_ht),0),
			COALESCE(SUM(total_vat),0), COALESCE(SUM(timbre),0), COUNT(*)
		FROM documents
		WHERE status='posted' AND doc_type IN ('SALE_TICKET','SALE_INVOICE')
		  AND doc_date >= ? AND doc_date <= ?`, from, to).
		Scan(&caTTC, &caHT, &vat, &timbre, &tickets)
	out["ca_ttc"] = caTTC
	out["ca_ht"] = caHT
	out["vat"] = vat
	out["timbre"] = timbre
	out["tickets"] = tickets
	if tickets > 0 {
		out["avg_ticket"] = caTTC / tickets
	} else {
		out["avg_ticket"] = 0
	}

	var refunds int64
	s.db.QueryRow(`SELECT COALESCE(SUM(total_ttc),0) FROM documents
		WHERE status='posted' AND doc_type='SALE_CREDIT_NOTE'
		  AND doc_date >= ? AND doc_date <= ?`, from, to).Scan(&refunds)
	out["refunds"] = refunds

	// VAT collected by rate — the G50 helper.
	byVat := map[string]int64{}
	if rows, err := s.db.Query(`SELECT l.vat_rate, COALESCE(SUM(l.line_vat),0), COALESCE(SUM(l.line_ht),0)
		FROM document_lines l JOIN documents d ON d.id = l.document_id
		WHERE d.status='posted' AND d.doc_type IN ('SALE_TICKET','SALE_INVOICE')
		  AND d.doc_date >= ? AND d.doc_date <= ?
		GROUP BY l.vat_rate`, from, to); err == nil {
		type vatRow struct {
			Rate int64 `json:"rate"`
			HT   int64 `json:"ht"`
			VAT  int64 `json:"vat"`
		}
		vats := []vatRow{}
		for rows.Next() {
			var rate, v, ht int64
			if rows.Scan(&rate, &v, &ht) == nil {
				vats = append(vats, vatRow{Rate: rate, HT: ht, VAT: v})
			}
		}
		rows.Close()
		out["by_vat_rate"] = vats
	}
	_ = byVat

	if s.can(r, "view_cost") {
		var lineHT, costMilli int64
		s.db.QueryRow(`SELECT COALESCE(SUM(l.line_ht),0),
				COALESCE(SUM(l.qty_milli * COALESCE(l.unit_cost,0)),0)
			FROM document_lines l JOIN documents d ON d.id = l.document_id
			WHERE d.status='posted' AND d.doc_type IN ('SALE_TICKET','SALE_INVOICE')
			  AND d.doc_date >= ? AND d.doc_date <= ?`, from, to).
			Scan(&lineHT, &costMilli)
		out["margin"] = lineHT - halfUp1000(costMilli)
	}

	writeJSON(w, http.StatusOK, out)
}

type breakdownRow struct {
	Key      string `json:"key"`
	Label    string `json:"label"`
	Count    int64  `json:"count"`
	QtyMilli int64  `json:"qty_milli"`
	TotalHT  int64  `json:"total_ht"`
	TotalTTC int64  `json:"total_ttc"`
	Margin   *int64 `json:"margin,omitempty"`
}

func (s *Server) reportBreakdown(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "reports") {
		forbid(w)
		return
	}
	from, to := reportRange(r)
	by := r.URL.Query().Get("by")
	showMargin := s.can(r, "view_cost")

	const salesWhere = `d.status='posted' AND d.doc_type IN ('SALE_TICKET','SALE_INVOICE')
		AND d.doc_date >= ? AND d.doc_date <= ?`

	items := []breakdownRow{}
	switch by {
	case "day", "hour", "user", "payment":
		key := map[string]string{
			"day":     "d.doc_date",
			"hour":    "strftime('%H', datetime(d.posted_at, 'localtime'))",
			"user":    "COALESCE(u.full_name, u.username, '—')",
			"payment": "COALESCE(d.payment_method, 'autre')",
		}[by]
		join := ""
		if by == "user" {
			join = " LEFT JOIN users u ON u.id = d.posted_by"
		}
		rows, err := s.db.Query(`SELECT `+key+`, COUNT(*), COALESCE(SUM(d.total_ht),0),
				COALESCE(SUM(d.total_ttc),0)
			FROM documents d`+join+` WHERE `+salesWhere+
			` GROUP BY `+key+` ORDER BY `+key, from, to)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		defer rows.Close()
		for rows.Next() {
			var x breakdownRow
			if rows.Scan(&x.Key, &x.Count, &x.TotalHT, &x.TotalTTC) == nil {
				x.Label = x.Key
				items = append(items, x)
			}
		}
	case "category", "product":
		key := "COALESCE(c.name, 'Sans catégorie')"
		join := ` JOIN products p ON p.id = l.product_id
			LEFT JOIN product_categories c ON c.id = p.category_id`
		if by == "product" {
			key = "COALESCE(p.name, l.description)"
			join = " LEFT JOIN products p ON p.id = l.product_id"
		}
		rows, err := s.db.Query(`SELECT `+key+`, COUNT(DISTINCT d.id),
				COALESCE(SUM(l.qty_milli),0), COALESCE(SUM(l.line_ht),0),
				COALESCE(SUM(l.line_ttc),0),
				COALESCE(SUM(l.qty_milli * COALESCE(l.unit_cost,0)),0)
			FROM document_lines l
			JOIN documents d ON d.id = l.document_id`+join+
			` WHERE `+salesWhere+
			` GROUP BY `+key+` ORDER BY SUM(l.line_ttc) DESC LIMIT 100`, from, to)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		defer rows.Close()
		for rows.Next() {
			var x breakdownRow
			var costMilli int64
			if rows.Scan(&x.Key, &x.Count, &x.QtyMilli, &x.TotalHT, &x.TotalTTC,
				&costMilli) == nil {
				x.Label = x.Key
				if showMargin {
					m := x.TotalHT - halfUp1000(costMilli)
					x.Margin = &m
				}
				items = append(items, x)
			}
		}
	default:
		writeErr(w, http.StatusBadRequest,
			"by must be day, hour, user, payment, category or product")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}
