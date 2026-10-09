import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/approval.dart';
import '../../util/feedback.dart';
import 'order_common.dart';

/// The status actions of a customer order, shared by the board (drag and
/// drop) and the order page (buttons). Each returns the updated order, or
/// null when nothing happened (cancelled by the user, or refused — the
/// reason is already shown).

/// Transitions a drag on the board may perform (from → targets).
const boardMoves = <String, Set<String>>{
  'new': {'validated', 'cancelled'},
  'validated': {'new', 'preparing', 'ready', 'cancelled'},
  'preparing': {'ready', 'cancelled'},
  'ready': {'shipping', 'delivered', 'cancelled'},
  'shipping': {'delivered', 'cancelled'},
  'delivered': {'invoiced'},
};

bool canMove(String from, String to) => boardMoves[from]?.contains(to) ?? false;

/// Runs the action that moves [o] to [to] (after a confirmation).
Future<CustomerOrder?> moveOrder(
    BuildContext context, ApiClient api, User user, CustomerOrder o, String to) async {
  final who = '${o.number} — ${o.partnerName}';
  switch ((o.status, to)) {
    case ('new', 'validated'):
      if (!await confirmAction(context,
          title: 'Valider la commande ?',
          message: '$who\nLe stock disponible est réservé ; ce qui manque part en reliquat.',
          confirmLabel: 'Valider',
          icon: Icons.check_circle_outline_rounded)) {
        return null;
      }
      if (!context.mounted) return null;
      return validateOrderFlow(context, api, user, o.id);
    case ('validated', 'new'):
      if (!await confirmAction(context,
          title: 'Rouvrir la commande ?',
          message: '$who\nElle repasse « Nouvelle » : la réservation du stock est levée.',
          confirmLabel: 'Rouvrir')) {
        return null;
      }
      if (!context.mounted) return null;
      return runGuarded(context, api, () => api.reopenOrder(o.id));
    case ('validated', 'preparing'):
      if (!await confirmAction(context,
          title: 'Démarrer la préparation ?', message: who, confirmLabel: 'Démarrer', icon: Icons.inventory_outlined)) {
        return null;
      }
      if (!context.mounted) return null;
      return runGuarded(context, api, () => api.startPreparation(o.id));
    case ('validated' || 'preparing', 'ready'):
      if (!await confirmAction(context,
          title: 'Marquer la commande prête ?',
          message: '$who\nCe qui n’a pas été scanné est prélevé automatiquement '
              '(lots qui périment en premier).',
          confirmLabel: 'Marquer prête',
          icon: Icons.inventory_2_outlined)) {
        return null;
      }
      if (!context.mounted) return null;
      return readyFlow(context, api, o.id, autoPick: true);
    case ('ready', 'shipping'):
      return shipFlow(context, api, o);
    case ('ready' || 'shipping', 'delivered'):
      return deliverFlow(context, api, o);
    case ('delivered', 'invoiced'):
      return invoiceFlow(context, api, o);
    case (_, 'cancelled'):
      return cancelFlow(context, api, o);
  }
  showToast(context, 'Ce changement se fait depuis la page de la commande.', kind: ToastKind.info);
  return null;
}

