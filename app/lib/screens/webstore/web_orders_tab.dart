import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/cloud.dart';
import '../../api/web_orders_sync.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/ui.dart';
import '../orders/order_common.dart' show frDate, frDateTime, OrderStatusChip;
import '../orders/order_detail_page.dart';
import 'web_common.dart';

/// « Commandes » of the online store: storefront orders and quote requests.
/// « Importer » turns one into a customer order of the shop (the client is
/// created if the phone number is unknown) — the same order can be imported
/// twice without creating a duplicate. Status changes made in « Commandes
/// clients » are pushed back to the site (also every 5 minutes by the app).
class WebOrdersTab extends StatefulWidget {
  const WebOrdersTab({super.key, required this.api, required this.client, required this.onAcked});
  final ApiClient api;
  final CloudClient client;
  final VoidCallback onAcked;

  @override
  State<WebOrdersTab> createState() => _WebOrdersTabState();
}

class _WebOrdersTabState extends State<WebOrdersTab> {
  List<Map<String, dynamic>>? _orders;
  String? _error;
  bool _history = false;
  String _kind = 'all'; // all | order | quote_request
  bool? _autoImport;
  bool _busy = false;
  final Set<String> _importing = {};

  bool get _canImport {
    final u = widget.api.user;
    return u == null || u.isAdmin || u.can('orders.manage');
  }

