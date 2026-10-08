package domain

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

var (
	ErrNotFound       = errors.New("document not found")
	ErrNotDraft       = errors.New("only draft documents can be posted or cancelled")
	ErrNotPosted      = errors.New("seuls les documents validés peuvent être annulés par contrepassation")
	ErrNoLines        = errors.New("document has no lines")
	ErrNoWarehouse    = errors.New("document type requires a warehouse")
	ErrNoDestWare     = errors.New("stock transfer requires a destination warehouse")
	ErrNoPartner      = errors.New("document type requires a partner")
	ErrBadAmount      = errors.New("payment requires a positive amount")
	ErrNoReason       = errors.New("un ajustement de stock exige un motif")
	ErrNotImplemented = errors.New("posting for this document type is not implemented yet")
)

// PostError carries a business refusal with a merchant-readable message.
type PostError struct{ Msg string }

func (e *PostError) Error() string { return e.Msg }

type docRow struct {
	id, docType, status, docDate string
	partnerID, warehouseID       sql.NullString
	destWarehouseID, refDocID    sql.NullString
	paymentMethod, supplierRef   sql.NullString
	reason                       sql.NullString
	amount, freight              int64
	acceptShortDated             int64
	acceptOverReceipt            int64
}

type lineRow struct {
	id                                 string
	productID, lotID                   sql.NullString
	qtyMilli, unitPrice, discount, vat int64
	qtyFree, packFactor                int64
	lotNumber, expiryDate              sql.NullString
	newSalePrice                       sql.NullInt64
	// computed during posting
	lineHT   int64
	baseQty  int64 // billed quantity in base units (milli)
	baseFree int64 // free quantity in base units (milli)
	// invoice-on-delivery: part of baseQty already moved by the referenced
	// BL/receipt (no second stock move) and the cost it moved at (per base unit)
	skipBase, refCost int64
	expected          sql.NullInt64 // inventory count: theoretical qty at count time
}

// baseUnits converts a pack quantity (milli) through the pack factor (milli).
func baseUnits(qtyMilli, factorMilli int64) int64 {
	if factorMilli == 0 || factorMilli == 1000 {
		return qtyMilli
	}
	return roundDiv(qtyMilli*factorMilli, 1000)
}

