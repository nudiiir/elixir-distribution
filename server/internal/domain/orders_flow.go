package domain

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// Logistics cycle of a validated order: preparation (picks per lot,
// scan), ready, delivery note, shipping, delivery (collection), invoice, cancellation,
// backorders.

// WrongProductError: a scanned barcode that is not on the order (HTTP 422).
type WrongProductError struct{ Msg string }

func (e *WrongProductError) Error() string { return e.Msg }

// lotOpenPicks is what preparations not yet shipped hold of a lot.
func lotOpenPicks(q Querier, lotID string) int64 {
	var n sql.NullInt64
	q.QueryRow(`SELECT SUM(k.qty_milli) FROM customer_order_picks k
		JOIN customer_orders o ON o.id = k.order_id
		WHERE k.lot_id = ? AND o.delivery_note_id IS NULL
		  AND o.status IN ('validated','preparing','ready')`, lotID).Scan(&n)
	return n.Int64
}

// LotAvailable = lot quantity − open picks.
func LotAvailable(q Querier, lotID string) int64 {
	var qty int64
	q.QueryRow(`SELECT qty_milli FROM lots WHERE id = ?`, lotID).Scan(&qty)
	return qty - lotOpenPicks(q, lotID)
}

// LotSuggestion is one FEFO candidate lot for a preparation.
type LotSuggestion struct {
	LotID        string  `json:"lot_id"`
	LotNumber    string  `json:"lot_number"`
	ExpiryDate   *string `json:"expiry_date"`
	QtyAvailable int64   `json:"qty_available_milli"`
	QtySuggested int64   `json:"qty_suggested_milli"`
}

// FEFOSuggestions spreads `need` over the product's lots, earliest expiry
// first, net of the other open preparations.
func FEFOSuggestions(q Queryer, productID string, need int64) ([]LotSuggestion, error) {
	rows, err := q.Query(`SELECT id, lot_number, expiry_date, qty_milli FROM lots
		WHERE product_id = ? AND qty_milli > 0
		ORDER BY (expiry_date IS NULL OR expiry_date = ''), expiry_date, created_at`, productID)
	if err != nil {
		return nil, err
	}
	var out []LotSuggestion
	for rows.Next() {
		var s LotSuggestion
		var exp sql.NullString
		if err := rows.Scan(&s.LotID, &s.LotNumber, &exp, &s.QtyAvailable); err != nil {
			rows.Close()
			return nil, err
		}
		if exp.Valid && exp.String != "" {
			e := exp.String
			s.ExpiryDate = &e
		}
		out = append(out, s)
	}
	rows.Close()
	res := []LotSuggestion{}
	for _, s := range out {
		s.QtyAvailable -= lotOpenPicks(q, s.LotID)
		if s.QtyAvailable <= 0 {
			continue
		}
		if need > 0 {
			s.QtySuggested = min(need, s.QtyAvailable)
			need -= s.QtySuggested
		}
		res = append(res, s)
	}
	return res, nil
}

func refreshPrepared(tx *sql.Tx, lineID string) (int64, error) {
	var n int64
	tx.QueryRow(`SELECT COALESCE(SUM(qty_milli),0) FROM customer_order_picks WHERE line_id = ?`, lineID).Scan(&n)
	_, err := tx.Exec(`UPDATE customer_order_lines SET qty_prepared_milli=?, updated_at=? WHERE id=?`, n, NowISO(), lineID)
	return n, err
}

// enterPreparation moves a validated (or ready, no BL yet) order to « preparing ».
func enterPreparation(tx *sql.Tx, o *orderHead, userID string) error {
	switch o.status {
	case OrderPreparing:
		return nil
	case OrderValidated:
		return setOrderStatus(tx, o, OrderPreparing, "start_preparation", userID, "préparation commencée")
	case OrderReady:
		if o.deliveryNoteID.Valid {
			return &PostError{"le BL de cette commande est déjà validé : la préparation ne peut plus changer"}
		}
		return setOrderStatus(tx, o, OrderPreparing, "resume_preparation", userID, "préparation reprise")
	}
	return &PostError{fmt.Sprintf("la commande %s est « %s » : elle ne se prépare pas",
		o.number, OrderStatusLabels[o.status])}
}

// StartPreparation: validated → preparing.
func StartPreparation(tx *sql.Tx, orderID, userID string) error {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	if o.status != OrderValidated {
		return &PostError{"seule une commande validée peut passer en préparation"}
	}
	return enterPreparation(tx, o, userID)
}