  bool get _isAdmin => widget.api.user?.isAdmin ?? false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadSetting();
  }

  Future<void> _loadSetting() async {
    try {
      final s = await widget.api.settings();
      if (mounted) setState(() => _autoImport = s[webAutoImportSetting] == '1');
    } catch (_) {}
  }

  Future<void> _setAutoImport(bool v) async {
    try {
      await widget.api.saveSettings({webAutoImportSetting: v ? '1' : '0'});
      if (!mounted) return;
      setState(() => _autoImport = v);
      showToast(
          context,
          v
              ? 'Import automatique activé : les nouvelles commandes du site arrivent toutes seules (toutes les 5 minutes).'
              : 'Import automatique désactivé.');
      if (v) _importAll();
    } catch (e) {
      if (mounted) showToast(context, 'Réglage impossible : $e', kind: ToastKind.error);
    }
  }

  Future<void> _load() async {
    setState(() {
      _orders = null;
      _error = null;
    });
    try {
      final items = await fetchStoreOrders(widget.client, status: _history ? 'all' : 'new', kind: _kind);
      if (mounted) setState(() => _orders = items);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _openOrder(String id) async {
    final user = widget.api.user;
    if (user == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OrderDetailPage(api: widget.api, user: user, orderId: id),
    ));
  }

  Future<void> _import(Map<String, dynamic> o) async {
    final id = '${o['id']}';
    if (_importing.contains(id)) return;
    setState(() => _importing.add(id));
    try {
      final r = await importStoreOrder(widget.api, widget.client, o);
      if (!mounted) return;
      final what = isQuoteRequest(o) ? 'Demande de devis' : 'Commande';
      final msg = r.created
          ? '$what ${o['number']} importée : ${r.order.number}'
              '${r.partnerCreated ? ' (nouveau client créé)' : ''}.'
          : '$what ${o['number']} déjà importée (${r.order.number}).';
      showToast(context, r.warnings.isEmpty ? msg : '$msg Attention : ${r.warnings.join(' ; ')}',
          kind: r.warnings.isEmpty ? ToastKind.success : ToastKind.warning,
          actionLabel: 'Ouvrir',
          onAction: () => _openOrder(r.order.id));
      widget.onAcked();
      _load();
    } catch (e) {
      if (mounted) showToast(context, 'Import impossible : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _importing.remove(id));
    }
  }

  Future<void> _importAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final created = await autoImportWebOrders(widget.api, widget.client);
      if (!mounted) return;
      showToast(
          context,
          created.isEmpty
              ? 'Aucune nouvelle commande à importer.'
              : '${created.length} commande${created.length > 1 ? 's' : ''} importée${created.length > 1 ? 's' : ''} : ${created.join(', ')}.');
      widget.onAcked();
      _load();
    } catch (e) {
      if (mounted) showToast(context, 'Import impossible : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncStatuses() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final n = await syncWebOrderStatuses(widget.api, widget.client);
      if (!mounted) return;
      showToast(
          context,
          n == 0
              ? 'Le site est déjà à jour.'
              : '$n statut${n > 1 ? 's' : ''} envoyé${n > 1 ? 's' : ''} au site (suivi client).');
      if (_history) _load();
    } catch (e) {
      if (mounted) showToast(context, 'Synchronisation impossible : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject(Map<String, dynamic> o) async {
    final quote = isQuoteRequest(o);
    final ok = await confirmAction(
      context,
      title: quote ? 'Refuser la demande ${o['number']} ?' : 'Refuser la commande ${o['number']} ?',
      message: 'Le client verra « refusée » sur la page de suivi. Ce choix ne peut pas être annulé.',
      confirmLabel: 'Refuser',
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      await ackStoreOrder(widget.client, '${o['id']}', accept: false);
      widget.onAcked();
      _load();
    } catch (e) {
      if (mounted) showToast(context, 'Refus impossible : $e', kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final orders = _orders;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ChoiceChip(
            label: const Text('À traiter'),
            selected: !_history,
            selectedColor: T.mintTint,
            onSelected: (_) {
              _history = false;
              _load();
            },
          ),
          ChoiceChip(
            label: const Text('Historique'),
            selected: _history,
            selectedColor: T.mintTint,
            onSelected: (_) {
              _history = true;
              _load();
            },
          ),
          const SizedBox(width: 10),
          for (final (k, l) in const [('all', 'Tout'), ('order', 'Commandes'), ('quote_request', 'Demandes de devis')])
            ChoiceChip(
              label: Text(l),
              selected: _kind == k,
              selectedColor: T.mintTint,
              onSelected: (_) {
                _kind = k;
                _load();
              },
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
        child: Row(children: [
          if (_autoImport != null)
            Tooltip(
              message: _isAdmin ? '' : 'Seul l’administrateur peut changer ce réglage.',
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(value: _autoImport!, onChanged: _isAdmin && _canImport ? _setAutoImport : null),
                Text('Importer automatiquement les nouvelles commandes', style: T.small.copyWith(color: T.ink)),
              ]),
            ),
          const Spacer(),
          TextButton.icon(
              onPressed: _busy ? null : _syncStatuses,
              icon: const Icon(Icons.sync_rounded, size: 18),
              label: const Text('Envoyer les statuts au site')),
          const SizedBox(width: 6),
          if (_canImport && !_history)
            OutlinedButton.icon(
                onPressed: _busy || (orders?.isEmpty ?? true) ? null : _importAll,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Tout importer')),
          const SizedBox(width: 6),
          TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded, size: 18), label: const Text('Actualiser')),
        ]),
      ),
      if (!_canImport)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          child: Text('Votre rôle ne permet pas d’importer les commandes (droit « Commandes clients › gérer »).',
              style: T.small.copyWith(color: T.warnDark)),
        ),
      Expanded(child: _body(orders)),
    ]);
  }

  Widget _body(List<Map<String, dynamic>>? orders) {
    if (_error != null) {
      return WebNotice(
          icon: Icons.error_outline_rounded, title: 'Chargement impossible', body: _error!, action: ('Réessayer', _load));
    }
    if (orders == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.6, color: T.mintDeep));
    }
    if (orders.isEmpty) {
      return WebNotice(
          icon: Icons.shopping_bag_outlined,
          title: _history ? 'Aucune commande' : 'Aucune commande à traiter',
          body: 'Les commandes et demandes de devis passées sur votre boutique en ligne apparaîtront ici.',
          action: ('Actualiser', _load));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      itemCount: orders.length,
      itemBuilder: (context, i) => Padding(padding: const EdgeInsets.only(bottom: 12), child: _card(orders[i])),
    );
  }

  Widget _card(Map<String, dynamic> o) {
    final quote = isQuoteRequest(o);
    final status = '${o['status'] ?? 'new'}';
    final items = [for (final l in (o['items'] as List? ?? const [])) if (l is Map) l];
    final importing = _importing.contains('${o['id']}');
    String s(String k) => '${o[k] ?? ''}'.trim();
    final place = [s('wilaya'), s('commune'), s('address')].where((x) => x.isNotEmpty).join(', ');
    return Container(
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: quote ? const Color(0xFF8B5CF6) : T.border, width: quote ? 1.5 : 1),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(quote ? Icons.request_quote_outlined : Icons.shopping_bag_outlined,
              size: 18, color: quote ? const Color(0xFF6D28D9) : T.muted),
          const SizedBox(width: 8),
          Text(s('number'), style: T.h2.copyWith(fontSize: 15)),
          const SizedBox(width: 10),
          if (quote)
            const MintChip('Demande de devis', color: Color(0x1F8B5CF6), fg: Color(0xFF6D28D9))
          else
            const MintChip('Commande'),
          const SizedBox(width: 6),
          switch (status) {
            'new' => const MintChip('nouvelle', color: Color(0xFFFFF1DB), fg: Color(0xFFA96311)),
            'accepted' => const MintChip('acceptée', color: T.mintTint, fg: T.mintDeep),
            'rejected' => const MintChip('refusée', color: Color(0xFFFBE3E3), fg: T.dangerDark),
            _ => OrderStatusChip(status),
          },
          const Spacer(),
          Text(frDateTime(s('created_at')), style: T.small),
          const SizedBox(width: 14),
          Text(quote ? 'Prix à confirmer' : fmtDA((o['total_centimes'] as num?)?.toInt() ?? 0),
              style: T.h2.copyWith(fontSize: 15)),
        ]),
        const SizedBox(height: 8),
        Text(
            [
              if (s('business_name').isNotEmpty) s('business_name'),
              s('customer_name'),
              if (s('customer_type').isNotEmpty) s('customer_type'),
              s('phone'),
            ].where((x) => x.isNotEmpty).join(' · '),
            style: T.body.copyWith(fontWeight: FontWeight.w600)),
        if (place.isNotEmpty) Text(place, style: T.bodyMuted),
        Wrap(spacing: 14, children: [
          if (o['delivery_method'] == 'pickup') Text('Retrait en magasin', style: T.small),
          if (o['preferred_date'] != null) Text('Souhaitée le ${frDate(s('preferred_date'))}', style: T.small),
          if (s('promo_code').isNotEmpty) Text('Code promo ${s('promo_code')}', style: T.small),
          if (o['shipping_centimes'] != null && !quote)
            Text('Livraison ${fmtDA((o['shipping_centimes'] as num).toInt())}', style: T.small),
          if (s('status_note').isNotEmpty) Text('Suivi : ${s('status_note')}', style: T.small),
        ]),
        if (s('note').isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 3), child: Text('Note : ${s('note')}', style: T.small)),
        const SizedBox(height: 8),
        for (final l in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(children: [
              Expanded(
                  child: Text('${l['name'] ?? l['product_id']}',
                      style: T.body.copyWith(color: l['is_free'] == true ? T.mintDark : T.ink))),
              Text(
                  l['is_free'] == true
                      ? '${fmtQty((l['qty_milli'] as num?)?.toInt() ?? 0)} offert'
                      : quote && ((l['price_centimes'] as num?)?.toInt() ?? 0) == 0
                          ? '${fmtQty((l['qty_milli'] as num?)?.toInt() ?? 0)} — prix sur demande'
                          : '${fmtQty((l['qty_milli'] as num?)?.toInt() ?? 0)} × ${fmtDA((l['price_centimes'] as num?)?.toInt() ?? 0)}',
                  style: T.bodyMuted),
            ]),
          ),
        if (_canImport) ...[
          const SizedBox(height: 10),
          Row(children: [
            if (quote)
              Expanded(
                child: Text(
                    'Importée comme commande « Nouvelle » : les prix du magasin sont appliqués, appelez le client pour confirmer.',
                    style: T.small),
              )
            else
              const Spacer(),
            if (status == 'new')
              OutlinedButton(
                  onPressed: () => _reject(o),
                  style: OutlinedButton.styleFrom(foregroundColor: T.dangerDark),
                  child: const Text('Refuser')),
            const SizedBox(width: 10),
            if (status != 'rejected')
              PrimaryButton(
                  label: importing
                      ? 'Import…'
                      : status == 'new'
                          ? (quote ? 'Importer la demande' : 'Importer la commande')
                          : 'Voir dans Commandes clients',
                  onPressed: importing ? null : () => _import(o)),
          ]),
        ],
      ]),
    );
  }
}
