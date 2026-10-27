package domain

import "sync/atomic"

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

// Timbre computes the stamp duty (droit de timbre de quittance) on a cash-paid sale, using
// the progressive scale of the Code du timbre (art. 100-I as reworked by the
// finance law that introduced art. 258 quinquies): nothing up to 300 DA, then
// per started bracket of 100 DA — 1 DA up to 30 000 DA, 1.5 DA from 30 000 to
// 100 000 DA, 2 DA beyond — rounded up to a whole DA, floor 5 DA, ceiling
// 10 000 DA. Exempt for electronic payments (the caller decides by method).
// TODO(fiscal): confirm the ceiling and the 5 DA floor against the current LF.
func Timbre(totalTTC int64) int64 {
	if totalTTC <= 30000 { // 300 DA
		return 0
	}
	rate := int64(100) // centimes per started 100 DA tranche
	switch {
	case totalTTC > 10000000: // 100 000 DA
		rate = 200
	case totalTTC > 3000000: // 30 000 DA
		rate = 150
	}
	t := ((totalTTC + 9999) / 10000) * rate
	t = ((t + 99) / 100) * 100 // whole DA, rounded up
	if t < 500 {
		t = 500
	}
	if t > 1000000 {
		t = 1000000
	}
	return t
}

// timbreOff mirrors the shop setting `timbre_enabled` = '0' for the callers
// that compute previews without a transaction at hand (draft totals, POS
// checks). The posting engine reads the setting itself, in its transaction.
var timbreOff atomic.Bool

// SetTimbreEnabled updates the cached `timbre_enabled` setting.
func SetTimbreEnabled(on bool) { timbreOff.Store(!on) }

// TimbreEnabled reports the cached `timbre_enabled` setting (default on).
func TimbreEnabled() bool { return !timbreOff.Load() }

// TimbreSettingOn reads `timbre_enabled` from the database (default on).
func TimbreSettingOn(q Querier) bool { return SettingBool(q, "timbre_enabled", true) }

// RefreshSettingsCache reloads the cached settings (call after a settings save).
func RefreshSettingsCache(q Querier) { SetTimbreEnabled(TimbreSettingOn(q)) }

// timbreDue is the legal rule alone: cash-paid sale tickets and invoices.
func timbreDue(docType, paymentMethod string) bool {
	if docType != SaleInvoice && docType != SaleTicket {
		return false
	}
	return paymentMethod == "cash"
}

// TimbreApplies reports whether stamp duty is due for the given document type
// and payment method — never when the shop switched the timbre off.
func TimbreApplies(docType, paymentMethod string) bool {
	return TimbreEnabled() && timbreDue(docType, paymentMethod)
}
