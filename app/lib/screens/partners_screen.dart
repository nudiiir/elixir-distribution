import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/crm_api.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/analysis_links.dart';
import '../util/commands.dart';
import '../util/prefs.dart';
import '../widgets/data_table.dart';
import '../widgets/doc_editor.dart';
import '../widgets/doc_list.dart' show DocChip, popToModuleRoot;
import '../widgets/list_toolbar.dart';
import '../widgets/ui.dart';
import 'crm/bulk_actions.dart';
import 'crm/crm_common.dart';
import 'crm/send_message.dart';
import 'crm/tags_page.dart';
import 'partners/partner_pages.dart';

const _prefs = 'partners';

/// Clients et fournisseurs: list → detail page → edit page.
/// Menu commands: `kind:customer` · `kind:supplier` · `new:customer` ·
/// `new:supplier`.
class PartnersScreen extends StatefulWidget {
  const PartnersScreen({super.key, required this.api, this.command});
  final ApiClient api;
  final ScreenCommand? command;

  @override
  State<PartnersScreen> createState() => _PartnersScreenState();
}

class _PartnersScreenState extends State<PartnersScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  String? _kind; // null | customer | supplier
  String? _balance; // null | any | owes_us | we_owe
  List<Partner> _items = const [];
  bool _loading = true;
  String? _error;

  // Filtres distribution / CRM (côté serveur, périmètre « own » respecté).
  String? _clientType;
  String? _crmStatus;
  String? _repId;
  String? _wilaya;
  String? _routeId;
  String? _tagId;
  List<CrmUser> _users = const [];
  List<CrmRoute> _routes = const [];
  List<CrmTag> _tags = const [];
  static const _pageSize = 500;
  bool _more = false; // the server may have more rows

  bool get _crm => crmView(widget.api);

  @override
  void initState() {
    super.initState();
    final k = UiPrefs.instance.get<String>(_prefs, 'kind');
    _kind = k == 'customer' || k == 'supplier' ? k : null;
    final b = UiPrefs.instance.get<String>(_prefs, 'balance');
    _balance = const ['any', 'owes_us', 'we_owe'].contains(b) ? b : null;
    _clientType = UiPrefs.instance.get<String>(_prefs, 'client_type');
    _crmStatus = UiPrefs.instance.get<String>(_prefs, 'crm_status');
    _wilaya = UiPrefs.instance.get<String>(_prefs, 'wilaya');
    widget.command?.addListener(_onCommand);
    if (widget.command?.value == null) _load();
    _loadLookups();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCommand());
  }

  @override
  void didUpdateWidget(PartnersScreen old) {
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
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onCommand() {
    final cmd = widget.command?.value;
    if (cmd == null || !mounted) return;
    widget.command!.done();
    if (!popToModuleRoot(context)) return;
    switch (cmd) {
      case 'kind:customer':
        _setKind('customer');
      case 'kind:supplier':
        _setKind('supplier');
      case 'new:customer':
        _setKind('customer');
        _create('customer');
      case 'new:supplier':
        _setKind('supplier');
        _create('supplier');
      default:
        _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _fetch(0);
      if (mounted) {
        setState(() {
          _items = items;
          _more = items.length >= _pageSize;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Impossible de charger la liste : $e';
        });
      }
    }
  }

  Future<List<Partner>> _fetch(int offset) => widget.api.crmPartners(
        q: _searchCtrl.text.trim(),
        kind: _kind,
        clientType: _clientType,
        crmStatus: _crmStatus,
        repUserId: _repId,
        wilaya: _wilaya,
        routeId: _routeId,
        tagId: _tagId,
        limit: _pageSize,
        offset: offset,
      );

  Future<void> _loadMore() async {
    setState(() => _loading = true);
    try {
      final more = await _fetch(_items.length);
      if (mounted) {
        setState(() {
          _items = [..._items, ...more];
          _more = more.length >= _pageSize;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Impossible de charger la suite : $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadLookups() async {
    CrmDirectory.users(widget.api).then((u) {
      if (mounted) setState(() => _users = u);
    }).catchError((_) {});
    CrmDirectory.routes(widget.api).then((r) {
      if (mounted) setState(() => _routes = r);
    });
    CrmDirectory.tags(widget.api, refresh: true).then((t) {
      if (mounted) setState(() => _tags = t);
    });
  }

  void _setCrm(void Function() change, [String? prefKey, String? value]) {
    setState(change);
    if (prefKey != null) UiPrefs.instance.set(_prefs, prefKey, value);
    _load();
  }

  void _clearAll() {
    _searchCtrl.clear();
    _balance = null;
    for (final k in ['balance', 'kind', 'client_type', 'crm_status', 'wilaya']) {
      UiPrefs.instance.set(_prefs, k, null);
    }
    _setCrm(() {
      _kind = null;
      _clientType = null;
      _crmStatus = null;
      _repId = null;
      _wilaya = null;
      _routeId = null;
      _tagId = null;
    });
  }

  List<ActiveFilter> get _activeFilters => [
        if (_clientType != null)
          ActiveFilter('Type : ${clientTypeLabels[_clientType] ?? _clientType}',
              () => _setCrm(() => _clientType = null, 'client_type', null)),
        if (_crmStatus != null)
          ActiveFilter('Statut : ${crmStatusLabels[_crmStatus] ?? _crmStatus}',
              () => _setCrm(() => _crmStatus = null, 'crm_status', null)),
        if (_repId != null)
          ActiveFilter('Commercial : ${_users.where((u) => u.id == _repId).firstOrNull?.name ?? '…'}',
              () => _setCrm(() => _repId = null)),
        if (_wilaya != null)
          ActiveFilter('Wilaya : ${wilayaLabel(_wilaya!)}', () => _setCrm(() => _wilaya = null, 'wilaya', null)),
        if (_routeId != null)
          ActiveFilter('Tournée : ${_routes.where((r) => r.id == _routeId).firstOrNull?.name ?? '…'}',
              () => _setCrm(() => _routeId = null)),
        if (_tagId != null)
          ActiveFilter('Étiquette : ${_tags.where((t) => t.id == _tagId).firstOrNull?.name ?? '…'}',
              () => _setCrm(() => _tagId = null)),
      ];

  List<BulkClient> _bulk(List<Partner> rows) => [
        for (final p in rows)
          if (p.kind != 'supplier') BulkClient(id: p.id, name: p.name, tagIds: p.tagIds, repUserId: p.repUserId),
      ];

  List<BulkAction<Partner>> get _bulkActions => [
        if (_crm && crmCan(widget.api, 'partners.edit'))
          BulkAction('Attribuer un commercial', Icons.badge_outlined, (rows) async {
            final done = await bulkAssignRep(context, widget.api, _bulk(rows));
            if (done) _load();
            return done;
          }),
        if (crmEditFiche(widget.api))
          BulkAction('Ajouter une étiquette', Icons.sell_outlined, (rows) async {
            final done = await bulkAddTag(context, widget.api, _bulk(rows));
            if (done) _load();
            return done;
          }),
        if (crmEdit(widget.api))
          BulkAction('Créer une tâche', Icons.add_task_rounded,
              (rows) => bulkCreateTasks(context, widget.api, _bulk(rows))),
        if (_crm)
          BulkAction('Message WhatsApp', Icons.chat_outlined, (rows) async {
            await bulkWhatsApp(context, widget.api, _bulk(rows));
            return false;
          }),
      ];

  void _setKind(String? k) {
    setState(() => _kind = k);
    UiPrefs.instance.set(_prefs, 'kind', k);
    _load();
  }

  void _setBalance(String? b) {
    setState(() => _balance = b);
    UiPrefs.instance.set(_prefs, 'balance', b);
  }

  List<Partner> get _visible => switch (_balance) {
        'any' => _items.where((p) => p.balance != 0).toList(),
        'owes_us' => _items.where((p) => p.balance > 0).toList(),
        'we_owe' => _items.where((p) => p.balance < 0).toList(),
        _ => _items,
      };

  String get _newKind => _kind == 'supplier' ? 'supplier' : 'customer';
  String get _title => switch (_kind) {
        'customer' => 'Clients',
        'supplier' => 'Fournisseurs',
        _ => 'Clients et fournisseurs',
      };

  Future<void> _create(String kind) async {
    final saved = await openPartnerForm(context, widget.api, kind: kind);
    if (saved == null || !mounted) return;
    _load();
    await openPartnerDetail(context, widget.api, saved);
    if (mounted) _load();
  }

  Future<void> _open(Partner p) async {
    await openPartnerDetail(context, widget.api, p);
    if (mounted) _load();
  }

  Future<void> _edit(Partner p) async {
    final saved =
        await openPartnerForm(context, widget.api, existing: p, kind: p.kind);
    if (saved != null && mounted) _load();
  }

  Future<void> _pay(Partner p, {required bool outgoing}) async {
    if (await showPartnerPaymentDialog(context, widget.api, p,
        outgoing: outgoing)) {
      _load();
    }
  }

  Future<void> _newDoc(Partner p, DocEditorConfig cfg) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) =>
          DocEditorScreen(api: widget.api, config: cfg, initialPartner: p),
    ));
    if (changed == true) _load();
  }

  List<RowAction<Partner>> _rowMenu(Partner p) => [
        RowAction('Ouvrir', Icons.open_in_new_rounded, _open),
        RowAction('Modifier', Icons.edit_outlined, _edit),
        if (p.kind != 'supplier' && (_crm || crmCan(widget.api, 'orders.view')))
          RowAction('Envoyer un message', Icons.chat_outlined,
              (p) => showSendMessagePanel(context, widget.api, partnerId: p.id, partnerName: p.name)),
        if (p.kind != 'supplier')
          RowAction('Encaisser', Icons.payments_outlined,
              (p) => _pay(p, outgoing: false)),
        if (p.kind != 'customer')
          RowAction(
              'Payer', Icons.payments_outlined, (p) => _pay(p, outgoing: true)),
        if (p.kind != 'supplier')
          RowAction('Nouvelle facture', Icons.note_add_outlined,
              (p) => _newDoc(p, saleInvoiceConfig)),
        if (p.kind != 'customer')
          RowAction('Nouveau bon de réception', Icons.move_to_inbox_outlined,
              (p) => _newDoc(p, purchaseReceiptConfig)),
      ];

  @override
  Widget build(BuildContext context) {
    final searching = _searchCtrl.text.trim().isNotEmpty;
    final filtered = searching || _kind != null || _balance != null || _activeFilters.isNotEmpty;
    final newLabel =
        _newKind == 'supplier' ? 'Nouveau fournisseur' : 'Nouveau client';
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: _title,
            primaryLabel: newLabel,
            primaryIcon: Icons.person_add_alt_1_outlined,
            onPrimary: () => _create(_newKind),
            more: [
              if (_newKind == 'supplier')
                MenuEntry('Nouveau client', Icons.person_add_alt_outlined,
                    () => _create('customer'))
              else
                MenuEntry('Nouveau fournisseur',
                    Icons.store_mall_directory_outlined,
                    () => _create('supplier')),
              if (_kind != 'supplier')
                MenuEntry('Gérer les étiquettes', Icons.sell_outlined, () async {
                  if (await openTagsPage(context, widget.api)) _loadLookups();
                }),
              if (AnalysisLinks.available)
                MenuEntry('Analyser : qui vous doit', Icons.insights_rounded,
                    () => AnalysisLinks.launch(AnalysisLinks.receivables())),
            ],
          ),
          const SizedBox(height: 16),
          ListToolbar(
            search: _searchCtrl,
            searchHint: 'Rechercher par nom ou téléphone…',
            onSearchChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 250), _load);
            },
            quickFilters: [
              FilterPill(
                  label: 'Clients',
                  active: _kind == 'customer',
                  onTap: () =>
                      _setKind(_kind == 'customer' ? null : 'customer')),
              FilterPill(
                  label: 'Fournisseurs',
                  active: _kind == 'supplier',
                  onTap: () =>
                      _setKind(_kind == 'supplier' ? null : 'supplier')),
              FilterPill(
                  label: 'Avec un solde',
                  icon: Icons.account_balance_wallet_outlined,
                  active: _balance != null,
                  onTap: () => _setBalance(_balance == null ? 'any' : null)),
            ],
            panel: Wrap(spacing: 14, runSpacing: 12, children: [
              FilterField<String>(
                label: 'Type',
                value: _kind,
                allLabel: 'Clients et fournisseurs',
                width: 240,
                options: const [
                  ('customer', 'Clients'),
                  ('supplier', 'Fournisseurs'),
                ],
                onChanged: _setKind,
              ),
              FilterField<String>(
                label: 'Solde',
                value: _balance,
                allLabel: 'Tous',
                width: 240,
                options: const [
                  ('any', 'Avec un solde'),
                  ('owes_us', 'Ils vous doivent'),
                  ('we_owe', 'Vous leur devez'),
                ],
                onChanged: _setBalance,
              ),
              if (_kind != 'supplier') ...[
                FilterField<String>(
                  label: 'Type de client',
                  value: _clientType,
                  options: [for (final e in clientTypeLabels.entries) (e.key, e.value)],
                  onChanged: (v) => _setCrm(() => _clientType = v, 'client_type', v),
                ),
                FilterField<String>(
                  label: 'Statut',
                  value: _crmStatus,
                  options: [for (final e in crmStatusLabels.entries) (e.key, e.value)],
                  onChanged: (v) => _setCrm(() => _crmStatus = v, 'crm_status', v),
                ),
                if (_users.isNotEmpty)
                  FilterField<String>(
                    label: 'Commercial',
                    value: _repId,
                    options: [for (final u in _users) (u.id, u.name)],
                    onChanged: (v) => _setCrm(() => _repId = v),
                  ),
                FilterField<String>(
                  label: 'Wilaya',
                  value: _wilaya,
                  allLabel: 'Toutes',
                  options: [for (final (c, n) in wilayas) (n, '$c · $n')],
                  onChanged: (v) => _setCrm(() => _wilaya = v, 'wilaya', v),
                ),
                if (_routes.isNotEmpty)
                  FilterField<String>(
                    label: 'Tournée',
                    value: _routeId,
                    allLabel: 'Toutes',
                    options: [for (final r in _routes) (r.id, r.name)],
                    onChanged: (v) => _setCrm(() => _routeId = v),
                  ),
                if (_tags.isNotEmpty)
                  FilterField<String>(
                    label: 'Étiquette',
                    value: _tagId,
                    allLabel: 'Toutes',
                    options: [for (final t in _tags) (t.id, t.name)],
                    onChanged: (v) => _setCrm(() => _tagId = v),
                  ),
              ],
            ]),
            active: _activeFilters,
            onClearAll: _clearAll,
          ),
          if (_more)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                Text('Les ${_items.length} premiers sont affichés.', style: T.small),
                TextButton(onPressed: _loading ? null : _loadMore, child: const Text('Charger les suivants')),
              ]),
            ),
          const SizedBox(height: 14),
          Expanded(
            child: DataListView<Partner>(
              items: _visible,
              prefsKey: _prefs,
              loading: _loading,
              error: _error,
              onRetry: _load,
              rowId: (p) => p.id,
              rowMenu: _rowMenu,
              bulkActions: _bulkActions,
              onTap: _open,
              exportTitle: _title,
              exportBaseName: 'clients-fournisseurs',
              empty: EmptyState(
                icon: Icons.people_alt_outlined,
                text: filtered
                    ? 'Personne ne correspond à ces filtres.'
                    : _kind == 'supplier'
                        ? 'Aucun fournisseur pour l’instant.'
                        : 'Aucun client pour l’instant.',
                actions: [
                  if (filtered)
                    ('Effacer les filtres', _clearAll),
                  (newLabel, () => _create(_newKind)),
                ],
              ),
              aggregates: (rows) {
                final owedToUs = rows
                    .where((p) => p.balance > 0)
                    .fold(0, (s, p) => s + p.balance);
                final weOwe = rows
                    .where((p) => p.balance < 0)
                    .fold(0, (s, p) => s - p.balance);
                return [
                  ('Ils vous doivent', fmtDA(owedToUs)),
                  ('Vous devez', fmtDA(weOwe)),
                ];
              },
              columns: [
                ColumnSpec(
                  id: 'name',
                  label: 'Nom',
                  flex: 4,
                  hideable: false,
                  sortKey: (p) => p.name.toLowerCase(),
                  exportValue: (p) => p.name,
                  cell: (context, p) => Text(p.name,
                      style: T.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                ColumnSpec(
                  id: 'phone',
                  label: 'Téléphone',
                  flex: 2,
                  sortKey: (p) => p.phone ?? '',
                  exportValue: (p) => p.phone ?? '',
                  cell: (context, p) =>
                      Text(p.phone ?? '—', style: T.monoSmall),
                ),
                ColumnSpec(
                  id: 'kind',
                  label: 'Client ou fournisseur',
                  width: 190,
                  visibleByDefault: false,
                  sortKey: (p) => p.kind,
                  exportValue: (p) => partnerKindWord(p.kind),
                  cell: (context, p) => Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: DocChip(
                        label: switch (p.kind) {
                          'customer' => 'Client',
                          'supplier' => 'Fournisseur',
                          _ => 'Client et fournisseur',
                        },
                        bg: T.cream,
                        fg: T.muted),
                  ),
                ),
                ColumnSpec(
                  id: 'client_type',
                  label: 'Type de client',
                  width: 150,
                  sortKey: (p) => clientTypeLabels[p.clientType] ?? p.clientType,
                  exportValue: (p) => p.kind == 'supplier' ? '' : (clientTypeLabels[p.clientType] ?? p.clientType),
                  cell: (context, p) => Text(
                      p.kind == 'supplier' ? '—' : (clientTypeLabels[p.clientType] ?? p.clientType),
                      style: T.small.copyWith(color: T.ink),
                      overflow: TextOverflow.ellipsis),
                ),
                ColumnSpec(
                  id: 'crm_status',
                  label: 'Statut',
                  width: 120,
                  sortKey: (p) => p.crmStatus,
                  exportValue: (p) => p.kind == 'supplier' ? '' : (crmStatusLabels[p.crmStatus] ?? p.crmStatus),
                  cell: (context, p) => p.kind == 'supplier'
                      ? const Text('—', style: T.small)
                      : Align(alignment: AlignmentDirectional.centerStart, child: CrmStatusChip(p.crmStatus)),
                ),
                ColumnSpec(
                  id: 'rep',
                  label: 'Commercial',
                  flex: 2,
                  sortKey: (p) => p.repName.toLowerCase(),
                  exportValue: (p) => p.repName,
                  cell: (context, p) => Text(p.repName.isEmpty ? '—' : p.repName,
                      style: T.small.copyWith(color: T.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                ColumnSpec(
                  id: 'wilaya',
                  label: 'Wilaya',
                  width: 160,
                  sortKey: (p) => p.wilaya.toLowerCase(),
                  exportValue: (p) => p.wilaya,
                  cell: (context, p) => Text(
                      p.wilaya.isEmpty ? '—' : (p.commune.isEmpty ? p.wilaya : '${p.wilaya} · ${p.commune}'),
                      style: T.small.copyWith(color: T.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                ColumnSpec(
                  id: 'route',
                  label: 'Tournée',
                  width: 150,
                  visibleByDefault: false,
                  sortKey: (p) => p.routeName.toLowerCase(),
                  exportValue: (p) => p.routeName,
                  cell: (context, p) => Text(p.routeName.isEmpty ? '—' : p.routeName,
                      style: T.small.copyWith(color: T.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                ColumnSpec(
                  id: 'tags',
                  label: 'Étiquettes',
                  flex: 2,
                  exportValue: (p) => [for (final t in _tags) if (p.tagIds.contains(t.id)) t.name].join(', '),
                  cell: (context, p) => ClipRect(
                    child: Wrap(spacing: 4, runSpacing: 4, clipBehavior: Clip.hardEdge, children: [
                      for (final t in _tags)
                        if (p.tagIds.contains(t.id)) TagChip(name: t.name, colour: t.colour),
                    ]),
                  ),
                ),
                ColumnSpec(
                  id: 'address',
                  label: 'Adresse',
                  flex: 3,
                  visibleByDefault: false,
                  sortKey: (p) => (p.address ?? '').toLowerCase(),
                  exportValue: (p) => p.address ?? '',
                  cell: (context, p) => Text(p.address ?? '—',
                      style: T.small,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                ColumnSpec(
                  id: 'nif',
                  label: 'NIF',
                  width: 190,
                  visibleByDefault: false,
                  exportValue: (p) => p.nif ?? '',
                  cell: (context, p) => Text(p.nif ?? '—', style: T.monoSmall),
                ),
                ColumnSpec(
                  id: 'rc',
                  label: 'RC',
                  width: 140,
                  visibleByDefault: false,
                  exportValue: (p) => p.rc ?? '',
                  cell: (context, p) => Text(p.rc ?? '—', style: T.monoSmall),
                ),
                ColumnSpec(
                  id: 'balance',
                  label: 'Solde',
                  width: 150,
                  numeric: true,
                  sortKey: (p) => p.balance,
                  exportValue: (p) => p.balance / 100,
                  cell: (context, p) => Tooltip(
                    message: partnerBalanceSentence(p),
                    child: Text(fmtDA(p.balance),
                        style: T.monoBody.copyWith(
                          color: p.balance > 0
                              ? T.warnDark
                              : p.balance < 0
                                  ? T.mintDark
                                  : T.faint,
                          fontWeight: FontWeight.w600,
                        )),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
