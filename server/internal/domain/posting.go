package domain

import (
	"database/sql"
	"errors"
	"fmt"
)

var (
	ErrNotFound       = errors.New("document not found")
	ErrNotDraft       = errors.New("only draft documents can be posted or cancelled")
	ErrNoLines        = errors.New("document has no lines")
	ErrNoWarehouse    = errors.New("document type requires a warehouse")
	ErrNoDestWare     = errors.New("stock transfer requires a destination warehouse")
	ErrNoPartner      = errors.New("document type requires a partner")
	ErrBadAmount      = errors.New("payment requires a positive amount")
	ErrNotImplemented = errors.New("posting for this document type is not implemented yet")
)

type docRow struct {
	id, docType, status, docDate string
	partnerID, warehouseID       sql.NullString
	destWarehouseID, refDocID    sql.NullString
	paymentMethod                sql.NullString
	amount                       int64
}

type lineRow struct {
	id                                 string
	productID, lotID                   sql.NullString
	qtyMilli, unitPrice, discount, vat int64
}

// Post validates a draft document and, in a single transaction: recomputes line
// and document totals, assigns the gapless sequential number, writes stock and
// partner ledger entries, and flips the document to posted. Returns the number.
func Post(db *sql.DB, docID, userID string) (string, error) {
	tx, err := db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	var d docRow
	err = tx.QueryRow(`SELECT id, doc_type, status, doc_date, partner_id, warehouse_id,
			dest_warehouse_id, ref_document_id, payment_method, amount
		FROM documents WHERE id = ?`, docID).Scan(
		&d.id, &d.docType, &d.status, &d.docDate, &d.partnerID, &d.warehouseID,
		&d.destWarehouseID, &d.refDocID, &d.paymentMethod, &d.amount)
	if err == sql.ErrNoRows {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if d.status != "draft" {
		return "", ErrNotDraft
	}
	if d.docType == InventoryCount {
		return "", ErrNotImplemented
	}

	isPayment := d.docType == PaymentIn || d.docType == PaymentOut
	now := NowISO()

	// ---- Lines and totals -------------------------------------------------
	var lines []lineRow
	var totalHT, totalVAT, totalTTC, totalDiscount int64

	if isPayment {
		if d.amount <= 0 {
			return "", ErrBadAmount
		}
		if !d.partnerID.Valid {
			return "", ErrNoPartner
		}
		totalTTC = d.amount
	} else {
		rows, err := tx.Query(`SELECT id, product_id, lot_id, qty_milli, unit_price, discount_pct, vat_rate
			FROM document_lines WHERE document_id = ? ORDER BY position, created_at`, docID)
		if err != nil {
			return "", err
		}
		for rows.Next() {
			var l lineRow
			if err := rows.Scan(&l.id, &l.productID, &l.lotID, &l.qtyMilli, &l.unitPrice, &l.discount, &l.vat); err != nil {
				rows.Close()
				return "", err
			}
			lines = append(lines, l)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return "", err
		}
		if len(lines) == 0 {
			return "", ErrNoLines
		}
		for _, l := range lines {
			ht, vat, ttc := LineTotals(l.unitPrice, l.qtyMilli, l.discount, l.vat)
			totalHT += ht
			totalVAT += vat
			totalTTC += ttc
			totalDiscount += LineDiscount(l.unitPrice, l.qtyMilli, l.discount)
			if _, err := tx.Exec(`UPDATE document_lines SET line_ht=?, line_vat=?, line_ttc=? WHERE id=?`,
				ht, vat, ttc, l.id); err != nil {
				return "", err
			}
		}
	}

	var timbre int64
	if TimbreApplies(d.docType, d.paymentMethod.String) {
		timbre = Timbre(totalTTC)
		totalTTC += timbre
	}

	// ---- Number -----------------------------------------------------------
	number, err := nextNumber(tx, d.docType, d.docDate)
	if err != nil {
		return "", err
	}

	// ---- Stock ledger -----------------------------------------------------
	sign := stockSign[d.docType]
	skipStock := false
	if sign != 0 && d.refDocID.Valid {
		// An invoice referencing a posted delivery/receipt must not move stock twice.
		var refType, refStatus string
		err := tx.QueryRow(`SELECT doc_type, status FROM documents WHERE id = ?`, d.refDocID.String).
			Scan(&refType, &refStatus)
		if err == nil && refStatus == "posted" &&
			((d.docType == SaleInvoice && refType == DeliveryNote) ||
				(d.docType == PurchaseInvoice && refType == PurchaseReceipt)) {
			skipStock = true
		}
	}

	if sign != 0 && !skipStock {
		if !d.warehouseID.Valid {
			return "", ErrNoWarehouse
		}
		if d.docType == StockTransfer && !d.destWarehouseID.Valid {
			return "", ErrNoDestWare
		}
		for _, l := range lines {
			if !l.productID.Valid || l.qtyMilli == 0 {
				continue
			}
			delta := sign * l.qtyMilli

			var unitCost int64
			if isCostBearing(d.docType) {
				// Net purchase cost per unit, after line discount.
				ht, _, _ := LineTotals(l.unitPrice, l.qtyMilli, l.discount, 0)
				unitCost = roundDiv(ht*1000, l.qtyMilli)
			} else {
				unitCost = currentAvgCost(tx, l.productID.String, d.warehouseID.String)
			}

			if err := applyStockMove(tx, l.productID.String, d.warehouseID.String, l.lotID,
				delta, unitCost, isCostBearing(d.docType), docID, l.id, now); err != nil {
				return "", err
			}
			if d.docType == StockTransfer {
				if err := applyStockMove(tx, l.productID.String, d.destWarehouseID.String, l.lotID,
					-delta, unitCost, true, docID, l.id, now); err != nil {
					return "", err
				}
			}
			if _, err := tx.Exec(`UPDATE document_lines SET unit_cost=? WHERE id=?`, unitCost, l.id); err != nil {
				return "", err
			}
		}
	}

	// ---- Partner ledger ---------------------------------------------------
	// Convention: positive = the partner owes us.
	var ledgerAmount int64
	var ledgerKind string
	switch d.docType {
	case SaleTicket, SaleInvoice:
		if d.paymentMethod.String == "credit" {
			if !d.partnerID.Valid {
				return "", ErrNoPartner
			}
			ledgerAmount, ledgerKind = totalTTC, "invoice"
		}
	case SaleCreditNote:
		if d.partnerID.Valid {
			ledgerAmount, ledgerKind = -totalTTC, "credit_note"
		}
	case PurchaseInvoice:
		if !d.partnerID.Valid {
			return "", ErrNoPartner
		}
		ledgerAmount, ledgerKind = -totalTTC, "invoice"
	case PurchaseCreditNote:
		if d.partnerID.Valid {
			ledgerAmount, ledgerKind = totalTTC, "credit_note"
		}
	case PaymentIn:
		ledgerAmount, ledgerKind = -d.amount, "payment"
	case PaymentOut:
		ledgerAmount, ledgerKind = d.amount, "payment"
	}
	if ledgerKind != "" && ledgerAmount != 0 {
		if _, err := tx.Exec(`INSERT INTO partner_ledger (id, partner_id, amount, kind, document_id, created_at)
			VALUES (?, ?, ?, ?, ?, ?)`,
			NewID(), d.partnerID.String, ledgerAmount, ledgerKind, docID, now); err != nil {
			return "", err
		}
	}

	// ---- Flip to posted ---------------------------------------------------
	if _, err := tx.Exec(`UPDATE documents SET number=?, status='posted',
			total_ht=?, total_vat=?, total_discount=?, timbre=?, total_ttc=?,
			posted_by=?, posted_at=?, updated_at=?
		WHERE id=?`,
		number, totalHT, totalVAT, totalDiscount, timbre, totalTTC,
		nullIfEmpty(userID), now, now, docID); err != nil {
		return "", err
	}

	if err := tx.Commit(); err != nil {
		return "", err
	}
	return number, nil
}

func nextNumber(tx *sql.Tx, docType, docDate string) (string, error) {
	year := 0
	if len(docDate) >= 4 {
		fmt.Sscanf(docDate[:4], "%d", &year)
	}
	if year == 0 {
		return "", fmt.Errorf("invalid doc_date %q", docDate)
	}
	if _, err := tx.Exec(`INSERT INTO sequences (doc_type, year, next_number) VALUES (?, ?, 1)
		ON CONFLICT (doc_type, year) DO NOTHING`, docType, year); err != nil {
		return "", err
	}
	var n int64
	if err := tx.QueryRow(`SELECT next_number FROM sequences WHERE doc_type=? AND year=?`,
		docType, year).Scan(&n); err != nil {
		return "", err
	}
	if _, err := tx.Exec(`UPDATE sequences SET next_number = next_number + 1
		WHERE doc_type=? AND year=?`, docType, year); err != nil {
		return "", err
	}
	return fmt.Sprintf("%s-%d-%06d", NumberPrefix[docType], year, n), nil
}

func currentAvgCost(tx *sql.Tx, productID, warehouseID string) int64 {
	var avg int64
	tx.QueryRow(`SELECT avg_cost FROM stock_levels WHERE product_id=? AND warehouse_id=?`,
		productID, warehouseID).Scan(&avg)
	return avg
}

// applyStockMove inserts a stock_ledger row and maintains the stock_levels
// cache. When updateAvg is set and the move is inbound, the weighted-average
// cost (CUMP) is recomputed.
func applyStockMove(tx *sql.Tx, productID, warehouseID string, lotID sql.NullString,
	deltaMilli, unitCost int64, updateAvg bool, docID, lineID, now string) error {

	if _, err := tx.Exec(`INSERT INTO stock_ledger
		(id, product_id, warehouse_id, lot_id, qty_delta_milli, unit_cost, document_id, line_id, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		NewID(), productID, warehouseID, lotID, deltaMilli, unitCost, docID, lineID, now); err != nil {
		return err
	}

	var oldQty, oldAvg int64
	exists := true
	err := tx.QueryRow(`SELECT qty_milli, avg_cost FROM stock_levels WHERE product_id=? AND warehouse_id=?`,
		productID, warehouseID).Scan(&oldQty, &oldAvg)
	if err == sql.ErrNoRows {
		exists = false
	} else if err != nil {
		return err
	}

	newQty := oldQty + deltaMilli
	newAvg := oldAvg
	if updateAvg && deltaMilli > 0 {
		if oldQty <= 0 {
			newAvg = unitCost
		} else {
			newAvg = roundDiv(oldQty*oldAvg+deltaMilli*unitCost, oldQty+deltaMilli)
		}
	}

	if exists {
		_, err = tx.Exec(`UPDATE stock_levels SET qty_milli=?, avg_cost=?, updated_at=?
			WHERE product_id=? AND warehouse_id=?`, newQty, newAvg, now, productID, warehouseID)
	} else {
		_, err = tx.Exec(`INSERT INTO stock_levels (product_id, warehouse_id, qty_milli, avg_cost, updated_at)
			VALUES (?, ?, ?, ?, ?)`, productID, warehouseID, newQty, newAvg, now)
	}
	return err
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