// PickResult describes the picks written for one request.
type PickResult struct {
	LineID        string   `json:"line_id"`
	ProductID     string   `json:"product_id"`
	ProductName   string   `json:"product_name"`
	PickIDs       []string `json:"pick_ids"`
	QtyMilli      int64    `json:"qty_milli"`
	QtyPrepared   int64    `json:"qty_prepared_milli"`
	QtyToPrepare  int64    `json:"qty_to_prepare_milli"`
	LineComplete  bool     `json:"line_complete"`
	OrderComplete bool     `json:"order_complete"`
	Lots          []string `json:"lots"`
}

// AddPick records `qty` prepared on a line. With lotID "" on a lot-tracked
// product the quantity is spread FEFO over the available lots.
func AddPick(tx *sql.Tx, orderID, lineID, lotID string, qty int64, barcode, userID string) (*PickResult, error) {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return nil, err
	}
	if err := enterPreparation(tx, o, userID); err != nil {
		return nil, err
	}
	return addPickRaw(tx, o, lineID, lotID, qty, barcode, userID, true)
}

func addPickRaw(tx *sql.Tx, o *orderHead, lineID, lotID string, qty int64, barcode, userID string, event bool) (*PickResult, error) {
	if qty <= 0 {
		return nil, &PostError{"la quantité préparée doit être positive"}
	}
	var productID, name string
	var validated, free, prepared int64
	if err := tx.QueryRow(`SELECT product_id, description, qty_validated_milli, qty_free_milli, qty_prepared_milli
		FROM customer_order_lines WHERE id=? AND order_id=?`, lineID, o.id).
		Scan(&productID, &name, &validated, &free, &prepared); err != nil {
		return nil, &NotFoundError{"ligne introuvable"}
	}
	target := validated + free
	if prepared+qty > target {
		return nil, &PostError{fmt.Sprintf("« %s » : %s à préparer, %s déjà préparé(s) — %s de trop",
			name, fmtQtyMilli(target), fmtQtyMilli(prepared), fmtQtyMilli(prepared+qty-target))}
	}
	res := &PickResult{LineID: lineID, ProductID: productID, ProductName: name, QtyMilli: qty,
		PickIDs: []string{}, Lots: []string{}}
	type chunk struct {
		lot    string
		number string
		qty    int64
	}
	var chunks []chunk
	if lotID != "" {
		var lp, num string
		if err := tx.QueryRow(`SELECT product_id, lot_number FROM lots WHERE id = ?`, lotID).Scan(&lp, &num); err != nil {
			return nil, &PostError{"lot introuvable"}
		}
		if lp != productID {
			return nil, &PostError{fmt.Sprintf("le lot %s n'appartient pas à « %s »", num, name)}
		}
		if a := LotAvailable(tx, lotID); a < qty && !allowNegativeStock(tx) {
			return nil, &PostError{fmt.Sprintf("lot %s de « %s » : %s disponible(s), %s demandé(s)",
				num, name, fmtQtyMilli(max(0, a)), fmtQtyMilli(qty))}
		}
		chunks = append(chunks, chunk{lotID, num, qty})
	} else if productIsLotTracked(tx, productID) {
		sugg, err := FEFOSuggestions(tx, productID, qty)
		if err != nil {
			return nil, err
		}
		left := qty
		for _, s := range sugg {
			if s.QtySuggested > 0 {
				chunks = append(chunks, chunk{s.LotID, s.LotNumber, s.QtySuggested})
				left -= s.QtySuggested
			}
		}
		if left > 0 {
			chunks = append(chunks, chunk{"", "", left}) // no lot left: booked without lot
		}
	} else {
		chunks = append(chunks, chunk{"", "", qty})
	}
	now := NowISO()
	for _, c := range chunks {
		id := NewID()
		if _, err := tx.Exec(`INSERT INTO customer_order_picks (id, order_id, line_id, lot_id, qty_milli, barcode, picked_by, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, id, o.id, lineID, nullIfEmpty(c.lot), c.qty, barcode,
			nullIfEmpty(userID), now); err != nil {
			return nil, err
		}
		res.PickIDs = append(res.PickIDs, id)
		if c.number != "" {
			res.Lots = append(res.Lots, c.number)
		}
	}
	p, err := refreshPrepared(tx, lineID)
	if err != nil {
		return nil, err
	}
	res.QtyPrepared, res.QtyToPrepare = p, target
	res.LineComplete = p >= target
	var open int
	tx.QueryRow(`SELECT COUNT(*) FROM customer_order_lines WHERE order_id=?
		AND qty_prepared_milli < qty_validated_milli + qty_free_milli`, o.id).Scan(&open)
	res.OrderComplete = open == 0
	if event {
		note := fmt.Sprintf("%s : +%s", name, fmtQtyMilli(qty))
		if len(res.Lots) > 0 {
			note += " (lot " + strings.Join(res.Lots, ", ") + ")"
		}
		if err := OrderEvent(tx, o.id, "pick", "", "", userID, note); err != nil {
			return nil, err
		}
	}
	return res, nil
}

// RemovePick cancels one pick (before the BL).
func RemovePick(tx *sql.Tx, orderID, pickID, userID string) error {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	var lineID, name string
	var qty int64
	if err := tx.QueryRow(`SELECT k.line_id, l.description, k.qty_milli FROM customer_order_picks k
		JOIN customer_order_lines l ON l.id = k.line_id WHERE k.id = ? AND k.order_id = ?`, pickID, orderID).
		Scan(&lineID, &name, &qty); err != nil {
		return &NotFoundError{"prélèvement introuvable"}
	}
	if err := enterPreparation(tx, o, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM customer_order_picks WHERE id = ?`, pickID); err != nil {
		return err
	}
	if _, err := refreshPrepared(tx, lineID); err != nil {
		return err
	}
	return OrderEvent(tx, orderID, "unpick", "", "", userID, fmt.Sprintf("%s : −%s", name, fmtQtyMilli(qty)))
}

// ResolveBarcode finds the product of a barcode (main, extra or pack code)
// and the base quantity one scan stands for.
func ResolveBarcode(q Querier, code string) (productID string, qty int64, ok bool) {
	code = strings.TrimSpace(code)
	if code == "" {
		return "", 0, false
	}
	if q.QueryRow(`SELECT id FROM products WHERE barcode = ?`, code).Scan(&productID) == nil {
		return productID, 1000, true
	}
	if q.QueryRow(`SELECT product_id FROM product_barcodes WHERE barcode = ?`, code).Scan(&productID) == nil {
		return productID, 1000, true
	}
	if q.QueryRow(`SELECT product_id, factor_milli FROM packagings WHERE barcode = ?`, code).Scan(&productID, &qty) == nil {
		return productID, qty, true
	}
	return "", 0, false
}

// ScanPick: one barcode scanned at the preparation desk. The scanned product
// must be on the order and still to prepare; the quantity defaults to the
// barcode's (1 unit, or the pack factor of a carton code).
func ScanPick(tx *sql.Tx, orderID, barcode string, qty int64, lotNumber, userID string) (*PickResult, error) {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return nil, err
	}
	pid, unit, ok := ResolveBarcode(tx, barcode)
	if !ok {
		return nil, &WrongProductError{fmt.Sprintf("code-barres « %s » inconnu", strings.TrimSpace(barcode))}
	}
	var pname string
	tx.QueryRow(`SELECT name FROM products WHERE id = ?`, pid).Scan(&pname)
	rows, err := tx.Query(`SELECT id, qty_validated_milli + qty_free_milli - qty_prepared_milli
		FROM customer_order_lines WHERE order_id = ? AND product_id = ?
		  AND qty_validated_milli + qty_free_milli > 0 ORDER BY position`, orderID, pid)
	if err != nil {
		return nil, err
	}
	type cand struct {
		id     string
		remain int64
	}
	var cands []cand
	for rows.Next() {
		var c cand
		rows.Scan(&c.id, &c.remain)
		cands = append(cands, c)
	}
	rows.Close()
	if len(cands) == 0 {
		return nil, &WrongProductError{fmt.Sprintf("« %s » n'est pas dans cette commande", pname)}
	}
	line := ""
	var remain int64
	for _, c := range cands {
		if c.remain > 0 {
			line, remain = c.id, c.remain
			break
		}
	}
	if line == "" {
		return nil, &PostError{fmt.Sprintf("« %s » est déjà entièrement préparé", pname)}
	}
	if qty <= 0 {
		qty = unit
	}
	if qty > remain {
		return nil, &PostError{fmt.Sprintf("« %s » : %s scanné(s), il n'en reste que %s à préparer",
			pname, fmtQtyMilli(qty), fmtQtyMilli(remain))}
	}
	lotID := ""
	if ln := strings.TrimSpace(lotNumber); ln != "" {
		if err := tx.QueryRow(`SELECT id FROM lots WHERE product_id = ? AND lot_number = ?`, pid, ln).Scan(&lotID); err != nil {
			return nil, &PostError{fmt.Sprintf("lot « %s » inconnu pour « %s »", ln, pname)}
		}
	}
	if err := enterPreparation(tx, o, userID); err != nil {
		return nil, err
	}
	return addPickRaw(tx, o, line, lotID, qty, strings.TrimSpace(barcode), userID, true)
}

