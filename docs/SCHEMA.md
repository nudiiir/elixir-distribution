# P0 Schema — documents, ledgers, catalog

The whole system follows three rules agreed at design time:

1. **Everything is a document with lines.** One `documents` + `document_lines` pair covers every business paper (till receipt, invoice, delivery note, credit note, purchase order, goods receipt, adjustment, transfer, payment). A document is editable in `draft`, immutable once `posted`. Corrections to a posted document are made with a new document (credit note), never by editing.
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
| `warehouses` | shop floor / depot / … |
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

Number format: `{PREFIX}-{YYYY}-{NNNNNN}` assigned **at posting** from `sequences` (gapless, per type, per year — Decree 05-468).

| doc_type | Prefix | Stock effect | Partner-ledger effect |
|---|---|---|---|
| `QUOTE` (quote) | DV | — | — |
| `SALE_TICKET` (till receipt) | TK | −qty @ avg_cost | +TTC only if `payment_method='credit'` |
| `SALE_INVOICE` (invoice) | FV | −qty @ avg_cost (unless it references BLs that already moved stock) | +TTC if credit |
| `DELIVERY_NOTE` (delivery note) | BL | −qty @ avg_cost | — |
| `SALE_CREDIT_NOTE` (credit note) | AV | +qty | −TTC |
| `PURCHASE_ORDER` (purchase order) | BC | — | — |
| `PURCHASE_RECEIPT` (goods receipt) | BR | +qty @ line unit_cost → **updates CUMP** | — |
| `PURCHASE_INVOICE` (supplier invoice) | FA | +qty @ cost if no receipt referenced | −TTC (we owe supplier) |
| `PURCHASE_CREDIT_NOTE` | AF | −qty | +TTC |
| `STOCK_ADJUSTMENT` | AJ | ±qty as entered | — |
| `STOCK_TRANSFER` | TR | −qty from `warehouse_id`, +qty to `dest_warehouse_id` | — |
| `INVENTORY_COUNT` | IN | delta = counted − current at posting | — |
| `PAYMENT_IN` (cash collection) | RG | — | −amount (customer paid) |
| `PAYMENT_OUT` (supplier payment) | RF | — | +amount |

**CUMP (weighted average cost)** on inbound stock: `new_avg = (old_qty×old_avg + in_qty×unit_cost) / (old_qty + in_qty)`. Outbound movements record the current avg_cost, which is what makes margin reports honest.

**Line math** (integer, half-up rounding):
`line_ht = unit_price × qty_milli × (10000 − discount_pct) / 10000 / 1000` · `line_vat = line_ht × vat_rate / 10000` · `line_ttc = line_ht + line_vat`. Retail prices are stored TTC; the client derives HT when building lines.

**Stamp duty** (timbre, cash-paid invoices only): currently 1% of TTC, min 5 DA, max 2 500 DA, **exempt when payment is electronic** (cib/edahabia/transfer). ⚠️ Verify against LF 2025 progressive scale before invoicing goes live — the rate lives in one function (`domain.Timbre`).

## Posting engine

One code path (`internal/domain/posting.go`) does all of the above: validate draft → begin transaction → assign number → write stock_ledger + update stock_levels → write partner_ledger → set `status='posted'`, `posted_at`, `posted_by` → commit. **No other code writes ledger rows.** Modules (P1 delivery COD ledger included) reuse it.

Deferred from P0 posting (tables ready, logic later): INVENTORY_COUNT delta computation, payment *allocation* against specific invoices (currently balance-level), multi-payment on one document.

`domain.PostTx` / `domain.VoidTx` are the same engine inside a transaction owned by the caller: customer orders post their BL, invoice and payments atomically with the order's status change.

## Distribution (migrations 0016–0017)

Customer orders are **not documents** (the `documents.doc_type` CHECK is unchanged): they live in their own tables and never touch a ledger themselves. What they generate — `DELIVERY_NOTE`, `SALE_INVOICE` (ref = the delivery note, so stock is not moved twice), `PAYMENT_IN` — goes through the posting engine. API contract: `docs/API_DISTRIBUTION.md`.

| Table | Role |
|---|---|
| `customer_orders` | order header: number `CC-YYYY-NNNNNN` (sequence key `CUSTOMER_ORDER`), partner, source (manual/phone/whatsapp/rep/web/portal), `external_ref` (storefront id, unique per source), status new→validated→preparing→ready→shipping→delivered→invoiced / cancelled, flags `is_partial`, `has_backorder`, `credit_override`, `web_status_dirty`, warehouse, rep, route, priority, `payment_mode` (account/cod), delivery address/wilaya/commune, totals, shipping fee / global discount, links `delivery_note_id`, `invoice_id`, `payment_id` |
| `customer_order_lines` | product, `qty_ordered/validated/prepared/delivered/backorder/free_milli`, unit_price HT, discount, VAT, line totals, `price_source`, promo rule, substitution and backorder links |
| `customer_order_events` | status history and actions (from, to, user, note, at) |
| `customer_order_picks` | preparation: line → lot, qty (paid + free), barcode, who |
| `customer_prices` | special price HT per partner **or** customer group × product, min qty tier, date range |
| `promo_rules` | free goods (« N + M », free units) or quantity discount; scope product/category/brand/all; audience all/group/partner; channel all/desk/web; dates |
| `product_quotas` | max qty per customer per day/week/month (partner NULL = every customer) |
| `vehicles`, `delivery_routes` | fleet; route templates (wilayas, communes, weekdays, default driver/vehicle) |
| `delivery_runs`, `run_stops` | a day's run (planned/out/closed/cancelled, cash expected/collected/difference) and its stops (pending/delivered/partial/failed, COD expected/collected, payment document) |
| `partner_contacts`, `tags`, `partner_tags`, `partner_files` | CRM: contacts (one primary), coloured tags, licence/trade-register scans (BLOB ≤ 5 MB) |
| `crm_activities` | calls, visits (GPS), notes, WhatsApp/SMS/e-mail, meetings — by user, optional order/document |
| `crm_tasks` | to-dos (call/visit/collect_payment/follow_up/other), assignee, due, status open/done/cancelled, source manual/auto_* with idempotency `auto_key` |
| `crm_segments` | saved segment rules (JSON); built-in segments live in code |
| `rep_targets` | monthly targets per sales rep (sales, orders, visits, new customers, collections) |
| `message_templates`, `message_log` | WhatsApp/SMS/e-mail templates with `{{placeholders}}` (French defaults seeded) and what was prepared/sent |

New `partners` columns: `client_type`, `crm_status`, `rep_user_id`, `route_id`, `wilaya`, `commune`, `latitude`, `longitude`, `opening_hours`, `license_no`, `whatsapp`, `website`, `source`, `payment_terms_days`.

View `v_customer_order_lines` feeds the analytics source `customer_orders`. Role « Gérant » (manager) receives the new permission keys (`orders.*`, `deliveries.*`, `crm.*`, `pricing.*`).

**Availability** (« disponible », available) = `stock_levels.qty_milli` − Σ (validated + free) of other orders `validated|preparing|ready` without a BL. Order validation caps lines to it (remainder → backorder), enforces quotas, and checks the account (balance + open orders + this order vs credit limit, overdue invoices, blocked status) — overridable with `orders.override_credit`.
