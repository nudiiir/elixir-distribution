# API Distribution — commandes clients, tarifs, livraisons, CRM, messages

Contrat serveur du module **Distribution** (grossistes et distributeurs qui livrent des commerces et des professionnels).
Migrations `0016_distribution.sql` et `0017_crm.sql`. Tout est sous `/api/v1`, authentifié
(`Authorization: Bearer <token>`), JSON UTF-8. Code : `server/internal/api/dist_*.go`,
`server/internal/domain/{orders,orders_flow,pricing,deliveries,ledger}.go`.

Le portail client (connexion des clients) est **hors périmètre**.

---

## 0. Conventions

| Sujet | Règle |
|---|---|
| Identifiants | UUIDv7 en chaîne (`"0192…"`). Les ids des segments intégrés sont `"builtin:<clé>"`. |
| Montants | **entiers en centimes** (DA × 100). `unit_price` des lignes de commande = **HT**. Prix produit (`price_retail`, `price_wholesale`) = TTC. Prix spéciaux client = **HT** (`price_ht`). |
| Quantités | **entiers en millièmes** (`*_milli`, 1 unité = 1000). |
| Pourcentages | entiers ×100 (`discount_pct` 750 = 7,5 %). Exception : `credit_usage_pct` et `achievement_pct` = pourcentage entier (85 = 85 %). |
| Dates métier | `"YYYY-MM-DD"` (heure locale du magasin). Horodatages : ISO-8601 UTC (`"2026-10-09T08:15:00Z"`). |
| Champs nullable | marqués `?` dans les tableaux (JSON `null`). |
| Corps inconnus | Les corps JSON sont décodés **strictement** (clé inconnue → 400), sauf `POST /orders/import-web` (tolérant). |
| Corps facultatif | Les actions marquées « corps facultatif » acceptent un corps vide. |
| Listes | Réponse `{"items": [...]}` (+ champs indiqués). |

### Erreurs

| HTTP | Corps | Quand |
|---|---|---|
| 400 | `{"error": "...", "field"?: "nom_du_champ"}` | saisie invalide (message en français) |
| 401 | `{"error": "authentification requise"}` | jeton absent / expiré |
| 403 | `{"error": "accès refusé"}` | permission manquante |
| 403 | `{"error": "...", "needs_approval": true, "action": "<droit>", "amount": <int>}` | droit débloquable par le **code du gérant** : appeler `POST /auth/approve {pin, action, amount}` puis **renvoyer la même requête** avec l'en-tête `X-Approval: <approval_token>` |
| 403 | `{"error": "ce client n'est pas dans votre portefeuille"}` | périmètre « own » (voir §7) |
| 404 | `{"error": "... introuvable"}` | |
| 409 | `{"error": "..."}` | règle métier refusée (statut, stock, quota, lot…) |
| 409 | `{"error": "validation bloquée : ...", "warnings": ["..."], "needs_override": true}` | contrôle crédit / compte à la validation (§1.4) |
| 409 | `{"error": "...", "smtp_not_configured": true}` | e-mail sans SMTP configuré |
| 422 | `{"error": "...", "wrong_product": true}` | scan d'un code-barres inconnu ou d'un produit absent de la commande |
| 502 | `{"error": "envoi impossible : ...", "log_id": "..."}` | le serveur SMTP a refusé |
| 500 | `{"error": "..."}` | erreur interne |

---

## 1. Permissions

Nouvelles clés (même mécanisme que les autres : `roles.perms_json`, grille « module.action »). La clé de
module seule (`orders`, `deliveries`, `crm`, `pricing`) est dérivée de `<module>.view`.

| Clé | Libellé | Donne accès à |
|---|---|---|
| `orders.view` | voir les commandes clients | listes, détail, préparation (lecture), reliquats, synchro web (lecture), alerte « à valider » |
| `orders.manage` | gérer les commandes | créer/modifier, préparer, scanner, BL, expédier, livrer, facturer, annuler, import web, ack synchro, reliquats |
| `orders.validate` | valider | `POST /orders/{id}/validate` |
| `orders.override_credit` | passer outre le contrôle de crédit | `override_credit: true` à la validation (sinon 403 `needs_approval`, action `orders.override_credit`) |
| `deliveries.view` | voir les livraisons | véhicules, tournées types, tournées |
| `deliveries.manage` | gérer les livraisons | toutes les écritures livraisons |
| `crm.view` | voir la relation client | activités, tâches, segments, timeline, KPI, objectifs, modèles de messages |
| `crm.edit` | modifier | écritures CRM (activités, tâches, contacts, étiquettes, pièces, segments, objectifs, modèles) |
| `crm.all_customers` | voir tous les clients | lève la restriction du périmètre « own » (§7) |
| `pricing.view` | voir les tarifs | prix spéciaux, promotions, quotas (lecture) |
| `pricing.edit` | modifier les tarifs | écritures tarifs |

Rôles par défaut : **Administrateur** a tout ; **Gérant** reçoit toutes ces clés (migration 0016) ; **Caissier** aucune.
Droits existants réutilisés : `price_edit` (prix différent du prix résolu, UG saisies à la main),
`discount` (+ limite `max_discount_pct`) pour une remise supérieure à la remise résolue, `void_document`
(annuler une commande dont le BL est validé). Tous acceptent le code du gérant (`needs_approval`).

Quand une ligne de tableau indique plusieurs permissions séparées par « | », **l'une d'elles suffit**.

---

## 2. Commandes clients

### 2.1 Statuts et transitions

| Statut | Libellé | Transitions autorisées (`allowed_transitions`) |
|---|---|---|
| `new` | Nouvelle | `validated`, `cancelled` |
| `validated` | Validée | `new` (rouvrir), `preparing`, `ready`, `cancelled` |
| `preparing` | En préparation | `ready`, `cancelled` |
| `ready` | Prête | `preparing` (si pas de BL), `shipping`, `delivered`, `cancelled` |
| `shipping` | En livraison | `ready` (échec de livraison), `delivered`, `cancelled` |
| `delivered` | Livrée | `invoiced` |
| `invoiced` | Facturée | — |
| `cancelled` | Annulée | — |

Origines (`source`) : `manual` (bureau), `phone`, `whatsapp`, `rep` (commercial), `web` (boutique, uniquement
par import), `portal` (réservé). Priorité : `0` normale, `1` haute, `2` urgente. `payment_mode` : `account`
(sur compte, défaut) ou `cod` (paiement à la livraison ; défaut des commandes web).

Numérotation : `CC-2026-000001` (réglages facultatifs `number_CUSTOMER_ORDER_prefix|year|digits|reset`, comme les
documents ; jamais réutilisé).

### 2.2 Quantités d'une ligne

| Champ | Sens |
|---|---|
| `qty_ordered_milli` | demandé par le client |
| `qty_validated_milli` | engagé sur cette commande (payant). Après le BL : la partie payante réellement partie |
| `qty_backorder_milli` | reliquat en attente de stock (= commandé − validé, + manquants constatés à la préparation) |
| `qty_free_milli` | unités gratuites (UG) en plus |
| `qty_to_prepare_milli` | `validated + free` (à prélever) |
| `qty_prepared_milli` | somme des prélèvements (payant + UG) |
| `qty_delivered_milli` | parti sur le BL (payant + UG) |

Montants : quantité facturée = `qty_ordered` tant que la commande est `new`, puis `qty_validated`.
`total_ttc` commande = Σ `line_ttc` + `shipping_fee` − `extra_discount`. Une ligne remplacée (substitution) ou
reprise en reliquat reste dans la liste avec toutes ses quantités à 0 (`qty_ordered_milli` = 0) pour l'historique.

