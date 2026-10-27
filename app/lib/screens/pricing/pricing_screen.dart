import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/commands.dart';
import '../../util/feedback.dart';
import '../../util/prefs.dart';
import '../../widgets/data_table.dart';
import '../../widgets/doc_editor.dart' show showPartnerPicker;
import '../../widgets/doc_list.dart' show DocChip, popToModuleRoot;
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import '../orders/order_common.dart';
import '../orders/product_pick.dart';
import 'pricing_forms.dart';

const _prefs = 'pricing';

String promoTypeLabel(String t) => t == 'free_goods' ? 'Unités gratuites' : 'Remise par quantité';
String periodLabel(String p) => switch (p) { 'day' => 'par jour', 'week' => 'par semaine', _ => 'par mois' };

String promoTarget(PromoRule r) => switch (r.scope) {
      'product' => r.productName ?? 'Produit',
      'category' => 'Catégorie ${r.categoryName ?? ''}',
      'brand' => 'Marque ${r.brand ?? ''}',
      _ => 'Tous les produits',
    };

String promoAudience(PromoRule r) => switch (r.audience) {
      'group' => 'Groupe ${r.groupName ?? ''}',
      'partner' => r.partnerName ?? 'Un client',
      _ => 'Tous les clients',
    };

String _dates(String? a, String? b) {
  if (a == null && b == null) return 'Toujours';
  if (a == null) return 'Jusqu’au ${frDate(b)}';
  if (b == null) return 'Depuis le ${frDate(a)}';
  return '${frDate(a)} → ${frDate(b)}';
}

/// « Tarifs et offres »: special prices (client / group), offers (free units,
/// quantity discount), quotas. Menu commands: `special` · `promos` ·
/// `quotas`. [product] narrows everything to one product (page opened from
/// a product). [client] does the same for one client (page opened from a
/// client).
class PricingScreen extends StatefulWidget {
  const PricingScreen({super.key, required this.api, required this.user, this.command, this.product, this.client});
  final ApiClient api;
  final User user;
  final ScreenCommand? command;
  final (String, String)? product;
  final (String, String)? client;