// ReadyOptions drive « marquer prête ».
type ReadyOptions struct {
	AcceptPartial bool // shortfalls go to backorder instead of refusing
	AutoPick      bool // prepare what remains FEFO (no scan workflow)
}

// MarkReady: validated|preparing → ready. Shortfalls (prepared < validated)
// move to backorder when accepted.
func MarkReady(tx *sql.Tx, orderID, userID string, opt ReadyOptions) error {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	if o.status != OrderValidated && o.status != OrderPreparing {
		return &PostError{fmt.Sprintf("la commande %s est « %s » : elle ne peut pas être marquée prête",
			o.number, OrderStatusLabels[o.status])}
	}
	lines, err := loadOrderLines(tx, orderID)
	if err != nil {
		return err
	}
	// Services are never picked: they are « prepared » as validated.
	for i := range lines {
		l := &lines[i]
		if l.isService && l.prepared != l.validated+l.free {
			l.prepared = l.validated + l.free
			tx.Exec(`UPDATE customer_order_lines SET qty_prepared_milli=? WHERE id=?`, l.prepared, l.id)
		}
	}
	if opt.AutoPick {
		for i := range lines {
			l := &lines[i]
			need := l.validated + l.free - l.prepared
			if need <= 0 || l.isService {
				continue
			}
			var otherPicks sql.NullInt64
			tx.QueryRow(`SELECT SUM(k.qty_milli) FROM customer_order_picks k
				JOIN customer_orders oo ON oo.id = k.order_id
				JOIN customer_order_lines ll ON ll.id = k.line_id
				WHERE ll.product_id = ? AND oo.warehouse_id = ? AND oo.id <> ? AND oo.delivery_note_id IS NULL
				  AND oo.status IN ('validated','preparing','ready')`, l.productID, o.warehouseID, orderID).Scan(&otherPicks)
			can := StockQty(tx, l.productID, o.warehouseID) - otherPicks.Int64
			if allowNegativeStock(tx) {
				can = need
			}
			take := min(need, max(0, can))
			if take <= 0 {
				continue
			}
			if _, err := addPickRaw(tx, o, l.id, "", take, "", userID, false); err != nil {
				return err
			}
			l.prepared += take
		}
	}
	var shortages []string
	anyPrepared := false
	for _, l := range lines {
		if l.prepared > 0 {
			anyPrepared = true
		}
		if t := l.validated + l.free; l.prepared < t {
			shortages = append(shortages, fmt.Sprintf("« %s » : %s préparé(s) sur %s",
				l.productName, fmtQtyMilli(l.prepared), fmtQtyMilli(t)))
		}
	}
	if !anyPrepared {
		return &PostError{"rien n'a été préparé sur cette commande"}
	}
	if len(shortages) > 0 && !opt.AcceptPartial {
		return &PostError{"préparation incomplète : " + strings.Join(shortages, " ; ") +
			" — confirmez pour mettre le manquant en reliquat"}
	}
	partial := false
	for _, l := range lines {
		paid := min(l.prepared, l.validated)
		short := l.validated - paid
		free := min(l.free, l.prepared-paid)
		if short > 0 {
			partial = true
			if l.priceSource != PriceManual && l.priceSource != PriceWeb {
				ent, _, err := FreeGoodsFor(tx, o.partnerID, l.productID, paid, o.orderDate, ChannelOf(o.source))
				if err != nil {
					return err
				}
				free = min(free, ent)
			}
		}
		if short == 0 && free == l.free {
			continue
		}
		if _, err := tx.Exec(`UPDATE customer_order_lines SET qty_validated_milli=?, qty_backorder_milli=qty_backorder_milli+?,
			qty_free_milli=?, updated_at=? WHERE id=?`, paid, short, free, NowISO(), l.id); err != nil {
			return err
		}
	}
	if partial {
		tx.Exec(`UPDATE customer_orders SET is_partial=1 WHERE id=?`, orderID)
	}
	note := "commande prête"
	if len(shortages) > 0 {
		note += " — manquant en reliquat : " + strings.Join(shortages, " ; ")
	}
	if err := setOrderStatus(tx, o, OrderReady, "ready", userID, note); err != nil {
		return err
	}
	return RecalcOrder(tx, orderID)
}

