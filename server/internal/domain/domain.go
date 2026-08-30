// Package domain holds the business rules: document types, line math, timbre,
// and the posting engine. No other package writes ledger rows.
package domain

import (
	"time"

	"github.com/google/uuid"
)

func NewID() string {
	id, err := uuid.NewV7()
	if err != nil {
		return uuid.NewString()
	}
	return id.String()
}

func NowISO() string {
	return time.Now().UTC().Format(time.RFC3339)
}

// Document types.
const (
	Quote              = "QUOTE"
	SaleTicket         = "SALE_TICKET"
	SaleInvoice        = "SALE_INVOICE"
	SaleCreditNote     = "SALE_CREDIT_NOTE"
	DeliveryNote       = "DELIVERY_NOTE"
	PurchaseOrder      = "PURCHASE_ORDER"
	PurchaseReceipt    = "PURCHASE_RECEIPT"
	PurchaseInvoice    = "PURCHASE_INVOICE"
	PurchaseCreditNote = "PURCHASE_CREDIT_NOTE"
	StockAdjustment    = "STOCK_ADJUSTMENT"
	StockTransfer      = "STOCK_TRANSFER"
	InventoryCount     = "INVENTORY_COUNT"
	PaymentIn          = "PAYMENT_IN"
	PaymentOut         = "PAYMENT_OUT"
)

// NumberPrefix maps a document type to its legal numbering prefix.
var NumberPrefix = map[string]string{
	Quote:              "DV",
	SaleTicket:         "TK",
	SaleInvoice:        "FV",
	SaleCreditNote:     "AV",
	DeliveryNote:       "BL",
	PurchaseOrder:      "BC",
	PurchaseReceipt:    "BR",
	PurchaseInvoice:    "FA",
	PurchaseCreditNote: "AF",
	StockAdjustment:    "AJ",
	StockTransfer:      "TR",
	InventoryCount:     "IN",
	PaymentIn:          "RG",
	PaymentOut:         "RF",
}

// stockSign: effect of a posted document on the stock in documents.warehouse_id.
// +1 inbound, -1 outbound, 0 none. STOCK_TRANSFER additionally writes +qty into
// dest_warehouse_id; STOCK_ADJUSTMENT lines carry their own sign in qty_milli.
var stockSign = map[string]int64{
	SaleTicket:         -1,
	SaleInvoice:        -1,
	DeliveryNote:       -1,
	SaleCreditNote:     +1,
	PurchaseReceipt:    +1,
	PurchaseInvoice:    +1,
	PurchaseCreditNote: -1,
	StockAdjustment:    +1, // lines are signed
	StockTransfer:      -1, // and +1 into dest
}

// IsInbound reports whether the document brings stock in at the line's declared
// cost (and must therefore update the weighted-average cost).
func isCostBearing(docType string) bool {
	return docType == PurchaseReceipt || docType == PurchaseInvoice
}
