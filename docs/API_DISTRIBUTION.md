# Distribution API — customer orders, pricing, deliveries, CRM, messages

Server contract of the **Distribution** module (wholesalers and distributors that deliver to shops and professionals).
Migrations `0016_distribution.sql` and `0017_crm.sql`. Everything lives under `/api/v1`, authenticated
(`Authorization: Bearer <token>`), JSON UTF-8. Code: `server/internal/api/dist_*.go`,
`server/internal/domain/{orders,orders_flow,pricing,deliveries,ledger}.go`.

The customer portal (customer log-in) is **out of scope**.

---

## 0. Conventions

| Topic | Rule |
|---|---|
| Identifiers | UUIDv7 as a string (`"0192…"`). Built-in segment ids are `"builtin:<key>"`. |
| Amounts | **integers in centimes** (DA × 100). Order-line `unit_price` = **excl. VAT (HT)**. Product prices (`price_retail`, `price_wholesale`) = incl. VAT (TTC). Customer special prices = **HT** (`price_ht`). |
| Quantities | **integers in thousandths** (`*_milli`, 1 unit = 1000). |
| Percentages | integers ×100 (`discount_pct` 750 = 7.5 %). Exception: `credit_usage_pct` and `achievement_pct` = whole percent (85 = 85 %). |
| Business dates | `"YYYY-MM-DD"` (store local time). Timestamps: ISO-8601 UTC (`"2026-10-09T08:15:00Z"`). |
| Nullable fields | marked `?` in the tables (JSON `null`). |
| Unknown bodies | JSON bodies are decoded **strictly** (unknown key → 400), except `POST /orders/import-web` (lenient). |
| Optional body | Actions marked "optional body" accept an empty body. |
| Lists | Response `{"items": [...]}` (+ the fields indicated). |

### Errors

| HTTP | Body | When |
|---|---|---|
| 400 | `{"error": "...", "field"?: "nom_du_champ"}` | invalid input (message in French) |
| 401 | `{"error": "authentification requise"}` | token missing / expired |
| 403 | `{"error": "accès refusé"}` | missing permission |
| 403 | `{"error": "...", "needs_approval": true, "action": "<droit>", "amount": <int>}` | right that can be unlocked with the **manager's code**: call `POST /auth/approve {pin, action, amount}` then **resend the same request** with the header `X-Approval: <approval_token>` |
| 403 | `{"error": "ce client n'est pas dans votre portefeuille"}` | "own" scope (see §7) |
| 404 | `{"error": "... introuvable"}` | |
| 409 | `{"error": "..."}` | business rule refused (status, stock, quota, lot…) |
| 409 | `{"error": "validation bloquée : ...", "warnings": ["..."], "needs_override": true}` | credit / account check at validation (§1.4) |
| 409 | `{"error": "...", "smtp_not_configured": true}` | e-mail without SMTP configured |
| 422 | `{"error": "...", "wrong_product": true}` | scan of an unknown barcode or of a product not in the order |
| 502 | `{"error": "envoi impossible : ...", "log_id": "..."}` | the SMTP server refused |
| 500 | `{"error": "..."}` | internal error |

---

## 1. Permissions

New keys (same mechanism as the others: `roles.perms_json`, "module.action" grid). The bare module
key (`orders`, `deliveries`, `crm`, `pricing`) is derived from `<module>.view`.

| Key | Label | Grants access to |
|---|---|---|
| `orders.view` | « voir les commandes clients » (view customer orders) | lists, detail, preparation (read), backorders, web sync (read), "to validate" alert |
| `orders.manage` | « gérer les commandes » (manage orders) | create/edit, prepare, scan, delivery note, ship, deliver, invoice, cancel, web import, sync ack, backorders |
| `orders.validate` | « valider » (validate) | `POST /orders/{id}/validate` |
| `orders.override_credit` | « passer outre le contrôle de crédit » (override the credit check) | `override_credit: true` at validation (otherwise 403 `needs_approval`, action `orders.override_credit`) |
| `deliveries.view` | « voir les livraisons » (view deliveries) | vehicles, route templates, delivery rounds |
| `deliveries.manage` | « gérer les livraisons » (manage deliveries) | all delivery writes |
| `crm.view` | « voir la relation client » (view customer relations) | activities, tasks, segments, timeline, KPIs, targets, message templates |
| `crm.edit` | « modifier » (edit) | CRM writes (activities, tasks, contacts, tags, attachments, segments, targets, templates) |
| `crm.all_customers` | « voir tous les clients » (view all customers) | lifts the "own" scope restriction (§7) |
| `pricing.view` | « voir les tarifs » (view pricing) | special prices, promotions, quotas (read) |
| `pricing.edit` | « modifier les tarifs » (edit pricing) | pricing writes |

Default roles: **Administrateur** (administrator) has everything; **Gérant** (manager) receives all these keys (migration 0016); **Caissier** (cashier) none.
Existing rights reused: `price_edit` (price different from the resolved price, free units entered by hand),
`discount` (+ limit `max_discount_pct`) for a discount higher than the resolved discount, `void_document`
(cancel an order whose delivery note is posted). All accept the manager's code (`needs_approval`).

When a table row lists several permissions separated by "|", **any one of them is enough**.

---

## 2. Customer orders

### 2.1 Statuses and transitions

| Status | Label | Allowed transitions (`allowed_transitions`) |
|---|---|---|
| `new` | « Nouvelle » (new) | `validated`, `cancelled` |
| `validated` | « Validée » (validated) | `new` (reopen), `preparing`, `ready`, `cancelled` |
| `preparing` | « En préparation » (being prepared) | `ready`, `cancelled` |
| `ready` | « Prête » (ready) | `preparing` (if no delivery note), `shipping`, `delivered`, `cancelled` |
| `shipping` | « En livraison » (out for delivery) | `ready` (delivery failed), `delivered`, `cancelled` |
| `delivered` | « Livrée » (delivered) | `invoiced` |
| `invoiced` | « Facturée » (invoiced) | — |
| `cancelled` | « Annulée » (cancelled) | — |

Origins (`source`): `manual` (back office), `phone`, `whatsapp`, `rep` (sales rep), `web` (web store, import
only), `portal` (reserved). Priority: `0` normal, `1` high, `2` urgent. `payment_mode`: `account`
(on account, default) or `cod` (cash on delivery; default for web orders).

Numbering: `CC-2026-000001` (optional settings `number_CUSTOMER_ORDER_prefix|year|digits|reset`, as for
documents; never reused).

### 2.2 Line quantities

| Field | Meaning |
|---|---|
| `qty_ordered_milli` | requested by the customer |
| `qty_validated_milli` | committed on this order (paid). After the delivery note: the paid part that actually left |
| `qty_backorder_milli` | backorder waiting for stock (= ordered − validated, + shortages found during preparation) |
| `qty_free_milli` | free units on top |
| `qty_to_prepare_milli` | `validated + free` (to pick) |
| `qty_prepared_milli` | sum of picks (paid + free units) |
| `qty_delivered_milli` | left on the delivery note (paid + free units) |

