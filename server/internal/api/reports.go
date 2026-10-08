package api

import (
	"net/http"
)

// Sales reporting over posted SALE_TICKET + SALE_INVOICE between from/to
// (doc_date, inclusive). Avoirs (SALE_CREDIT_NOTE) are surfaced as refunds AND
// netted out of the net_* figures, the VAT-by-rate table, the margin and the
// breakdowns, so a returned item never keeps counting as profit or collected
// VAT. The timbre is a tax collected for the State, not revenue: it is reported
// on its own line and excluded from ca_ttc.

// sgn: +1 for a sale, -1 for a credit note.
const sgn = "(CASE WHEN d.doc_type='SALE_CREDIT_NOTE' THEN -1 ELSE 1 END)"

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
	caTTC -= timbre // le timbre n'est pas du chiffre d'affaires
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

	var refunds, refundsHT, refundsVAT int64
	s.db.QueryRow(`SELECT COALESCE(SUM(total_ttc),0), COALESCE(SUM(total_ht),0),
			COALESCE(SUM(total_vat),0) FROM documents
		WHERE status='posted' AND doc_type='SALE_CREDIT_NOTE'
		  AND doc_date >= ? AND doc_date <= ?`, from, to).Scan(&refunds, &refundsHT, &refundsVAT)
	out["refunds"] = refunds
	out["refunds_ht"] = refundsHT
	out["net_ca_ttc"] = caTTC - refunds
	out["net_ca_ht"] = caHT - refundsHT
	out["net_vat"] = vat - refundsVAT

	// VAT collected by rate, net of returns — the G50 helper.
	if rows, err := s.db.Query(`SELECT l.vat_rate, COALESCE(SUM(`+sgn+` * l.line_vat),0),
			COALESCE(SUM(`+sgn+` * l.line_ht),0)
		FROM document_lines l JOIN documents d ON d.id = l.document_id
		WHERE d.status='posted' AND d.doc_type IN ('SALE_TICKET','SALE_INVOICE','SALE_CREDIT_NOTE')
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

	if s.can(r, "view_cost") {
		// unit_cost est porté par unité de la ligne : qty_milli × unit_cost est
		// le coût de la ligne, avoirs déduits (retour au coût de la vente).
		var lineHT, costMilli int64
		s.db.QueryRow(`SELECT COALESCE(SUM(`+sgn+` * l.line_ht),0),
				COALESCE(SUM(`+sgn+` * l.qty_milli * COALESCE(l.unit_cost,0)),0)
			FROM document_lines l JOIN documents d ON d.id = l.document_id
			WHERE d.status='posted' AND d.doc_type IN ('SALE_TICKET','SALE_INVOICE','SALE_CREDIT_NOTE')
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

	// Sales and credit notes together, credit notes counted negatively.
	const salesWhere = `d.status='posted'
		AND d.doc_type IN ('SALE_TICKET','SALE_INVOICE','SALE_CREDIT_NOTE')
		AND d.doc_date >= ? AND d.doc_date <= ?`

	items := []breakdownRow{}
	switch by {
	case "payment":
		// A mixed payment counts each document_payments row under its method:
		// HT pro rata of the row in the document total, timbre taken off the
		// cash row only (the timbre is not revenue).
		rows, err := s.db.Query(`SELECT k, SUM(cnt), SUM(ht), SUM(ttc) FROM (
				SELECT COALESCE(d.payment_method, 'autre') AS k,
					CASE WHEN d.doc_type='SALE_CREDIT_NOTE' THEN 0 ELSE 1 END AS cnt,
					`+sgn+` * d.total_ht AS ht,
					`+sgn+` * (d.total_ttc - d.timbre) AS ttc
				FROM documents d WHERE `+salesWhere+`
				  AND NOT EXISTS (SELECT 1 FROM document_payments p WHERE p.document_id = d.id)
				UNION ALL
				SELECT p.method,
					CASE WHEN d.doc_type='SALE_CREDIT_NOTE' THEN 0 ELSE 1 END,
					`+sgn+` * (CASE WHEN d.total_ttc = 0 THEN 0
						ELSE d.total_ht * p.amount / d.total_ttc END),
					`+sgn+` * (p.amount - CASE WHEN p.method = 'cash' THEN d.timbre ELSE 0 END)
				FROM document_payments p JOIN documents d ON d.id = p.document_id
				WHERE `+salesWhere+`
			) GROUP BY k ORDER BY k`, from, to, from, to)
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
	case "day", "hour", "user":
		key := map[string]string{
			"day":     "d.doc_date",
			"hour":    "strftime('%H', datetime(d.posted_at, 'localtime'))",
			"user":    "COALESCE(u.full_name, u.username, '—')",
		}[by]
		join := ""
		if by == "user" {
			join = " LEFT JOIN users u ON u.id = d.posted_by"
		}
		rows, err := s.db.Query(`SELECT `+key+`,
				COALESCE(SUM(CASE WHEN d.doc_type='SALE_CREDIT_NOTE' THEN 0 ELSE 1 END),0),
				COALESCE(SUM(`+sgn+` * d.total_ht),0),
				COALESCE(SUM(`+sgn+` * (d.total_ttc - d.timbre)),0)
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
		rows, err := s.db.Query(`SELECT `+key+`,
				COUNT(DISTINCT CASE WHEN d.doc_type<>'SALE_CREDIT_NOTE' THEN d.id END),
				COALESCE(SUM(`+sgn+` * l.qty_milli * COALESCE(NULLIF(l.pack_factor_milli,0),1000) / 1000),0),
				COALESCE(SUM(`+sgn+` * l.line_ht),0),
				COALESCE(SUM(`+sgn+` * l.line_ttc),0),
				COALESCE(SUM(`+sgn+` * l.qty_milli * COALESCE(l.unit_cost,0)),0)
			FROM document_lines l
			JOIN documents d ON d.id = l.document_id`+join+
			` WHERE `+salesWhere+
			` GROUP BY `+key+` ORDER BY SUM(`+sgn+` * l.line_ttc) DESC LIMIT 100`, from, to)
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
