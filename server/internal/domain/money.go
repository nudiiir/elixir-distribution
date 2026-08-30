package domain

// All money is int64 centimes; quantities are int64 milli-units;
// percentages are int64 percent*100 (19% == 1900).

// roundDiv divides with half-up rounding, handling negative numerators.
func roundDiv(n, d int64) int64 {
	if d == 0 {
		return 0
	}
	if n >= 0 {
		return (n + d/2) / d
	}
	return -((-n + d/2) / d)
}

// LineTotals computes HT/VAT/TTC for one line.
func LineTotals(unitPrice, qtyMilli, discountPct, vatRate int64) (ht, vat, ttc int64) {
	gross := roundDiv(unitPrice*qtyMilli, 1000)
	ht = roundDiv(gross*(10000-discountPct), 10000)
	vat = roundDiv(ht*vatRate, 10000)
	return ht, vat, ht + vat
}

// LineDiscount returns the discount amount for one line (gross HT - net HT).
func LineDiscount(unitPrice, qtyMilli, discountPct int64) int64 {
	gross := roundDiv(unitPrice*qtyMilli, 1000)
	net := roundDiv(gross*(10000-discountPct), 10000)
	return gross - net
}

// Timbre computes the droit de timbre for cash-paid invoices:
// 1% of TTC, minimum 5 DA, maximum 2500 DA. Exempt for electronic payments
// (art. 258 quinquies) — the caller decides applicability by payment method.
// TODO: verify against the LF 2025 progressive scale before go-live.
func Timbre(totalTTC int64) int64 {
	t := roundDiv(totalTTC, 100) // 1%
	if t < 500 {
		t = 500 // 5 DA
	}
	if t > 250000 {
		t = 250000 // 2500 DA
	}
	return t
}

// TimbreApplies reports whether stamp duty is due for the given document type
// and payment method.
func TimbreApplies(docType, paymentMethod string) bool {
	if docType != SaleInvoice && docType != SaleTicket {
		return false
	}
	return paymentMethod == "cash"
}