Amounts: billed quantity = `qty_ordered` while the order is `new`, then `qty_validated`.
Order `total_ttc` = Σ `line_ttc` + `shipping_fee` − `extra_discount`. A replaced line (substitution) or one
moved to a backorder stays in the list with all its quantities at 0 (`qty_ordered_milli` = 0) for history.

**Available** (`available_milli`) = stock of the order's warehouse − what other orders
`validated|preparing|ready` without a delivery note reserve (validated + free units).

### 2.3 `CustomerOrder` object

| Field | Type | Note |
|---|---|---|
| `id`, `number` | string | |
| `order_date` | date | |
| `partner_id`, `partner_name`, `partner_phone`, `partner_client_type` | string | |
| `source` | string | see §2.1 |
| `external_ref`? , `external_number`? | string | web store id / number |
| `status`, `status_label` | string | |
| `is_partial`, `has_backorder`, `credit_override`, `web_status_dirty` | bool | |
| `warehouse_id`, `warehouse_name` | string | |
| `rep_user_id`?, `rep_name` | string | sales rep |
| `route_id`?, `route_name` | string | delivery round (inherited from the customer) |
| `priority` | int | 0/1/2 |
| `payment_mode` | string | `account`/`cod` |
| `requested_date`? | date | requested delivery date |
| `delivery_address`, `wilaya`, `commune`, `contact_name`, `contact_phone` | string | default: customer record |
| `notes` (visible to the customer), `internal_notes` | string | |
| `total_ht`, `total_vat`, `total_discount`, `shipping_fee`, `extra_discount`, `total_ttc` | int (centimes) | `shipping_fee`/`extra_discount` incl. VAT (TTC) |
| `promo_code`, `cancel_reason` | string | |
| `delivery_note_id`?, `delivery_note_number`? | string | generated delivery note |
| `invoice_id`?, `invoice_number`? | string | invoice |
| `payment_id`?, `payment_number`? | string | cash collection on delivery |
| `created_by`?, `created_by_name`, `validated_by`?, `validated_at`?, `delivered_at`?, `created_at`, `updated_at` | | |
| `lines_count` | int | active lines |
| `lines` | `OrderLine[]` | **detail only** |
| `events` | `OrderEvent[]` | **detail only**, chronological order |
| `picks` | `OrderPick[]` | **detail only** |
| `allowed_transitions` | string[] | **detail only** |

`OrderLine`: `id`, `position` (int), `product_id`, `product_name`, `barcode`?, `is_service` (bool), `track_lots` (bool),
`qty_ordered_milli`, `qty_validated_milli`, `qty_prepared_milli`, `qty_delivered_milli`, `qty_backorder_milli`,
`qty_free_milli`, `qty_to_prepare_milli`, `unit_price` (HT), `discount_pct`, `vat_rate`, `line_ht`, `line_vat`,
`line_ttc`, `price_source` (`special_partner|special_group|wholesale|retail|promo|manual|web|backorder`),
`promo_rule_id`?, `substituted_from_line_id`?, `substituted_from_product_id`?, `backorder_from_line_id`?, `notes`,
`stock_milli` (warehouse stock), `available_milli`.

`OrderEvent`: `id`, `action`, `from_status`?, `to_status`?, `user_id`?, `user_name`, `note`, `created_at`.
Actions: `create`, `import`, `update`, `add_line`, `edit_line`, `delete_line`, `substitute`, `validate`, `reopen`,
`start_preparation`, `resume_preparation`, `pick`, `unpick`, `ready`, `delivery_note`, `ship`, `deliver`,
`delivery_failed`, `run_add`, `run_remove`, `cod_collected`, `invoice`, `cancel`, `release_backorder`, `backorder_moved`.

`OrderPick`: `id`, `line_id`, `product_id`, `lot_id`?, `lot_number`?, `expiry_date`?, `qty_milli`, `barcode`,
`picked_by`?, `picked_by_name`, `created_at`.

Actions that return "the order" respond with the **detailed** object (with `lines`, `events`, `picks`,
`allowed_transitions`), sometimes with extra keys at the same level (as indicated).

### 2.4 Routes

| Method | Path | Permission | Body → Response |
|---|---|---|---|
| GET | `/orders` | orders.view | Query filters below → `{items: CustomerOrder[] (no detail), counts: {new:int,…,cancelled:int}, total:int}` |
| GET | `/orders/statuses` | (logged in) | `{items:[{key,label,transitions:[]}], sources:[...]}` |
| POST | `/orders` | orders.manage | `OrderBody` → **201** order |
| GET | `/orders/{id}` | orders.view | → order |
| PUT | `/orders/{id}` | orders.manage | `OrderBody` (if `lines` is present: lines replaced) → order |
| POST | `/orders/{id}/lines` | orders.manage | `{lines: OrderLineBody[]}` → order |
| PATCH | `/orders/{id}/lines/{lineId}` | orders.manage | `{qty_milli?, unit_price?, discount_pct?, qty_free_milli?, notes?}` → order |
| DELETE | `/orders/{id}/lines/{lineId}` | orders.manage | → order |
| POST | `/orders/{id}/lines/{lineId}/substitute` | orders.manage | `{product_id, qty_milli? (default: ordered qty), keep_price?: bool}` → order + `new_line_id` |
| POST | `/orders/{id}/validate` | orders.validate | `ValidateBody` (optional) → order + `validation: {warnings:[], backorders:[{line_id,product_id,product_name,qty_backorder_milli}], partial:bool}` |
| POST | `/orders/{id}/reopen` | orders.manage | — → order (validated → new) |
| POST | `/orders/{id}/start-preparation` | orders.manage | — → order |
| GET | `/orders/{id}/picking-list` | orders.view | → `PickingList` |
| GET | `/orders/picking-list?ids=a,b` | orders.view | → batch preparation `{items: PickingLine[] (per product, with orders[]), order_ids}` |
| POST | `/orders/{id}/picks` | orders.manage | `{line_id, lot_id? , qty_milli}` → `PickResult` |
| DELETE | `/orders/{id}/picks/{pickId}` | orders.manage | → order |
| POST | `/orders/{id}/scan` | orders.manage | `{barcode, qty_milli?, lot_number?}` → `PickResult` |
| POST | `/orders/{id}/ready` | orders.manage | `{accept_partial?: bool, auto_pick?: bool}` (optional) → order |
| POST | `/orders/{id}/delivery-note` | orders.manage | — → order + `document_id`, `document_number` (delivery note) |
| POST | `/orders/{id}/ship` | orders.manage | `{note?}` (optional) → order |
| POST | `/orders/{id}/deliver` | orders.manage | `{cod_amount?, payment_method?, receiver_name?, note?}` (optional) → order + `payment_number` ("" if none) |
| POST | `/orders/{id}/invoice` | orders.manage | `{payment_method?}` (optional) → order + `document_id`, `document_number` (invoice) |
| POST | `/orders/{id}/cancel` | orders.manage (+ `void_document` if the delivery note is posted) | `{reason}` → order |
| POST | `/orders/{id}/release-backorder` | orders.manage | `{line_ids?: []}` (optional) → order |
| GET | `/orders/backorders` | orders.view | query `partner_id`, `product_id`, `rep_user_id`, `fulfillable=1` → `{items: BackorderRow[], total, fulfillable_count}` |
| POST | `/orders/backorders/new-order` | orders.manage | `{partner_id, line_ids?: []}` → **201** new order |
| GET | `/products/{id}/waiting-customers` | orders.view | → `{product_id, product_name, stock_milli, total_backorder_milli, items: BackorderRow[]}` |
| POST | `/orders/import-web` | orders.manage | `WebOrderPayload` → **201** (created) or **200** (already imported) order + `created`, `partner_created`, `warnings` |
| GET | `/orders/web-sync` | orders.view | → `{items: WebSyncItem[]}` |
| POST | `/orders/web-sync/ack` | orders.manage | `{items:[{id, status}]}` → `{cleared:int}` |

