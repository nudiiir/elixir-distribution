import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart' show PlaySound, SND_ALIAS, SND_ASYNC, SND_NODEFAULT;

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/ui.dart';
import 'order_actions.dart';
import 'order_common.dart';
import 'orders_pdf.dart';

/// Windows system sound (non-blocking); silent if anything fails.
void _sound(String alias) {
  try {
    final p = alias.toNativeUtf16();
    PlaySound(p, 0, SND_ALIAS | SND_ASYNC | SND_NODEFAULT);
    calloc.free(p);
  } catch (_) {
    SystemSound.play(SystemSoundType.alert);
  }
}

/// « Préparation » : the picker scans each product; the screen says clearly
/// if it was right (green + sound) or wrong (red + error sound), shows the
/// lots to take first (FEFO) and the progress.
class PickingPage extends StatefulWidget {
  const PickingPage({super.key, required this.api, required this.user, required this.orderId});
  final ApiClient api;
  final User user;
  final String orderId;

  @override
  State<PickingPage> createState() => _PickingPageState();
}

class _PickingPageState extends State<PickingPage> {
  ApiClient get api => widget.api;

  PickingList? _pl;
  String? _error;
  bool _busy = false;
  final _scan = TextEditingController();
  final _scanFocus = FocusNode();
  final _qty = TextEditingController();
  final _lot = TextEditingController();

