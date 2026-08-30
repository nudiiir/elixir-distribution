# P0 Schema — documents, ledgers, catalog

The whole system follows three rules agreed at design time:

1. **Everything is a document with lines.** One `documents` + `document_lines` pair covers every business paper (ticket, facture, BL, avoir, bon de commande, réception, ajustement, transfert, règlement). A document is editable in `draft`, immutable once `posted`. Corrections to a posted document are made with a new document (avoir), never by editing.
2. **Ledgers, not mutable balances.** Posting a document writes immutable rows to `stock_ledger` and/or `partner_ledger`. `stock_levels` is a cache maintained in the same transaction and always recomputable from the ledger. Client credit = SUM of `partner_ledger`.
3. **Catalog ≠ stock.** `products` is identity; quantities live per warehouse (and optionally per lot) in the ledger/levels.

## Technical conventions (non-negotiable)

- **IDs**: UUIDv7 as TEXT — sortable by creation time, offline-safe.
- **Money**: INTEGER **centimes** (DZD × 100). Never REAL.
- **Quantities**: INTEGER **milli-units** (`qty_milli`, qty × 1000) so weighable products (1.475 kg) stay exact.
- **Percentages** (VAT, discount): INTEGER percent × 100 (19% → `1900`).
- **Timestamps**: TEXT ISO-8601 UTC; business dates: TEXT `YYYY-MM-DD` local.
- SQLite pragmas: `journal_mode=WAL`, `foreign_keys=ON`, `busy_timeout=5000`, `synchronous=NORMAL`. One server process owns the file.

## Tables (15)

| Table | Role |
|---|---|
| `settings` | key/value: company identity (name, NIF, NIS, RC, AI, address), preferences |
| `users` | login, role (`admin`/`manager`/`cashier`) |
| `product_categories` | tree (parent_id) |
| `products` | barcode, name FR/AR, unit, weighable flag, VAT rate, purchase price (last), retail/wholesale prices (TTC), min stock, lot-tracking flag |
| `lots` | lot number + expiry per product (only when `track_lots`) |
| `warehouses` | shop floor / dépôt / … |
| `partners` | unified clients + suppliers (`kind`: customer/supplier/both) with fiscal IDs (NIF/NIS/RC/AI) and credit limit |
| `sequences` | gapless numbering: (doc_type, year) → next_number, consumed inside the posting transaction |
| `caisse_sessions` | open/close, opening cash, expected vs counted |
| `documents` | header for every doc type (see below) |
| `document_lines` | product, qty_milli, unit_price HT, discount, VAT, computed line totals, unit_cost |
| `stock_ledger` | immutable ±qty movements with unit_cost, per warehouse/lot, linked to document+line |
| `stock_levels` | cache: (product, warehouse) → qty_milli, avg_cost (CUMP) |
| `partner_ledger` | immutable signed amounts per partner (convention: **positive = partner owes us**) |
| `audit_log` | who did what |

## Document types and what posting does

Number format: `{PREFIX}-{YYYY}-{NNNNNN}` assigned **at posting** from `sequences` (gapless, per type, per year — décret 05-468).

| doc_type | Prefix | Stock effect | Partner-ledger effect |
|---|---|---|---|
| `QUOTE` (devis) | DV | — | — |
| `SALE_TICKET` (ticket caisse) | TK | −qty @ avg_cost | +TTC only if `payment_method='credit'` |
| `SALE_INVOICE` (facture) | FV | −qty @ avg_cost (unless it references BLs that already moved stock) | +TTC if credit |
| `DELIVERY_NOTE` (BL) | BL | −qty @ avg_cost | — |
| `SALE_CREDIT_NOTE` (avoir) | AV | +qty | −TTC |
| `PURCHASE_ORDER` (bon de commande) | BC | — | — |
| `PURCHASE_RECEIPT` (réception) | BR | +qty @ line unit_cost → **updates CUMP** | — |
| `PURCHASE_INVOICE` (facture fournisseur) | FA | +qty @ cost if no receipt referenced | −TTC (we owe supplier) |
| `PURCHASE_CREDIT_NOTE` | AF | −qty | +TTC |
| `STOCK_ADJUSTMENT` | AJ | ±qty as entered | — |
| `STOCK_TRANSFER` | TR | −qty from `warehouse_id`, +qty to `dest_warehouse_id` | — |
| `INVENTORY_COUNT` | IN | delta = counted − current at posting | — |
| `PAYMENT_IN` (encaissement) | RG | — | −amount (customer paid) |
| `PAYMENT_OUT` (règlement fournisseur) | RF | — | +amount |

**CUMP (weighted average cost)** on inbound stock: `new_avg = (old_qty×old_avg + in_qty×unit_cost) / (old_qty + in_qty)`. Outbound movements record the current avg_cost, which is what makes margin reports honest.

**Line math** (integer, half-up rounding):
`line_ht = unit_price × qty_milli × (10000 − discount_pct) / 10000 / 1000` · `line_vat = line_ht × vat_rate / 10000` · `line_ttc = line_ht + line_vat`. Retail prices are stored TTC; the client derives HT when building lines.

**Timbre** (stamp duty, cash-paid invoices only): currently 1% of TTC, min 5 DA, max 2 500 DA, **exempt when payment is electronic** (cib/edahabia/transfer). ⚠️ Verify against LF 2025 progressive scale before invoicing goes live — the rate lives in one function (`domain.Timbre`).

## Posting engine

One code path (`internal/domain/posting.go`) does all of the above: validate draft → begin transaction → assign number → write stock_ledger + update stock_levels → write partner_ledger → set `status='posted'`, `posted_at`, `posted_by` → commit. **No other code writes ledger rows.** Modules (P1 delivery COD ledger included) reuse it.

Deferred from P0 posting (tables ready, logic later): INVENTORY_COUNT delta computation, payment *allocation* against specific invoices (currently balance-level), multi-payment on one document.