**`GET /orders` filters** (all optional): `status` (comma-separated list), `partner_id`, `rep_user_id`,
`wilaya`, `route_id`, `source`, `warehouse_id`, `priority`, `from`, `to` (on `order_date`, inclusive),
`has_backorder=1`, `q` (order number, web number, customer name/phone, contact phone), `sort=priority`
(priority desc then date; default date desc), `limit` (≤ 500, default 100), `offset`.
`counts` = count per status with **the same filters except `status`** (kanban columns); `total` = count
with all filters.

**`OrderBody`** (POST/PUT /orders)

| Field | Type | Default / rule |
|---|---|---|
| `partner_id` | string | **required** on creation; a customer (`customer`/`both`). Can be changed only while `new`. |
| `source` | string | `manual`; `web`/`portal` refused (400) |
| `order_date` | date | today |
| `warehouse_id` | string | default warehouse |
| `rep_user_id`? | string | customer record; `source: "rep"` with no value = the current user; `""` = none |
| `route_id`? | string | customer record |
| `priority` | int | 0 |
| `payment_mode` | string | `account` |
| `requested_date`? | date | |
| `delivery_address`?, `wilaya`?, `commune`?, `contact_name`?, `contact_phone`? | string | absent = customer record (creation) / unchanged (PUT) |
| `notes`, `internal_notes`, `promo_code` | string | |
| `shipping_fee`, `extra_discount` | int (centimes incl. VAT) | 0 |
| `external_ref`?, `external_number`? | string | |
| `lines` | `OrderLineBody[]` | ≥ 1 on creation |

On PUT, non-pointer scalar fields (`priority`, `notes`, `internal_notes`, `shipping_fee`, `extra_discount`,
`promo_code`, `payment_mode`, `order_date`, `warehouse_id`) are **replaced**: send back the current value.
Editable statuses: `new` and `validated`. Replacing the lines of a `validated` order **puts it back to `new`**
(to be validated again). Refused with 409 if picks exist.

**`OrderLineBody`**: `product_id` (string, required), `qty_milli` (int > 0), `unit_price`? (HT; absent = resolved
price), `discount_pct`? (absent = resolved discount), `qty_free_milli`? (absent = free units from promotions), `notes`.
A `unit_price` different from the resolved price requires `price_edit` (otherwise 403 `needs_approval`), the line
switches to `price_source: "manual"` and its resolved discount is ignored. A discount higher than the resolved
discount requires `discount`.

**Editing a line (PATCH)**: statuses `new`/`validated`. On a validated order the new quantity is
re-validated immediately against availability (the rest → backorder). Changing `qty_milli` recomputes the free
units from promotions (unless `qty_free_milli` is provided, which requires `price_edit`).

**Substitution**: statuses `new`/`validated`/`preparing`, line without picks. The old line goes to 0, a
new line points to it (`substituted_from_line_id`, `substituted_from_product_id`), with the resolved price for the
new product (or the old price with `keep_price: true`, right `price_edit`). If the order is validated the
new line is validated against availability.

### 2.5 Validation (credit check, backorder, quotas)

`ValidateBody` (optional):

| Field | Type | Meaning |
|---|---|---|
| `override_credit` | bool | override the account alerts; requires `orders.override_credit` (otherwise 403 `needs_approval`, action `orders.override_credit`) |
| `partial` | bool | default `true`: shortages go to backorder. `false`: refused with 409 « stock insuffisant : … » (insufficient stock) if anything is missing |
| `lines` | `[{line_id, qty_validated_milli}]` | validated quantity forced per line (0 ≤ q ≤ ordered); the rest → backorder |

Order of checks (all or nothing, in one transaction):
1. status `new`; at least one line;
2. availability per product → `qty_validated` = min(ordered, available), rest → `qty_backorder`; services and
   setting `allow_negative_stock = 1`: no limit; nothing available at all → 409;
3. free units recomputed on the validated quantity (capped at the remaining availability);
4. **quotas** (cannot be overridden) → 409 `quota dépassé pour « X » : 3 déjà commandé(s) cette semaine, maximum 5 par client — il reste 2` (quota exceeded: 3 already ordered this week, max 5 per customer, 2 left);
5. **customer account** → alerts: customer `crm_status = blocked`; limit (customer `credit_limit`, otherwise setting
   `default_credit_limit`) exceeded by balance + open orders (`validated…delivered`) + this order;
   unpaid overdue invoices. If there are alerts and no `override_credit` → **409** `{error, warnings, needs_override: true}`.
   With `override_credit`: validated, `credit_override = true`, audit log entry `order.credit_override`.

### 2.6 Preparation

**`PickingList`** (`GET /orders/{id}/picking-list`): `{order: CustomerOrder (no detail), lines: PickingLine[], picks: OrderPick[]}`.
Lines are sorted by **category then product name** (products have no location field).

`PickingLine`: `line_id`, `product_id`, `product_name`, `barcode`?, `category_name`, `brand`, `is_service`, `track_lots`,
`qty_validated_milli`, `qty_free_milli`, `qty_to_prepare_milli`, `qty_prepared_milli`, `qty_remaining_milli`,
`stock: [{warehouse_id, warehouse_name, qty_milli}]` (all active warehouses),
`lot_suggestions: [{lot_id, lot_number, expiry_date?, qty_available_milli, qty_suggested_milli}]` (FEFO, net of
preparations in progress; empty if not lot-tracked), `orders?` (batch preparation only:
`[{order_id, order_number, partner_name, line_id, qty_remaining_milli}]`).

**`PickResult`** (picks / scan): `line_id`, `product_id`, `product_name`, `pick_ids: []`, `qty_milli` (added),
`qty_prepared_milli`, `qty_to_prepare_milli`, `line_complete` (bool), `order_complete` (bool), `lots: [lot_number…]`.

Rules:
- a pick moves `validated` → `preparing` (and `ready` without a delivery note → `preparing`);
- refused if prepared + qty > to prepare (409 « … de trop », too many);
- `lot_id` provided: must belong to the product and have availability (lot − preparations in progress);
- without `lot_id` on a lot/expiry-tracked product: spread FEFO across lots (any remainder without a lot);
- **scan**: the barcode is looked up in `products.barcode`, `product_barcodes`, then the carton codes
  (`packagings`, quantity = carton factor). Unknown or product not in the order → **422**
  `wrong_product: true`. Product already fully prepared or quantity above the remainder → 409.
  `lot_number` optional (otherwise FEFO).

