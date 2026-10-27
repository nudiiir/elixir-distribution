package domain

import (
	"database/sql"
	"fmt"
	"strings"
)

// Delivery runs: a run (delivery_runs) carries stops
// (run_stops), one per ready order. On departure, each order goes « en
// livraison » (delivery note generated if needed); each stop is settled (delivered, partial,
// failed); at closing, the collected money becomes a PAYMENT_IN receipt
// per customer and the expected / collected difference is computed.

func loadRunStatus(tx Queryer, runID string) (string, error) {
	var st string
	err := tx.QueryRow(`SELECT status FROM delivery_runs WHERE id = ?`, runID).Scan(&st)
	if err == sql.ErrNoRows {
		return "", &NotFoundError{"tournée introuvable"}
	}
	return st, err
}

// AddRunStops puts ready orders on a planned (or departed) run. On a departed
// run the orders leave at once (shipping).
func AddRunStops(tx *sql.Tx, runID string, orderIDs []string, userID string) error {
	st, err := loadRunStatus(tx, runID)
	if err != nil {
		return err
	}
	if st != "planned" && st != "out" {
		return &PostError{"la tournée est clôturée : impossible d'y ajouter une commande"}
	}
	var seq int64
	tx.QueryRow(`SELECT COALESCE(MAX(sequence),0) FROM run_stops WHERE run_id = ?`, runID).Scan(&seq)
	for _, oid := range orderIDs {
		o, err := loadOrderHead(tx, oid)
		if err != nil {
			return err
		}
		if o.status != OrderReady {
			return &PostError{fmt.Sprintf("la commande %s est « %s » : seule une commande prête part en tournée",
				o.number, OrderStatusLabels[o.status])}
		}
		var other string
		tx.QueryRow(`SELECT r.run_date FROM run_stops s JOIN delivery_runs r ON r.id = s.run_id
			WHERE s.order_id = ? AND s.status = 'pending' AND r.status IN ('planned','out') AND r.id <> ?`,
			oid, runID).Scan(&other)
		if other != "" {
			return &PostError{fmt.Sprintf("la commande %s est déjà sur la tournée du %s", o.number, other)}
		}
		var dup int
		tx.QueryRow(`SELECT COUNT(*) FROM run_stops WHERE run_id=? AND order_id=?`, runID, oid).Scan(&dup)
		if dup > 0 {
			if _, err := tx.Exec(`UPDATE run_stops SET status='pending', failure_reason='', updated_at=?
				WHERE run_id=? AND order_id=?`, NowISO(), runID, oid); err != nil {
				return err
			}
		} else {
			seq++
			var cod int64
			if o.paymentMode == "cod" {
				var paid sql.NullInt64
				if o.paymentID.Valid {
					tx.QueryRow(`SELECT amount FROM documents WHERE id = ?`, o.paymentID.String).Scan(&paid)
				}
				cod = max(0, o.totalTTC-paid.Int64)
			}
			now := NowISO()
			if _, err := tx.Exec(`INSERT INTO run_stops (id, run_id, order_id, sequence, status, cod_expected, created_at, updated_at)
				VALUES (?, ?, ?, ?, 'pending', ?, ?, ?)`, NewID(), runID, oid, seq, cod, now, now); err != nil {
				return err
			}
		}
		if err := OrderEvent(tx, oid, "run_add", "", "", userID, "ajoutée à une tournée de livraison"); err != nil {
			return err
		}
		if st == "out" {
			if err := ShipOrder(tx, oid, userID, "partie en tournée"); err != nil {
				return err
			}
		}
	}
	return nil
}

// RemoveRunStop takes a pending stop off a run (a departed order comes back
// to « ready »).
func RemoveRunStop(tx *sql.Tx, runID, stopID, userID string) error {
	st, err := loadRunStatus(tx, runID)
	if err != nil {
		return err
	}
	var orderID, status string
	if err := tx.QueryRow(`SELECT order_id, status FROM run_stops WHERE id=? AND run_id=?`, stopID, runID).
		Scan(&orderID, &status); err != nil {
		return &NotFoundError{"arrêt introuvable"}
	}
	if status != "pending" || (st != "planned" && st != "out") {
		return &PostError{"seul un arrêt en attente d'une tournée ouverte peut être retiré"}
	}
	if _, err := tx.Exec(`DELETE FROM run_stops WHERE id=?`, stopID); err != nil {
		return err
	}
	o, err := loadOrderHead(tx, orderID)
	if err != nil {
		return err
	}
	if o.status == OrderShipping {
		return setOrderStatus(tx, o, OrderReady, "run_remove", userID, "retirée de la tournée")
	}
	return OrderEvent(tx, orderID, "run_remove", "", "", userID, "retirée de la tournée")
}

