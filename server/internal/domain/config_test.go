package domain_test

import (
	"testing"

	"elixir/server/internal/domain"
)

func (f *fx) set(k, v string) {
	f.exec(`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, '2026-01-01')
		ON CONFLICT (key) DO UPDATE SET value = excluded.value`, k, v)
}

func (f *fx) number(id string) string {
	var n string
	f.db.QueryRow(`SELECT COALESCE(number,'') FROM documents WHERE id = ?`, id).Scan(&n)
	return n
}

func (f *fx) sale(prod, partner, method string, units, price int64) string {
	f.t.Helper()
	id := f.doc(dc{typ: domain.SaleTicket, partner: partner, method: method},
		ln{prod: prod, qty: units * 1000, price: price})
	f.post(id)
	return id
}

func TestNumberingDefaultUnchanged(t *testing.T) {
	f := newFx(t)
	f.product("P", false)
	f.partner("S", "supplier")
	f.receive("P", 10, 100)
	id := f.sale("P", "", "cash", 1, 200)
	if got := f.number(id); got != "TK-2026-000001" {
		t.Fatalf("default number = %q, want TK-2026-000001", got)
	}
}

func TestNumberingPrefixYearDigitsReset(t *testing.T) {
	f := newFx(t)
	f.product("P", false)
	f.partner("S", "supplier")
	f.receive("P", 10, 100)

	f.set("number_SALE_TICKET_prefix", "CAI")
	f.set("number_SALE_TICKET_digits", "4")
	if got := f.number(f.sale("P", "", "cash", 1, 200)); got != "CAI-2026-0001" {
		t.Fatalf("got %q, want CAI-2026-0001", got)
	}

	// Without the year the series is continuous (reset forced off).
	f.set("number_SALE_TICKET_year", "0")
	f.set("number_SALE_TICKET_reset", "1")
	if got := f.number(f.sale("P", "", "cash", 1, 200)); got != "CAI-0001" {
		t.Fatalf("got %q, want CAI-0001", got)
	}
	if got := f.number(f.sale("P", "", "cash", 1, 200)); got != "CAI-0002" {
		t.Fatalf("got %q, want CAI-0002", got)
	}

	// No prefix, no year.
	f.set("number_SALE_TICKET_prefix", "")
	if got := f.number(f.sale("P", "", "cash", 1, 200)); got != "0003" {
		t.Fatalf("got %q, want 0003", got)
	}

	// Continuous with the year: the counter does not restart.
	fm := domain.NumberFormat{Prefix: "FV", IncludeYear: true, Digits: 6}
	if fm.Format(2027, 12) != "FV-2027-000012" {
		t.Fatal(fm.Format(2027, 12))
	}
	if msg := (domain.NumberFormat{Prefix: "FV", Digits: 6, ResetYearly: true}).Validate(); msg == "" {
		t.Fatal("reset without the year must be refused")
	}
	if msg := (domain.NumberFormat{Prefix: "F V", Digits: 6}).Validate(); msg == "" {
		t.Fatal("a prefix with a space must be refused")
	}
	if msg := (domain.NumberFormat{Prefix: "FV", Digits: 3}).Validate(); msg == "" {
		t.Fatal("3 digits must be refused")
	}
}

func TestNumberingNeverLowerThanIssued(t *testing.T) {
	f := newFx(t)
	f.product("P", false)
	f.partner("S", "supplier")
	f.receive("P", 10, 100)
	f.sale("P", "", "cash", 1, 200) // TK-2026-000001
	f.sale("P", "", "cash", 1, 200) // TK-2026-000002

	if err := domain.SetNextNumber(f.db, domain.SaleTicket, 2026, 2); err == nil {
		t.Fatal("lowering to an issued number must be refused")
	}
	if err := domain.SetNextNumber(f.db, domain.SaleTicket, 2026, 50); err != nil {
		t.Fatal(err)
	}
	if got := f.number(f.sale("P", "", "cash", 1, 200)); got != "TK-2026-000050" {
		t.Fatalf("got %q, want TK-2026-000050", got)
	}
	// Back down below 50 is now refused, 51 accepted.
	if err := domain.SetNextNumber(f.db, domain.SaleTicket, 2026, 10); err == nil {
		t.Fatal("must refuse 10 after 50 was issued")
	}
	if err := domain.SetNextNumber(f.db, domain.SaleTicket, 2026, 51); err != nil {
		t.Fatal(err)
	}
	last, _ := domain.LastIssued(f.db, domain.SaleTicket, domain.LoadNumberFormat(f.db, domain.SaleTicket), 2026)
	eq(t, "last issued", last, 50)

	// A raw counter pushed back by hand never yields a duplicate number.
	f.exec(`UPDATE sequences SET next_number = 1 WHERE doc_type = 'SALE_TICKET'`)
	if got := f.number(f.sale("P", "", "cash", 1, 200)); got != "TK-2026-000003" {
		t.Fatalf("got %q, want the first free number TK-2026-000003", got)
	}
}