`POST /orders/{id}/ready` (`validated|preparing` → `ready`):
- `auto_pick: true`: automatically picks the remainder (FEFO, capped at the warehouse stock) — for stores without scanning;
- services: considered prepared;
- if a line is incomplete and `accept_partial` is absent → 409 « préparation incomplète : … — confirmez pour mettre
  le manquant en reliquat » (incomplete preparation, confirm to move the shortage to backorder); with `accept_partial: true`: `qty_validated` = paid quantity prepared, the paid shortage
  is added to `qty_backorder`, free units are recomputed, `is_partial = true`;
- nothing prepared → 409.

### 2.7 Delivery note, shipping, delivery, invoice, cancellation

- **Delivery note** (`POST /orders/{id}/delivery-note`, status `ready`): creates and **posts** a `DELIVERY_NOTE` (usual
  posting engine: stock taken out per lot, negative-stock check) — one line per picked lot for the paid
  part, one « (UG) » (free units) line at 100 % discount for the free units, one product-less « Frais de livraison » (delivery fee) line
  (`shipping_fee`) and one negative « Remise (code …) » (discount) line (`extra_discount`). Idempotent: returns the existing delivery note.
  `qty_delivered_milli` = prepared.
- **Ship** (`ready` → `shipping`): generates the delivery note if missing.
- **Deliver** (`shipping|ready` → `delivered`): generates the delivery note if missing. `cod_amount > 0` creates and posts a
  `PAYMENT_IN` (`payment_method`: `cash` default, `cib`, `edahabia`, `cheque`, `transfer`) on the customer's account;
  one cash collection per order (409 otherwise).
- **Invoice** (`delivered` → `invoiced`): creates and posts a `SALE_INVOICE` that copies the delivery note lines with
  `ref_document_id = delivery note` (stock does not move a second time). `payment_method`: `credit` by default (on account,
  `due_date` = today + the customer's `payment_terms_days`, otherwise setting `default_payment_days`, 30 by default);
  `cash|cib|edahabia|cheque|transfer` possible **unless** a cash collection on delivery exists (409).
- **Cancel** (`reason` required, 400 otherwise): from `new…shipping`. If the delivery note is posted: reversal of the delivery note
  (stock returned) — requires `void_document` (otherwise 403 `needs_approval` action `void_document`). Pending delivery-round
  stops are set to failed, backorders are cancelled. `delivered`/`invoiced` → 409 (issue a credit note).

### 2.8 Backorders

**`BackorderRow`**: `line_id`, `order_id`, `order_number`, `order_status`, `order_date`, `partner_id`,
`partner_name`, `partner_phone`, `product_id`, `product_name`, `warehouse_id`, `qty_backorder_milli`, `unit_price`,
`available_milli` (availability remaining before this line), `fulfillable_milli` (can be served now, first come
first served by order date).

- `GET /orders/backorders?fulfillable=1` → only the lines that can be served now.
- `POST /orders/{id}/release-backorder`: puts the backorder back **into the same order** (status `validated` or
  `preparing` only) within the limit of availability; 409 if nothing is available.
- `POST /orders/backorders/new-order`: creates a **new order** (`new`, `source: manual`,
  `price_source: backorder`, same prices/discounts, `backorder_from_line_id`) with all the customer's backorders (or the
  given `line_ids`); the original lines go to backorder 0.
- `GET /products/{id}/waiting-customers`: "who is waiting for this product" (when stock arrives).

### 2.9 Web store

**`WebOrderPayload`** (`POST /orders/import-web`, unknown keys ignored):

| Field | Type | Note |
|---|---|---|
| `id` | string | **required** — store id; **idempotency key** (`external_ref`) |
| `number` | string | number displayed by the store (`external_number`) |
| `customer_name`, `phone`, `email`, `customer_type`, `business_name`, `nif`, `wilaya`, `commune`, `address`, `note` | string | |
| `items` | `[{product_id, name?, qty_milli? \| qty? (units, decimal), price_centimes? (displayed unit price incl. VAT)}]` | ≥ 1 |
| `shipping_fee_centimes`, `discount_centimes` | int | → `shipping_fee`, `extra_discount` |
| `promo_code`, `created_at`, `total_centimes` | | `total_centimes` ≠ computed total → warning |

Processing: already imported (`source = web` + same `id`) → **200** with `created: false`. Otherwise:
1. customer looked up by **normalised phone** (`0XXXXXXXXX`, accepts `+213…`, `00213…`, spaces, dots) in
   `partners.phone`, `partners.whatsapp`, then contacts; otherwise **creation** of a customer (`kind: customer`,
   name = `business_name` otherwise `customer_name`, `source: web`, `crm_status: active`, `client_type` derived from
   `customer_type`: sup→`supermarket`, restau→`restaurant`, hôtel→`hotel`, gross→`wholesaler`, détail/commerce/pro→`retailer`,
   empty/particulier→`individual`) + primary contact = `customer_name` if a business name is provided;
2. order `source: web`, `payment_mode: cod`, price = `price_centimes` converted to HT (`price_source: web`, discount 0),
   free units from promotions with channel `all|web` added; unknown items ignored → `warnings` + internal note; no item
   recognised → 409.

Response: order + `created` (bool), `partner_created` (bool), `warnings` (string[]).

**Status sync back to the store**: any status change of a `web` order sets
`web_status_dirty = true`.
`GET /orders/web-sync` → `WebSyncItem`: `id`, `number`, `external_ref`, `external_number`, `status`, `status_label`,
`updated_at`, `cancel_reason`, `last_event_note`, `last_event_at`. After pushing to the store:
`POST /orders/web-sync/ack {items:[{id, status}]}` resets the flag to `false` only if the status has not changed
in the meantime (`cleared` = number cleared).

---

## 3. Pricing

### 3.1 Price resolution (`GET /pricing/resolve`)

Permission `orders.view | pricing.view`. Query: `product_id` (required), `partner_id`, `qty_milli` (default 1000),
`date` (default today), `channel` (`desk` default | `web`).
Response `{quote: PriceQuote, quotas: QuotaRow[]}`.

`PriceQuote`: `product_id`, `product_name`, `qty_milli`, `unit_price` (HT), `discount_pct`, `vat_rate`,
`price_source`, `special_price_id`?, `qty_free_milli`, `promo_rule_id`?, `promo_rule_name`?, `base_price_ttc`,
`line_ht`, `line_ttc`.

Order:
1. **customer** special price (highest `min_qty_milli` tier reached, valid period) → `special_partner`, discount 0;
2. special price of the customer's **group** → `special_group`, discount 0;
3. price list: the **group** level if there is one, otherwise `partners.price_level`; `wholesale` (if `price_wholesale` > 0)
   or `retail`; product promo price (`promo_price` within its dates and lower) → `promo`; otherwise the group discount;
