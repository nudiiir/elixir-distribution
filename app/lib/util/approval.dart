import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import 'feedback.dart';

/// Plain French for each right (approval dialog, roles page).
const rightSentences = <String, String>{
  'view_cost': 'voir les prix d’achat, le coût moyen et les marges',
  'discount': 'accorder une remise',
  'price_edit': 'changer le prix à la caisse',
  'credit_sale': 'vendre à crédit',
  'credit_limit': 'dépasser le plafond de crédit du client',
  'approval_above': 'valider une vente d’un montant élevé',
  'negative_stock': 'vendre au-delà du stock disponible',
  'refund': 'faire un avoir ou un retour',
  'void_document': 'annuler un document validé',
  'change_date': 'modifier la date d’un document',
  'open_drawer': 'ouvrir le tiroir-caisse sans vente',
  'close_till': 'clôturer la caisse (rapport Z)',
  'view_today': 'voir le chiffre d’affaires et le bénéfice du jour',
  'stock_adjust': 'ajuster le stock ou faire un inventaire',
  'import_data': 'importer des données',
  'export_data': 'exporter des données',
  'orders.override_credit': 'valider une commande malgré le compte du client',
};

const _actionWords = <String, String>{
  'view': 'voir',
  'create': 'créer',
  'edit': 'modifier',
  'cancel': 'annuler',
  'validate': 'valider',
  'export': 'exporter',
  'print': 'imprimer',
};

const _moduleWords = <String, String>{
  'dashboard': 'le tableau de bord',
  'pos': 'la caisse',
  'sales': 'les ventes',
  'purchases': 'les achats',
  'stock': 'le stock',
  'products': 'les produits',
  'partners': 'les clients et fournisseurs',
  'assistant': 'l’assistant',
  'reports': 'les rapports',
  'webstore': 'la boutique en ligne',
  'settings': 'les paramètres',
};

/// « valider dans les ventes », « accorder une remise »…
String rightSentence(String key) {
  final s = rightSentences[key];
  if (s != null) return s;
  final i = key.indexOf('.');
  if (i > 0) {
    final a = _actionWords[key.substring(i + 1)];
    final m = _moduleWords[key.substring(0, i)];
    if (a != null && m != null) return '$a dans $m';
  }
  return key;
}

/// Module of the permission grid for a document type (same as the server).
String docRightModule(String docType) {
  if (docType.startsWith('PURCHASE')) return 'purchases';
  if (docType == 'STOCK_ADJUSTMENT' || docType == 'STOCK_TRANSFER' || docType == 'INVENTORY_COUNT') {
    return 'stock';
  }
  if (docType.startsWith('PAYMENT')) return 'partners';
  return 'sales';
}

/// True when [user] may do [action] ('validate', 'cancel', 'void'…) on this
/// document type alone; false = the manager code will be asked. Null user
/// (unknown) = true.
bool canDocAlone(User? user, String docType, String action) {
  if (user == null || user.isAdmin) return true;
  final pos = user.can('pos') && (docType == 'SALE_TICKET' || docType == 'PAYMENT_IN');
  switch (action) {
    case 'void':
      return user.can('${docRightModule(docType)}.cancel') && user.can('void_document');
    case 'validate':
      return pos || user.can('${docRightModule(docType)}.validate');
    default:
      return user.can('${docRightModule(docType)}.$action');
  }
}

String _amountText(String action, int amount) {
  if (amount <= 0) return '';
  if (action == 'discount') {
    final v = amount / 100;
    return ' (${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2).replaceAll('.', ',')} %)';
  }
  final da = (amount / 100).toStringAsFixed(2).replaceAll('.', ',');
  return ' ($da DA)';
}

/// Thrown by [withApproval] when the manager code dialog is closed: the
/// action did not happen. Its message is ready to show.
class ApprovalCancelled extends ApiException {
  ApprovalCancelled()
      : super(403, 'Action annulée : le code du gérant n’a pas été saisi.');
}

/// Runs [run]. When the server answers `needs_approval`, shows « Code du
/// gérant », gets a single-use token, puts it on `api.approvalToken` (sent as
/// X-Approval by the NEXT request only) and runs [run] again.
/// Throws [ApprovalCancelled] when the dialog is closed.
Future<V> withApproval<V>(
    BuildContext context, ApiClient api, Future<V> Function() run) async {
  var rounds = 0;
  while (true) {
    try {
      return await run();
    } on ApiException catch (e) {
      if (!e.needsApproval || rounds >= 4 || !context.mounted) rethrow;
      rounds++;
      final approval = await showManagerCodeDialog(context, api,
          action: e.action ?? '', amount: e.amount, reason: e.message);
      if (approval == null) throw ApprovalCancelled();
      if (context.mounted) {
        showToast(context, 'Approuvé par ${approval.approverName}', kind: ToastKind.info);
      }
      api.approvalToken = approval.token;
    }
  }
}