// StartRun: planned → out; every pending order leaves (shipping, BL generated).
func StartRun(tx *sql.Tx, runID, userID string) error {
	st, err := loadRunStatus(tx, runID)
	if err != nil {
		return err
	}
	if st != "planned" {
		return &PostError{"seule une tournée planifiée peut partir"}
	}
	rows, err := tx.Query(`SELECT order_id FROM run_stops WHERE run_id=? AND status='pending' ORDER BY sequence`, runID)
	if err != nil {
		return err
	}
	var ids []string
	for rows.Next() {
		var id string
		rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()
	if len(ids) == 0 {
		return &PostError{"la tournée n'a aucune commande"}
	}
	for _, id := range ids {
		o, err := loadOrderHead(tx, id)
		if err != nil {
			return err
		}
		if o.status == OrderShipping {
			continue
		}
		if err := ShipOrder(tx, id, userID, "partie en tournée"); err != nil {
			return &PostError{fmt.Sprintf("commande %s : %s", o.number, err.Error())}
		}
	}
	now := NowISO()
	_, err = tx.Exec(`UPDATE delivery_runs SET status='out', departed_at=?, updated_at=? WHERE id=?`, now, now, runID)
	return err
}

// StopResult is what the driver reports for one stop.
type StopResult struct {
	Status        string // delivered | partial | failed
	FailureReason string
	CODCollected  int64
	Method        string
	Receiver      string
	Note          string
}

// RecordStop records a stop: delivered/partial → order delivered (the money
// is booked at closing); failed → order back to « ready ».
func RecordStop(tx *sql.Tx, runID, stopID, userID string, in StopResult) error {
	st, err := loadRunStatus(tx, runID)
	if err != nil {
		return err
	}
	if st != "out" {
		return &PostError{"la tournée n'est pas en cours : démarrez-la avant de saisir les livraisons"}
	}
	var orderID, status string
	if err := tx.QueryRow(`SELECT order_id, status FROM run_stops WHERE id=? AND run_id=?`, stopID, runID).
		Scan(&orderID, &status); err != nil {
		return &NotFoundError{"arrêt introuvable"}
	}
	if status != "pending" {
		return &PostError{"cet arrêt est déjà soldé"}
	}
	if in.Method == "" {
		in.Method = "cash"
	}
	if !paymentInMethods[in.Method] {
		return &PostError{"mode d'encaissement invalide (cash, cib, edahabia, cheque, transfer)"}
	}
	if in.CODCollected < 0 {
		return &PostError{"le montant encaissé ne peut pas être négatif"}
	}
	now := NowISO()
	switch in.Status {
	case "delivered", "partial":
		note := in.Note
		if in.Status == "partial" {
			note = strings.TrimSpace("livraison partielle — " + in.Note)
		}
		if _, err := DeliverOrder(tx, orderID, userID, DeliverOptions{Receiver: in.Receiver, Note: note}); err != nil {
			return err
		}
		if in.Status == "partial" {
			tx.Exec(`UPDATE customer_orders SET is_partial=1 WHERE id=?`, orderID)
		}
		_, err = tx.Exec(`UPDATE run_stops SET status=?, cod_collected=?, payment_method=?, receiver_name=?,
			delivered_at=?, note=?, updated_at=? WHERE id=?`, in.Status, in.CODCollected, in.Method,
			strings.TrimSpace(in.Receiver), now, in.Note, now, stopID)
		return err
	case "failed":
		reason := strings.TrimSpace(in.FailureReason)
		if reason == "" {
			return &PostError{"indiquez le motif de l'échec de livraison"}
		}
		o, err := loadOrderHead(tx, orderID)
		if err != nil {
			return err
		}
		if o.status == OrderShipping {
			if err := setOrderStatus(tx, o, OrderReady, "delivery_failed", userID, "échec de livraison : "+reason); err != nil {
				return err
			}
		}
		_, err = tx.Exec(`UPDATE run_stops SET status='failed', failure_reason=?, note=?, updated_at=? WHERE id=?`,
			reason, in.Note, now, stopID)
		return err
	}
	return &PostError{"résultat invalide (delivered, partial ou failed)"}
}

// RunReconciliation is the cash summary of a closed run.
type RunReconciliation struct {
	Expected   int64           `json:"cash_expected"`
	Collected  int64           `json:"cash_collected"`
	Difference int64           `json:"cash_difference"`
	Counted    *int64          `json:"counted_cash"`
	Payments   []RunPaymentRow `json:"payments"`
}

// RunPaymentRow is one PAYMENT_IN written at closing.
type RunPaymentRow struct {
	StopID     string `json:"stop_id"`
	OrderID    string `json:"order_id"`
	PartnerID  string `json:"partner_id"`
	Amount     int64  `json:"amount"`
	Method     string `json:"payment_method"`
	DocumentID string `json:"document_id"`
	Number     string `json:"number"`
}

// CloseRun closes a departed run: every stop must be settled; collected money
// becomes one PAYMENT_IN per stop; expected (COD of delivered stops) vs
// collected gives the difference.
func CloseRun(tx *sql.Tx, runID, userID string, counted *int64, note string) (*RunReconciliation, error) {
	st, err := loadRunStatus(tx, runID)
	if err != nil {
		return nil, err
	}
	if st != "out" {
		return nil, &PostError{"seule une tournée en cours peut être clôturée"}
	}
	var pending int
	tx.QueryRow(`SELECT COUNT(*) FROM run_stops WHERE run_id=? AND status='pending'`, runID).Scan(&pending)
	if pending > 0 {
		return nil, &PostError{fmt.Sprintf("%d arrêt(s) non soldé(s) : indiquez livré ou échec avant de clôturer", pending)}
	}
	rows, err := tx.Query(`SELECT s.id, s.order_id, o.partner_id, o.number, s.status, s.cod_expected, s.cod_collected,
			s.payment_method, s.payment_id IS NOT NULL
		FROM run_stops s JOIN customer_orders o ON o.id = s.order_id
		WHERE s.run_id = ? ORDER BY s.sequence`, runID)
	if err != nil {
		return nil, err
	}
	type stop struct {
		id, orderID, partnerID, number, status string
		expected, collected                    int64
		method                                 string
		paid                                   bool
	}
	var stops []stop
	for rows.Next() {
		var s stop
		if err := rows.Scan(&s.id, &s.orderID, &s.partnerID, &s.number, &s.status, &s.expected, &s.collected,
			&s.method, &s.paid); err != nil {
			rows.Close()
			return nil, err
		}
		stops = append(stops, s)
	}
	rows.Close()
	rec := &RunReconciliation{Counted: counted, Payments: []RunPaymentRow{}}
	for _, s := range stops {
		if s.status == "delivered" || s.status == "partial" {
			rec.Expected += s.expected
		}
		rec.Collected += s.collected
		if s.collected <= 0 || s.paid {
			continue
		}
		docID, number, err := CreatePaymentIn(tx, s.partnerID, s.collected, s.method,
			"Encaissement tournée — commande "+s.number, userID)
		if err != nil {
			return nil, err
		}
		if _, err := tx.Exec(`UPDATE run_stops SET payment_id=?, updated_at=? WHERE id=?`, docID, NowISO(), s.id); err != nil {
			return nil, err
		}
		tx.Exec(`UPDATE customer_orders SET payment_id=COALESCE(payment_id, ?) WHERE id=?`, docID, s.orderID)
		if err := OrderEvent(tx, s.orderID, "cod_collected", "", "", userID,
			fmt.Sprintf("encaissé %s DA à la livraison (%s)", fmtDA(s.collected), number)); err != nil {
			return nil, err
		}
		rec.Payments = append(rec.Payments, RunPaymentRow{StopID: s.id, OrderID: s.orderID, PartnerID: s.partnerID,
			Amount: s.collected, Method: s.method, DocumentID: docID, Number: number})
	}
	rec.Difference = rec.Collected - rec.Expected
	now := NowISO()
	var countedV any
	if counted != nil {
		countedV = *counted
	}
	notesSet := ""
	args := []any{rec.Expected, rec.Collected, rec.Difference, countedV, now, nullIfEmpty(userID), now}
	if strings.TrimSpace(note) != "" {
		notesSet = ", notes = ?"
		args = append(args, strings.TrimSpace(note))
	}
	args = append(args, runID)
	if _, err := tx.Exec(`UPDATE delivery_runs SET status='closed', cash_expected=?, cash_collected=?,
		cash_difference=?, counted_cash=?, closed_at=?, closed_by=?, updated_at=?`+notesSet+` WHERE id=?`, args...); err != nil {
		return nil, err
	}
	auditTx(tx, userID, "delivery_run.close", "delivery_run", runID,
		fmt.Sprintf("clôture : attendu %s DA, collecté %s DA, écart %s DA", fmtDA(rec.Expected),
			fmtDA(rec.Collected), fmtDA(rec.Difference)))
	return rec, nil
}