// ---- Documents generated by the order ------------------------------------------------

type genLine struct {
	productID, lotID, description string
	qty, price, discount, vat     int64
}

func insertDocument(tx *sql.Tx, docType, docDate, partnerID, warehouseID, refID, method, dueDate,
	notes, internal, userID string, amount int64, lines []genLine) (string, error) {
	id, now := NewID(), NowISO()
	if _, err := tx.Exec(`INSERT INTO documents (id, doc_type, status, doc_date, partner_id, warehouse_id,
			ref_document_id, amount, payment_method, notes, due_date, internal_notes, created_by, created_at, updated_at)
		VALUES (?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, docType, docDate, nullIfEmpty(partnerID), nullIfEmpty(warehouseID), nullIfEmpty(refID), amount,
		nullIfEmpty(method), nullIfEmpty(notes), nullIfEmpty(dueDate), nullIfEmpty(internal),
		nullIfEmpty(userID), now, now); err != nil {
		return "", err
	}
	for i, l := range lines {
		ht, vat, ttc := LineTotals(l.price, l.qty, l.discount, l.vat)
		if _, err := tx.Exec(`INSERT INTO document_lines (id, document_id, position, product_id, lot_id,
				description, qty_milli, unit_price, discount_pct, vat_rate, line_ht, line_vat, line_ttc,
				pack_factor_milli, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1000, ?)`,
			NewID(), id, i, nullIfEmpty(l.productID), nullIfEmpty(l.lotID), l.description, l.qty,
			l.price, l.discount, l.vat, ht, vat, ttc, now); err != nil {
			return "", err
		}
	}
	return id, nil
}

func today() string { return time.Now().Format("2006-01-02") }

// GenerateDeliveryNote creates and posts the BL of a ready order from its
// prepared quantities: one line per lot picked, the paid part at the order
// price, the free units (UG) on their own line at 100 % discount. Shipping
// fee and global discount become lines without product. Returns the BL id
// and number (the existing BL when already generated).
func GenerateDeliveryNote(tx *sql.Tx, orderID, userID string) (string, string, error) {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return "", "", err
	}
	if o.deliveryNoteID.Valid {
		var num sql.NullString
		tx.QueryRow(`SELECT number FROM documents WHERE id = ?`, o.deliveryNoteID.String).Scan(&num)
		return o.deliveryNoteID.String, num.String, nil
	}
	if o.status != OrderReady {
		return "", "", &PostError{fmt.Sprintf("la commande %s est « %s » : le BL se génère quand elle est prête",
			o.number, OrderStatusLabels[o.status])}
	}
	lines, err := loadOrderLines(tx, orderID)
	if err != nil {
		return "", "", err
	}
	var gl []genLine
	for _, l := range lines {
		if l.prepared <= 0 {
			continue
		}
		if l.isService {
			if l.validated > 0 {
				gl = append(gl, genLine{l.productID, "", l.description, l.validated, l.unitPrice, l.discount, l.vat})
			}
			continue
		}
		rows, err := tx.Query(`SELECT COALESCE(k.lot_id,''), SUM(k.qty_milli) FROM customer_order_picks k
			LEFT JOIN lots lt ON lt.id = k.lot_id
			WHERE k.line_id = ? GROUP BY k.lot_id
			ORDER BY (lt.expiry_date IS NULL OR lt.expiry_date=''), lt.expiry_date, k.lot_id`, l.id)
		if err != nil {
			return "", "", err
		}
		type grp struct {
			lot string
			qty int64
		}
		var groups []grp
		for rows.Next() {
			var g grp
			rows.Scan(&g.lot, &g.qty)
			groups = append(groups, g)
		}
		rows.Close()
		paidLeft, freeLeft := l.validated, l.free
		for _, g := range groups {
			p := min(g.qty, paidLeft)
			if p > 0 {
				gl = append(gl, genLine{l.productID, g.lot, l.description, p, l.unitPrice, l.discount, l.vat})
				paidLeft -= p
			}
			f := min(g.qty-p, freeLeft)
			if f > 0 {
				gl = append(gl, genLine{l.productID, g.lot, l.description + " (UG)", f, l.unitPrice, 10000, l.vat})
				freeLeft -= f
			}
		}
	}
	if len(gl) == 0 {
		return "", "", &PostError{"rien n'a été préparé : aucun BL à générer"}
	}
	if o.shippingFee > 0 {
		gl = append(gl, genLine{"", "", "Frais de livraison", 1000, o.shippingFee, 0, 0})
	}
	if o.extraDiscount > 0 {
		d := "Remise"
		if o.promoCode != "" {
			d += " (code " + o.promoCode + ")"
		}
		gl = append(gl, genLine{"", "", d, 1000, -o.extraDiscount, 0, 0})
	}
	notes := "Commande " + o.number
	var ext sql.NullString
	tx.QueryRow(`SELECT external_number FROM customer_orders WHERE id=?`, orderID).Scan(&ext)
	if ext.String != "" {
		notes += " (web " + ext.String + ")"
	}
	docID, err := insertDocument(tx, DeliveryNote, today(), o.partnerID, o.warehouseID, "", "", "",
		notes, "", userID, 0, gl)
	if err != nil {
		return "", "", err
	}
	number, err := PostTx(tx, docID, userID)
	if err != nil {
		return "", "", err
	}
	if _, err := tx.Exec(`UPDATE customer_orders SET delivery_note_id=?, updated_at=? WHERE id=?`,
		docID, NowISO(), orderID); err != nil {
		return "", "", err
	}
	if _, err := tx.Exec(`UPDATE customer_order_lines SET qty_delivered_milli = qty_prepared_milli WHERE order_id=?`,
		orderID); err != nil {
		return "", "", err
	}
	o.deliveryNoteID = sql.NullString{String: docID, Valid: true}
	return docID, number, OrderEvent(tx, orderID, "delivery_note", "", "", userID, "BL "+number+" validé")
}

// ShipOrder: ready → shipping (the BL is generated when missing).
func ShipOrder(tx *sql.Tx, orderID, userID, note string) error {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	if o.status != OrderReady {
		return &PostError{fmt.Sprintf("la commande %s est « %s » : seule une commande prête part en livraison",
			o.number, OrderStatusLabels[o.status])}
	}
	if _, _, err := GenerateDeliveryNote(tx, orderID, userID); err != nil {
		return err
	}
	if note == "" {
		note = "partie en livraison"
	}
	return setOrderStatus(tx, o, OrderShipping, "ship", userID, note)
}

// DeliverOptions: cash on delivery collected outside a delivery run.
type DeliverOptions struct {
	CODAmount int64
	Method    string
	Receiver  string
	Note      string
}

var paymentInMethods = map[string]bool{"cash": true, "cib": true, "edahabia": true, "cheque": true, "transfer": true}

// CreatePaymentIn writes and posts a PAYMENT_IN (encaissement) for a customer.
func CreatePaymentIn(tx *sql.Tx, partnerID string, amount int64, method, notes, userID string) (string, string, error) {
	if amount <= 0 {
		return "", "", &PostError{"le montant encaissé doit être positif"}
	}
	if method == "" {
		method = "cash"
	}
	if !paymentInMethods[method] {
		return "", "", &PostError{"mode d'encaissement invalide (cash, cib, edahabia, cheque, transfer)"}
	}
	id, err := insertDocument(tx, PaymentIn, today(), partnerID, "", "", method, "", notes, "", userID, amount, nil)
	if err != nil {
		return "", "", err
	}
	number, err := PostTx(tx, id, userID)
	return id, number, err
}

// DeliverOrder: shipping|ready → delivered, with the optional COD payment.
func DeliverOrder(tx *sql.Tx, orderID, userID string, opt DeliverOptions) (string, error) {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return "", err
	}
	if o.status != OrderShipping && o.status != OrderReady {
		return "", &PostError{fmt.Sprintf("la commande %s est « %s » : elle ne peut pas être livrée",
			o.number, OrderStatusLabels[o.status])}
	}
	if _, _, err := GenerateDeliveryNote(tx, orderID, userID); err != nil {
		return "", err
	}
	payNumber := ""
	if opt.CODAmount > 0 {
		if o.paymentID.Valid {
			return "", &PostError{"un encaissement est déjà enregistré pour cette commande"}
		}
		pid, num, err := CreatePaymentIn(tx, o.partnerID, opt.CODAmount, opt.Method,
			"Encaissement à la livraison — commande "+o.number, userID)
		if err != nil {
			return "", err
		}
		payNumber = num
		if _, err := tx.Exec(`UPDATE customer_orders SET payment_id=? WHERE id=?`, pid, orderID); err != nil {
			return "", err
		}
	}
	now := NowISO()
	if _, err := tx.Exec(`UPDATE customer_orders SET delivered_at=?, updated_at=? WHERE id=?`, now, now, orderID); err != nil {
		return "", err
	}
	note := "livrée"
	if strings.TrimSpace(opt.Receiver) != "" {
		note += " — reçue par " + strings.TrimSpace(opt.Receiver)
	}
	if payNumber != "" {
		note += fmt.Sprintf(" — encaissé %s DA (%s)", fmtDA(opt.CODAmount), payNumber)
	}
	if strings.TrimSpace(opt.Note) != "" {
		note += " — " + strings.TrimSpace(opt.Note)
	}
	return payNumber, setOrderStatus(tx, o, OrderDelivered, "deliver", userID, note)
}

// PaymentTermsDays: the customer's own terms, else `default_payment_days` (30).
func PaymentTermsDays(q Querier, partnerID string) int64 {
	var d sql.NullInt64
	q.QueryRow(`SELECT payment_terms_days FROM partners WHERE id = ?`, partnerID).Scan(&d)
	if d.Valid && d.Int64 >= 0 {
		return d.Int64
	}
	return SettingInt(q, "default_payment_days", 30)
}

// InvoiceOrder creates and posts the SALE_INVOICE of a delivered order from
// its BL (ref_document_id = BL: the stock is not moved twice). On account by
// default; a COD already collected forces « credit » so the payment settles it.
func InvoiceOrder(tx *sql.Tx, orderID, userID, method string) (string, string, error) {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return "", "", err
	}
	if o.status != OrderDelivered {
		return "", "", &PostError{fmt.Sprintf("la commande %s est « %s » : seule une commande livrée se facture",
			o.number, OrderStatusLabels[o.status])}
	}
	if !o.deliveryNoteID.Valid {
		return "", "", &PostError{"la commande n'a pas de BL"}
	}
	if method == "" || o.paymentID.Valid {
		if method != "" && method != "credit" {
			return "", "", &PostError{"un encaissement à la livraison est déjà enregistré : la facture est émise sur le compte (credit)"}
		}
		method = "credit"
	}
	if method != "credit" && !paymentInMethods[method] {
		return "", "", &PostError{"mode de paiement invalide"}
	}
	rows, err := tx.Query(`SELECT COALESCE(product_id,''), COALESCE(lot_id,''), description, qty_milli, unit_price,
			discount_pct, vat_rate
		FROM document_lines WHERE document_id = ? ORDER BY position, created_at`, o.deliveryNoteID.String)
	if err != nil {
		return "", "", err
	}
	var gl []genLine
	for rows.Next() {
		var l genLine
		if err := rows.Scan(&l.productID, &l.lotID, &l.description, &l.qty, &l.price, &l.discount, &l.vat); err != nil {
			rows.Close()
			return "", "", err
		}
		gl = append(gl, l)
	}
	rows.Close()
	var blNumber string
	tx.QueryRow(`SELECT COALESCE(number,'') FROM documents WHERE id=?`, o.deliveryNoteID.String).Scan(&blNumber)
	due := ""
	if method == "credit" {
		due = time.Now().AddDate(0, 0, int(PaymentTermsDays(tx, o.partnerID))).Format("2006-01-02")
	}
	id, err := insertDocument(tx, SaleInvoice, today(), o.partnerID, o.warehouseID, o.deliveryNoteID.String,
		method, due, "Commande "+o.number+" — BL "+blNumber, "", userID, 0, gl)
	if err != nil {
		return "", "", err
	}
	number, err := PostTx(tx, id, userID)
	if err != nil {
		return "", "", err
	}
	if _, err := tx.Exec(`UPDATE customer_orders SET invoice_id=?, updated_at=? WHERE id=?`, id, NowISO(), orderID); err != nil {
		return "", "", err
	}
	return id, number, setOrderStatus(tx, o, OrderInvoiced, "invoice", userID, "facture "+number)
}

// CancelOrder cancels an order not yet delivered. A posted BL is reversed
// (contrepassation) only when mayVoid (right void_document): the goods come
// back into stock, nothing else posted stays.
func CancelOrder(tx *sql.Tx, orderID, userID, reason string, mayVoid bool) error {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return &PostError{"le motif d'annulation est obligatoire"}
	}
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	if !canTransition(o.status, OrderCancelled) {
		return &PostError{fmt.Sprintf("la commande %s est « %s » : elle ne peut plus être annulée (faites un avoir)",
			o.number, OrderStatusLabels[o.status])}
	}
	note := "annulée : " + reason
	if o.deliveryNoteID.Valid {
		var status, number string
		tx.QueryRow(`SELECT status, COALESCE(number,'') FROM documents WHERE id=?`, o.deliveryNoteID.String).
			Scan(&status, &number)
		if status == "posted" {
			if !mayVoid {
				return &PostError{fmt.Sprintf("le BL %s est validé : l'annuler (retour en stock) exige le droit « annuler un document validé »", number)}
			}
			if err := VoidTx(tx, o.deliveryNoteID.String, userID, "annulation de la commande "+o.number+" — "+reason); err != nil {
				return err
			}
			note += " — BL " + number + " contrepassé"
		}
	}
	if _, err := tx.Exec(`UPDATE run_stops SET status='failed', failure_reason='commande annulée', updated_at=?
		WHERE order_id=? AND status='pending'`, NowISO(), orderID); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE customer_order_lines SET qty_backorder_milli=0 WHERE order_id=?`, orderID); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE customer_orders SET cancel_reason=?, has_backorder=0, updated_at=? WHERE id=?`,
		reason, NowISO(), orderID); err != nil {
		return err
	}
	auditTx(tx, userID, "order.cancel", "customer_order", orderID, o.number+" — "+reason)
	return setOrderStatus(tx, o, OrderCancelled, "cancel", userID, note)
}

// ---- Backorders -----------------------------------------------------------------------

// ReleaseBackorder brings backorder quantities back into the same order (still
// validated or preparing) as far as the stock now allows.
func ReleaseBackorder(tx *sql.Tx, orderID string, lineIDs []string, userID string) (int64, error) {
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return 0, err
	}
	if o.status != OrderValidated && o.status != OrderPreparing {
		return 0, &PostError{"le reliquat ne revient dans la commande que si elle est validée ou en préparation — sinon créez une nouvelle commande de reliquat"}
	}
	want := map[string]bool{}
	for _, id := range lineIDs {
		want[id] = true
	}
	lines, err := loadOrderLines(tx, orderID)
	if err != nil {
		return 0, err
	}
	var released int64
	parts := []string{}
	for _, l := range lines {
		if l.backorder <= 0 || (len(want) > 0 && !want[l.id]) {
			continue
		}
		a := AvailableQty(tx, l.productID, o.warehouseID, orderID)
		if allowNegativeStock(tx) {
			a = l.backorder
		}
		take := min(l.backorder, max(0, a))
		if take <= 0 {
			continue
		}
		v := l.validated + take
		free := l.free
		if l.priceSource != PriceManual && l.priceSource != PriceWeb {
			ent, _, err := FreeGoodsFor(tx, o.partnerID, l.productID, v, o.orderDate, ChannelOf(o.source))
			if err != nil {
				return 0, err
			}
			free = min(ent, max(0, a-take)+l.free)
		}
		if _, err := tx.Exec(`UPDATE customer_order_lines SET qty_validated_milli=?, qty_backorder_milli=?,
			qty_free_milli=?, updated_at=? WHERE id=?`, v, l.backorder-take, free, NowISO(), l.id); err != nil {
			return 0, err
		}
		released += take
		parts = append(parts, fmt.Sprintf("%s ×%s", l.productName, fmtQtyMilli(take)))
	}
	if released == 0 {
		return 0, &PostError{"aucun reliquat n'est disponible en stock pour l'instant"}
	}
	if err := RecalcOrder(tx, orderID); err != nil {
		return 0, err
	}
	return released, OrderEvent(tx, orderID, "release_backorder", "", "", userID,
		"reliquat remis dans la commande : "+strings.Join(parts, ", "))
}

// BackorderToNewOrder gathers backorder lines of a customer (all, or the
// given line ids) into a new order. The original lines stop waiting.
func BackorderToNewOrder(tx *sql.Tx, partnerID string, lineIDs []string, userID string) (string, string, error) {
	where := `o.partner_id = ? AND o.status <> 'cancelled' AND l.qty_backorder_milli > 0`
	args := []any{partnerID}
	if len(lineIDs) > 0 {
		where += ` AND l.id IN (` + strings.TrimSuffix(strings.Repeat("?,", len(lineIDs)), ",") + `)`
		for _, id := range lineIDs {
			args = append(args, id)
		}
	}
	rows, err := tx.Query(`SELECT l.id, l.order_id, o.number, l.product_id, l.qty_backorder_milli, l.unit_price,
			l.discount_pct, o.warehouse_id, COALESCE(o.rep_user_id,''), o.payment_mode
		FROM customer_order_lines l JOIN customer_orders o ON o.id = l.order_id
		WHERE `+where+` ORDER BY o.order_date, o.number, l.position`, args...)
	if err != nil {
		return "", "", err
	}
	type bl struct {
		lineID, orderID, number, productID string
		qty, price, disc                   int64
		wh, rep, mode                      string
	}
	var items []bl
	for rows.Next() {
		var b bl
		if err := rows.Scan(&b.lineID, &b.orderID, &b.number, &b.productID, &b.qty, &b.price, &b.disc,
			&b.wh, &b.rep, &b.mode); err != nil {
			rows.Close()
			return "", "", err
		}
		items = append(items, b)
	}
	rows.Close()
	if len(items) == 0 {
		return "", "", &PostError{"aucun reliquat en attente pour ce client"}
	}
	in := OrderInput{PartnerID: partnerID, Source: "manual", WarehouseID: items[0].wh, PaymentMode: items[0].mode,
		InternalNotes: "Reliquat de " + items[0].number}
	if items[0].rep != "" {
		r := items[0].rep
		in.RepUserID = &r
	}
	origins := map[string]string{}
	for _, b := range items {
		price, disc := b.price, b.disc
		in.Lines = append(in.Lines, OrderLineInput{ProductID: b.productID, QtyMilli: b.qty, UnitPrice: &price,
			DiscountPct: &disc, PriceSource: PriceBackorder, BackorderFromLineID: b.lineID})
		origins[b.orderID] = b.number
	}
	if len(origins) > 1 {
		nums := []string{}
		for _, n := range origins {
			nums = append(nums, n)
		}
		in.InternalNotes = "Reliquats de " + strings.Join(nums, ", ")
	}
	id, number, err := CreateOrder(tx, in, userID)
	if err != nil {
		return "", "", err
	}
	for _, b := range items {
		if _, err := tx.Exec(`UPDATE customer_order_lines SET qty_backorder_milli=0, updated_at=? WHERE id=?`,
			NowISO(), b.lineID); err != nil {
			return "", "", err
		}
	}
	for oid := range origins {
		if err := RecalcOrder(tx, oid); err != nil {
			return "", "", err
		}
		if err := OrderEvent(tx, oid, "backorder_moved", "", "", userID, "reliquat repris dans la commande "+number); err != nil {
			return "", "", err
		}
	}
	return id, number, nil
}