**Disponible** (`available_milli`) = stock du dépôt de la commande − ce que les autres commandes
`validated|preparing|ready` sans BL réservent (validé + UG).

### 2.3 Objet `CustomerOrder`

| Champ | Type | Note |
|---|---|---|
| `id`, `number` | string | |
| `order_date` | date | |
| `partner_id`, `partner_name`, `partner_phone`, `partner_client_type` | string | |
| `source` | string | voir §2.1 |
| `external_ref`? , `external_number`? | string | id / n° boutique web |
| `status`, `status_label` | string | |
| `is_partial`, `has_backorder`, `credit_override`, `web_status_dirty` | bool | |
| `warehouse_id`, `warehouse_name` | string | |
| `rep_user_id`?, `rep_name` | string | commercial |
| `route_id`?, `route_name` | string | tournée (héritée du client) |
| `priority` | int | 0/1/2 |
| `payment_mode` | string | `account`/`cod` |
| `requested_date`? | date | livraison souhaitée |
| `delivery_address`, `wilaya`, `commune`, `contact_name`, `contact_phone` | string | défaut : fiche client |
| `notes` (visible client), `internal_notes` | string | |
| `total_ht`, `total_vat`, `total_discount`, `shipping_fee`, `extra_discount`, `total_ttc` | int (centimes) | `shipping_fee`/`extra_discount` en TTC |
| `promo_code`, `cancel_reason` | string | |
| `delivery_note_id`?, `delivery_note_number`? | string | BL généré |
| `invoice_id`?, `invoice_number`? | string | facture |
| `payment_id`?, `payment_number`? | string | encaissement à la livraison |
| `created_by`?, `created_by_name`, `validated_by`?, `validated_at`?, `delivered_at`?, `created_at`, `updated_at` | | |
| `lines_count` | int | lignes actives |
| `lines` | `OrderLine[]` | **détail seulement** |
| `events` | `OrderEvent[]` | **détail seulement**, ordre chronologique |
| `picks` | `OrderPick[]` | **détail seulement** |
| `allowed_transitions` | string[] | **détail seulement** |

`OrderLine` : `id`, `position` (int), `product_id`, `product_name`, `barcode`?, `is_service` (bool), `track_lots` (bool),
`qty_ordered_milli`, `qty_validated_milli`, `qty_prepared_milli`, `qty_delivered_milli`, `qty_backorder_milli`,
`qty_free_milli`, `qty_to_prepare_milli`, `unit_price` (HT), `discount_pct`, `vat_rate`, `line_ht`, `line_vat`,
`line_ttc`, `price_source` (`special_partner|special_group|wholesale|retail|promo|manual|web|backorder`),
`promo_rule_id`?, `substituted_from_line_id`?, `substituted_from_product_id`?, `backorder_from_line_id`?, `notes`,
`stock_milli` (stock du dépôt), `available_milli`.

`OrderEvent` : `id`, `action`, `from_status`?, `to_status`?, `user_id`?, `user_name`, `note`, `created_at`.
Actions : `create`, `import`, `update`, `add_line`, `edit_line`, `delete_line`, `substitute`, `validate`, `reopen`,
`start_preparation`, `resume_preparation`, `pick`, `unpick`, `ready`, `delivery_note`, `ship`, `deliver`,
`delivery_failed`, `run_add`, `run_remove`, `cod_collected`, `invoice`, `cancel`, `release_backorder`, `backorder_moved`.

`OrderPick` : `id`, `line_id`, `product_id`, `lot_id`?, `lot_number`?, `expiry_date`?, `qty_milli`, `barcode`,
`picked_by`?, `picked_by_name`, `created_at`.

Les actions qui renvoient « la commande » répondent l'objet **détaillé** (avec `lines`, `events`, `picks`,
`allowed_transitions`), avec parfois des clés supplémentaires au même niveau (indiquées).

### 2.4 Routes

| Méthode | Chemin | Permission | Corps → Réponse |
|---|---|---|---|
| GET | `/orders` | orders.view | Filtres query ci-dessous → `{items: CustomerOrder[] (sans détail), counts: {new:int,…,cancelled:int}, total:int}` |
| GET | `/orders/statuses` | (connecté) | `{items:[{key,label,transitions:[]}], sources:[...]}` |
| POST | `/orders` | orders.manage | `OrderBody` → **201** commande |
| GET | `/orders/{id}` | orders.view | → commande |
| PUT | `/orders/{id}` | orders.manage | `OrderBody` (si `lines` présent : lignes remplacées) → commande |
| POST | `/orders/{id}/lines` | orders.manage | `{lines: OrderLineBody[]}` → commande |
| PATCH | `/orders/{id}/lines/{lineId}` | orders.manage | `{qty_milli?, unit_price?, discount_pct?, qty_free_milli?, notes?}` → commande |
| DELETE | `/orders/{id}/lines/{lineId}` | orders.manage | → commande |
| POST | `/orders/{id}/lines/{lineId}/substitute` | orders.manage | `{product_id, qty_milli? (défaut : qté commandée), keep_price?: bool}` → commande + `new_line_id` |
| POST | `/orders/{id}/validate` | orders.validate | `ValidateBody` (facultatif) → commande + `validation: {warnings:[], backorders:[{line_id,product_id,product_name,qty_backorder_milli}], partial:bool}` |
| POST | `/orders/{id}/reopen` | orders.manage | — → commande (validated → new) |
| POST | `/orders/{id}/start-preparation` | orders.manage | — → commande |
| GET | `/orders/{id}/picking-list` | orders.view | → `PickingList` |
| GET | `/orders/picking-list?ids=a,b` | orders.view | → préparation groupée `{items: PickingLine[] (par produit, avec orders[]), order_ids}` |
| POST | `/orders/{id}/picks` | orders.manage | `{line_id, lot_id? , qty_milli}` → `PickResult` |
| DELETE | `/orders/{id}/picks/{pickId}` | orders.manage | → commande |
| POST | `/orders/{id}/scan` | orders.manage | `{barcode, qty_milli?, lot_number?}` → `PickResult` |
| POST | `/orders/{id}/ready` | orders.manage | `{accept_partial?: bool, auto_pick?: bool}` (facultatif) → commande |
| POST | `/orders/{id}/delivery-note` | orders.manage | — → commande + `document_id`, `document_number` (BL) |
| POST | `/orders/{id}/ship` | orders.manage | `{note?}` (facultatif) → commande |
| POST | `/orders/{id}/deliver` | orders.manage | `{cod_amount?, payment_method?, receiver_name?, note?}` (facultatif) → commande + `payment_number` ("" si aucun) |
| POST | `/orders/{id}/invoice` | orders.manage | `{payment_method?}` (facultatif) → commande + `document_id`, `document_number` (facture) |
| POST | `/orders/{id}/cancel` | orders.manage (+ `void_document` si BL validé) | `{reason}` → commande |
| POST | `/orders/{id}/release-backorder` | orders.manage | `{line_ids?: []}` (facultatif) → commande |
| GET | `/orders/backorders` | orders.view | query `partner_id`, `product_id`, `rep_user_id`, `fulfillable=1` → `{items: BackorderRow[], total, fulfillable_count}` |
| POST | `/orders/backorders/new-order` | orders.manage | `{partner_id, line_ids?: []}` → **201** nouvelle commande |
| GET | `/products/{id}/waiting-customers` | orders.view | → `{product_id, product_name, stock_milli, total_backorder_milli, items: BackorderRow[]}` |
| POST | `/orders/import-web` | orders.manage | `WebOrderPayload` → **201** (créée) ou **200** (déjà importée) commande + `created`, `partner_created`, `warnings` |
| GET | `/orders/web-sync` | orders.view | → `{items: WebSyncItem[]}` |
| POST | `/orders/web-sync/ack` | orders.manage | `{items:[{id, status}]}` → `{cleared:int}` |