  /// Last scan result: (ok, big text, detail).
  (bool, String, String)? _feedback;
  String? _lastLineId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scan.dispose();
    _scanFocus.dispose();
    _qty.dispose();
    _lot.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final pl = await api.pickingList(widget.orderId);
      if (mounted) {
        setState(() {
          _pl = pl;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  int get _toPrepare => _pl?.lines.fold<int>(0, (s, l) => s + l.qtyToPrepareMilli) ?? 0;
  int get _prepared => _pl?.lines.fold<int>(0, (s, l) => s + l.qtyPreparedMilli) ?? 0;

  Future<void> _doScan() async {
    final code = _scan.text.trim();
    if (code.isEmpty || _busy) return;
    final qty = _qty.text.trim().isEmpty ? null : parseQty(_qty.text);
    setState(() => _busy = true);
    try {
      final r = await api.scanPick(widget.orderId, code, qtyMilli: qty, lotNumber: _lot.text.trim());
      _sound('SystemAsterisk');
      setState(() {
        _lastLineId = r.lineId;
        _feedback = (
          true,
          '${r.productName}  +${fmtQty(r.qtyMilli)}',
          r.orderComplete
              ? 'Tout est préparé : vous pouvez marquer la commande prête.'
              : r.lineComplete
                  ? 'Ligne complète (${fmtQty(r.qtyPreparedMilli)}/${fmtQty(r.qtyToPrepareMilli)}).'
                  : 'Préparé ${fmtQty(r.qtyPreparedMilli)} sur ${fmtQty(r.qtyToPrepareMilli)}'
                      '${r.lots.isEmpty ? '' : ' — lot ${r.lots.join(', ')}'}.',
        );
      });
      _qty.clear();
      _lot.clear();
      await _load();
    } on DistApiException catch (e) {
      _sound('SystemHand');
      setState(() => _feedback = (false, e.wrongProduct ? 'Mauvais produit' : 'Refusé', e.message));
    } catch (e) {
      _sound('SystemHand');
      setState(() => _feedback = (false, 'Erreur', e is ApiException ? e.message : '$e'));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _scan.clear();
        _scanFocus.requestFocus();
      }
    }
  }

  /// Manual pick (no scanner): quantity + lot.
  Future<void> _manualPick(PickingLine l) async {
    final res = await showDialog<(int, String?)>(context: context, builder: (_) => _PickDialog(line: l));
    if (res == null || !mounted) return;
    final r = await runGuarded(context, api, () => api.addPick(widget.orderId, lineId: l.lineId, lotId: res.$2, qtyMilli: res.$1));
    if (r != null && mounted) {
      setState(() {
        _lastLineId = r.lineId;
        _feedback = (true, '${r.productName}  +${fmtQty(r.qtyMilli)}', 'Prélèvement enregistré.');
      });
      _load();
    }
    _scanFocus.requestFocus();
  }

  Future<void> _undoPick(OrderPick p, String name) async {
    final ok = await confirmAction(context,
        title: 'Annuler ce prélèvement ?',
        message: '$name : ${fmtQty(p.qtyMilli)}${p.lotNumber == null ? '' : ' (lot ${p.lotNumber})'}',
        confirmLabel: 'Annuler le prélèvement',
        danger: true);
    if (!ok || !mounted) return;
    final r = await runGuarded(context, api, () => api.deletePick(widget.orderId, p.id));
    if (r != null && mounted) _load();
  }

  Future<void> _ready({bool autoPick = false}) async {
    if (autoPick) {
      final ok = await confirmAction(context,
          title: 'Tout prélever automatiquement ?',
          message: 'Le reste est prélevé dans le stock du dépôt, en prenant d’abord les lots qui périment le plus tôt.',
          confirmLabel: 'Tout prélever et marquer prête');
      if (!ok || !mounted) return;
    }
    final o = await readyFlow(context, api, widget.orderId, autoPick: autoPick);
    if (o != null && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final pl = _pl;
    final o = pl?.order;
    final title = 'Préparation ${o?.number ?? ''}';
    return AppPage(
      crumbs: [
        Crumb('Commandes clients', () => Navigator.of(context).popUntil((r) => r.isFirst)),
        Crumb(o?.number ?? 'Commande', () => Navigator.of(context).pop()),
        const Crumb('Préparation'),
      ],
      title: title,
      subtitle: o == null ? null : Text('${o.partnerName}${o.routeName.isEmpty ? '' : ' · tournée ${o.routeName}'}', style: T.bodyMuted),
      maxWidth: 1280,
      actions: [
        PageAction(
            label: 'Imprimer la liste',
            icon: Icons.print_outlined,
            onPressed: pl == null
                ? null
                : () async {
                    try {
                      await printPickingPdf(api, pl);
                    } catch (e) {
                      if (context.mounted) showActionError(context, e);
                    }
                  }),
        PageAction(label: 'Tout prélever', icon: Icons.done_all_rounded, onPressed: pl == null ? null : () => _ready(autoPick: true)),
        PageAction(label: 'Marquer prête', icon: Icons.inventory_2_outlined, primary: true, onPressed: pl == null ? null : _ready),
      ],
      body: pl == null
          ? (_error == null
              ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: T.mint)))
              : EmptyState(icon: Icons.cloud_off_rounded, text: _error!, actions: [('Réessayer', _load)]))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _scanBox(),
              _progress(),
              const SizedBox(height: 12),
              for (final l in pl.lines) _lineCard(l, pl),
            ]),
    );
  }

  Widget _scanBox() {
    final fb = _feedback;
    return PageSection(
      title: 'Scanner',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _scan,
              focusNode: _scanFocus,
              autofocus: true,
              style: T.body.copyWith(fontSize: 18),
              onSubmitted: (_) => _doScan(),
              decoration: InputDecoration(
                hintText: 'Scannez le code-barres du produit (ou du carton)',
                prefixIcon: const Icon(Icons.qr_code_scanner_rounded),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 110, child: FormText(controller: _qty, numeric: true, hint: 'Qté (1)', onSubmitted: (_) => _doScan())),
          const SizedBox(width: 8),
          SizedBox(width: 150, child: FormText(controller: _lot, hint: 'N° de lot (facultatif)', onSubmitted: (_) => _doScan())),
          const SizedBox(width: 8),
          SizedBox(height: 50, child: PrimaryButton(label: _busy ? '…' : 'Valider le scan', onPressed: _busy ? null : _doScan)),
        ]),
        if (fb != null)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: fb.$1 ? T.mintTint2 : T.dangerTint,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: fb.$1 ? T.mint : T.danger, width: 1.5),
            ),
            child: Row(children: [
              Icon(fb.$1 ? Icons.check_circle_rounded : Icons.cancel_rounded, size: 34, color: fb.$1 ? T.mintDark : T.dangerDark),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(fb.$2, style: T.h1.copyWith(fontSize: 21, color: fb.$1 ? T.mintDark : T.dangerDark)),
                  const SizedBox(height: 2),
                  Text(fb.$3, style: T.body),
                ]),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _progress() {
    final total = _toPrepare;
    final done = _prepared;
    final ratio = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    final linesDone = _pl!.lines.where((l) => l.qtyRemainingMilli <= 0).length;
    return Row(children: [
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
              value: ratio, minHeight: 14, color: ratio >= 1 ? T.mint : T.mintDeep, backgroundColor: T.border2),
        ),
      ),
      const SizedBox(width: 14),
      Text('${(ratio * 100).round()} % · $linesDone/${_pl!.lines.length} lignes · ${fmtQty(done)}/${fmtQty(total)} unités',
          style: T.body.copyWith(fontWeight: FontWeight.w700)),
    ]);
  }

  Widget _lineCard(PickingLine l, PickingList pl) {
    final done = l.qtyRemainingMilli <= 0;
    final last = l.lineId == _lastLineId;
    final picks = [for (final p in pl.picks) if (p.lineId == l.lineId) p];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: done ? T.mintTint : T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: last ? T.mint : T.border, width: last ? 2 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(done ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
              color: done ? T.mintDark : T.ghost, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.productName, style: T.h2.copyWith(fontSize: 16)),
              Text([l.barcode ?? '', l.categoryName, l.brand].where((s) => s.isNotEmpty).join(' · '), style: T.small),
              if (l.stock.isNotEmpty)
                Text('Stock : ${l.stock.map((s) => '${s.warehouseName} ${fmtQty(s.qtyMilli)}').join(' · ')}', style: T.small),
            ]),
          ),
          _qtyBox('À prélever', fmtQty(l.qtyToPrepareMilli), sub: l.qtyFreeMilli > 0 ? 'dont ${fmtQty(l.qtyFreeMilli)} offert' : null),
          _qtyBox('Préparé', fmtQty(l.qtyPreparedMilli), color: done ? T.mintDark : T.ink),
          _qtyBox('Reste', fmtQty(l.qtyRemainingMilli.clamp(0, 1 << 40)), color: done ? T.mintDark : T.warnDark),
          const SizedBox(width: 8),
          if (!done && !l.isService)
            OutlinedButton.icon(
              onPressed: () => _manualPick(l),
              icon: const Icon(Icons.pan_tool_alt_outlined, size: 16),
              label: const Text('Prélever'),
            ),
        ]),
        if (l.lots.isNotEmpty && !done) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            Text('Prendre d’abord :', style: T.label),
            for (final s in l.lots)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: T.warnTint, borderRadius: BorderRadius.circular(T.rChip)),
                child: Text(
                    'Lot ${s.lotNumber}${s.expiryDate == null ? '' : ' · périme ${frDate(s.expiryDate)}'} · ${fmtQty(s.qtySuggestedMilli)}',
                    style: T.small.copyWith(color: T.warnDark, fontWeight: FontWeight.w700)),
              ),
          ]),
        ] else if (l.trackLots && l.lots.isEmpty && !done)
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Aucun lot disponible pour ce produit.', style: T.small.copyWith(color: T.dangerDark))),
        if (l.orders.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(l.orders.map((x) => '${x.orderNumber} ${x.partnerName} : ${fmtQty(x.qtyRemainingMilli)}').join(' · '),
                style: T.small),
          ),
        if (picks.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in picks)
              InputChip(
                label: Text('${fmtQty(p.qtyMilli)}${p.lotNumber == null ? '' : ' · lot ${p.lotNumber}'} · ${p.pickedByName}',
                    style: T.small.copyWith(color: T.ink)),
                onDeleted: () => _undoPick(p, l.productName),
                deleteButtonTooltipMessage: 'Annuler ce prélèvement',
                backgroundColor: T.surface,
                side: const BorderSide(color: T.border3),
                visualDensity: VisualDensity.compact,
              ),
          ]),
        ],
      ]),
    );
  }

  Widget _qtyBox(String label, String value, {Color? color, String? sub}) => SizedBox(
        width: 100,
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(label, style: T.label),
          Text(value, style: T.monoBig.copyWith(fontSize: 20, color: color ?? T.ink)),
          if (sub != null) Text(sub, style: T.small.copyWith(fontSize: 12)),
        ]),
      );
}