/// Validation with the credit check: blocking alerts → « Valider quand
/// même » (manager code if the user lacks orders.override_credit).
Future<CustomerOrder?> validateOrderFlow(BuildContext context, ApiClient api, User user, String id,
    {List<Map<String, dynamic>>? lines}) async {
  CustomerOrder? done;
  try {
    done = await withApproval(context, api, () => api.validateOrder(id, lines: lines));
  } on DistApiException catch (e) {
    if (!e.needsOverride) {
      if (context.mounted) showActionError(context, e);
      return null;
    }
    if (!context.mounted) return null;
    final canOverride = user.isAdmin || user.can('orders.override_credit');
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
        title: const Row(children: [
          Icon(Icons.gpp_maybe_outlined, color: T.warnDark),
          SizedBox(width: 10),
          Expanded(child: Text('Compte client à vérifier', style: T.h2)),
        ]),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.message, style: T.body.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final w in e.warnings)
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('• $w', style: T.body)),
            const SizedBox(height: 10),
            Text(
                canOverride
                    ? 'Vous pouvez valider quand même : ce choix est noté dans le journal.'
                    : 'Pour valider quand même, le code du gérant sera demandé.',
                style: T.bodyMuted),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ne pas valider')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: T.warn, foregroundColor: T.ink),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Valider quand même'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return null;
    done = await runGuarded(context, api, () => api.validateOrder(id, overrideCredit: true, lines: lines));
  } catch (e) {
    if (context.mounted) showActionError(context, e);
    return null;
  }
  if (done == null || !context.mounted) return done;
  final v = done.raw['validation'] is Map
      ? ValidationInfo.fromJson(Map<String, dynamic>.from(done.raw['validation'] as Map))
      : null;
  if (v != null && v.backorders.isNotEmpty) {
    showToast(
        context,
        'Commande validée en partie : ${v.backorders.length} ligne${v.backorders.length > 1 ? 's' : ''} '
        'en reliquat (${v.backorders.map((b) => '${b.productName} × ${fmtQty(b.qtyMilli)}').join(', ')}).',
        kind: ToastKind.warning);
  } else {
    showToast(context, 'Commande ${done.number} validée.');
  }
  return done;
}

/// « Prête » ; an incomplete preparation asks to put the missing part in
/// backorder.
Future<CustomerOrder?> readyFlow(BuildContext context, ApiClient api, String id, {bool autoPick = false}) async {
  try {
    final o = await withApproval(context, api, () => api.markReady(id, autoPick: autoPick));
    if (context.mounted) showToast(context, 'Commande ${o.number} prête à livrer.');
    return o;
  } on ApiException catch (e) {
    if (!context.mounted) return null;
    if (e.status == 409 && e.message.contains('incompl')) {
      final ok = await confirmAction(context,
          title: 'Préparation incomplète',
          message: '${e.message}\n\nLe manquant part en reliquat : il sera livré plus tard.',
          confirmLabel: 'Mettre en reliquat et marquer prête',
          icon: Icons.call_split_rounded);
      if (!ok || !context.mounted) return null;
      final o = await runGuarded(context, api, () => api.markReady(id, acceptPartial: true, autoPick: autoPick));
      if (o != null && context.mounted) showToast(context, 'Commande ${o.number} prête (en partie).');
      return o;
    }
    showActionError(context, e);
    return null;
  }
}

Future<CustomerOrder?> shipFlow(BuildContext context, ApiClient api, CustomerOrder o) async {
  final note = await askText(context,
      title: 'Expédier ${o.number} ?',
      message: 'La commande part en livraison ; le bon de livraison est créé s’il manque. '
          'Une note (n° de suivi, transporteur…) peut être ajoutée.',
      label: 'Note (facultative)',
      required: false,
      confirmLabel: 'Expédier');
  if (note == null || !context.mounted) return null;
  final r = await runGuarded(context, api, () => api.shipOrder(o.id, note: note));
  if (r != null && context.mounted) showToast(context, 'Commande ${r.number} en livraison.');
  return r;
}

Future<CustomerOrder?> deliverFlow(BuildContext context, ApiClient api, CustomerOrder o) async {
  final res = await showDialog<(int, String, String)>(
    context: context,
    builder: (_) => _DeliverDialog(order: o),
  );
  if (res == null || !context.mounted) return null;
  final r = await runGuarded(
      context, api, () => api.deliverOrder(o.id, codAmount: res.$1, paymentMethod: res.$2, receiverName: res.$3));
  if (r != null && context.mounted) {
    final pay = '${r.raw['payment_number'] ?? ''}';
    showToast(context, 'Commande ${r.number} livrée${pay.isEmpty ? '' : ' — encaissement $pay'}.');
  }
  return r;
}

Future<CustomerOrder?> invoiceFlow(BuildContext context, ApiClient api, CustomerOrder o) async {
  final method = await showDialog<String>(
    context: context,
    builder: (_) => _InvoiceDialog(order: o),
  );
  if (method == null || !context.mounted) return null;
  final r = await runGuarded(context, api, () => api.invoiceOrder(o.id, paymentMethod: method));
  if (r != null && context.mounted) {
    showToast(context, 'Facture ${r.raw['document_number'] ?? r.invoiceNumber ?? ''} créée.');
  }
  return r;
}