**Filtres de `GET /orders`** (tous facultatifs) : `status` (liste séparée par virgules), `partner_id`, `rep_user_id`,
`wilaya`, `route_id`, `source`, `warehouse_id`, `priority`, `from`, `to` (sur `order_date`, inclusifs),
`has_backorder=1`, `q` (n° commande, n° web, nom/téléphone client, téléphone de contact), `sort=priority`
(priorité desc puis date ; défaut date desc), `limit` (≤ 500, défaut 100), `offset`.
`counts` = nombre par statut avec **les mêmes filtres sauf `status`** (colonnes du kanban) ; `total` = nombre
avec tous les filtres.

**`OrderBody`** (POST/PUT /orders)

| Champ | Type | Défaut / règle |
|---|---|---|
| `partner_id` | string | **obligatoire** à la création ; client (`customer`/`both`). Modifiable seulement si `new`. |
| `source` | string | `manual` ; `web`/`portal` refusés (400) |
| `order_date` | date | aujourd'hui |
| `warehouse_id` | string | dépôt par défaut |
| `rep_user_id`? | string | fiche client ; `source: "rep"` sans valeur = l'utilisateur ; `""` = aucun |
| `route_id`? | string | fiche client |
| `priority` | int | 0 |
| `payment_mode` | string | `account` |
| `requested_date`? | date | |
| `delivery_address`?, `wilaya`?, `commune`?, `contact_name`?, `contact_phone`? | string | absent = fiche client (création) / inchangé (PUT) |
| `notes`, `internal_notes`, `promo_code` | string | |
| `shipping_fee`, `extra_discount` | int (centimes TTC) | 0 |
| `external_ref`?, `external_number`? | string | |
| `lines` | `OrderLineBody[]` | ≥ 1 à la création |

Au PUT, les champs scalaires non-pointeurs (`priority`, `notes`, `internal_notes`, `shipping_fee`, `extra_discount`,
`promo_code`, `payment_mode`, `order_date`, `warehouse_id`) sont **remplacés** : renvoyer la valeur actuelle.
Statuts modifiables : `new` et `validated`. Remplacer les lignes d'une commande `validated` la **repasse en `new`**
(à revalider). Refus 409 si des prélèvements existent.

**`OrderLineBody`** : `product_id` (string, obligatoire), `qty_milli` (int > 0), `unit_price`? (HT ; absent = prix
résolu), `discount_pct`? (absent = remise résolue), `qty_free_milli`? (absent = UG des promotions), `notes`.
Un `unit_price` différent du prix résolu exige `price_edit` (sinon 403 `needs_approval`), la ligne passe en
`price_source: "manual"` et sa remise résolue est ignorée. Une remise supérieure à la remise résolue exige
`discount`.

**Modification d'une ligne (PATCH)** : statuts `new`/`validated`. Sur une commande validée la nouvelle quantité est
revalidée immédiatement contre le disponible (le reste → reliquat). Changer `qty_milli` recalcule les UG des
promotions (sauf si `qty_free_milli` est fourni, ce qui exige `price_edit`).

**Substitution** : statuts `new`/`validated`/`preparing`, ligne sans prélèvement. L'ancienne ligne passe à 0, une
nouvelle ligne pointe vers elle (`substituted_from_line_id`, `substituted_from_product_id`), prix résolu pour le
nouveau produit (ou ancien prix avec `keep_price: true`, droit `price_edit`). Si la commande est validée la
nouvelle ligne est validée contre le disponible.

### 2.5 Validation (contrôle crédit, reliquat, quotas)

`ValidateBody` (facultatif) :

| Champ | Type | Sens |
|---|---|---|
| `override_credit` | bool | passer outre les alertes de compte ; exige `orders.override_credit` (sinon 403 `needs_approval`, action `orders.override_credit`) |
| `partial` | bool | défaut `true` : les manquants vont en reliquat. `false` : refus 409 « stock insuffisant : … » s'il manque quoi que ce soit |
| `lines` | `[{line_id, qty_validated_milli}]` | quantité validée imposée par ligne (0 ≤ q ≤ commandé) ; le reste → reliquat |

Ordre des contrôles (tout ou rien, dans une transaction) :
1. statut `new` ; au moins une ligne ;
2. disponible par produit → `qty_validated` = min(commandé, disponible), reste → `qty_backorder` ; services et
   réglage `allow_negative_stock = 1` : pas de limite ; rien de disponible du tout → 409 ;
3. UG recalculées sur la quantité validée (limitées au disponible restant) ;
4. **quotas** (non contournables) → 409 `quota dépassé pour « X » : 3 déjà commandé(s) cette semaine, maximum 5 par client — il reste 2` ;
5. **compte client** → alertes : client `crm_status = blocked` ; plafond (`credit_limit` du client, sinon réglage
   `default_credit_limit`) dépassé par solde + commandes ouvertes (`validated…delivered`) + cette commande ;
   factures échues impayées. S'il y a des alertes et pas `override_credit` → **409** `{error, warnings, needs_override: true}`.
   Avec `override_credit` : validée, `credit_override = true`, journal d'audit `order.credit_override`.

### 2.6 Préparation