/// « Code du gérant » — numeric pad; returns the approval, or null if closed.
Future<Approval?> showManagerCodeDialog(BuildContext context, ApiClient api,
    {required String action, int amount = 0, String? reason}) {
  return showDialog<Approval>(
    context: context,
    builder: (_) => _ManagerCodeDialog(api: api, action: action, amount: amount, reason: reason),
  );
}

class _ManagerCodeDialog extends StatefulWidget {
  const _ManagerCodeDialog({required this.api, required this.action, required this.amount, this.reason});
  final ApiClient api;
  final String action;
  final int amount;
  final String? reason;

  @override
  State<_ManagerCodeDialog> createState() => _ManagerCodeDialogState();
}

class _ManagerCodeDialogState extends State<_ManagerCodeDialog> {
  String _pin = '';
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    if (_pin.length < 4 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final a = await widget.api.approve(_pin, widget.action, amount: widget.amount);
      if (mounted) Navigator.of(context).pop(a);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _pin = '';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final what = rightSentence(widget.action) + _amountText(widget.action, widget.amount);
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: const Row(children: [
        Icon(Icons.lock_person_outlined, color: T.mintDark),
        SizedBox(width: 10),
        Text('Code du gérant', style: T.h2),
      ]),
      content: SizedBox(
        width: 340,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Cette action demande l’accord d’un responsable :', style: T.bodyMuted),
          const SizedBox(height: 4),
          Text(what[0].toUpperCase() + what.substring(1), style: T.body.copyWith(fontWeight: FontWeight.w700)),
          if (widget.reason != null && widget.reason!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(widget.reason!, style: T.small),
          ],
          const SizedBox(height: 16),
          const Text('Le gérant tape son code caisse :', style: T.label),
          const SizedBox(height: 8),
          PinPad(
            value: _pin,
            enabled: !_busy,
            onChanged: (v) => setState(() {
              _pin = v;
              _error = null;
            }),
            onSubmit: _submit,
          ),
          FieldError(_error),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: _pin.length >= 4 && !_busy ? _submit : null,
          child: Text(_busy ? 'Vérification…' : 'Valider'),
        ),
      ],
    );
  }
}

/// A 4–6 digit code entry: dots + numeric pad (mouse / touch) + keyboard
/// digits, Backspace, Enter.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.value,
    required this.onChanged,
    this.onSubmit,
    this.maxLength = 6,
    this.enabled = true,
  });
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmit;
  final int maxLength;
  final bool enabled;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _digit(String d) {
    if (!widget.enabled || widget.value.length >= widget.maxLength) return;
    widget.onChanged(widget.value + d);
  }

  void _back() {
    if (!widget.enabled || widget.value.isEmpty) return;
    widget.onChanged(widget.value.substring(0, widget.value.length - 1));
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final ch = e.character;
    if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) {
      _digit(ch);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.backspace) {
      _back();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      widget.onSubmit?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _key(String label, VoidCallback onTap, {IconData? icon, String? tooltip}) {
    final child = icon != null ? Icon(icon, size: 20) : Text(label, style: T.h2.copyWith(fontSize: 20));
    final btn = SizedBox(
      width: 84,
      height: 52,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: T.ink,
          side: const BorderSide(color: T.border3),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rInner)),
        ),
        onPressed: widget.enabled ? onTap : null,
        child: child,
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(4),
      child: tooltip == null ? btn : Tooltip(message: tooltip, child: btn),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          height: 48,
          width: 276,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: T.bg,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border3),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < widget.maxLength; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 6),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < widget.value.length ? T.ink : Colors.transparent,
                  border: Border.all(color: i < widget.value.length ? T.ink : T.ghost, width: 1.5),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) _key(d, () => _digit(d))]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          _key('', () => widget.onChanged(''), icon: Icons.clear_rounded, tooltip: 'Tout effacer'),
          _key('0', () => _digit('0')),
          _key('', _back, icon: Icons.backspace_outlined, tooltip: 'Effacer un chiffre'),
        ]),
      ]),
    );
  }
}