4. active promotions (dates, channel `all|<channel>`, audience `all` / `group` = customer's group / `partner` = the customer):
   `qty_discount` → the rule's discount if qty ≥ N **and** higher than the discount already obtained; `free_goods` → free units =
   ⌊qty / N⌋ × M (most generous rule).

Channel of an order: `web` for `source = web|portal`, otherwise `desk`.

### 3.2 Special prices

| Method | Path | Permission | |
|---|---|---|---|
| GET | `/customer-prices` | pricing.view \| orders.view | query `partner_id`, `group_id`, `product_id`, `q` → `{items: CustomerPrice[]}` |
| POST | `/customer-prices` | pricing.edit | `CustomerPriceInput` → **201** `CustomerPrice` |
| PUT | `/customer-prices/{id}` | pricing.edit | `CustomerPriceInput` → `CustomerPrice` |
| DELETE | `/customer-prices/{id}` | pricing.edit | → `{deleted: id}` |

`CustomerPriceInput`: `partner_id`? **or** `group_id`? (exactly one, 400 otherwise), `product_id`, `price_ht` (≥ 0),
`min_qty_milli` (≥ 0), `start_date`?, `end_date`?, `notes`.
`CustomerPrice` = these fields + `id`, `partner_name`?, `group_name`?, `product_name`, `created_at`, `updated_at`.

### 3.3 Promotions

| Method | Path | Permission | |
|---|---|---|---|
| GET | `/promo-rules` | pricing.view \| orders.view | query `active=1`, `product_id`, `type` → `{items: PromoRule[]}` |
| GET | `/promo-rules/web` | pricing.view \| orders.view \| webstore.view | rules to publish on the store: active today, `channel` `all|web`, `audience = all` → `{items, date}` |
| POST | `/promo-rules` | pricing.edit | `PromoInput` → **201** `PromoRule` |
| PUT | `/promo-rules/{id}` | pricing.edit | `PromoInput` → `PromoRule` |
| DELETE | `/promo-rules/{id}` | pricing.edit | → `{deleted}` |

`PromoInput`: `name` (required), `scope` (`product` → `product_id` required | `category` → `category_id` |
`brand` → `brand` | `all`), `type` (`free_goods` → `free_qty_milli` > 0 | `qty_discount` → `discount_pct` 1–10000),
`min_qty_milli` (> 0, = N), `start_date`?, `end_date`?, `audience` (`all` default | `group` → `group_id` |
`partner` → `partner_id`), `channel` (`all` default | `desk` | `web`), `active` (bool, default true), `notes`.
`PromoRule` = these fields (+ `product_name`?, `category_name`?, `id`, `created_at`, `updated_at`) and `label`
(« 10 + 1 gratuit(s) » (10 + 1 free), « −7 % dès 20 » (−7 % from 20)).

### 3.4 Quotas

| Method | Path | Permission | |
|---|---|---|---|
| GET | `/product-quotas` | pricing.view \| orders.view | query `product_id`, `partner_id` (includes "all customers" quotas) → `{items: Quota[]}` |
| GET | `/product-quotas/usage` | pricing.view \| orders.view | query `partner_id` (required), `product_id` → `{items: QuotaRow[]}` |
| POST | `/product-quotas` | pricing.edit | `{product_id, partner_id? (absent = every customer), max_qty_milli > 0, period: day|week|month, active?, notes}` → **201** `Quota` |
| PUT | `/product-quotas/{id}` | pricing.edit | same → `Quota` |
| DELETE | `/product-quotas/{id}` | pricing.edit | → `{deleted}` |

`Quota`: `id`, `product_id`, `product_name`, `partner_id`?, `partner_name`?, `max_qty_milli`, `period`, `active`,
`notes`, `created_at`, `updated_at`.
`QuotaRow`: `id`, `product_id`, `product_name`, `partner_id` ("" = all), `max_qty_milli`, `period`,
`period_start` (Monday for `week`, 1st of the month for `month`), `used_milli`, `remaining_milli`.
Consumption = **validated** quantities of the customer's orders (excluding `new`/`cancelled`) whose `order_date` ≥ start of
period. A customer-specific quota replaces the general quota for the same period.

---

## 4. Deliveries

### 4.1 Vehicles — `deliveries.view` (GET) / `deliveries.manage`

`GET /vehicles` → `{items: Vehicle[]}`; `POST /vehicles` → 201; `PUT /vehicles/{id}`; `DELETE /vehicles/{id}` → `{deleted}`.
Body: `{name (required), plate, capacity_kg (int), active?, notes}`.
`Vehicle`: `id`, `name`, `plate`, `capacity_kg`, `active`, `notes`, `created_at`, `updated_at`.

### 4.2 Route templates (routes) — read `deliveries.view | orders.view | crm.view`, write `deliveries.manage`

`GET /delivery-routes` → `{items: DeliveryRoute[]}`; `POST` → 201; `PUT /delivery-routes/{id}`;
`DELETE /delivery-routes/{id}` (409 if used by customers, orders or delivery rounds: deactivate it instead).
Body: `{name (required, unique), wilayas: string[], communes: string[], weekdays: int[] (1 = Monday … 7),
default_driver_user_id?, default_driver_name, default_vehicle_id?, active?, notes}`.
`DeliveryRoute` = these fields + `id`, `partners_count`, `ready_orders_count`, `created_at`, `updated_at`.
The customer carries `route_id`; the order inherits it. Ready orders of a route: `GET /orders?status=ready&route_id=…`.

### 4.3 Delivery rounds (runs)

Statuses: `planned` → `out` → `closed`; `planned` → `cancelled`. Stops: `pending` → `delivered` | `partial` | `failed`.

| Method | Path | Permission | |
|---|---|---|---|
| GET | `/delivery-runs` | deliveries.view | query `from`, `to` (run_date), `status` (list), `route_id`, `driver_user_id` → `{items: DeliveryRun[]}` (without `stops`) |
| POST | `/delivery-runs` | deliveries.manage | `{run_date? (default today), route_id?, driver_user_id?, driver_name, vehicle_id?, notes, order_ids?: []}` → **201** `DeliveryRun` (default driver/vehicle from the route template) |
| GET | `/delivery-runs/{id}` | deliveries.view | → `DeliveryRun` with `stops` |
| PUT | `/delivery-runs/{id}` | deliveries.manage | `{run_date (required), route_id?, driver_user_id?, driver_name, vehicle_id?, notes}` (planned/out) |
| POST | `/delivery-runs/{id}/stops` | deliveries.manage | `{order_ids: []}` — `ready` orders; if the round is `out`, they leave immediately |
| PUT | `/delivery-runs/{id}/stops/order` | deliveries.manage | `{stop_ids: [] (desired order)}` |
| PATCH | `/delivery-runs/{id}/stops/{stopId}` | deliveries.manage | `{cod_expected?, note?}` |
| DELETE | `/delivery-runs/{id}/stops/{stopId}` | deliveries.manage | `pending` stop of an open round; the order goes back to `ready` if it had left |
| POST | `/delivery-runs/{id}/start` | deliveries.manage | `planned` → `out`; each pending order goes to `shipping` (delivery note generated). Error → 409 « commande CC-… : … » (order CC-…: …) |
| POST | `/delivery-runs/{id}/stops/{stopId}/result` | deliveries.manage | `{status: delivered|partial|failed, failure_reason (required if failed), cod_collected (int ≥ 0), payment_method (cash default|cib|edahabia|cheque|transfer), receiver_name, note}` |
| POST | `/delivery-runs/{id}/close` | deliveries.manage | `{counted_cash?, notes?}` (optional) → `DeliveryRun` + `reconciliation` |
| POST | `/delivery-runs/{id}/cancel` | deliveries.manage | `planned` only; stops deleted |

Rules: an order can be on only **one** open round (409). `cod_expected` defaults to the order's total incl. VAT
if `payment_mode = cod` (minus any cash collection already made), otherwise 0. Result `delivered`/`partial` → the
order goes to `delivered` (partial: `is_partial = true`; returns are handled with a credit note); **the money is
only booked at closing**. `failed` → the order goes back to `ready` (event `delivery_failed`), it can
go out again on another round. Results can only be entered on an `out` round (409 otherwise); stop already settled → 409.

**Closing**: refused (409) if `pending` stops remain. For each stop with `cod_collected > 0`: a
posted `PAYMENT_IN` on the customer's account (`payment_id` on the stop and the order). `reconciliation`:
`{cash_expected (Σ cod_expected of delivered/partial stops), cash_collected, cash_difference (collected − expected),
counted_cash?, payments: [{stop_id, order_id, partner_id, amount, payment_method, document_id, number}]}`.

`DeliveryRun`: `id`, `run_date`, `route_id`?, `route_name`, `driver_user_id`?, `driver_name` (as entered, otherwise the
user's name), `vehicle_id`?, `vehicle_name`, `status`, `departed_at`?, `closed_at`?, `cash_expected`,
`cash_collected`, `cash_difference`, `counted_cash`?, `notes`, `stops_count`, `pending_count`, `cod_expected_total`,
`cod_collected_total`, `created_at`, `updated_at`, `stops`? (detail).

`RunStop`: `id`, `order_id`, `order_number`, `order_status`, `partner_id`, `partner_name`, `partner_phone`,
`delivery_address`, `wilaya`, `commune`, `latitude`?, `longitude`? (float, customer record), `total_ttc`,
`delivery_note_id`?, `delivery_note_number`?, `sequence`, `status`, `failure_reason`, `cod_expected`,
`cod_collected`, `payment_method`, `payment_id`?, `payment_number`?, `receiver_name`, `delivered_at`?, `note`.

---

## 5. CRM

### 5.1 Customer record (existing routes `GET/POST/PUT /partners`)

New `Partner` fields (response): `client_type` (`supermarket|restaurant|hotel|wholesaler|retailer|individual|other`,
default `other`), `crm_status` (`prospect|active|dormant|blocked`, default `active`), `rep_user_id`?, `rep_name`,
`route_id`?, `route_name`, `wilaya`, `commune`, `latitude`? , `longitude`? (float), `opening_hours`, `license_no`,
`whatsapp`, `website`, `source` (`manual|web|import|rep|portal`), `payment_terms_days`? (int, null = store
default), `tag_ids` (string[]). `email` already existed and is read/written.

Input (POST/PUT): same names, **all optional**; absent = unchanged (PUT) / default (POST).
`rep_user_id: ""` / `route_id: ""` = none; `payment_terms_days: -1` = store default; `tag_ids` replaces the
tags. Invalid values → 400. (The legacy PUT fields keep their "replace" semantics.)

New `GET /partners` filters: `client_type`, `crm_status`, `rep_user_id`, `route_id`, `wilaya`, `source`,
`tag_id` (+ "own" restriction, §7).

| Method | Path | Permission | |
|---|---|---|---|
| GET | `/partners/{id}/credit` | orders.view \| crm.view \| partners.view | `{partner_id, balance, credit_limit (0 = none), open_orders_total, open_orders_count, available_credit? (null without a limit), overdue_amount, overdue_count, crm_status, payment_terms_days}` |
| GET | `/partners/{id}/kpis` | crm.view \| partners.view | see below |
| GET | `/partners/{id}/timeline` | crm.view \| partners.view | query `limit` (≤ 200, default 50), `offset`, `kinds` (list) → `{items: TimelineItem[], total, limit, offset}` |

**KPIs**: `partner_id`, `turnover_30d`, `turnover_90d`, `turnover_365d` (incl. VAT: tickets + invoices − credit notes + delivery notes not yet
invoiced), `purchases_count_365d` (distinct purchase days), `avg_basket`, `order_frequency_days`? (float, average gap
between purchases), `last_order_date`?, `days_since_last_order` (-1 = never), `top_products: [{product_id, name,
qty_milli, amount}]` (10, over 365 d), `payment_delay_avg_days`? (float, invoice → the payment that settles it, FIFO),
`balance`, `credit_limit`, `credit_usage_pct`, `overdue_amount`, `open_orders_count`, `open_orders_amount`,
`backorder_lines`, `backorder_qty_milli`.

**`TimelineItem`** (sorted descending on `at`): `kind` (`order|order_event|document|payment|activity|task|message`),
`id`, `at`, `title`, `detail`, `amount`? (centimes), `ref_id`? (linked order or document), `status`, `sub_type`
(doc_type, activity type, channel, action…), `user_name`. Data-entry/preparation events (create, pick,
edit_line…) are excluded.

### 5.2 Contacts, tags, attachments

| Method | Path | Permission | |
|---|---|---|---|
| GET | `/partners/{id}/contacts` | crm.view \| partners.view | `{items: Contact[]}` (primary first) |
| POST | `/partners/{id}/contacts` | crm.edit \| partners.edit | `{name (required), role, phone, whatsapp, email, is_primary, notes}` → 201 `Contact` |
| PUT | `/partner-contacts/{id}` | crm.edit \| partners.edit | same → `Contact` |
| DELETE | `/partner-contacts/{id}` | crm.edit \| partners.edit | → `{deleted}` |
| GET | `/tags` | crm.view \| partners.view | `{items: [{id, name, colour, partners_count, created_at, updated_at}]}` |
| POST | `/tags` | crm.edit \| partners.edit | `{name (unique), colour ("#RRGGBB", default #00CC99)}` → 201 |
| PUT | `/tags/{id}` | crm.edit \| partners.edit | same |
| DELETE | `/tags/{id}` | crm.edit \| partners.edit | → `{deleted}` |
| PUT | `/partners/{id}/tags` | crm.edit \| partners.edit | `{tag_ids: []}` → `Partner` |
| GET | `/partners/{id}/files` | crm.view \| partners.view | `{items: [{id, partner_id, kind, name, mime, size, expires_at?, expired (bool), notes, created_at}]}` |
| POST | `/partners/{id}/files?name=&kind=&expires_at=&notes=` | crm.edit \| partners.edit | **body = raw file** (≤ 5 MB, 413 above); `kind`: `license|registre|nif|nis|contract|id|other` → 201 |
| GET | `/partners/{id}/files/{fid}` | crm.view \| partners.view | binary content (`Content-Type`, `Content-Disposition`) |
| DELETE | `/partners/{id}/files/{fid}` | crm.edit \| partners.edit | → `{deleted}` |

`Contact`: `id`, `partner_id`, `name`, `role`, `phone`, `whatsapp`, `email`, `is_primary`, `notes`, `created_at`, `updated_at`.
Only one primary contact per customer (marking a contact as primary removes the mark from the others).

### 5.3 Activities

| Method | Path | Permission | |
|---|---|---|---|
| GET | `/crm/activities` | crm.view | query `partner_id`, `user_id` (`me` accepted), `type`, `order_id`, `from`, `to` (date or timestamp), `limit`, `offset` → `{items: Activity[]}` (most recent first) |
| POST | `/crm/activities` | crm.edit | `ActivityInput` → 201 `Activity` |
| PUT | `/crm/activities/{id}` | crm.edit | `ActivityInput` |
| DELETE | `/crm/activities/{id}` | crm.edit | → `{deleted}` |

`ActivityInput`: `partner_id` (required), `type` (`call|visit|note|whatsapp|sms|email|meeting`), `outcome`,
`summary`, `at` (ISO, default now), `duration_min` (int ≥ 0), `order_id`?, `document_id`?, `latitude`?,
`longitude`? (visit GPS), `next_action`, `next_action_due`? (date: also creates a `follow_up` task
assigned to the author, on creation only). The author (`user_id`) = the logged-in user.
`Activity`: these fields + `id`, `partner_name`, `user_id`?, `user_name`, `order_number`?, `created_at`, `updated_at`.

### 5.4 Tasks

| Method | Path | Permission | |
|---|---|---|---|
| GET | `/crm/tasks` | crm.view | query `assignee_id` (`me` \| `unassigned` \| id), `status` (`open` default \| `done` \| `cancelled` \| `all`), `partner_id`, `type`, `source`, `order_id`, `due` (`overdue` \| `today` \| `week`), `limit` (≤ 500, default 200) → `{items: Task[]}` (ascending due date) |
| GET | `/crm/tasks/summary` | crm.view | query `assignee_id` (`me` \| id \| `all` default) → `{open, overdue, today, upcoming_7d}` |
| POST | `/crm/tasks` | crm.edit | `TaskInput` → 201 `Task` (without `assignee_id`: the current user) |
| PUT | `/crm/tasks/{id}` | crm.edit | `TaskInput` (`assignee_id` absent = none) |
| POST | `/crm/tasks/{id}/complete` | crm.edit | `{result?}` → `Task` (409 if already closed) |
| POST | `/crm/tasks/{id}/cancel` | crm.edit | `{result?}` → `Task` |
| POST | `/crm/tasks/generate` | crm.edit | `{inactive_days? (default: setting crm_inactive_days, 30), overdue?: bool, inactive?: bool, backorder?: bool}` (all true by default) → `{created, by_source: {auto_overdue, auto_inactive, auto_backorder}, skipped, inactive_days}` |

`TaskInput`: `title` (required), `description`, `partner_id`?, `order_id`?, `assignee_id`?, `due_at`? (date or
ISO), `priority` (0/1/2), `type` (`call|visit|collect_payment|follow_up|other`).
`Task`: `id`, `title`, `description`, `partner_id`?, `partner_name`?, `partner_phone`?, `order_id`?, `order_number`?,
`assignee_id`?, `assignee_name`, `due_at`?, `overdue` (bool), `priority`, `status`, `type`, `source`
(`manual|auto_overdue|auto_inactive|auto_backorder`), `auto_key`?, `completed_at`?, `completed_by`?, `result`,
`created_by`?, `created_at`, `updated_at`.

**Automatic generation** (idempotent: no new task if a task with the same `auto_key` is open or was
closed less than 7 days ago; due date = today):
- overdue invoices → `collect_payment` priority 1, assigned to the customer's sales rep (`auto_key` `overdue:<partner>`);
- customers with `crm_status = active` and no purchase for N days (who have bought before) → `follow_up` (`inactive:<partner>`);
- backorder line that has become fulfillable → `call` priority 1 (`backorder:<line>`).

### 5.5 Segments

| Method | Path | Permission | |
|---|---|---|---|
| GET | `/crm/segments` | crm.view | `{items: [{id, name, builtin (bool), rules, created_at?, updated_at?}]}` (built-in first) |
| POST | `/crm/segments` | crm.edit | `{name (unique), rules: SegmentRules}` → 201 |
| PUT | `/crm/segments/{id}` | crm.edit | same |
| DELETE | `/crm/segments/{id}` | crm.edit | → `{deleted}` |
| POST | `/crm/segments/evaluate` | crm.view | `{rules: SegmentRules}` → `SegmentResult` |
| GET | `/crm/segments/{id}/evaluate` | crm.view | saved or built-in id; query `client_type`, `tag_id`, `wilaya`, `rep_user_id`, `route_id`, `crm_status` override the filters → `SegmentResult` + `segment` |

Built-in: `builtin:inactive_30`, `builtin:inactive_60`, `builtin:inactive_90`, `builtin:credit_80`,
`builtin:overdue`, `builtin:top_customers` (top 20, 90 d), `builtin:declining` (30 d vs the previous 30 d,
drop ≥ 20 %), `builtin:new_customers` (created in the last 30 d). "By type / tag / wilaya / sales rep /
delivery round" = rules without `builtin` with the desired filter.

`SegmentRules` (all optional): `builtin` (`inactive|credit_usage|overdue|top_customers|declining|new_customers`),
`days` (inactive/new, default 30), `min_pct` (credit_usage, default 80), `min_drop_pct` (declining, default 20), `limit`
(top, default 20), `period_days` (turnover window, default 90; 30 for declining), filters `client_type`, `crm_status`,
`tag_id`, `wilaya`, `rep_user_id`, `route_id`, `group_id`, `min_turnover`, `min_balance` (centimes).

`SegmentResult`: `{items: CustomerMetric[], count, period: {from, to}, rules, total_turnover, total_balance}`.
`CustomerMetric`: `partner_id`, `name`, `phone`, `client_type`, `crm_status`, `wilaya`, `rep_user_id`?, `rep_name`,
`route_id`?, `created_at`, `tag_ids`, `turnover` (incl. VAT over `period_days`), `turnover_previous` (previous period),
`orders_count` (orders over the period), `last_order_date` ("" = never), `days_since_last_order` (-1 = never),
`balance`, `credit_limit`, `credit_usage_pct`, `overdue_amount`, `overdue_count`.
Only active customers (`customer|both`) are evaluated, excluding the till's walk-in customer.

### 5.6 Sales rep targets and performance

| Method | Path | Permission | |
|---|---|---|---|
| GET | `/crm/rep-targets?month=YYYY-MM` | crm.view | `{items: RepTarget[], month}` (a restricted rep only sees their own) |
| PUT | `/crm/rep-targets` | crm.edit (not a restricted "own" role) | `{user_id, month, sales_target, orders_target, visits_target, new_customers_target, collections_target}` → `RepTarget` (created or replaced) |
| GET | `/crm/reps/performance?month=YYYY-MM&user_id=` | crm.view | `{items: RepPerf[], month, from, to}` |

`RepTarget`: `id`, `user_id`, `user_name`, `month`, `sales_target` (centimes), `orders_target`, `visits_target`,
`new_customers_target`, `collections_target` (centimes), `updated_at`.
`RepPerf`: `user_id`, `name`, `month`, `sales` (incl. VAT of their orders for the month excluding new/cancelled), `orders_count`,
`new_customers` (customers created during the month with them as sales rep), `visits`, `calls` (activities), `collections`
(posted `PAYMENT_IN` of the month from their customers), `customers` (portfolio), `targets`? (`RepTarget`),
`achievement_pct` (`{sales, orders, visits, new_customers, collections}` as whole %, key absent without a target).
Reps listed: active users with a target this month, a portfolio, or orders as sales rep.

---

## 6. Messages (WhatsApp / SMS / e-mail)

| Method | Path | Permission | |
|---|---|---|---|
| GET | `/message-templates` | crm.view \| orders.view | query `code`, `channel`, `lang` → `{items: Template[]}` |
| POST | `/message-templates` | crm.edit | `TemplateInput` → 201 |
| PUT | `/message-templates/{id}` | crm.edit | `TemplateInput` |
| DELETE | `/message-templates/{id}` | crm.edit | 409 for a default template (`is_system`) |
| GET | `/messages/placeholders` | (logged in) | `{items: [{key, label}]}` |
| POST | `/messages/render` | crm.view \| orders.view | see below → `Rendered` |
| POST | `/messages/log` | crm.view \| orders.view | `{partner_id?, order_id?, channel, template_code, recipient, subject, body, status: prepared|sent}` → 201 `MessageLog` |
| GET | `/messages/log` | crm.view \| orders.view | query `partner_id`, `order_id`, `channel`, `status`, `limit` → `{items: MessageLog[]}` |
| POST | `/messages/send-email` | crm.edit \| orders.manage | `{partner_id?, order_id?, to? (default: customer's e-mail, then a contact's), subject, body, template_code}` → `MessageLog`; SMTP not configured → 409 `smtp_not_configured`; SMTP refusal → 502 (logged as `failed`) |

`TemplateInput`: `code` (`[a-z0-9_]{2,40}`), `channel` (`whatsapp|sms|email`), `lang` (`fr` default | `ar`), `name`,
`subject` (e-mail), `body` (required), `active` (default true). Unique per (code, channel, language) → 409.
`Template` = these fields + `id`, `is_system`, `created_at`, `updated_at`.
Templates provided (in French) — WhatsApp: `order_confirmed`, `order_ready`, `order_shipped`, `order_delivered`,
`payment_reminder`, `statement`, `backorder_available`, `promo`; e-mail: `order_confirmed`, `payment_reminder`, `statement`.

**Rendering** (`POST /messages/render`) — body: `template_id` **or** `code` (+ `channel` default `whatsapp`, `lang`
default `fr`, falling back to French) **or** free `body` (+ `subject`, `channel`); `partner_id`? (derived from
`order_id`), `order_id`?, `extra`? (`{key: value}` that completes/overrides the variables).
`{{…}}` variables: `client`, `contact`, `numero`, `reference_web`, `montant` (« 12 345,00 DA »), `solde`, `date`
(DD/MM/YYYY), `date_commande`, `magasin` (setting `company_name`), `telephone_magasin` (`company_phone`),
`lien_suivi` (setting `order_tracking_url`, `{ref}` replaced by the web reference or the order number), `produit`
(via `extra`), `promo` (current web offers, or `extra`), `statut`.
`Rendered`: `channel`, `template_code`, `subject`, `body`, `recipient` (213… or e-mail), `phone_intl` (`213XXXXXXXXX`
from the customer's `whatsapp`, otherwise phone, otherwise primary contact), `wa_link`
(`https://wa.me/<phone_intl>?text=<encoded text>`, or `https://wa.me/?text=…` without a number), `mailto`, `missing`
(unresolved variables, replaced with empty text).
Recommended WhatsApp flow: render → open `wa_link` → `POST /messages/log` (`prepared` or `sent`).

`MessageLog`: `id`, `partner_id`?, `partner_name`?, `order_id`?, `order_number`?, `channel`, `template_code`,
`recipient`, `subject`, `body`, `status` (`prepared|sent|failed`), `error`, `user_id`?, `user_name`, `created_at`.

**SMTP** (Settings, `PUT /settings`): `smtp_host`, `smtp_port` (default 587), `smtp_user`, `smtp_pass`, `smtp_from`
(default `smtp_user`), `smtp_security` (`starttls` default, `ssl` default if port 465, `none`). `GET /settings`
**never** returns `smtp_pass` but `smtp_pass_set: "1"|"0"`; do not send `smtp_pass` on PUT to keep it.

---

## 7. "Own" scope (sales reps)

A role with scope `own` (table `roles.scope`):
- **orders** (`GET /orders`, detail, actions, backorders, alerts): only the orders where they are the
  sales rep (`rep_user_id`), that they created, or of customers for whom they are the sales rep — unless `crm.all_customers`;
- **customers**, if the role has `crm.view` and not `crm.all_customers`: `GET /partners` only shows their customers
  (`partners.rep_user_id` = them) and all suppliers; timeline, KPIs, credit, contacts, attachments, activities,
  segments, message log and order creation are refused (403) for other reps' customers;
- `GET /partners/{id}` remains accessible (picking a customer on other screens);
- tasks: those assigned to them or concerning their customers;
- targets/performance: their own only.
A `warehouse` role only sees the orders of its warehouses. The administrator sees everything.

---

## 8. Miscellaneous

- **Alerts** (`GET /alerts`): new types `orders_new` (« N commande(s) client à valider », N customer order(s) to validate, target `orders`,
  if `orders.view`) and `tasks_overdue` (the user's overdue tasks, target `crm`, if `crm.view`).
- **Analytics**: new source `customer_orders` (view `v_customer_order_lines`, one row per order line;
  measures `orders_count`, `amount_ttc`, `amount_ht`, `qty_ordered`, `qty_delivered`, `qty_backorder`, `fill_rate`
  (service level = validated/ordered), `customers_count`, `avg_order`, `lines_count`).
- **"Transactions" reset**: also clears orders, picks, delivery rounds, stops and the message log.
- **Settings read**: `default_credit_limit`, `default_payment_days` (30), `crm_inactive_days` (30),
  `order_tracking_url`, `company_name`, `company_phone`, `allow_negative_stock`, `number_CUSTOMER_ORDER_*`, `smtp_*`.
- **Audit log**: `order.create`, `order.import_web`, `order.credit_override`, `order.invoice`, `order.cancel`,
  `pricing.special_price`, `pricing.promo`, `pricing.quota`, `delivery_run.create`, `delivery_run.close`,
  `crm.tasks_generate`, `crm.rep_target`, `partner.file`, `partner.file_delete` (+ the actions of the generated documents).

### Typical flow (desktop)

1. Entry: `GET /pricing/resolve` (preview) + `GET /partners/{id}/credit` → `POST /orders`.
2. Validation: `POST /orders/{id}/validate`; if 409 `needs_override` → show `warnings`, offer « Valider quand
   même » (validate anyway) → same call with `override_credit: true` (403 `needs_approval` → manager's code).
3. Preparation: `GET /orders/{id}/picking-list` → scans `POST /orders/{id}/scan` (422 = wrong product) →
   `POST /orders/{id}/ready` (409 incomplete → confirm with `accept_partial: true`).
4. Delivery: delivery round (`POST /delivery-runs`, `start`, `result`, `close`) or direct `ship`/`deliver`.
5. `POST /orders/{id}/invoice`.
6. Web: loop `GET /cloud/...` (store) → `POST /orders/import-web` for each order; then
   `GET /orders/web-sync` → push the statuses → `POST /orders/web-sync/ack`. Promotions to publish:
   `GET /promo-rules/web`.
