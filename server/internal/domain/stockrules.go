package domain

import (
	"database/sql"
	"fmt"
	"strconv"
	"strings"
)

// allowNegativeStock reports the shop-level choice to let stock go below zero.
// Default is OFF: a sale/transfer/adjustment that exceeds what is on hand is
// refused with a readable message instead of silently corrupting the CUMP.
func allowNegativeStock(tx *sql.Tx) bool {
	var v string
	tx.QueryRow(`SELECT value FROM settings WHERE key='allow_negative_stock'`).Scan(&v)
	return strings.TrimSpace(v) == "1"
}

func fmtQtyMilli(q int64) string {
	s := strconv.FormatFloat(float64(q)/1000, 'f', 3, 64)
	s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	return strings.Replace(s, ".", ",", 1)
}

// checkOutflow refuses an outbound move larger than the level on hand.
func checkOutflow(tx *sql.Tx, productID, warehouseID string, need int64) error {
	var have int64
	tx.QueryRow(`SELECT qty_milli FROM stock_levels WHERE product_id=? AND warehouse_id=?`,
		productID, warehouseID).Scan(&have)
	if have >= need {
		return nil
	}
	var name string
	tx.QueryRow(`SELECT name FROM products WHERE id=?`, productID).Scan(&name)
	if have < 0 {
		have = 0
	}
	return &PostError{fmt.Sprintf("stock insuffisant pour « %s » (disponible %s, demandé %s)",
		name, fmtQtyMilli(have), fmtQtyMilli(need))}
}

// refMovement returns the total base quantity (milli, absolute) a document
// moved for a product and the weighted unit cost it moved at.
func refMovement(tx *sql.Tx, refID, productID string) (qty, cost int64) {
	var q, v int64
	tx.QueryRow(`SELECT COALESCE(SUM(ABS(qty_delta_milli)),0),
			COALESCE(SUM(ABS(qty_delta_milli)*unit_cost),0)
		FROM stock_ledger
		WHERE document_id=? AND product_id=? AND is_reversal=0 AND qty_delta_milli<>0`,
		refID, productID).Scan(&q, &v)
	if q > 0 {
		return q, roundDiv(v, q)
	}
	return 0, 0
}

// refConsumed is the base quantity of a product already invoiced against the
// same delivery note / receipt by OTHER posted invoices.
func refConsumed(tx *sql.Tx, refID, productID, selfID string) int64 {
	var q int64
	tx.QueryRow(`SELECT CAST(COALESCE(SUM(CAST(ROUND(
			l.qty_milli * COALESCE(NULLIF(l.pack_factor_milli,0),1000) / 1000.0) AS INTEGER)),0) AS INTEGER)
		FROM document_lines l JOIN documents d ON d.id = l.document_id
		WHERE d.ref_document_id=? AND d.status='posted' AND d.id<>?
		  AND d.doc_type IN ('SALE_INVOICE','PURCHASE_INVOICE') AND l.product_id=?`,
		refID, selfID, productID).Scan(&q)
	return q
}

// refLineCost returns the per-base-unit cost a posted sale carried on its lines
// for a product (used to re-enter a customer return at the cost it left at).
func refLineCost(tx *sql.Tx, refID, productID string) (int64, bool) {
	var cost, baseQty int64
	tx.QueryRow(`SELECT COALESCE(SUM(l.unit_cost * l.qty_milli),0),
			COALESCE(SUM(l.qty_milli * COALESCE(NULLIF(l.pack_factor_milli,0),1000) / 1000),0)
		FROM document_lines l
		WHERE l.document_id=? AND l.product_id=? AND l.unit_cost IS NOT NULL`,
		refID, productID).Scan(&cost, &baseQty)
	if baseQty <= 0 || cost <= 0 {
		return 0, false
	}
	return roundDiv(cost, baseQty), true
}

type lotChunk struct {
	lot sql.NullString
	qty int64 // signed
}

// productIsService: a service (repair labour, delivery, installation) is sold
// like a product but never moves stock.
func productIsService(tx *sql.Tx, productID string) bool {
	var kind string
	tx.QueryRow(`SELECT kind FROM products WHERE id=?`, productID).Scan(&kind)
	return kind == "service"
}

func productIsLotTracked(tx *sql.Tx, productID string) bool {
	var n int64
	tx.QueryRow(`SELECT track_lots + track_expiry FROM products WHERE id=?`, productID).Scan(&n)
	return n > 0
}

// fefoSplit spreads an outbound quantity over the product's lots, earliest
// expiry first. Whatever the lots cannot cover is booked without a lot.
func fefoSplit(tx *sql.Tx, productID string, need int64) []lotChunk {
	type lot struct {
		id  string
		qty int64
	}
	var avail []lot
	if rows, err := tx.Query(`SELECT id, qty_milli FROM lots
		WHERE product_id=? AND qty_milli>0
		ORDER BY (expiry_date IS NULL OR expiry_date=''), expiry_date, created_at`, productID); err == nil {
		for rows.Next() {
			var l lot
			if rows.Scan(&l.id, &l.qty) == nil {
				avail = append(avail, l)
			}
		}
		rows.Close()
	}
	var out []lotChunk
	for _, l := range avail {
		if need <= 0 {
			break
		}
		take := l.qty
		if take > need {
			take = need
		}
		out = append(out, lotChunk{sql.NullString{String: l.id, Valid: true}, -take})
		need -= take
	}
	if need > 0 {
		out = append(out, lotChunk{sql.NullString{}, -need})
	}
	return out
}

// unwindAvg removes q units bought at cost from a weighted average. Outflows
// never change a CUMP, so when nothing else came in meanwhile this restores the
// exact previous average. With nothing left the average is kept as is.
func unwindAvg(oldQty, oldAvg, q, cost int64) int64 {
	rest := oldQty - q
	if rest <= 0 {
		return oldAvg
	}
	v := roundDiv(oldQty*oldAvg-q*cost, rest)
	if v < 0 {
		return oldAvg
	}
	return v
}

// revalueAvg corrects the CUMP when a supplier invoice prices goods differently
// from the receipt that already brought them in. Only the part still on hand
// can be revalued (the rest is already sold). The correction is written as a
// zero-quantity ledger row carrying the new absolute average, so the nightly
// replay reproduces it.
func revalueAvg(tx *sql.Tx, productID, warehouseID string, diffPerUnit, portion int64, docID, now string) error {
	var q, avg int64
	if err := tx.QueryRow(`SELECT qty_milli, avg_cost FROM stock_levels WHERE product_id=? AND warehouse_id=?`,
		productID, warehouseID).Scan(&q, &avg); err != nil || q <= 0 {
		return nil
	}
	if portion > q {
		portion = q
	}
	newAvg := avg + roundDiv(diffPerUnit*portion, q)
	if newAvg < 0 {
		newAvg = 0
	}
	if newAvg == avg {
		return nil
	}
	if _, err := tx.Exec(`INSERT INTO stock_ledger
		(id, product_id, warehouse_id, qty_delta_milli, unit_cost, document_id, created_at, is_reversal, avg_after)
		VALUES (?, ?, ?, 0, ?, ?, ?, 0, ?)`,
		NewID(), productID, warehouseID, diffPerUnit, docID, now, newAvg); err != nil {
		return err
	}
	_, err := tx.Exec(`UPDATE stock_levels SET avg_cost=?, updated_at=? WHERE product_id=? AND warehouse_id=?`,
		newAvg, now, productID, warehouseID)
	return err
}