**`PickingList`** (`GET /orders/{id}/picking-list`) : `{order: CustomerOrder (sans détail), lines: PickingLine[], picks: OrderPick[]}`.
Les lignes sont triées par **catégorie puis nom de produit** (les produits n'ont pas de champ emplacement).

`PickingLine` : `line_id`, `product_id`, `product_name`, `barcode`?, `category_name`, `brand`, `is_service`, `track_lots`,
`qty_validated_milli`, `qty_free_milli`, `qty_to_prepare_milli`, `qty_prepared_milli`, `qty_remaining_milli`,
`stock: [{warehouse_id, warehouse_name, qty_milli}]` (tous les dépôts actifs),
`lot_suggestions: [{lot_id, lot_number, expiry_date?, qty_available_milli, qty_suggested_milli}]` (FEFO, net des
préparations en cours ; vide si non suivi par lot), `orders?` (préparation groupée seulement :
`[{order_id, order_number, partner_name, line_id, qty_remaining_milli}]`).

**`PickResult`** (picks / scan) : `line_id`, `product_id`, `product_name`, `pick_ids: []`, `qty_milli` (ajouté),
`qty_prepared_milli`, `qty_to_prepare_milli`, `line_complete` (bool), `order_complete` (bool), `lots: [lot_number…]`.

Règles :
- un prélèvement fait passer `validated` → `preparing` (et `ready` sans BL → `preparing`) ;
- refus si préparé + qté > à préparer (409 « … de trop ») ;
- `lot_id` fourni : doit appartenir au produit et avoir le disponible (lot − préparations en cours) ;
- sans `lot_id` sur un produit suivi par lot/DLC : réparti FEFO sur les lots (le reliquat éventuel sans lot) ;
- **scan** : le code-barres est cherché dans `products.barcode`, `product_barcodes`, puis les codes carton
  (`packagings`, quantité = facteur du carton). Inconnu ou produit absent de la commande → **422**
  `wrong_product: true`. Produit déjà entièrement préparé ou quantité supérieure au reste → 409.
  `lot_number` facultatif (sinon FEFO).

`POST /orders/{id}/ready` (`validated|preparing` → `ready`) :
- `auto_pick: true` : prélève automatiquement le reste (FEFO, limité au stock du dépôt) — pour les magasins sans scan ;
- services : considérés préparés ;
- si une ligne est incomplète et `accept_partial` absent → 409 « préparation incomplète : … — confirmez pour mettre
  le manquant en reliquat » ; avec `accept_partial: true` : `qty_validated` = payant préparé, le manque payant
  s'ajoute à `qty_backorder`, les UG sont recalculées, `is_partial = true` ;
- rien de préparé → 409.

### 2.7 BL, expédition, livraison, facture, annulation

- **BL** (`POST /orders/{id}/delivery-note`, statut `ready`) : crée et **valide** un `DELIVERY_NOTE` (moteur de
  validation habituel : stock sorti par lot, contrôle stock négatif) — une ligne par lot prélevé pour la part
  payante, une ligne « (UG) » à 100 % de remise pour les gratuits, une ligne sans produit « Frais de livraison »
  (`shipping_fee`) et une ligne négative « Remise (code …) » (`extra_discount`). Idempotent : renvoie le BL existant.
  `qty_delivered_milli` = préparé.
- **Expédier** (`ready` → `shipping`) : génère le BL s'il manque.
- **Livrer** (`shipping|ready` → `delivered`) : génère le BL s'il manque. `cod_amount > 0` crée et valide un
  `PAYMENT_IN` (`payment_method` : `cash` défaut, `cib`, `edahabia`, `cheque`, `transfer`) au compte du client ;
  un seul encaissement par commande (409 sinon).
- **Facturer** (`delivered` → `invoiced`) : crée et valide une `SALE_INVOICE` qui reprend les lignes du BL avec
  `ref_document_id = BL` (le stock ne bouge pas une seconde fois). `payment_method` : `credit` par défaut (au compte,
  `due_date` = aujourd'hui + `payment_terms_days` du client, sinon réglage `default_payment_days`, 30 par défaut) ;
  `cash|cib|edahabia|cheque|transfer` possible **sauf** si un encaissement à la livraison existe (409).
- **Annuler** (`reason` obligatoire, 400 sinon) : depuis `new…shipping`. Si le BL est validé : contrepassation du BL
  (retour en stock) — exige `void_document` (sinon 403 `needs_approval` action `void_document`). Les arrêts de
  tournée en attente passent en échec, les reliquats sont annulés. `delivered`/`invoiced` → 409 (faire un avoir).

### 2.8 Reliquats

**`BackorderRow`** : `line_id`, `order_id`, `order_number`, `order_status`, `order_date`, `partner_id`,
`partner_name`, `partner_phone`, `product_id`, `product_name`, `warehouse_id`, `qty_backorder_milli`, `unit_price`,
`available_milli` (disponible restant avant cette ligne), `fulfillable_milli` (servable maintenant, premier arrivé
premier servi par ordre de date de commande).

- `GET /orders/backorders?fulfillable=1` → seulement les lignes servables maintenant.
- `POST /orders/{id}/release-backorder` : remet le reliquat **dans la même commande** (statut `validated` ou
  `preparing` seulement) dans la limite du disponible ; 409 si rien n'est disponible.
- `POST /orders/backorders/new-order` : crée une **nouvelle commande** (`new`, `source: manual`,
  `price_source: backorder`, mêmes prix/remises, `backorder_from_line_id`) avec tous les reliquats du client (ou les
  `line_ids` donnés) ; les lignes d'origine passent à reliquat 0.
- `GET /products/{id}/waiting-customers` : « qui attend ce produit » (à l'arrivée du stock).

### 2.9 Boutique web

**`WebOrderPayload`** (`POST /orders/import-web`, clés inconnues ignorées) :

| Champ | Type | Note |
|---|---|---|
| `id` | string | **obligatoire** — id boutique ; **clé d'idempotence** (`external_ref`) |
| `number` | string | n° affiché par la boutique (`external_number`) |
| `customer_name`, `phone`, `email`, `customer_type`, `business_name`, `nif`, `wilaya`, `commune`, `address`, `note` | string | |
| `items` | `[{product_id, name?, qty_milli? \| qty? (unités, décimal), price_centimes? (prix unitaire TTC affiché)}]` | ≥ 1 |
| `shipping_fee_centimes`, `discount_centimes` | int | → `shipping_fee`, `extra_discount` |
| `promo_code`, `created_at`, `total_centimes` | | `total_centimes` ≠ total calculé → avertissement |

Traitement : déjà importée (`source = web` + même `id`) → **200** avec `created: false`. Sinon :
1. client cherché par **téléphone normalisé** (`0XXXXXXXXX`, accepte `+213…`, `00213…`, espaces, points) dans
   `partners.phone`, `partners.whatsapp`, puis les contacts ; sinon **création** d'un client (`kind: customer`,
   nom = `business_name` sinon `customer_name`, `source: web`, `crm_status: active`, `client_type` déduit de
   `customer_type` : sup→`supermarket`, restau→`restaurant`, hôtel→`hotel`, gross→`wholesaler`, détail/commerce/pro→`retailer`,
   vide/particulier→`individual`) + contact principal = `customer_name` si raison sociale fournie ;
2. commande `source: web`, `payment_mode: cod`, prix = `price_centimes` converti en HT (`price_source: web`, remise 0),
   UG des promotions canal `all|web` ajoutées ; articles inconnus ignorés → `warnings` + note interne ; aucun article
   reconnu → 409.

Réponse : commande + `created` (bool), `partner_created` (bool), `warnings` (string[]).

**Synchro des statuts vers la boutique** : tout changement de statut d'une commande `web` met
`web_status_dirty = true`.
`GET /orders/web-sync` → `WebSyncItem` : `id`, `number`, `external_ref`, `external_number`, `status`, `status_label`,
`updated_at`, `cancel_reason`, `last_event_note`, `last_event_at`. Après l'envoi à la boutique :
`POST /orders/web-sync/ack {items:[{id, status}]}` ne remet le drapeau à `false` que si le statut n'a pas changé
entre-temps (`cleared` = nombre effacé).

---

## 3. Tarifs

### 3.1 Résolution du prix (`GET /pricing/resolve`)

Permission `orders.view | pricing.view`. Query : `product_id` (obligatoire), `partner_id`, `qty_milli` (défaut 1000),
`date` (défaut aujourd'hui), `channel` (`desk` défaut | `web`).
Réponse `{quote: PriceQuote, quotas: QuotaRow[]}`.

`PriceQuote` : `product_id`, `product_name`, `qty_milli`, `unit_price` (HT), `discount_pct`, `vat_rate`,
`price_source`, `special_price_id`?, `qty_free_milli`, `promo_rule_id`?, `promo_rule_name`?, `base_price_ttc`,
`line_ht`, `line_ttc`.

Ordre :
1. prix spécial **du client** (palier `min_qty_milli` le plus haut atteint, période valide) → `special_partner`, remise 0 ;
2. prix spécial **du groupe** du client → `special_group`, remise 0 ;
3. tarif : niveau du **groupe** s'il y en a un, sinon `partners.price_level` ; `wholesale` (si `price_wholesale` > 0)
   ou `retail` ; prix promo produit (`promo_price` dans ses dates et plus bas) → `promo` ; sinon remise du groupe ;
4. promotions actives (dates, canal `all|<canal>`, public `all` / `group` = groupe du client / `partner` = le client) :
   `qty_discount` → remise de la règle si qté ≥ N **et** supérieure à la remise acquise ; `free_goods` → UG =
   ⌊qté / N⌋ × M (règle la plus généreuse).

Canal d'une commande : `web` pour `source = web|portal`, sinon `desk`.

### 3.2 Prix spéciaux

| Méthode | Chemin | Permission | |
|---|---|---|---|
| GET | `/customer-prices` | pricing.view \| orders.view | query `partner_id`, `group_id`, `product_id`, `q` → `{items: CustomerPrice[]}` |
| POST | `/customer-prices` | pricing.edit | `CustomerPriceInput` → **201** `CustomerPrice` |
| PUT | `/customer-prices/{id}` | pricing.edit | `CustomerPriceInput` → `CustomerPrice` |
| DELETE | `/customer-prices/{id}` | pricing.edit | → `{deleted: id}` |

`CustomerPriceInput` : `partner_id`? **ou** `group_id`? (exactement un, 400 sinon), `product_id`, `price_ht` (≥ 0),
`min_qty_milli` (≥ 0), `start_date`?, `end_date`?, `notes`.
`CustomerPrice` = ces champs + `id`, `partner_name`?, `group_name`?, `product_name`, `created_at`, `updated_at`.

### 3.3 Promotions

| Méthode | Chemin | Permission | |
|---|---|---|---|
| GET | `/promo-rules` | pricing.view \| orders.view | query `active=1`, `product_id`, `type` → `{items: PromoRule[]}` |
| GET | `/promo-rules/web` | pricing.view \| orders.view \| webstore.view | règles à publier sur la boutique : actives aujourd'hui, `channel` `all|web`, `audience = all` → `{items, date}` |
| POST | `/promo-rules` | pricing.edit | `PromoInput` → **201** `PromoRule` |
| PUT | `/promo-rules/{id}` | pricing.edit | `PromoInput` → `PromoRule` |
| DELETE | `/promo-rules/{id}` | pricing.edit | → `{deleted}` |

`PromoInput` : `name` (obligatoire), `scope` (`product` → `product_id` requis | `category` → `category_id` |
`brand` → `brand` | `all`), `type` (`free_goods` → `free_qty_milli` > 0 | `qty_discount` → `discount_pct` 1–10000),
`min_qty_milli` (> 0, = N), `start_date`?, `end_date`?, `audience` (`all` défaut | `group` → `group_id` |
`partner` → `partner_id`), `channel` (`all` défaut | `desk` | `web`), `active` (bool, défaut true), `notes`.
`PromoRule` = ces champs (+ `product_name`?, `category_name`?, `id`, `created_at`, `updated_at`) et `label`
(« 10 + 1 gratuit(s) », « −7 % dès 20 »).

### 3.4 Quotas

| Méthode | Chemin | Permission | |
|---|---|---|---|
| GET | `/product-quotas` | pricing.view \| orders.view | query `product_id`, `partner_id` (inclut les quotas « tous clients ») → `{items: Quota[]}` |
| GET | `/product-quotas/usage` | pricing.view \| orders.view | query `partner_id` (obligatoire), `product_id` → `{items: QuotaRow[]}` |
| POST | `/product-quotas` | pricing.edit | `{product_id, partner_id? (absent = chaque client), max_qty_milli > 0, period: day|week|month, active?, notes}` → **201** `Quota` |
| PUT | `/product-quotas/{id}` | pricing.edit | idem → `Quota` |
| DELETE | `/product-quotas/{id}` | pricing.edit | → `{deleted}` |

`Quota` : `id`, `product_id`, `product_name`, `partner_id`?, `partner_name`?, `max_qty_milli`, `period`, `active`,
`notes`, `created_at`, `updated_at`.
`QuotaRow` : `id`, `product_id`, `product_name`, `partner_id` ("" = tous), `max_qty_milli`, `period`,
`period_start` (lundi pour `week`, 1er du mois pour `month`), `used_milli`, `remaining_milli`.
Consommation = quantités **validées** des commandes du client (hors `new`/`cancelled`) dont `order_date` ≥ début de
période. Un quota propre au client remplace le quota général de même période.

---

## 4. Livraisons

### 4.1 Véhicules — `deliveries.view` (GET) / `deliveries.manage`

`GET /vehicles` → `{items: Vehicle[]}` ; `POST /vehicles` → 201 ; `PUT /vehicles/{id}` ; `DELETE /vehicles/{id}` → `{deleted}`.
Corps : `{name (obligatoire), plate, capacity_kg (int), active?, notes}`.
`Vehicle` : `id`, `name`, `plate`, `capacity_kg`, `active`, `notes`, `created_at`, `updated_at`.

### 4.2 Tournées types (routes) — lecture `deliveries.view | orders.view | crm.view`, écriture `deliveries.manage`

`GET /delivery-routes` → `{items: DeliveryRoute[]}` ; `POST` → 201 ; `PUT /delivery-routes/{id}` ;
`DELETE /delivery-routes/{id}` (409 si utilisée par des clients, commandes ou tournées : la désactiver).
Corps : `{name (obligatoire, unique), wilayas: string[], communes: string[], weekdays: int[] (1 = lundi … 7),
default_driver_user_id?, default_driver_name, default_vehicle_id?, active?, notes}`.
`DeliveryRoute` = ces champs + `id`, `partners_count`, `ready_orders_count`, `created_at`, `updated_at`.
Le client porte `route_id` ; la commande l'hérite. Commandes prêtes d'une tournée : `GET /orders?status=ready&route_id=…`.

### 4.3 Tournées (runs)

Statuts : `planned` → `out` → `closed` ; `planned` → `cancelled`. Arrêts : `pending` → `delivered` | `partial` | `failed`.

| Méthode | Chemin | Permission | |
|---|---|---|---|
| GET | `/delivery-runs` | deliveries.view | query `from`, `to` (run_date), `status` (liste), `route_id`, `driver_user_id` → `{items: DeliveryRun[]}` (sans `stops`) |
| POST | `/delivery-runs` | deliveries.manage | `{run_date? (défaut aujourd'hui), route_id?, driver_user_id?, driver_name, vehicle_id?, notes, order_ids?: []}` → **201** `DeliveryRun` (chauffeur/véhicule par défaut de la tournée type) |
| GET | `/delivery-runs/{id}` | deliveries.view | → `DeliveryRun` avec `stops` |
| PUT | `/delivery-runs/{id}` | deliveries.manage | `{run_date (obligatoire), route_id?, driver_user_id?, driver_name, vehicle_id?, notes}` (planned/out) |
| POST | `/delivery-runs/{id}/stops` | deliveries.manage | `{order_ids: []}` — commandes `ready` ; si la tournée est `out`, elles partent aussitôt |
| PUT | `/delivery-runs/{id}/stops/order` | deliveries.manage | `{stop_ids: [] (ordre voulu)}` |
| PATCH | `/delivery-runs/{id}/stops/{stopId}` | deliveries.manage | `{cod_expected?, note?}` |
| DELETE | `/delivery-runs/{id}/stops/{stopId}` | deliveries.manage | arrêt `pending` d'une tournée ouverte ; la commande repasse `ready` si elle était partie |
| POST | `/delivery-runs/{id}/start` | deliveries.manage | `planned` → `out` ; chaque commande en attente passe `shipping` (BL généré). Erreur → 409 « commande CC-… : … » |
| POST | `/delivery-runs/{id}/stops/{stopId}/result` | deliveries.manage | `{status: delivered|partial|failed, failure_reason (obligatoire si failed), cod_collected (int ≥ 0), payment_method (cash défaut|cib|edahabia|cheque|transfer), receiver_name, note}` |
| POST | `/delivery-runs/{id}/close` | deliveries.manage | `{counted_cash?, notes?}` (facultatif) → `DeliveryRun` + `reconciliation` |
| POST | `/delivery-runs/{id}/cancel` | deliveries.manage | `planned` seulement ; arrêts supprimés |

Règles : une commande ne peut être que sur **une** tournée ouverte (409). `cod_expected` par défaut = total TTC de la
commande si `payment_mode = cod` (moins un encaissement déjà fait), sinon 0. Résultat `delivered`/`partial` → la
commande passe `delivered` (partial : `is_partial = true` ; les retours se font par avoir) ; **l'argent n'est
comptabilisé qu'à la clôture**. `failed` → la commande revient `ready` (événement `delivery_failed`), elle peut
repartir sur une autre tournée. Saisie de résultat seulement sur une tournée `out` (409 sinon) ; arrêt déjà soldé → 409.

**Clôture** : refusée (409) s'il reste des arrêts `pending`. Pour chaque arrêt avec `cod_collected > 0` : un
`PAYMENT_IN` validé au compte du client (`payment_id` sur l'arrêt et la commande). `reconciliation` :
`{cash_expected (Σ cod_expected des arrêts livrés/partiels), cash_collected, cash_difference (collecté − attendu),
counted_cash?, payments: [{stop_id, order_id, partner_id, amount, payment_method, document_id, number}]}`.

`DeliveryRun` : `id`, `run_date`, `route_id`?, `route_name`, `driver_user_id`?, `driver_name` (saisi, sinon nom de
l'utilisateur), `vehicle_id`?, `vehicle_name`, `status`, `departed_at`?, `closed_at`?, `cash_expected`,
`cash_collected`, `cash_difference`, `counted_cash`?, `notes`, `stops_count`, `pending_count`, `cod_expected_total`,
`cod_collected_total`, `created_at`, `updated_at`, `stops`? (détail).

`RunStop` : `id`, `order_id`, `order_number`, `order_status`, `partner_id`, `partner_name`, `partner_phone`,
`delivery_address`, `wilaya`, `commune`, `latitude`?, `longitude`? (float, fiche client), `total_ttc`,
`delivery_note_id`?, `delivery_note_number`?, `sequence`, `status`, `failure_reason`, `cod_expected`,
`cod_collected`, `payment_method`, `payment_id`?, `payment_number`?, `receiver_name`, `delivered_at`?, `note`.

---

## 5. CRM

### 5.1 Fiche client (routes existantes `GET/POST/PUT /partners`)

Nouveaux champs de `Partner` (réponse) : `client_type` (`supermarket|restaurant|hotel|wholesaler|retailer|individual|other`,
défaut `other`), `crm_status` (`prospect|active|dormant|blocked`, défaut `active`), `rep_user_id`?, `rep_name`,
`route_id`?, `route_name`, `wilaya`, `commune`, `latitude`? , `longitude`? (float), `opening_hours`, `license_no`,
`whatsapp`, `website`, `source` (`manual|web|import|rep|portal`), `payment_terms_days`? (int, null = défaut du
magasin), `tag_ids` (string[]). `email` existait déjà et est lu/écrit.

Entrée (POST/PUT) : mêmes noms, **tous facultatifs** ; absent = inchangé (PUT) / défaut (POST).
`rep_user_id: ""` / `route_id: ""` = aucun ; `payment_terms_days: -1` = défaut du magasin ; `tag_ids` remplace les
étiquettes. Valeurs invalides → 400. (Les champs historiques du PUT gardent leur sémantique « remplacement ».)

Nouveaux filtres de `GET /partners` : `client_type`, `crm_status`, `rep_user_id`, `route_id`, `wilaya`, `source`,
`tag_id` (+ restriction « own », §7).

| Méthode | Chemin | Permission | |
|---|---|---|---|
| GET | `/partners/{id}/credit` | orders.view \| crm.view \| partners.view | `{partner_id, balance, credit_limit (0 = aucun), open_orders_total, open_orders_count, available_credit? (null sans plafond), overdue_amount, overdue_count, crm_status, payment_terms_days}` |
| GET | `/partners/{id}/kpis` | crm.view \| partners.view | voir ci-dessous |
| GET | `/partners/{id}/timeline` | crm.view \| partners.view | query `limit` (≤ 200, défaut 50), `offset`, `kinds` (liste) → `{items: TimelineItem[], total, limit, offset}` |

**KPI** : `partner_id`, `turnover_30d`, `turnover_90d`, `turnover_365d` (TTC : tickets + factures − avoirs + BL non
facturés), `purchases_count_365d` (jours d'achat distincts), `avg_basket`, `order_frequency_days`? (float, écart moyen
entre achats), `last_order_date`?, `days_since_last_order` (-1 = jamais), `top_products: [{product_id, name,
qty_milli, amount}]` (10, sur 365 j), `payment_delay_avg_days`? (float, facture → règlement qui la solde, FIFO),
`balance`, `credit_limit`, `credit_usage_pct`, `overdue_amount`, `open_orders_count`, `open_orders_amount`,
`backorder_lines`, `backorder_qty_milli`.

**`TimelineItem`** (tri décroissant sur `at`) : `kind` (`order|order_event|document|payment|activity|task|message`),
`id`, `at`, `title`, `detail`, `amount`? (centimes), `ref_id`? (commande ou document lié), `status`, `sub_type`
(doc_type, type d'activité, canal, action…), `user_name`. Les événements de saisie/préparation (create, pick,
edit_line…) sont exclus.

### 5.2 Contacts, étiquettes, pièces

| Méthode | Chemin | Permission | |
|---|---|---|---|
| GET | `/partners/{id}/contacts` | crm.view \| partners.view | `{items: Contact[]}` (principal d'abord) |
| POST | `/partners/{id}/contacts` | crm.edit \| partners.edit | `{name (obligatoire), role, phone, whatsapp, email, is_primary, notes}` → 201 `Contact` |
| PUT | `/partner-contacts/{id}` | crm.edit \| partners.edit | idem → `Contact` |
| DELETE | `/partner-contacts/{id}` | crm.edit \| partners.edit | → `{deleted}` |
| GET | `/tags` | crm.view \| partners.view | `{items: [{id, name, colour, partners_count, created_at, updated_at}]}` |
| POST | `/tags` | crm.edit \| partners.edit | `{name (unique), colour ("#RRGGBB", défaut #00CC99)}` → 201 |
| PUT | `/tags/{id}` | crm.edit \| partners.edit | idem |
| DELETE | `/tags/{id}` | crm.edit \| partners.edit | → `{deleted}` |
| PUT | `/partners/{id}/tags` | crm.edit \| partners.edit | `{tag_ids: []}` → `Partner` |
| GET | `/partners/{id}/files` | crm.view \| partners.view | `{items: [{id, partner_id, kind, name, mime, size, expires_at?, expired (bool), notes, created_at}]}` |
| POST | `/partners/{id}/files?name=&kind=&expires_at=&notes=` | crm.edit \| partners.edit | **corps = fichier brut** (≤ 5 Mo, 413 au-delà) ; `kind` : `license|registre|nif|nis|contract|id|other` → 201 |
| GET | `/partners/{id}/files/{fid}` | crm.view \| partners.view | contenu binaire (`Content-Type`, `Content-Disposition`) |
| DELETE | `/partners/{id}/files/{fid}` | crm.edit \| partners.edit | → `{deleted}` |

`Contact` : `id`, `partner_id`, `name`, `role`, `phone`, `whatsapp`, `email`, `is_primary`, `notes`, `created_at`, `updated_at`.
Un seul contact principal par client (marquer un contact principal retire la marque des autres).

### 5.3 Activités

| Méthode | Chemin | Permission | |
|---|---|---|---|
| GET | `/crm/activities` | crm.view | query `partner_id`, `user_id` (`me` accepté), `type`, `order_id`, `from`, `to` (date ou horodatage), `limit`, `offset` → `{items: Activity[]}` (récent d'abord) |
| POST | `/crm/activities` | crm.edit | `ActivityInput` → 201 `Activity` |
| PUT | `/crm/activities/{id}` | crm.edit | `ActivityInput` |
| DELETE | `/crm/activities/{id}` | crm.edit | → `{deleted}` |

`ActivityInput` : `partner_id` (obligatoire), `type` (`call|visit|note|whatsapp|sms|email|meeting`), `outcome`,
`summary`, `at` (ISO, défaut maintenant), `duration_min` (int ≥ 0), `order_id`?, `document_id`?, `latitude`?,
`longitude`? (GPS de visite), `next_action`, `next_action_due`? (date : crée en plus une tâche `follow_up`
assignée à l'auteur, à la création seulement). L'auteur (`user_id`) = l'utilisateur connecté.
`Activity` : ces champs + `id`, `partner_name`, `user_id`?, `user_name`, `order_number`?, `created_at`, `updated_at`.

### 5.4 Tâches

| Méthode | Chemin | Permission | |
|---|---|---|---|
| GET | `/crm/tasks` | crm.view | query `assignee_id` (`me` \| `unassigned` \| id), `status` (`open` défaut \| `done` \| `cancelled` \| `all`), `partner_id`, `type`, `source`, `order_id`, `due` (`overdue` \| `today` \| `week`), `limit` (≤ 500, défaut 200) → `{items: Task[]}` (échéance croissante) |
| GET | `/crm/tasks/summary` | crm.view | query `assignee_id` (`me` \| id \| `all` défaut) → `{open, overdue, today, upcoming_7d}` |
| POST | `/crm/tasks` | crm.edit | `TaskInput` → 201 `Task` (sans `assignee_id` : l'utilisateur) |
| PUT | `/crm/tasks/{id}` | crm.edit | `TaskInput` (`assignee_id` absent = aucun) |
| POST | `/crm/tasks/{id}/complete` | crm.edit | `{result?}` → `Task` (409 si déjà close) |
| POST | `/crm/tasks/{id}/cancel` | crm.edit | `{result?}` → `Task` |
| POST | `/crm/tasks/generate` | crm.edit | `{inactive_days? (défaut réglage crm_inactive_days, 30), overdue?: bool, inactive?: bool, backorder?: bool}` (tous vrais par défaut) → `{created, by_source: {auto_overdue, auto_inactive, auto_backorder}, skipped, inactive_days}` |

`TaskInput` : `title` (obligatoire), `description`, `partner_id`?, `order_id`?, `assignee_id`?, `due_at`? (date ou
ISO), `priority` (0/1/2), `type` (`call|visit|collect_payment|follow_up|other`).
`Task` : `id`, `title`, `description`, `partner_id`?, `partner_name`?, `partner_phone`?, `order_id`?, `order_number`?,
`assignee_id`?, `assignee_name`, `due_at`?, `overdue` (bool), `priority`, `status`, `type`, `source`
(`manual|auto_overdue|auto_inactive|auto_backorder`), `auto_key`?, `completed_at`?, `completed_by`?, `result`,
`created_by`?, `created_at`, `updated_at`.

**Génération automatique** (idempotente : pas de nouvelle tâche si une tâche de même `auto_key` est ouverte ou a été
close depuis moins de 7 jours ; échéance = aujourd'hui) :
- factures échues → `collect_payment` priorité 1, assignée au commercial du client (`auto_key` `overdue:<partner>`) ;
- clients `crm_status = active` sans achat depuis N jours (et ayant déjà acheté) → `follow_up` (`inactive:<partner>`) ;
- ligne en reliquat devenue servable → `call` priorité 1 (`backorder:<line>`).

### 5.5 Segments

| Méthode | Chemin | Permission | |
|---|---|---|---|
| GET | `/crm/segments` | crm.view | `{items: [{id, name, builtin (bool), rules, created_at?, updated_at?}]}` (intégrés d'abord) |
| POST | `/crm/segments` | crm.edit | `{name (unique), rules: SegmentRules}` → 201 |
| PUT | `/crm/segments/{id}` | crm.edit | idem |
| DELETE | `/crm/segments/{id}` | crm.edit | → `{deleted}` |
| POST | `/crm/segments/evaluate` | crm.view | `{rules: SegmentRules}` → `SegmentResult` |
| GET | `/crm/segments/{id}/evaluate` | crm.view | id enregistré ou intégré ; query `client_type`, `tag_id`, `wilaya`, `rep_user_id`, `route_id`, `crm_status` surchargent les filtres → `SegmentResult` + `segment` |

Intégrés : `builtin:inactive_30`, `builtin:inactive_60`, `builtin:inactive_90`, `builtin:credit_80`,
`builtin:overdue`, `builtin:top_customers` (20 meilleurs, 90 j), `builtin:declining` (30 j vs 30 j précédents,
baisse ≥ 20 %), `builtin:new_customers` (créés depuis 30 j). « Par type / étiquette / wilaya / commercial /
tournée » = règles sans `builtin` avec le filtre voulu.

`SegmentRules` (tous facultatifs) : `builtin` (`inactive|credit_usage|overdue|top_customers|declining|new_customers`),
`days` (inactive/new, défaut 30), `min_pct` (credit_usage, défaut 80), `min_drop_pct` (declining, défaut 20), `limit`
(top, défaut 20), `period_days` (fenêtre du CA, défaut 90 ; 30 pour declining), filtres `client_type`, `crm_status`,
`tag_id`, `wilaya`, `rep_user_id`, `route_id`, `group_id`, `min_turnover`, `min_balance` (centimes).

`SegmentResult` : `{items: CustomerMetric[], count, period: {from, to}, rules, total_turnover, total_balance}`.
`CustomerMetric` : `partner_id`, `name`, `phone`, `client_type`, `crm_status`, `wilaya`, `rep_user_id`?, `rep_name`,
`route_id`?, `created_at`, `tag_ids`, `turnover` (TTC sur `period_days`), `turnover_previous` (période précédente),
`orders_count` (commandes sur la période), `last_order_date` ("" = jamais), `days_since_last_order` (-1 = jamais),
`balance`, `credit_limit`, `credit_usage_pct`, `overdue_amount`, `overdue_count`.
Seuls les clients actifs (`customer|both`) sont évalués, sans le client comptoir de la caisse.

### 5.6 Objectifs et performance des commerciaux

| Méthode | Chemin | Permission | |
|---|---|---|---|
| GET | `/crm/rep-targets?month=YYYY-MM` | crm.view | `{items: RepTarget[], month}` (un commercial restreint ne voit que les siens) |
| PUT | `/crm/rep-targets` | crm.edit (pas un rôle restreint « own ») | `{user_id, month, sales_target, orders_target, visits_target, new_customers_target, collections_target}` → `RepTarget` (créé ou remplacé) |
| GET | `/crm/reps/performance?month=YYYY-MM&user_id=` | crm.view | `{items: RepPerf[], month, from, to}` |

`RepTarget` : `id`, `user_id`, `user_name`, `month`, `sales_target` (centimes), `orders_target`, `visits_target`,
`new_customers_target`, `collections_target` (centimes), `updated_at`.
`RepPerf` : `user_id`, `name`, `month`, `sales` (TTC de ses commandes du mois hors new/annulées), `orders_count`,
`new_customers` (clients créés dans le mois avec lui comme commercial), `visits`, `calls` (activités), `collections`
(`PAYMENT_IN` validés du mois de ses clients), `customers` (portefeuille), `targets`? (`RepTarget`),
`achievement_pct` (`{sales, orders, visits, new_customers, collections}` en % entier, clé absente sans objectif).
Commerciaux listés : utilisateurs actifs ayant un objectif ce mois, un portefeuille ou des commandes comme commercial.

---

## 6. Messages (WhatsApp / SMS / e-mail)

| Méthode | Chemin | Permission | |
|---|---|---|---|
| GET | `/message-templates` | crm.view \| orders.view | query `code`, `channel`, `lang` → `{items: Template[]}` |
| POST | `/message-templates` | crm.edit | `TemplateInput` → 201 |
| PUT | `/message-templates/{id}` | crm.edit | `TemplateInput` |
| DELETE | `/message-templates/{id}` | crm.edit | 409 pour un modèle par défaut (`is_system`) |
| GET | `/messages/placeholders` | (connecté) | `{items: [{key, label}]}` |
| POST | `/messages/render` | crm.view \| orders.view | voir ci-dessous → `Rendered` |
| POST | `/messages/log` | crm.view \| orders.view | `{partner_id?, order_id?, channel, template_code, recipient, subject, body, status: prepared|sent}` → 201 `MessageLog` |
| GET | `/messages/log` | crm.view \| orders.view | query `partner_id`, `order_id`, `channel`, `status`, `limit` → `{items: MessageLog[]}` |
| POST | `/messages/send-email` | crm.edit \| orders.manage | `{partner_id?, order_id?, to? (défaut e-mail du client, puis d'un contact), subject, body, template_code}` → `MessageLog` ; SMTP non configuré → 409 `smtp_not_configured` ; refus SMTP → 502 (journalisé `failed`) |

`TemplateInput` : `code` (`[a-z0-9_]{2,40}`), `channel` (`whatsapp|sms|email`), `lang` (`fr` défaut | `ar`), `name`,
`subject` (e-mail), `body` (obligatoire), `active` (défaut true). Unique par (code, canal, langue) → 409.
`Template` = ces champs + `id`, `is_system`, `created_at`, `updated_at`.
Modèles fournis (français) — WhatsApp : `order_confirmed`, `order_ready`, `order_shipped`, `order_delivered`,
`payment_reminder`, `statement`, `backorder_available`, `promo` ; e-mail : `order_confirmed`, `payment_reminder`, `statement`.

**Rendu** (`POST /messages/render`) — corps : `template_id` **ou** `code` (+ `channel` défaut `whatsapp`, `lang`
défaut `fr`, repli sur le français) **ou** `body` libre (+ `subject`, `channel`) ; `partner_id`? (déduit de
`order_id`), `order_id`?, `extra`? (`{clé: valeur}` qui complète/remplace les variables).
Variables `{{…}}` : `client`, `contact`, `numero`, `reference_web`, `montant` (« 12 345,00 DA »), `solde`, `date`
(JJ/MM/AAAA), `date_commande`, `magasin` (réglage `company_name`), `telephone_magasin` (`company_phone`),
`lien_suivi` (réglage `order_tracking_url`, `{ref}` remplacé par la référence web ou le n° de commande), `produit`
(via `extra`), `promo` (offres web en cours, ou `extra`), `statut`.
`Rendered` : `channel`, `template_code`, `subject`, `body`, `recipient` (213… ou e-mail), `phone_intl` (`213XXXXXXXXX`
depuis `whatsapp` du client, sinon téléphone, sinon contact principal), `wa_link`
(`https://wa.me/<phone_intl>?text=<texte encodé>`, ou `https://wa.me/?text=…` sans numéro), `mailto`, `missing`
(variables non résolues, remplacées par du vide).
Flux conseillé WhatsApp : render → ouvrir `wa_link` → `POST /messages/log` (`prepared` ou `sent`).

`MessageLog` : `id`, `partner_id`?, `partner_name`?, `order_id`?, `order_number`?, `channel`, `template_code`,
`recipient`, `subject`, `body`, `status` (`prepared|sent|failed`), `error`, `user_id`?, `user_name`, `created_at`.

**SMTP** (Paramètres, `PUT /settings`) : `smtp_host`, `smtp_port` (défaut 587), `smtp_user`, `smtp_pass`, `smtp_from`
(défaut `smtp_user`), `smtp_security` (`starttls` défaut, `ssl` défaut si port 465, `none`). `GET /settings` ne
renvoie **jamais** `smtp_pass` mais `smtp_pass_set: "1"|"0"` ; ne pas renvoyer `smtp_pass` au PUT pour le garder.

---

## 7. Périmètre « own » (commerciaux)

Un rôle de périmètre `own` (table `roles.scope`) :
- **commandes** (`GET /orders`, détail, actions, reliquats, alertes) : seulement les commandes dont il est le
  commercial (`rep_user_id`), qu'il a créées, ou des clients dont il est le commercial — sauf `crm.all_customers` ;
- **clients**, si le rôle a `crm.view` et pas `crm.all_customers` : `GET /partners` ne montre que ses clients
  (`partners.rep_user_id` = lui) et tous les fournisseurs ; timeline, KPI, crédit, contacts, pièces, activités,
  segments, journal des messages et création de commande sont refusés (403) pour les clients des autres ;
- `GET /partners/{id}` reste accessible (choix d'un client sur les autres écrans) ;
- tâches : celles qui lui sont assignées ou qui concernent ses clients ;
- objectifs/performance : les siens uniquement.
Un rôle `warehouse` ne voit que les commandes de ses dépôts. L'administrateur voit tout.

---

## 8. Divers

- **Alertes** (`GET /alerts`) : nouveaux types `orders_new` (« N commande(s) client à valider », cible `orders`,
  si `orders.view`) et `tasks_overdue` (tâches en retard de l'utilisateur, cible `crm`, si `crm.view`).
- **Analyses** : nouvelle source `customer_orders` (vue `v_customer_order_lines`, une ligne par ligne de commande ;
  mesures `orders_count`, `amount_ttc`, `amount_ht`, `qty_ordered`, `qty_delivered`, `qty_backorder`, `fill_rate`
  (taux de service = validé/commandé), `customers_count`, `avg_order`, `lines_count`).
- **Réinitialisation « transactions »** : vide aussi commandes, prélèvements, tournées, arrêts et journal des messages.
- **Réglages lus** : `default_credit_limit`, `default_payment_days` (30), `crm_inactive_days` (30),
  `order_tracking_url`, `company_name`, `company_phone`, `allow_negative_stock`, `number_CUSTOMER_ORDER_*`, `smtp_*`.
- **Journal d'audit** : `order.create`, `order.import_web`, `order.credit_override`, `order.invoice`, `order.cancel`,
  `pricing.special_price`, `pricing.promo`, `pricing.quota`, `delivery_run.create`, `delivery_run.close`,
  `crm.tasks_generate`, `crm.rep_target`, `partner.file`, `partner.file_delete` (+ les actions des documents générés).

### Parcours type (desktop)

1. Saisie : `GET /pricing/resolve` (aperçu) + `GET /partners/{id}/credit` → `POST /orders`.
2. Validation : `POST /orders/{id}/validate` ; si 409 `needs_override` → afficher `warnings`, proposer « Valider quand
   même » → même appel avec `override_credit: true` (403 `needs_approval` → code du gérant).
3. Préparation : `GET /orders/{id}/picking-list` → scans `POST /orders/{id}/scan` (422 = mauvais produit) →
   `POST /orders/{id}/ready` (409 incomplet → confirmer avec `accept_partial: true`).
4. Livraison : tournée (`POST /delivery-runs`, `start`, `result`, `close`) ou `ship`/`deliver` direct.
5. `POST /orders/{id}/invoice`.
6. Web : boucle `GET /cloud/...` (boutique) → `POST /orders/import-web` pour chaque commande ; puis
   `GET /orders/web-sync` → pousser les statuts → `POST /orders/web-sync/ack`. Promotions à publier :
   `GET /promo-rules/web`.