class _PickDialog extends StatefulWidget {
  const _PickDialog({required this.line});
  final PickingLine line;

  @override
  State<_PickDialog> createState() => _PickDialogState();
}

class _PickDialogState extends State<_PickDialog> {
  late final _qty = TextEditingController(text: fmtQty(widget.line.qtyRemainingMilli));
  String? _lotId; // null = automatic FEFO
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  void _submit() {
    final q = parseQty(_qty.text);
    if (q == null || q <= 0 || q > widget.line.qtyRemainingMilli) {
      setState(() => _error = 'Entre 0 et ${fmtQty(widget.line.qtyRemainingMilli)}.');
      return;
    }
    Navigator.pop(context, (q, _lotId));
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Prélever — ${l.productName}', style: T.h2),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          LabeledField(
            label: 'Quantité prélevée',
            error: _error,
            child: FormText(controller: _qty, numeric: true, autofocus: true, onSubmitted: (_) => _submit()),
          ),
          if (l.trackLots)
            LabeledField(
              label: 'Lot',
              helper: 'Automatique = les lots qui périment le plus tôt d’abord.',
              child: FormDropdown<String?>(
                value: _lotId,
                options: [
                  (null, 'Automatique (FEFO)'),
                  for (final s in l.lots)
                    (s.lotId, '${s.lotNumber}${s.expiryDate == null ? '' : ' — ${frDate(s.expiryDate)}'} (${fmtQty(s.qtyAvailableMilli)} dispo)'),
                ],
                onChanged: (v) => setState(() => _lotId = v),
              ),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: _submit,
          child: const Text('Prélever'),
        ),
      ],
    );
  }
}