Future<CustomerOrder?> cancelFlow(BuildContext context, ApiClient api, CustomerOrder o) async {
  final reason = await askText(context,
      title: 'Annuler la commande ${o.number} ?',
      message: o.deliveryNoteId != null
          ? 'Le bon de livraison sera contrepassé (la marchandise revient en stock). Les reliquats sont annulés.'
          : 'La réservation du stock est levée et les reliquats sont annulés.',
      label: 'Motif de l’annulation',
      confirmLabel: 'Annuler la commande',
      danger: true);
  if (reason == null || !context.mounted) return null;
  final r = await runGuarded(context, api, () => api.cancelOrder(o.id, reason));
  if (r != null && context.mounted) showToast(context, 'Commande ${r.number} annulée.');
  return r;
}

class _DeliverDialog extends StatefulWidget {
  const _DeliverDialog({required this.order});
  final CustomerOrder order;

  @override
  State<_DeliverDialog> createState() => _DeliverDialogState();
}

class _DeliverDialogState extends State<_DeliverDialog> {
  late final _cod = TextEditingController(
      text: widget.order.paymentMode == 'cod' && widget.order.paymentId == null
          ? editDA(widget.order.totalTTC)
          : '');
  final _receiver = TextEditingController();
  String _method = 'cash';
  String? _error;

  @override
  void dispose() {
    _cod.dispose();
    _receiver.dispose();
    super.dispose();
  }

  void _submit() {
    final t = _cod.text.trim();
    final v = t.isEmpty ? 0 : parseDA(t);
    if (v == null || v < 0) {
      setState(() => _error = 'Montant invalide.');
      return;
    }
    Navigator.pop(context, (v, _method, _receiver.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Livrer ${o.number}', style: T.h2),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${o.partnerName} — total ${fmtDA(o.totalTTC)}', style: T.bodyMuted),
          if (o.paymentId != null)
            Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Déjà encaissée (${o.paymentNumber ?? ''}).', style: T.small)),
          const SizedBox(height: 14),
          LabeledField(
            label: 'Montant encaissé à la livraison',
            helper: o.paymentMode == 'cod'
                ? 'Paiement à la livraison : le montant attendu est pré-rempli.'
                : 'Vide = rien encaissé (la commande reste sur le compte du client).',
            error: _error,
            child: FormText(controller: _cod, numeric: true, suffixText: 'DA', autofocus: true, onSubmitted: (_) => _submit()),
          ),
          LabeledField(
            label: 'Moyen de paiement',
            child: FormDropdown<String>(
                value: _method, options: paymentMethodsCod, onChanged: (v) => setState(() => _method = v ?? 'cash')),
          ),
          LabeledField(
            label: 'Reçu par (facultatif)',
            child: FormText(controller: _receiver, hint: 'Nom de la personne', onSubmitted: (_) => _submit()),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: _submit,
          child: const Text('Confirmer la livraison'),
        ),
      ],
    );
  }
}

class _InvoiceDialog extends StatefulWidget {
  const _InvoiceDialog({required this.order});
  final CustomerOrder order;

  @override
  State<_InvoiceDialog> createState() => _InvoiceDialogState();
}

class _InvoiceDialogState extends State<_InvoiceDialog> {
  String _method = 'credit';

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final paid = o.paymentId != null;
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Facturer ${o.number}', style: T.h2),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('La facture reprend le bon de livraison ${o.deliveryNoteNumber ?? ''} '
              '(le stock ne bouge pas une seconde fois).', style: T.bodyMuted),
          const SizedBox(height: 14),
          LabeledField(
            label: 'Règlement',
            helper: paid
                ? 'Déjà encaissée à la livraison (${o.paymentNumber ?? ''}) : facture au compte.'
                : '« Au compte » : échéance selon les conditions du client.',
            child: FormDropdown<String>(
              value: _method,
              options: [
                ('credit', 'Au compte (à payer plus tard)'),
                if (!paid) ...paymentMethodsCod,
              ],
              onChanged: (v) => setState(() => _method = v ?? 'credit'),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: () => Navigator.pop(context, _method),
          child: const Text('Créer la facture'),
        ),
      ],
    );
  }
}
