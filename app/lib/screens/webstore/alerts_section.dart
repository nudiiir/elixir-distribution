import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/list_toolbar.dart';
import 'web_common.dart';

/// « Alertes stock » : visitors who asked « Prévenez-moi » on an
/// out-of-stock product. Call them back, then mark them handled.
class AlertsSection extends StatefulWidget {
  const AlertsSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<AlertsSection> createState() => _AlertsSectionState();
}

/// 0661223344 → 213661223344 for wa.me links.
String waNumber(String phone) {
  var d = phone.replaceAll(RegExp(r'\D'), '');
  if (d.startsWith('00')) d = d.substring(2);
  if (d.startsWith('0')) d = '213${d.substring(1)}';
  return d;
}

class _AlertsSectionState extends State<AlertsSection> {
  String _status = 'open';
  Future<List<WebAlert>>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() =>
      setState(() => _future = widget.ctx.client.webAlerts(status: _status));

  Future<void> _handle(List<String> ids, {bool reopen = false}) async {
    try {
      await widget.ctx.client.webHandleAlerts(ids, reopen: reopen);
      if (mounted) {
        showToast(context,
            reopen ? 'Alerte rouverte.' : '${ids.length} alerte(s) marquée(s) traitée(s).');
      }
      widget.ctx.reload();
      _reload();
    } catch (e) {
      if (mounted) toastError(context, 'Action impossible', e);
    }
  }

  void _whatsapp(WebAlert a) {
    final who = (a.name ?? '').isEmpty ? 'Bonjour' : 'Bonjour ${a.name}';
    final text = a.backInStock
        ? '$who, « ${a.productName} » est de nouveau disponible chez '
            '${widget.ctx.store.name}. ${widget.ctx.publicUrl}/p/${a.productId}'
        : '$who, nous avons bien noté votre demande pour « ${a.productName} ». '
            'Nous vous prévenons dès son retour.';
    openWebUrl('https://wa.me/${waNumber(a.phone)}?text=${Uri.encodeComponent(text)}');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        WebPaneHeader(
          title: 'Alertes « Prévenez-moi »',
          intro: 'Ces visiteurs attendent le retour d’un produit en rupture. '
              'Appelez-les ou écrivez-leur, puis marquez l’alerte traitée.',
          actions: [
            PageAction(label: 'Actualiser', icon: Icons.refresh_rounded, onPressed: _reload),
          ],
        ),
        const SizedBox(height: 14),
        Row(children: [
          for (final (v, l) in const [('open', 'À traiter'), ('handled', 'Traitées'), ('all', 'Toutes')])
            FilterPill(
                label: l,
                active: _status == v,
                onTap: () {
                  _status = v;
                  _reload();
                }),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: WebLoader<List<WebAlert>>(
            future: _future,
            onRetry: _reload,
            builder: (items) {
              if (items.isEmpty) {
                return WebNotice(
                    icon: Icons.notifications_none_rounded,
                    title: _status == 'open' ? 'Aucune alerte à traiter' : 'Aucune alerte',
                    body: 'Quand un produit est en rupture, le site propose « Prévenez-moi » : '
                        'les demandes arrivent ici.',
                    action: ('Actualiser', _reload));
              }
              final backOpen = [
                for (final a in items)
                  if (a.backInStock && a.status == 'open') a.id
              ];
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (backOpen.isNotEmpty)
                  InfoBanner(
                    kind: ToastKind.success,
                    icon: Icons.inventory_rounded,
                    text: '${backOpen.length} demande(s) concernent un produit de nouveau en stock : '
                        'prévenez ces clients.',
                    actions: [
                      OutlinedButton(
                          onPressed: () => _handle(backOpen),
                          child: const Text('Tout marquer traité')),
                    ],
                  ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 18),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final a = items[i];
                      return Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: const BoxDecoration(
                            border: Border(bottom: BorderSide(color: T.border))),
                        child: Row(children: [
                          Expanded(
                            flex: 4,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(a.productName,
                                  style: T.body.copyWith(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              Row(children: [
                                StatusPill(
                                    a.backInStock
                                        ? 'De retour en stock (${fmtQty(a.qtyMilli)})'
                                        : 'Toujours en rupture',
                                    kind: a.backInStock ? ToastKind.success : ToastKind.info),
                                const SizedBox(width: 8),
                                Text('Demandé le ${fmtDateTime(a.createdAt)}', style: T.small),
                              ]),
                            ]),
                          ),
                          Expanded(
                            flex: 3,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text((a.name ?? '').isEmpty ? 'Sans nom' : a.name!, style: T.body),
                              SelectableText(a.phone, style: T.monoBody),
                            ]),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => openWebUrl('tel:${a.phone.replaceAll(' ', '')}'),
                            icon: const Icon(Icons.call_outlined, size: 16),
                            label: const Text('Appeler'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => _whatsapp(a),
                            icon: const Icon(Icons.chat_outlined, size: 16),
                            label: const Text('WhatsApp'),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 150,
                            child: a.status == 'open'
                                ? FilledButton(
                                    style: FilledButton.styleFrom(
                                        backgroundColor: T.mint, foregroundColor: T.ink),
                                    onPressed: () => _handle([a.id]),
                                    child: const Text('Marquer traitée'))
                                : TextButton(
                                    onPressed: () => _handle([a.id], reopen: true),
                                    child: const Text('Rouvrir')),
                          ),
                        ]),
                      );
                    },
                  ),
                ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}