func TestTimbreSwitchedOff(t *testing.T) {
	f := newFx(t)
	f.product("P", false)
	f.partner("S", "supplier")
	f.receive("P", 10, 100)

	var timbre, ttc int64
	id := f.sale("P", "", "cash", 1, 100000) // 1 000 DA cash → 10 DA timbre
	f.db.QueryRow(`SELECT timbre, total_ttc FROM documents WHERE id=?`, id).Scan(&timbre, &ttc)
	eq(t, "timbre on", timbre, 1000)

	f.set("timbre_enabled", "0")
	id = f.sale("P", "", "cash", 1, 100000)
	f.db.QueryRow(`SELECT timbre, total_ttc FROM documents WHERE id=?`, id).Scan(&timbre, &ttc)
	eq(t, "timbre off", timbre, 0)
	eq(t, "ttc off", ttc, 100000)

	// Mixed payment: the cash row is the goods only.
	id = f.doc(dc{typ: domain.SaleTicket}, ln{prod: "P", qty: 1000, price: 100000})
	f.exec(`INSERT INTO document_payments (id, document_id, method, amount, created_at) VALUES
		('PA', ?, 'cash', 60000, '2026-03-10'), ('PB', ?, 'cib', 40000, '2026-03-10')`, id, id)
	f.post(id)
	f.db.QueryRow(`SELECT timbre FROM documents WHERE id=?`, id).Scan(&timbre)
	eq(t, "split timbre off", timbre, 0)

	// Cached flag used by previews.
	domain.RefreshSettingsCache(f.db)
	if domain.TimbreApplies(domain.SaleTicket, "cash") {
		t.Fatal("TimbreApplies must honour timbre_enabled=0")
	}
	domain.SetTimbreEnabled(true)
	if !domain.TimbreApplies(domain.SaleTicket, "cash") {
		t.Fatal("TimbreApplies must be back on")
	}
}

func TestLoyaltyEarnVoidRedeem(t *testing.T) {
	f := newFx(t)
	f.product("P", false)
	f.partner("S", "supplier")
	f.partner("C", "customer")
	f.receive("P", 100, 100)
	f.set("timbre_enabled", "0")

	// Disabled: nothing earned.
	f.sale("P", "C", "cib", 1, 50000)
	eq(t, "disabled", domain.LoyaltyBalance(f.db, "C"), 0)

	f.set("loyalty_enabled", "1")
	f.set("loyalty_earn_per", "10000")   // 1 point / 100 DA
	f.set("loyalty_point_value", "100")  // 1 DA / point
	f.set("loyalty_min_redeem", "5")
	s1 := f.sale("P", "C", "cib", 1, 125000) // 1 250 DA → 12 points
	eq(t, "earned", domain.LoyaltyBalance(f.db, "C"), 12)
	f.sale("P", "", "cash", 1, 125000) // no customer: nothing
	eq(t, "no customer", domain.LoyaltyBalance(f.db, "C"), 12)

	// Redeem: below the minimum, above the balance, then OK.
	if _, err := domain.RedeemLoyalty(f.db, "C", 3, "", ""); err == nil {
		t.Fatal("below minimum must be refused")
	}
	if _, err := domain.RedeemLoyalty(f.db, "C", 13, "", ""); err == nil {
		t.Fatal("above balance must be refused")
	}
	red, err := domain.RedeemLoyalty(f.db, "C", 10, "", "")
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "value", red.Value, 1000)
	eq(t, "after redeem", red.Balance, 2)

	// The sale was abandoned: points come back, once.
	bal, err := domain.CancelRedemption(f.db, red.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "after cancel", bal, 12)
	if _, err := domain.CancelRedemption(f.db, red.ID, ""); err == nil {
		t.Fatal("double cancel must be refused")
	}

	// Redeem on a sale, then void the sale: earned taken back, used given back.
	s2 := f.doc(dc{typ: domain.SaleTicket, partner: "C", method: "cib"}, ln{prod: "P", qty: 1000, price: 30000})
	if _, err := domain.RedeemLoyalty(f.db, "C", 6, s2, ""); err != nil {
		t.Fatal(err)
	}
	f.post(s2)                                         // +3 points
	eq(t, "before void", domain.LoyaltyBalance(f.db, "C"), 12-6+3)
	if err := domain.Void(f.db, s2, "", "erreur"); err != nil {
		t.Fatal(err)
	}
	eq(t, "after void", domain.LoyaltyBalance(f.db, "C"), 12)
	if err := domain.Void(f.db, s1, "", "erreur"); err != nil {
		t.Fatal(err)
	}
	eq(t, "after void s1", domain.LoyaltyBalance(f.db, "C"), 0)

	// Switched off: redeem refused.
	f.set("loyalty_enabled", "0")
	if _, err := domain.RedeemLoyalty(f.db, "C", 5, "", ""); err == nil {
		t.Fatal("redeem with the programme off must be refused")
	}
}