func auditTx(tx *sql.Tx, userID, action, entity, entityID, detail string) {
	tx.Exec(`INSERT INTO audit_log (id, user_id, action, entity, entity_id, detail, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		NewID(), nullIfEmpty(userID), action, entity, entityID, detail, NowISO())
}

// Post validates a draft document and, in a single transaction: recomputes line
// and document totals, assigns the gapless sequential number, writes stock and
// partner ledger entries, and flips the document to posted. Returns the number.
//
// Réception fournisseur — règles de la spécification :
//   - fournisseur obligatoire ;
//   - lot obligatoire quand suivi_lot, DLC obligatoire quand suivi_peremption ;
//   - gratuités et frais d'approche pliés dans le coût effectif ;
//   - conversion d'unité (carton → pièces) au niveau de la ligne ;
//   - mise à jour du reliquat des lignes du bon de commande lié ;
//   - prix de vente saisi sur la ligne appliqué au produit, journalisé ;
//   - durée de vie minimale par fournisseur, acceptation courte durée loguée ;
//   - facture fournisseur en double (même fournisseur + même n°) refusée.
// UserMayOversell, set by the API layer, reports whether the posting user has
// the « negative_stock » right (sell beyond what is on hand) even when the
// shop setting allow_negative_stock is off. Nil = only the setting counts.
var UserMayOversell func(tx *sql.Tx, userID string) bool

func Post(db *sql.DB, docID, userID string) (string, error) {
	tx, err := db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	var d docRow
	err = tx.QueryRow(`SELECT id, doc_type, status, doc_date, partner_id, warehouse_id,
			dest_warehouse_id, ref_document_id, payment_method, amount,
			supplier_ref, reason, freight_cost, accept_short_dated, accept_over_receipt
		FROM documents WHERE id = ?`, docID).Scan(
		&d.id, &d.docType, &d.status, &d.docDate, &d.partnerID, &d.warehouseID,
		&d.destWarehouseID, &d.refDocID, &d.paymentMethod, &d.amount,
		&d.supplierRef, &d.reason, &d.freight, &d.acceptShortDated, &d.acceptOverReceipt)
	if err == sql.ErrNoRows {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if d.status != "draft" {
		return "", ErrNotDraft
	}

	isPayment := d.docType == PaymentIn || d.docType == PaymentOut
	now := NowISO()

	// ---- Business gates ---------------------------------------------------
	if d.docType == PurchaseReceipt && !d.partnerID.Valid {
		return "", &PostError{"le fournisseur est obligatoire pour valider une réception"}
	}
	if d.docType == StockAdjustment && strings.TrimSpace(d.reason.String) == "" {
		return "", ErrNoReason
	}
	if d.docType == PurchaseInvoice && strings.TrimSpace(d.supplierRef.String) != "" {
		var dup string
		tx.QueryRow(`SELECT number FROM documents
			WHERE doc_type='PURCHASE_INVOICE' AND status='posted' AND partner_id = ?
			  AND TRIM(LOWER(supplier_ref)) = TRIM(LOWER(?)) AND id <> ?`,
			d.partnerID, d.supplierRef.String, docID).Scan(&dup)
		if dup != "" {
			return "", &PostError{fmt.Sprintf(
				"facture en double : le n° fournisseur « %s » est déjà enregistré (%s)",
				strings.TrimSpace(d.supplierRef.String), dup)}
		}
	}

	// Facture saisie à la main alors que la réception correspondante existe
	// déjà (même fournisseur, même n° fournisseur, pas encore facturée) : le
	// stock entrerait deux fois. On exige le rattachement à la réception.
	if d.docType == PurchaseInvoice && !d.refDocID.Valid && d.partnerID.Valid &&
		strings.TrimSpace(d.supplierRef.String) != "" {
		var rcpt string
		tx.QueryRow(`SELECT r.number FROM documents r
			WHERE r.doc_type='PURCHASE_RECEIPT' AND r.status='posted' AND r.partner_id = ?
			  AND TRIM(LOWER(r.supplier_ref)) = TRIM(LOWER(?))
			  AND NOT EXISTS (SELECT 1 FROM documents i WHERE i.ref_document_id = r.id
			                  AND i.doc_type='PURCHASE_INVOICE' AND i.status='posted')
			LIMIT 1`, d.partnerID.String, d.supplierRef.String).Scan(&rcpt)
		if rcpt != "" {
			return "", &PostError{fmt.Sprintf(
				"la réception %s porte déjà ce n° fournisseur : rattachez la facture à cette réception (sinon le stock entrerait deux fois)", rcpt)}
		}
	}

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
		rows, err := tx.Query(`SELECT id, product_id, lot_id, qty_milli, unit_price, discount_pct,
				vat_rate, qty_free_milli, pack_factor_milli, lot_number, expiry_date, new_sale_price,
				expected_milli
			FROM document_lines WHERE document_id = ? ORDER BY position, created_at`, docID)
		if err != nil {
			return "", err
		}
		for rows.Next() {
			var l lineRow
			if err := rows.Scan(&l.id, &l.productID, &l.lotID, &l.qtyMilli, &l.unitPrice,
				&l.discount, &l.vat, &l.qtyFree, &l.packFactor, &l.lotNumber, &l.expiryDate,
				&l.newSalePrice, &l.expected); err != nil {
				rows.Close()
				return "", err
			}
			if l.packFactor <= 0 {
				l.packFactor = 1000
			}
			l.baseQty = baseUnits(l.qtyMilli, l.packFactor)
			l.baseFree = baseUnits(l.qtyFree, l.packFactor)
			lines = append(lines, l)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return "", err
		}
		if len(lines) == 0 {
			return "", ErrNoLines
		}
		for i := range lines {
			l := &lines[i]
			ht, vat, ttc := LineTotals(l.unitPrice, l.qtyMilli, l.discount, l.vat)
			l.lineHT = ht
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
	// Paiement mixte : des lignes document_payments remplacent le mode unique.
	var split *splitPayment
	if d.docType == SaleTicket || d.docType == SaleInvoice {
		sp, err := loadSplitPayment(tx, docID)
		if err != nil {
			return "", err
		}
		split = sp
	}
	// Droit de timbre : désactivable dans Paramètres › Taxes (timbre_enabled).
	timbreOn := TimbreSettingOn(tx)
	goodsTTC := totalTTC // ce que le client paie pour la marchandise (fidélité)
	if split != nil {
		t, err := split.settleTimbre(totalTTC, d.partnerID.Valid, timbreOn)
		if err != nil {
			return "", err
		}
		timbre = t
		totalTTC += timbre
	} else if timbreOn && timbreDue(d.docType, d.paymentMethod.String) {
		timbre = Timbre(totalTTC)
		totalTTC += timbre
	}

	// ---- Lot / DLC enforcement on cost-bearing inbound documents ----------
	if isCostBearing(d.docType) {
		if err := resolveLots(tx, &d, lines, userID); err != nil {
			return "", err
		}
	}

	// ---- Number -----------------------------------------------------------
	number, err := nextNumber(tx, d.docType, d.docDate)
	if err != nil {
		return "", err
	}

	// ---- Stock ledger -----------------------------------------------------
	sign := stockSign[d.docType]

	// Invoice on a posted delivery note / receipt: only the quantity the
	// referenced document has not already moved is moved now. What the BL
	// already took out is not taken twice, but lines (or excess quantities) the
	// BL did not carry still move stock, and the cost the BL moved at is
	// inherited so margin and price-variance stay exact.
	onRef := false
	if sign != 0 && d.refDocID.Valid {
		var refType, refStatus string
		err := tx.QueryRow(`SELECT doc_type, status FROM documents WHERE id = ?`, d.refDocID.String).
			Scan(&refType, &refStatus)
		onRef = err == nil && refStatus == "posted" &&
			((d.docType == SaleInvoice && refType == DeliveryNote) ||
				(d.docType == PurchaseInvoice && refType == PurchaseReceipt))
	}
	if onRef {
		remaining := map[string]int64{}
		costs := map[string]int64{}
		for i := range lines {
			l := &lines[i]
			if !l.productID.Valid {
				continue
			}
			pid := l.productID.String
			rem, seen := remaining[pid]
			if !seen {
				q, c := refMovement(tx, d.refDocID.String, pid)
				rem = q - refConsumed(tx, d.refDocID.String, pid, docID)
				costs[pid] = c
			}
			if rem < 0 {
				rem = 0
			}
			s := l.baseQty
			if s > rem {
				s = rem
			}
			if s < 0 {
				s = 0
			}
			remaining[pid] = rem - s
			l.skipBase, l.refCost = s, costs[pid]
		}
	}

	if sign != 0 {
		if d.docType == StockTransfer && !d.destWarehouseID.Valid {
			return "", ErrNoDestWare
		}
		needWarehouse := func() error {
			if !d.warehouseID.Valid {
				return ErrNoWarehouse
			}
			return nil
		}

		// Frais d'approche : alloués aux lignes au prorata de la valeur HT.
		// Le reliquat d'arrondi va à la dernière ligne allouée.
		freightAlloc := map[string]int64{}
		if isCostBearing(d.docType) && d.freight > 0 {
			var allocatableHT int64
			for _, l := range lines {
				if l.productID.Valid && l.baseQty+l.baseFree > 0 {
					allocatableHT += l.lineHT
				}
			}
			if allocatableHT > 0 {
				var allocated int64
				lastID := ""
				for _, l := range lines {
					if !l.productID.Valid || l.baseQty+l.baseFree == 0 {
						continue
					}
					a := roundDiv(d.freight*l.lineHT, allocatableHT)
					freightAlloc[l.id] = a
					allocated += a
					lastID = l.id
				}
				if lastID != "" {
					freightAlloc[lastID] += d.freight - allocated
				}
			}
		}

		allowNeg := allowNegativeStock(tx) || (UserMayOversell != nil && UserMayOversell(tx, userID))
		salesFamily := d.docType == SaleTicket || d.docType == SaleInvoice ||
			d.docType == DeliveryNote || d.docType == SaleCreditNote

		for _, l := range lines {
			if !l.productID.Valid {
				continue
			}
			pid := l.productID.String
			if productIsService(tx, pid) {
				continue // un service est facturé, jamais stocké
			}

			var delta, unitCost, lineCostBase int64
			updateAvg := isCostBearing(d.docType)
			if isCostBearing(d.docType) {
				// Coût effectif : (net HT + frais alloués) / (qté + gratuit),
				// en unités de base. Les gratuités entrent en stock sans valeur
				// ajoutée : elles diluent le coût unitaire.
				units := l.baseQty + l.baseFree
				if units == 0 {
					continue
				}
				unitCost = roundDiv((l.lineHT+freightAlloc[l.id])*1000, units)
				lineCostBase = unitCost
				delta = sign * (l.baseQty - l.skipBase + l.baseFree)
			} else {
				if l.baseQty == 0 {
					continue
				}
				unitCost = currentAvgCost(tx, pid, d.warehouseID.String)
				// Un retour client rentre au coût auquel la vente l'a sorti,
				// pas au CMUP du jour : la marge nette reste juste.
				if d.docType == SaleCreditNote && d.refDocID.Valid {
					if c, ok := refLineCost(tx, d.refDocID.String, pid); ok {
						unitCost = c
					}
				}
				delta = sign * (l.baseQty - l.skipBase)
				lineCostBase = unitCost
				if l.skipBase > 0 {
					lineCostBase = roundDiv(l.skipBase*l.refCost+(l.baseQty-l.skipBase)*unitCost, l.baseQty)
				}
				// Un ajustement ENTRANT est valorisé : au coût déclaré sur la
				// ligne (stock initial) ou, à défaut, au CMUP courant — dans
				// les deux cas l'écriture porte son coût, ce qui rend le
				// rejeu du journal déterministe.
				if d.docType == StockAdjustment && delta > 0 {
					if l.unitPrice > 0 {
						unitCost = l.unitPrice
					}
					lineCostBase = unitCost
					updateAvg = true
				}
			}

			if delta != 0 {
				if err := needWarehouse(); err != nil {
					return "", err
				}
				if delta < 0 && !allowNeg {
					if err := checkOutflow(tx, pid, d.warehouseID.String, -delta); err != nil {
						return "", err
					}
				}
				chunks := []lotChunk{{l.lotID, delta}}
				if delta < 0 && !l.lotID.Valid && d.docType != StockTransfer && productIsLotTracked(tx, pid) {
					chunks = fefoSplit(tx, pid, -delta)
				}
				for _, c := range chunks {
					if err := applyStockMove(tx, pid, d.warehouseID.String, c.lot,
						c.qty, unitCost, updateAvg, docID, l.id, now); err != nil {
						return "", err
					}
				}
				if d.docType == StockTransfer {
					if err := applyStockMove(tx, pid, d.destWarehouseID.String, l.lotID,
						-delta, unitCost, true, docID, l.id, now); err != nil {
						return "", err
					}
				}
			}

			// Facture fournisseur sur réception : la part déjà entrée au prix de
			// la réception est réévaluée si le prix facturé diffère.
			if isCostBearing(d.docType) && l.skipBase > 0 && unitCost != l.refCost {
				if err := needWarehouse(); err != nil {
					return "", err
				}
				if err := revalueAvg(tx, pid, d.warehouseID.String,
					unitCost-l.refCost, l.skipBase, docID, now); err != nil {
					return "", err
				}
			}

			lineCost := lineCostBase
			if salesFamily {
				// Coût porté PAR UNITÉ DE LA LIGNE (carton, pièce…) : les rapports
				// multiplient qty_milli × unit_cost.
				lineCost = roundDiv(lineCostBase*l.packFactor, 1000)
			}
			if _, err := tx.Exec(`UPDATE document_lines SET unit_cost=? WHERE id=?`, lineCost, l.id); err != nil {
				return "", err
			}

			// Historique du dernier prix payé au fournisseur.
			if isCostBearing(d.docType) && d.partnerID.Valid &&
				(l.skipBase == 0 || unitCost != l.refCost) {
				if _, err := tx.Exec(`INSERT INTO supplier_prices
					(id, partner_id, product_id, unit_cost, document_id, created_at)
					VALUES (?, ?, ?, ?, ?, ?)`,
					NewID(), d.partnerID.String, pid, unitCost, docID, now); err != nil {
					return "", err
				}
			}
		}
	}

	// ---- Inventory count: lines carry the COUNTED absolute quantity. The
	// variance is counted − theoretical-at-count-time (expected_milli, stamped
	// by the client); applied on top of the CURRENT level so sales/receipts
	// recorded between the count and its validation are not wiped out.
	if d.docType == InventoryCount {
		if !d.warehouseID.Valid {
			return "", ErrNoWarehouse
		}
		for _, l := range lines {
			if !l.productID.Valid {
				continue
			}
			if l.qtyMilli < 0 {
				return "", &PostError{"une quantité comptée ne peut pas être négative"}
			}
			if productIsService(tx, l.productID.String) {
				continue
			}
			var current int64
			tx.QueryRow(`SELECT qty_milli FROM stock_levels WHERE product_id=? AND warehouse_id=?`,
				l.productID.String, d.warehouseID.String).Scan(&current)
			base := current
			if l.expected.Valid {
				base = l.expected.Int64
			}
			delta := l.qtyMilli - base
			if current+delta < 0 {
				// Le comptage contredit les mouvements postérieurs : on ramène à 0.
				delta = -current
			}
			if delta == 0 {
				continue
			}
			cost := currentAvgCost(tx, l.productID.String, d.warehouseID.String)
			if err := applyStockMove(tx, l.productID.String, d.warehouseID.String, l.lotID,
				delta, cost, false, docID, l.id, now); err != nil {
				return "", err
			}
			if _, err := tx.Exec(`UPDATE document_lines SET unit_cost=? WHERE id=?`,
				cost, l.id); err != nil {
				return "", err
			}
		}
	}

	// ---- Bon de commande lié : reliquat, sur-réception, statut ------------
	if d.docType == PurchaseReceipt && d.refDocID.Valid {
		if err := applyToOrder(tx, &d, lines, userID, number, false); err != nil {
			return "", err
		}
	}

	// ---- Prix de vente saisi sur les lignes de réception ------------------
	if d.docType == PurchaseReceipt {
		for _, l := range lines {
			if !l.productID.Valid || !l.newSalePrice.Valid || l.newSalePrice.Int64 < 0 {
				continue
			}
			var current int64
			var name string
			if err := tx.QueryRow(`SELECT price_retail, name FROM products WHERE id = ?`,
				l.productID.String).Scan(&current, &name); err != nil {
				continue
			}
			if current == l.newSalePrice.Int64 {
				continue
			}
			if _, err := tx.Exec(`UPDATE products SET price_retail=?, updated_at=? WHERE id=?`,
				l.newSalePrice.Int64, now, l.productID.String); err != nil {
				return "", err
			}
			auditTx(tx, userID, "reception.price_change", "product", l.productID.String,
				fmt.Sprintf("%s : prix de vente %d,%02d → %d,%02d DA (%s)",
					name, current/100, current%100,
					l.newSalePrice.Int64/100, l.newSalePrice.Int64%100, number))
		}
	}

	// ---- Partner ledger ---------------------------------------------------
	// Convention: positive = the partner owes us.
	var ledgerAmount int64
	var ledgerKind string
	switch d.docType {
	case SaleTicket, SaleInvoice:
		if split != nil {
			// Seule la part « crédit » d'un paiement mixte va au compte client.
			if split.credit > 0 {
				ledgerAmount, ledgerKind = split.credit, "invoice"
			}
		} else if d.paymentMethod.String == "credit" {
			if !d.partnerID.Valid {
				return "", ErrNoPartner
			}
			ledgerAmount, ledgerKind = totalTTC, "invoice"
		}
	case SaleCreditNote:
		// Un avoir se règle d'UNE seule façon : remboursé en espèces/carte (le
		// compte client n'est pas touché) OU porté au crédit du compte client.
		// Si la vente d'origine était à crédit, l'avoir vient en déduction de la
		// dette, jamais en espèces.
		method := d.paymentMethod.String
		paidOut := method == "cash" || method == "cib" || method == "edahabia"
		if d.refDocID.Valid {
			var refMethod sql.NullString
			tx.QueryRow(`SELECT payment_method FROM documents WHERE id = ?`, d.refDocID.String).
				Scan(&refMethod)
			if refMethod.String == "" {
				// Vente d'origine en paiement mixte avec une part à crédit :
				// le retour vient en déduction de la dette.
				var n int
				tx.QueryRow(`SELECT COUNT(*) FROM document_payments WHERE document_id = ? AND method = 'credit'`,
					d.refDocID.String).Scan(&n)
				if n > 0 {
					refMethod = sql.NullString{String: "credit", Valid: true}
				}
			}
			if refMethod.String == "credit" && paidOut {
				paidOut = false
				if _, err := tx.Exec(`UPDATE documents SET payment_method='credit' WHERE id=?`, docID); err != nil {
					return "", err
				}
			}
		}
		if d.partnerID.Valid && !paidOut {
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

	// ---- Fidélité : points gagnés sur la vente ------------------------------
	if err := earnLoyalty(tx, d.docType, d.partnerID, docID, goodsTTC, userID, now); err != nil {
		return "", err
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

// resolveLots enforces the tracking flags and creates missing lot rows for a
// cost-bearing inbound document. It also applies the supplier's minimum
// remaining shelf life.
func resolveLots(tx *sql.Tx, d *docRow, lines []lineRow, userID string) error {
	var minShelfDays int64
	if d.partnerID.Valid {
		tx.QueryRow(`SELECT min_shelf_days FROM partners WHERE id = ?`, d.partnerID.String).
			Scan(&minShelfDays)
	}
	limit := ""
	if minShelfDays > 0 {
		limit = time.Now().AddDate(0, 0, int(minShelfDays)).Format("2006-01-02")
	}

	for i := range lines {
		l := &lines[i]
		if !l.productID.Valid || l.baseQty+l.baseFree == 0 {
			continue
		}
		var trackLots, trackExpiry int64
		var name string
		if err := tx.QueryRow(`SELECT track_lots, track_expiry, name FROM products WHERE id = ?`,
			l.productID.String).Scan(&trackLots, &trackExpiry, &name); err != nil {
			continue
		}
		lotNumber := strings.TrimSpace(l.lotNumber.String)
		expiry := strings.TrimSpace(l.expiryDate.String)

		if trackLots == 1 && lotNumber == "" {
			return &PostError{fmt.Sprintf("le n° de lot est obligatoire pour « %s »", name)}
		}
		if trackExpiry == 1 && expiry == "" {
			return &PostError{fmt.Sprintf("la date de péremption est obligatoire pour « %s »", name)}
		}
		if limit != "" && expiry != "" && expiry < limit {
			if d.acceptShortDated == 0 {
				return &PostError{fmt.Sprintf(
					"durée de vie insuffisante pour « %s » (DLC %s, minimum fournisseur %d jours) — acceptation explicite requise",
					name, expiry, minShelfDays)}
			}
			auditTx(tx, userID, "reception.short_dated_accepted", "product", l.productID.String,
				fmt.Sprintf("%s : lot %s, DLC %s sous la durée minimale (%d j)", name, lotNumber, expiry, minShelfDays))
		}

		if lotNumber == "" {
			continue
		}
		var lotID string
		err := tx.QueryRow(`SELECT id FROM lots WHERE product_id=? AND lot_number=?`,
			l.productID.String, lotNumber).Scan(&lotID)
		if err == sql.ErrNoRows {
			lotID = NewID()
			if _, err := tx.Exec(`INSERT INTO lots (id, product_id, lot_number, expiry_date, created_at)
				VALUES (?, ?, ?, ?, ?)`,
				lotID, l.productID.String, lotNumber, nullIfEmpty(expiry), NowISO()); err != nil {
				return err
			}
		} else if err != nil {
			return err
		} else if expiry != "" {
			tx.Exec(`UPDATE lots SET expiry_date=? WHERE id=? AND (expiry_date IS NULL OR expiry_date='')`,
				expiry, lotID)
		}
		l.lotID = sql.NullString{String: lotID, Valid: true}
		if _, err := tx.Exec(`UPDATE document_lines SET lot_id=? WHERE id=?`, lotID, l.id); err != nil {
			return err
		}
	}
	return nil
}

// applyToOrder maintains qte_recue on the linked purchase order and derives its
// status. reverse=true subtracts (used when a reception is voided).
func applyToOrder(tx *sql.Tx, d *docRow, lines []lineRow, userID, number string, reverse bool) error {
	var refType string
	if err := tx.QueryRow(`SELECT doc_type FROM documents WHERE id = ?`, d.refDocID.String).
		Scan(&refType); err != nil || refType != PurchaseOrder {
		return nil // linked to something else (or gone) — not an order
	}

	var tolerance int64 = 500 // 5 % par défaut
	if d.partnerID.Valid {
		var t sql.NullInt64
		tx.QueryRow(`SELECT over_receipt_pct FROM partners WHERE id = ?`, d.partnerID.String).Scan(&t)
		if t.Valid {
			tolerance = t.Int64
		}
	}

	for _, l := range lines {
		if !l.productID.Valid || l.baseQty == 0 {
			continue
		}
		qty := l.baseQty
		if reverse {
			qty = -qty
		}
		var lineID string
		var ordered, received int64
		err := tx.QueryRow(`SELECT id, qty_milli, qty_received_milli FROM document_lines
			WHERE document_id=? AND product_id=? ORDER BY position LIMIT 1`,
			d.refDocID.String, l.productID.String).Scan(&lineID, &ordered, &received)
		if err != nil {
			continue // reception line not on the order — accepted, it simply doesn't decrement anything
		}
		newReceived := received + qty
		if !reverse && ordered > 0 {
			allowed := ordered + roundDiv(ordered*tolerance, 10000)
			if newReceived > allowed {
				if d.acceptOverReceipt == 0 {
					var name string
					tx.QueryRow(`SELECT name FROM products WHERE id=?`, l.productID.String).Scan(&name)
					return &PostError{fmt.Sprintf(
						"sur-réception au-delà de la tolérance (%d,%02d %%) pour « %s » — confirmation explicite requise",
						tolerance/100, tolerance%100, name)}
				}
				auditTx(tx, userID, "reception.over_receipt_accepted", "document", d.refDocID.String,
					fmt.Sprintf("sur-réception acceptée sur %s (produit %s, %s)", number, l.productID.String, d.id))
			}
		}
		if _, err := tx.Exec(`UPDATE document_lines SET qty_received_milli=? WHERE id=?`,
			newReceived, lineID); err != nil {
			return err
		}
	}
	return RefreshOrderStatus(tx, d.refDocID.String)
}

// RefreshOrderStatus recomputes the derived reception status of a purchase
// order from its lines. 'closed' is terminal and never recomputed away.
func RefreshOrderStatus(tx *sql.Tx, orderID string) error {
	var current sql.NullString
	if err := tx.QueryRow(`SELECT order_status FROM documents WHERE id=?`, orderID).
		Scan(&current); err != nil {
		return nil
	}
	if current.String == "closed" {
		return nil
	}
	rows, err := tx.Query(`SELECT qty_milli, qty_received_milli, qty_cancelled_milli
		FROM document_lines WHERE document_id=? AND product_id IS NOT NULL`, orderID)
	if err != nil {
		return err
	}
	defer rows.Close()
	anyRecv, all := false, true
	for rows.Next() {
		var ordered, received, cancelled int64
		if err := rows.Scan(&ordered, &received, &cancelled); err != nil {
			return err
		}
		if received > 0 {
			anyRecv = true
		}
		if received+cancelled < ordered {
			all = false
		}
	}
	var st any
	switch {
	case all && anyRecv:
		st = "received"
	case anyRecv:
		st = "partial"
	default:
		st = nil
	}
	_, err = tx.Exec(`UPDATE documents SET order_status=?, updated_at=? WHERE id=?`,
		st, NowISO(), orderID)
	return err
}

// Void reverses a POSTED document: it writes negating stock-ledger rows at the
// original costs, negates the partner-ledger entries, decrements any linked
// purchase-order receipts, and marks the document cancelled. The number stays.
// The error remains visible; a corrected document is created separately.
func Void(db *sql.DB, docID, userID, reason string) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var d docRow
	var number sql.NullString
	err = tx.QueryRow(`SELECT id, doc_type, status, doc_date, partner_id, warehouse_id,
			dest_warehouse_id, ref_document_id, number FROM documents WHERE id = ?`, docID).Scan(
		&d.id, &d.docType, &d.status, &d.docDate, &d.partnerID, &d.warehouseID,
		&d.destWarehouseID, &d.refDocID, &number)
	if err == sql.ErrNoRows {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if d.status != "posted" {
		return ErrNotPosted
	}
	now := NowISO()

	// Contrepassation du stock : une écriture inverse par écriture d'origine,
	// au même coût. Annuler une sortie ne change pas le CUMP ; annuler une
	// entrée valorisée (réception, facture, ajustement, arrivée de transfert)
	// retire sa valeur de la moyenne pondérée.
	rows, err := tx.Query(`SELECT product_id, warehouse_id, lot_id, qty_delta_milli, unit_cost, line_id
		FROM stock_ledger WHERE document_id = ?`, docID)
	if err != nil {
		return err
	}
	type move struct {
		productID, warehouseID string
		lotID                  sql.NullString
		delta, cost            int64
		lineID                 sql.NullString
	}
	var moves []move
	for rows.Next() {
		var m move
		if err := rows.Scan(&m.productID, &m.warehouseID, &m.lotID, &m.delta, &m.cost, &m.lineID); err != nil {
			rows.Close()
			return err
		}
		moves = append(moves, m)
	}
	rows.Close()
	allowNeg := allowNegativeStock(tx)
	valued := isCostBearing(d.docType) || d.docType == StockTransfer || d.docType == StockAdjustment
	for _, m := range moves {
		if m.delta == 0 { // réévaluation de prix : pas de quantité à contrepasser
			continue
		}
		lineID := ""
		if m.lineID.Valid {
			lineID = m.lineID.String
		}
		// Défaire une entrée dont la marchandise est déjà sortie ferait passer
		// le stock en négatif : on refuse (sauf réglage contraire).
		if m.delta > 0 && !allowNeg {
			if err := checkOutflow(tx, m.productID, m.warehouseID, m.delta); err != nil {
				return &PostError{"contrepassation impossible : " + err.Error()}
			}
		}
		// Contrepasser une entrée valorisée retire aussi son coût du CUMP.
		if err := applyMove(tx, m.productID, m.warehouseID, m.lotID, -m.delta, m.cost,
			moveOpts{unwind: m.delta > 0 && valued, reversal: true}, docID, lineID, now); err != nil {
			return err
		}
	}

	// Contrepassation du compte partenaire.
	prows, err := tx.Query(`SELECT partner_id, amount, kind FROM partner_ledger WHERE document_id = ?`, docID)
	if err != nil {
		return err
	}
	type pl struct {
		partnerID string
		amount    int64
		kind      string
	}
	var pls []pl
	for prows.Next() {
		var p pl
		if err := prows.Scan(&p.partnerID, &p.amount, &p.kind); err != nil {
			prows.Close()
			return err
		}
		pls = append(pls, p)
	}
	prows.Close()
	for _, p := range pls {
		// partner_ledger.kind is CHECK-constrained (no 'void'): the reversal is
		// an 'adjustment' on the same document, which is now cancelled.
		if _, err := tx.Exec(`INSERT INTO partner_ledger (id, partner_id, amount, kind, document_id, created_at)
			VALUES (?, ?, ?, 'adjustment', ?, ?)`, NewID(), p.partnerID, -p.amount, docID, now); err != nil {
			return err
		}
	}

	// Décrémenter le reliquat du bon de commande lié.
	if d.docType == PurchaseReceipt && d.refDocID.Valid {
		lrows, err := tx.Query(`SELECT id, product_id, lot_id, qty_milli, unit_price, discount_pct,
				vat_rate, qty_free_milli, pack_factor_milli, lot_number, expiry_date, new_sale_price
			FROM document_lines WHERE document_id = ?`, docID)
		if err != nil {
			return err
		}
		var lines []lineRow
		for lrows.Next() {
			var l lineRow
			if err := lrows.Scan(&l.id, &l.productID, &l.lotID, &l.qtyMilli, &l.unitPrice,
				&l.discount, &l.vat, &l.qtyFree, &l.packFactor, &l.lotNumber, &l.expiryDate,
				&l.newSalePrice); err != nil {
				lrows.Close()
				return err
			}
			if l.packFactor <= 0 {
				l.packFactor = 1000
			}
			l.baseQty = baseUnits(l.qtyMilli, l.packFactor)
			lines = append(lines, l)
		}
		lrows.Close()
		if err := applyToOrder(tx, &d, lines, userID, number.String, true); err != nil {
			return err
		}
	}

	if _, err := tx.Exec(`UPDATE documents SET status='cancelled', updated_at=? WHERE id=?`,
		now, docID); err != nil {
		return err
	}
	detail := "contrepassation du document " + number.String
	if strings.TrimSpace(reason) != "" {
		detail += " — " + strings.TrimSpace(reason)
	}
	auditTx(tx, userID, "document.void", "document", docID, detail)

	// Fidélité : points gagnés repris, points utilisés rendus.
	if err := voidLoyalty(tx, docID, userID, now); err != nil {
		return err
	}

	return tx.Commit()
}

// StockDivergence reports one cache row that no longer matches the ledger.
type StockDivergence struct {
	ProductID   string `json:"product_id"`
	WarehouseID string `json:"warehouse_id"`
	CachedQty   int64  `json:"cached_qty_milli"`
	LedgerQty   int64  `json:"ledger_qty_milli"`
	CachedAvg   int64  `json:"cached_avg_cost"`
	LedgerAvg   int64  `json:"ledger_avg_cost"`
}

// VerifyStock replays the whole movement ledger and compares quantity and CUMP
// against the stock_levels cache. The ledger is the source of truth; the cache
// is only a convenience, and this is the nightly divergence check the spec
// requires. When repair is true, divergent cache rows are rewritten from the
// ledger.
func VerifyStock(db *sql.DB, repair bool) ([]StockDivergence, error) {
	rows, err := db.Query(`SELECT sl.product_id, sl.warehouse_id, sl.qty_delta_milli, sl.unit_cost, d.doc_type,
			sl.is_reversal, sl.avg_after
		FROM stock_ledger sl JOIN documents d ON d.id = sl.document_id
		ORDER BY sl.created_at, sl.id`)
	if err != nil {
		return nil, err
	}
	type key struct{ p, w string }
	type acc struct{ qty, avg int64 }
	state := map[key]*acc{}
	for rows.Next() {
		var p, w, dt string
		var delta, cost, rev int64
		var avgAfter sql.NullInt64
		if err := rows.Scan(&p, &w, &delta, &cost, &dt, &rev, &avgAfter); err != nil {
			rows.Close()
			return nil, err
		}
		k := key{p, w}
		a := state[k]
		if a == nil {
			a = &acc{}
			state[k] = a
		}
		// Même règle que le posting : seules les entrées valorisées
		// (réception/facture d'achat, arrivée d'un transfert, ajustement
		// entrant) recalculent la moyenne pondérée, au coût porté par la ligne.
		valued := isCostBearing(dt) || dt == StockTransfer || dt == StockAdjustment
		if avgAfter.Valid { // réévaluation : CUMP absolu, aucune quantité
			a.avg = avgAfter.Int64
			continue
		}
		if rev == 1 { // contrepassation : défait le CUMP d'une entrée valorisée
			if delta < 0 && valued {
				a.avg = unwindAvg(a.qty, a.avg, -delta, cost)
			}
			a.qty += delta
			continue
		}
		updateAvg := delta > 0 && valued
		if updateAvg {
			if a.qty <= 0 {
				a.avg = cost
			} else {
				a.avg = roundDiv(a.qty*a.avg+delta*cost, a.qty+delta)
			}
		}
		a.qty += delta
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	var out []StockDivergence
	crows, err := db.Query(`SELECT product_id, warehouse_id, qty_milli, avg_cost FROM stock_levels`)
	if err != nil {
		return nil, err
	}
	defer crows.Close()
	for crows.Next() {
		var p, w string
		var qty, avg int64
		if err := crows.Scan(&p, &w, &qty, &avg); err != nil {
			return nil, err
		}
		a := state[key{p, w}]
		lq, la := int64(0), int64(0)
		if a != nil {
			lq, la = a.qty, a.avg
		}
		if lq != qty || la != avg {
			out = append(out, StockDivergence{
				ProductID: p, WarehouseID: w,
				CachedQty: qty, LedgerQty: lq,
				CachedAvg: avg, LedgerAvg: la,
			})
		}
	}
	if repair {
		for _, dv := range out {
			db.Exec(`UPDATE stock_levels SET qty_milli=?, avg_cost=?, updated_at=?
				WHERE product_id=? AND warehouse_id=?`,
				dv.LedgerQty, dv.LedgerAvg, NowISO(), dv.ProductID, dv.WarehouseID)
		}
	}
	return out, nil
}

// nextNumber draws the document number; the format comes from the numbering
// settings (numbering.go), today's « FV-2026-000124 » by default.
func nextNumber(tx *sql.Tx, docType, docDate string) (string, error) {
	return nextNumberFmt(tx, docType, docDate)
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
	return applyMove(tx, productID, warehouseID, lotID, deltaMilli, unitCost,
		moveOpts{updateAvg: updateAvg}, docID, lineID, now)
}

// moveOpts: updateAvg folds an inbound move into the CUMP; unwind (reversal of
// an inbound valued move) takes it back out; reversal marks the ledger row so
// the nightly replay can tell a void from an ordinary movement.
type moveOpts struct{ updateAvg, unwind, reversal bool }

func applyMove(tx *sql.Tx, productID, warehouseID string, lotID sql.NullString,
	deltaMilli, unitCost int64, o moveOpts, docID, lineID, now string) error {
	updateAvg := o.updateAvg

	rev := 0
	if o.reversal {
		rev = 1
	}
	if _, err := tx.Exec(`INSERT INTO stock_ledger
		(id, product_id, warehouse_id, lot_id, qty_delta_milli, unit_cost, document_id, line_id,
		 created_at, is_reversal)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		NewID(), productID, warehouseID, lotID, deltaMilli, unitCost, docID,
		nullIfEmpty(lineID), now, rev); err != nil {
		return err
	}
	if lotID.Valid {
		if _, err := tx.Exec(`UPDATE lots SET qty_milli = qty_milli + ? WHERE id = ?`,
			deltaMilli, lotID.String); err != nil {
			return err
		}
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
	} else if o.unwind && deltaMilli < 0 {
		newAvg = unwindAvg(oldQty, oldAvg, -deltaMilli, unitCost)
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

// PaymentMethods lists the methods a document_payments row may carry.
var PaymentMethods = map[string]string{
	"cash":     "Espèces",
	"cib":      "CIB",
	"edahabia": "Edahabia",
	"cheque":   "Chèque",
	"transfer": "Virement",
	"credit":   "Crédit",
	"gift":     "Carte cadeau",
}

// splitPayment is the sum of a document's document_payments rows by method.
type splitPayment struct {
	cash, credit, other int64
}

func loadSplitPayment(tx *sql.Tx, docID string) (*splitPayment, error) {
	rows, err := tx.Query(`SELECT method, amount FROM document_payments WHERE document_id = ?`, docID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var sp splitPayment
	n := 0
	for rows.Next() {
		var method string
		var amount int64
		if err := rows.Scan(&method, &amount); err != nil {
			return nil, err
		}
		n++
		switch method {
		case "cash":
			sp.cash += amount
		case "credit":
			sp.credit += amount
		default:
			sp.other += amount
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, nil
	}
	return &sp, nil
}

// SplitTimbre returns the stamp duty due on a mixed payment: the cash part of
// the goods is what the non-cash methods leave of the total, and only that part
// bears the timbre. The cash row(s) must then equal that part + the timbre.
func SplitTimbre(totalTTC, nonCash int64) (cashGoods, timbre int64) {
	cashGoods = totalTTC - nonCash
	if cashGoods > 0 {
		timbre = Timbre(cashGoods)
	}
	return
}

// settle checks that the rows cover the ticket exactly and returns the timbre.
func (sp *splitPayment) settle(totalTTC int64, hasPartner bool) (int64, error) {
	return sp.settleTimbre(totalTTC, hasPartner, true)
}

// settleTimbre is settle with the shop's timbre switch (timbre_enabled).
func (sp *splitPayment) settleTimbre(totalTTC int64, hasPartner, timbreOn bool) (int64, error) {
	if sp.credit > 0 && !hasPartner {
		return 0, &PostError{"un paiement à crédit exige un client"}
	}
	nonCash := sp.credit + sp.other
	cashGoods, timbre := SplitTimbre(totalTTC, nonCash)
	if !timbreOn {
		timbre = 0
	}
	if cashGoods < 0 {
		return 0, &PostError{fmt.Sprintf(
			"les paiements hors espèces (%s DA) dépassent le total du ticket (%s DA)",
			fmtDA(nonCash), fmtDA(totalTTC))}
	}
	if sp.cash == 0 && cashGoods > 0 {
		timbre = 0
	}
	if sp.cash != cashGoods+timbre {
		return 0, &PostError{fmt.Sprintf(
			"la somme des paiements (%s DA) ne correspond pas au total à payer (%s DA)",
			fmtDA(sp.cash+nonCash), fmtDA(totalTTC+timbre))}
	}
	return timbre, nil
}

func fmtDA(c int64) string {
	sign := ""
	if c < 0 {
		sign, c = "-", -c
	}
	return fmt.Sprintf("%s%d,%02d", sign, c/100, c%100)
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