  @override
  State<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends State<PricingScreen> {
  ApiClient get api => widget.api;
  bool get _edit => widget.user.isAdmin || widget.user.can('pricing.edit');

  String _tab = 'special';
  final _search = TextEditingController();
  Timer? _debounce;
  late (String, String)? _product = widget.product;
  late (String, String)? _client = widget.client;
  String? _groupId;
  bool _activeOnly = true;

  List<CustomerGroup> _groups = const [];
  List<Category> _categories = const [];

  List<CustomerPrice> _prices = const [];
  List<PromoRule> _promos = const [];
  List<Quota> _quotas = const [];
  List<QuotaRow> _usage = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final t = UiPrefs.instance.get<String>(_prefs, 'tab');
    if (t == 'special' || t == 'promos' || t == 'quotas') _tab = t!;
    if (widget.client != null) _tab = 'special';
    widget.command?.addListener(_onCommand);
    _loadRefs();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCommand());
  }

  @override
  void didUpdateWidget(PricingScreen old) {
    super.didUpdateWidget(old);
    if (old.command != widget.command) {
      old.command?.removeListener(_onCommand);
      widget.command?.addListener(_onCommand);
    }
  }

  @override
  void dispose() {
    widget.command?.removeListener(_onCommand);
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onCommand() {
    final cmd = widget.command?.value;
    if (cmd == null || !mounted) return;
    widget.command!.done();
    if (!popToModuleRoot(context)) return;
    if (cmd == 'special' || cmd == 'promos' || cmd == 'quotas') _setTab(cmd);
  }

  Future<void> _loadRefs() async {
    try {
      final g = await api.customerGroups();
      if (mounted) setState(() => _groups = g);
    } catch (_) {}
    try {
      final c = await api.categories();
      if (mounted) setState(() => _categories = c);
    } catch (_) {}
  }

  void _setTab(String t) {
    setState(() => _tab = t);
    UiPrefs.instance.set(_prefs, 'tab', t);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      switch (_tab) {
        case 'special':
          final r = await api.customerPrices(
              partnerId: _client?.$1, groupId: _groupId, productId: _product?.$1, q: _search.text.trim());
          if (mounted) setState(() => _prices = r);
        case 'promos':
          final r = await api.promoRules(activeOnly: _activeOnly, productId: _product?.$1);
          if (mounted) setState(() => _promos = r);
        case 'quotas':
          final r = await api.quotas(productId: _product?.$1, partnerId: _client?.$1);
          List<QuotaRow> usage = const [];
          if (_client != null) usage = await api.quotaUsage(_client!.$1, productId: _product?.$1);
          if (mounted) {
            setState(() {
              _quotas = r;
              _usage = usage;
            });
          }
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Impossible de charger : $e';
        });
      }
    }
  }

  Future<void> _open(Widget page) async {
    final saved = await Navigator.of(context).push<Object>(MaterialPageRoute(builder: (_) => page));
    if (saved != null && mounted) _load();
  }

  void _new() => _open(switch (_tab) {
        'promos' => PromoFormPage(api: api, groups: _groups, categories: _categories, initialProduct: _product),
        'quotas' => QuotaFormPage(api: api, initialProduct: _product),
        _ => SpecialPriceFormPage(api: api, groups: _groups, initialProduct: _product, initialPartner: _client),
      });

  Future<void> _delete(String what, Future<void> Function() run) async {
    final ok = await confirmAction(context, title: 'Supprimer $what ?', confirmLabel: 'Supprimer', danger: true);
    if (!ok || !mounted) return;
    final done = await runGuarded(context, api, () async {
      await run();
      return true;
    });
    if (done == true && mounted) {
      showToast(context, 'Supprimé.');
      _load();
    }
  }

  Future<void> _pickProduct() async {
    if (_product != null) {
      setState(() => _product = null);
      _load();
      return;
    }
    final p = await pickProduct(context, api);
    if (p != null && mounted) {
      setState(() => _product = (p.id, p.name));
      _load();
    }
  }

  Future<void> _pickClient() async {
    if (_client != null) {
      setState(() => _client = null);
      _load();
      return;
    }
    final p = await showPartnerPicker(context, api, kind: 'customer');
    if (p != null && mounted) {
      setState(() => _client = (p.id, p.name));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = switch (_tab) {
      'promos' => 'Nouvelle offre',
      'quotas' => 'Nouveau quota',
      _ => 'Nouveau prix spécial',
    };
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeader(
          title: widget.product != null
              ? 'Tarifs et offres — ${widget.product!.$2}'
              : widget.client != null
                  ? 'Tarifs et offres — ${widget.client!.$2}'
                  : 'Tarifs et offres',
          primaryLabel: _edit ? label : null,
          onPrimary: _new,
          more: [MenuEntry('Actualiser', Icons.refresh_rounded, _load)],
        ),
        const SizedBox(height: 14),
        Row(children: [
          FilterPill(label: 'Prix spéciaux', icon: Icons.sell_outlined, active: _tab == 'special', onTap: () => _setTab('special')),
          FilterPill(
              label: 'Offres et UG', icon: Icons.card_giftcard_outlined, active: _tab == 'promos', onTap: () => _setTab('promos')),
          FilterPill(label: 'Quotas', icon: Icons.production_quantity_limits_rounded, active: _tab == 'quotas', onTap: () => _setTab('quotas')),
        ]),
        const SizedBox(height: 12),
        ListToolbar(
          search: _tab == 'special' ? _search : null,
          searchHint: 'Produit ou client…',
          onSearchChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), _load);
          },
          quickFilters: [
            if (widget.product == null)
              FilterPill(
                  label: _product == null ? 'Choisir un produit' : 'Produit : ${_product!.$2}',
                  icon: Icons.inventory_2_outlined,
                  active: _product != null,
                  onTap: _pickProduct),
            if (_tab != 'promos' && widget.client == null)
              FilterPill(
                  label: _client == null
                      ? (_tab == 'quotas' ? 'Voir la consommation d’un client' : 'Choisir un client')
                      : 'Client : ${_client!.$2}',
                  icon: Icons.person_search_outlined,
                  active: _client != null,
                  onTap: _pickClient),
            if (_tab == 'promos')
              FilterPill(
                  label: 'Actives aujourd’hui',
                  active: _activeOnly,
                  onTap: () {
                    setState(() => _activeOnly = !_activeOnly);
                    _load();
                  }),
          ],
          panel: _tab == 'special' && _groups.isNotEmpty
              ? FilterPanel(fields: [
                  FilterField<String>(
                    label: 'Groupe de clients',
                    value: _groupId,
                    options: [for (final g in _groups) (g.id, g.name)],
                    onChanged: (v) {
                      setState(() => _groupId = v);
                      _load();
                    },
                  ),
                ])
              : null,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: switch (_tab) {
            'promos' => _promosList(),
            'quotas' => _quotasView(),
            _ => _pricesList(),
          },
        ),
      ]),
    );
  }

  Widget _pricesList() => DataListView<CustomerPrice>(
        items: _prices,
        prefsKey: 'pricing_special',
        loading: _loading,
        error: _error,
        onRetry: _load,
        rowId: (p) => p.id,
        onTap: _edit ? (p) => _open(SpecialPriceFormPage(api: api, existing: p, groups: _groups)) : null,
        exportTitle: 'Prix spéciaux',
        exportBaseName: 'prix-speciaux',
        rowMenu: (p) => [
          if (_edit) RowAction('Modifier', Icons.edit_outlined, (p) => _open(SpecialPriceFormPage(api: api, existing: p, groups: _groups))),
          if (_edit) RowAction('Supprimer', Icons.delete_outline_rounded, (p) => _delete('ce prix spécial', () => api.deleteCustomerPrice(p.id)), danger: true),
        ],
        empty: EmptyState(
          icon: Icons.sell_outlined,
          text: 'Aucun prix spécial. Un prix spécial remplace le tarif normal pour un client ou un groupe.',
          actions: [if (_edit) ('Nouveau prix spécial', _new)],
        ),
        columns: [
          ColumnSpec(
            id: 'who',
            label: 'Client / groupe',
            flex: 3,
            hideable: false,
            sortKey: (p) => p.who.toLowerCase(),
            exportValue: (p) => p.who,
            cell: (_, p) => Row(children: [
              Icon(p.groupId != null ? Icons.groups_outlined : Icons.person_outline_rounded, size: 16, color: T.muted),
              const SizedBox(width: 6),
              Flexible(child: Text(p.who, style: T.body, overflow: TextOverflow.ellipsis)),
            ]),
          ),
          ColumnSpec(
            id: 'product',
            label: 'Produit',
            flex: 3,
            sortKey: (p) => p.productName.toLowerCase(),
            exportValue: (p) => p.productName,
            cell: (_, p) => Text(p.productName, style: T.body, overflow: TextOverflow.ellipsis),
          ),
          ColumnSpec(
            id: 'price',
            label: 'Prix HT',
            width: 130,
            numeric: true,
            sortKey: (p) => p.priceHT,
            exportValue: (p) => p.priceHT / 100,
            cell: (_, p) => Text(fmtDA(p.priceHT), style: T.monoBody.copyWith(fontWeight: FontWeight.w700)),
          ),
          ColumnSpec(
            id: 'min',
            label: 'Dès',
            width: 80,
            numeric: true,
            sortKey: (p) => p.minQtyMilli,
            exportValue: (p) => p.minQtyMilli / 1000,
            cell: (_, p) => Text(p.minQtyMilli > 0 ? fmtQty(p.minQtyMilli) : '1', style: T.monoSmall),
          ),
          ColumnSpec(
            id: 'dates',
            label: 'Validité',
            flex: 2,
            exportValue: (p) => _dates(p.startDate, p.endDate),
            cell: (_, p) => Text(_dates(p.startDate, p.endDate), style: T.small),
          ),
        ],
      );

  Widget _promosList() => DataListView<PromoRule>(
        items: _promos,
        prefsKey: 'pricing_promos',
        loading: _loading,
        error: _error,
        onRetry: _load,
        rowId: (p) => p.id,
        onTap: _edit ? (p) => _open(PromoFormPage(api: api, existing: p, groups: _groups, categories: _categories)) : null,
        exportTitle: 'Offres',
        exportBaseName: 'offres',
        rowMenu: (p) => [
          if (_edit)
            RowAction('Modifier', Icons.edit_outlined,
                (p) => _open(PromoFormPage(api: api, existing: p, groups: _groups, categories: _categories))),
          if (_edit) RowAction('Supprimer', Icons.delete_outline_rounded, (p) => _delete('l’offre « ${p.name} »', () => api.deletePromoRule(p.id)), danger: true),
        ],
        empty: EmptyState(
          icon: Icons.card_giftcard_outlined,
          text: _activeOnly ? 'Aucune offre active aujourd’hui.' : 'Aucune offre.',
          actions: [if (_edit) ('Nouvelle offre', _new)],
        ),
        columns: [
          ColumnSpec(
            id: 'name',
            label: 'Offre',
            flex: 3,
            hideable: false,
            sortKey: (p) => p.name.toLowerCase(),
            exportValue: (p) => p.name,
            cell: (_, p) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Flexible(child: Text(p.name, style: T.body.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                if (!p.active) ...[const SizedBox(width: 6), const DocChip(label: 'Inactive', bg: T.cream, fg: T.muted)],
              ]),
              Text(p.label.isEmpty ? promoTypeLabel(p.type) : p.label, style: T.small.copyWith(color: T.mintDark, fontWeight: FontWeight.w700)),
            ]),
          ),
          ColumnSpec(
            id: 'target',
            label: 'Produits',
            flex: 3,
            exportValue: promoTarget,
            cell: (_, p) => Text(promoTarget(p), style: T.body, overflow: TextOverflow.ellipsis),
          ),
          ColumnSpec(
            id: 'audience',
            label: 'Clients',
            flex: 2,
            exportValue: promoAudience,
            cell: (_, p) => Text(promoAudience(p), style: T.small),
          ),
          ColumnSpec(
            id: 'channel',
            label: 'Canal',
            width: 120,
            exportValue: (p) => p.channel,
            cell: (_, p) => Text(switch (p.channel) { 'desk' => 'Bureau', 'web' => 'Web', _ => 'Partout' }, style: T.small),
          ),
          ColumnSpec(
            id: 'dates',
            label: 'Validité',
            flex: 2,
            exportValue: (p) => _dates(p.startDate, p.endDate),
            cell: (_, p) => Text(_dates(p.startDate, p.endDate), style: T.small),
          ),
        ],
      );

  Widget _quotasView() {
    final list = DataListView<Quota>(
      items: _quotas,
      prefsKey: 'pricing_quotas',
      loading: _loading,
      error: _error,
      onRetry: _load,
      rowId: (q) => q.id,
      onTap: _edit ? (q) => _open(QuotaFormPage(api: api, existing: q)) : null,
      exportTitle: 'Quotas',
      exportBaseName: 'quotas',
      rowMenu: (q) => [
        if (_edit) RowAction('Modifier', Icons.edit_outlined, (q) => _open(QuotaFormPage(api: api, existing: q))),
        if (_edit) RowAction('Supprimer', Icons.delete_outline_rounded, (q) => _delete('ce quota', () => api.deleteQuota(q.id)), danger: true),
      ],
      empty: EmptyState(
        icon: Icons.production_quantity_limits_rounded,
        text: 'Aucun quota. Un quota limite la quantité d’un produit rare par client.',
        actions: [if (_edit) ('Nouveau quota', _new)],
      ),
      columns: [
        ColumnSpec(
          id: 'product',
          label: 'Produit',
          flex: 3,
          hideable: false,
          sortKey: (q) => q.productName.toLowerCase(),
          exportValue: (q) => q.productName,
          cell: (_, q) => Row(children: [
            Flexible(child: Text(q.productName, style: T.body, overflow: TextOverflow.ellipsis)),
            if (!q.active) ...[const SizedBox(width: 6), const DocChip(label: 'Inactif', bg: T.cream, fg: T.muted)],
          ]),
        ),
        ColumnSpec(
          id: 'client',
          label: 'Client',
          flex: 2,
          exportValue: (q) => q.partnerName ?? 'Chaque client',
          cell: (_, q) => Text(q.partnerName ?? 'Chaque client', style: T.small),
        ),
        ColumnSpec(
          id: 'max',
          label: 'Maximum',
          width: 170,
          numeric: true,
          sortKey: (q) => q.maxQtyMilli,
          exportValue: (q) => q.maxQtyMilli / 1000,
          cell: (_, q) => Text('${fmtQty(q.maxQtyMilli)} ${periodLabel(q.period)}', style: T.monoBody),
        ),
      ],
    );
    if (_client == null) return list;
    return Column(children: [
      Expanded(flex: 3, child: list),
      const SizedBox(height: 12),
      Expanded(
        flex: 2,
        child: Card14(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Consommation de ${_client!.$2} (période en cours)', style: T.h2),
            const SizedBox(height: 10),
            Expanded(
              child: _usage.isEmpty
                  ? Text('Aucun quota ne concerne ce client.', style: T.bodyMuted)
                  : ListView(children: [
                      for (final u in _usage)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            Expanded(flex: 3, child: Text(u.productName, style: T.body)),
                            SizedBox(width: 200, child: Text('depuis le ${frDate(u.periodStart)}', style: T.small)),
                            SizedBox(
                              width: 220,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: u.maxQtyMilli == 0 ? 0 : (u.usedMilli / u.maxQtyMilli).clamp(0.0, 1.0),
                                  minHeight: 8,
                                  color: u.remainingMilli <= 0 ? T.danger : T.mint,
                                  backgroundColor: T.border2,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: 220,
                              child: Text(
                                  '${fmtQty(u.usedMilli)} / ${fmtQty(u.maxQtyMilli)} — reste ${fmtQty(u.remainingMilli)}',
                                  textAlign: TextAlign.end,
                                  style: T.monoSmall.copyWith(color: u.remainingMilli <= 0 ? T.dangerDark : T.ink)),
                            ),
                          ]),
                        ),
                    ]),
            ),
          ]),
        ),
      ),
    ]);
  }
}
