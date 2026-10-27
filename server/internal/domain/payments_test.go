package domain_test

import (
	"errors"
	"strings"
	"testing"

	"elixir/server/internal/domain"
)

// pay adds a document_payments row to a draft.
func (f *fx) pay(docID, method string, amount int64) {
	f.t.Helper()
	f.n++
	f.exec(`INSERT INTO document_payments (id, document_id, method, amount, created_at)
		VALUES (?, ?, ?, ?, '2026-03-10T08:00:00Z')`, docID+"-P"+method+string(rune('a'+f.n)), docID, method, amount)
}

func (f *fx) docTotals(id string) (ttc, timbre int64) {
	f.db.QueryRow(`SELECT total_ttc, timbre FROM documents WHERE id=?`, id).Scan(&ttc, &timbre)
	return
}

func (f *fx) balance(partner string) (bal int64) {
	f.db.QueryRow(`SELECT COALESCE(SUM(amount),0) FROM partner_ledger WHERE partner_id=?`, partner).Scan(&bal)
	return
}

func TestSplitCashCardTimbreOnCashPartOnly(t *testing.T) {
	f := newFx(t)
	f.partner("S", "supplier")
	f.product("P", false)
	f.receive("P", 10, 50000)

	// 1 000 DA ticket: 600 DA by CIB, 400 DA in cash. The stamp duty is only due
	// on the 400 DA in cash (5 DA floor), not on 1 000 DA (10 DA).
	_, timbreFull := domain.SplitTimbre(100000, 0)
	eq(t, "timbre on a full-cash 1000 DA ticket", timbreFull, 1000)

	tk := f.doc(dc{typ: domain.SaleTicket}, ln{prod: "P", qty: 1000, price: 100000})
	f.pay(tk, "cib", 60000)
	f.pay(tk, "cash", 40500)
	f.post(tk)
	ttc, timbre := f.docTotals(tk)
	eq(t, "timbre on the 400 DA cash part", timbre, 500)
	eq(t, "total = goods + timbre on cash part", ttc, 100500)
	q, _ := f.level("P")
	eq(t, "stock after split sale", q, 9000)
	f.mustVerify()

	// Card + Edahabia only: no cash, no stamp duty.
	tk2 := f.doc(dc{typ: domain.SaleTicket}, ln{prod: "P", qty: 1000, price: 100000})
	f.pay(tk2, "cib", 60000)
	f.pay(tk2, "edahabia", 40000)
	f.post(tk2)
	_, timbre = f.docTotals(tk2)
	eq(t, "timbre with no cash part", timbre, 0)
}

func TestSplitMustCoverTotalExactly(t *testing.T) {
	f := newFx(t)
	f.partner("S", "supplier")
	f.product("P", false)
	f.receive("P", 10, 50000)

	// Cash row forgets the stamp duty → refused.
	tk := f.doc(dc{typ: domain.SaleTicket}, ln{prod: "P", qty: 1000, price: 100000})
	f.pay(tk, "cib", 60000)
	f.pay(tk, "cash", 40000)
	err := f.postErr(tk)
	var pe *domain.PostError
	if !errors.As(err, &pe) || !strings.Contains(pe.Msg, "ne correspond pas") {
		t.Fatalf("expected a French mismatch refusal, got %v", err)
	}
	// Non-cash methods above the total → refused.
	tk2 := f.doc(dc{typ: domain.SaleTicket}, ln{prod: "P", qty: 1000, price: 100000})
	f.pay(tk2, "cib", 120000)
	if err := f.postErr(tk2); !errors.As(err, &pe) || !strings.Contains(pe.Msg, "dépassent") {
		t.Fatalf("expected an over-payment refusal, got %v", err)
	}
	q, _ := f.level("P")
	eq(t, "refused tickets move no stock", q, 10000)
}

func TestSplitCashCreditGoesToLedgerAndVoids(t *testing.T) {
	f := newFx(t)
	f.partner("S", "supplier")
	f.partner("C", "customer")
	f.product("P", false)
	f.receive("P", 10, 50000)

	// Credit without a customer → refused.
	anon := f.doc(dc{typ: domain.SaleTicket}, ln{prod: "P", qty: 1000, price: 100000})
	f.pay(anon, "credit", 30000)
	f.pay(anon, "cash", 70700)
	if err := f.postErr(anon); err == nil || !strings.Contains(err.Error(), "client") {
		t.Fatalf("expected customer-required refusal, got %v", err)
	}

	// 1 000 DA: 300 DA on credit, 700 DA in cash (+7 DA stamp duty).
	tk := f.doc(dc{typ: domain.SaleTicket, partner: "C"}, ln{prod: "P", qty: 1000, price: 100000})
	f.pay(tk, "credit", 30000)
	f.pay(tk, "cash", 70700)
	f.post(tk)
	ttc, timbre := f.docTotals(tk)
	eq(t, "timbre on the 700 DA cash part", timbre, 700)
	eq(t, "total", ttc, 100700)
	eq(t, "only the credit part goes to the customer account", f.balance("C"), 30000)

	if err := domain.Void(f.db, tk, "", "erreur de caisse"); err != nil {
		t.Fatal(err)
	}
	eq(t, "balance after void", f.balance("C"), 0)
	q, _ := f.level("P")
	eq(t, "stock after void", q, 10000)
	f.mustVerify()
}

func TestReturnOnSplitCreditSaleReducesDebt(t *testing.T) {
	f := newFx(t)
	f.partner("S", "supplier")
	f.partner("C", "customer")
	f.product("P", false)
	f.receive("P", 10, 50000)

	tk := f.doc(dc{typ: domain.SaleTicket, partner: "C"}, ln{prod: "P", qty: 1000, price: 20000})
	f.pay(tk, "credit", 20000)
	f.post(tk)
	eq(t, "debt after credit split", f.balance("C"), 20000)
	av := f.doc(dc{typ: domain.SaleCreditNote, partner: "C", method: "cash", ref: tk},
		ln{prod: "P", qty: 1000, price: 20000})
	f.post(av)
	eq(t, "return on a credit split reduces the debt", f.balance("C"), 0)
}
