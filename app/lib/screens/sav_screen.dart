import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../api/client.dart';
import '../api/models.dart';
import '../templates/template_render.dart' show saveAndOpenPdf;
import '../theme/tokens.dart';
import '../widgets/ui.dart';

const _statusMeta = {
  'received': ('Reçu', T.warnTint, T.warnDark),
  'in_progress': ('En réparation', Color(0x14CFDCFA), Color(0xFF4A63B8)),
  'ready': ('Prêt', T.mintTint, T.mintDark),
  'returned': ('Rendu', T.cream, T.faint),
  'cancelled': ('Annulé', T.dangerTint, T.dangerDark),
};

/// SAV: dépôts de réparation + recherche IMEI (historique de vente/garantie).
class SavScreen extends StatefulWidget {
  const SavScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<SavScreen> createState() => _SavScreenState();
}

class _SavScreenState extends State<SavScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  String? _statusFilter;
  List<Repair> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await widget.api
          .repairs(status: _statusFilter, q: _searchCtrl.text.trim());
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openForm({Repair? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _RepairDialog(api: widget.api, existing: existing),
    );
    if (saved == true) _load();
  }

  Future<void> _imeiLookup() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ImeiLookupDialog(api: widget.api),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Réparations (SAV)', style: T.h1),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _imeiLookup,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: T.border3),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(T.rInner)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            icon: const Icon(Icons.search_rounded, size: 16, color: T.ink),
            label: Text('Recherche IMEI',
                style:
                    T.small.copyWith(color: T.ink, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 170,
            child: PrimaryButton(
                label: 'Nouveau dépôt', onPressed: () => _openForm()),
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          _Pill(
            label: 'Tous',
            selected: _statusFilter == null,
            onTap: () {
              setState(() => _statusFilter = null);
              _load();
            },
          ),
          for (final e in _statusMeta.entries)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: _Pill(
                label: e.value.$1,
                selected: _statusFilter == e.key,
                onTap: () {
                  setState(() =>
                      _statusFilter = _statusFilter == e.key ? null : e.key);
                  _load();
                },
              ),
            ),
          const Spacer(),
          SizedBox(
            width: 280,
            child: SearchField(
              controller: _searchCtrl,
              hint: 'Client, téléphone, IMEI, N°…',
              onChanged: (_) {
                _debounce?.cancel();
                _debounce =
                    Timer(const Duration(milliseconds: 250), _load);
              },
            ),
          ),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: Card14(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: _items.isEmpty
                ? EmptyState(
                    icon: Icons.build_outlined,
                    text: _loading ? 'Chargement…' : 'Aucune réparation')
                : ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, i) {
                      final x = _items[i];
                      final meta = _statusMeta[x.status] ??
                          ('?', T.cream, T.faint);
                      return InkWell(
                        onTap: () => _openForm(existing: x),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(children: [
                            SizedBox(
                                width: 130,
                                child: Text(x.number,
                                    style: T.monoBody
                                        .copyWith(fontSize: 11.5))),
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(x.customerName, style: T.body),
                                  if (x.customerPhone != null)
                                    Text(x.customerPhone!,
                                        style: T.monoSmall
                                            .copyWith(fontSize: 10.5)),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 4,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(x.device,
                                      style:
                                          T.body.copyWith(fontSize: 12.5)),
                                  Text(x.fault,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: T.small
                                          .copyWith(fontSize: 11)),
                                ],
                              ),
                            ),
                            if (x.deposit > 0)
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                    end: 12),
                                child: Text('Acompte ${fmtDA(x.deposit)}',
                                    style: T.monoSmall),
                              ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: meta.$2,
                                borderRadius:
                                    BorderRadius.circular(T.rChip),
                              ),
                              child: Text(meta.$1.toUpperCase(),
                                  style: T.label.copyWith(
                                      color: meta.$3, fontSize: 9)),
                            ),
                            const SizedBox(width: 12),
                            Text(
                                x.createdAt.length >= 10
                                    ? x.createdAt.substring(0, 10)
                                    : '',
                                style: T.monoSmall.copyWith(fontSize: 10.5)),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}

class _RepairDialog extends StatefulWidget {
  const _RepairDialog({required this.api, this.existing});
  final ApiClient api;
  final Repair? existing;

  @override
  State<_RepairDialog> createState() => _RepairDialogState();
}

class _RepairDialogState extends State<_RepairDialog> {
  late final _name =
      TextEditingController(text: widget.existing?.customerName ?? '');
  late final _phone =
      TextEditingController(text: widget.existing?.customerPhone ?? '');
  late final _device =
      TextEditingController(text: widget.existing?.device ?? '');
  late final _serial =
      TextEditingController(text: widget.existing?.serial ?? '');
  late final _fault = TextEditingController(text: widget.existing?.fault ?? '');
  late final _deposit = TextEditingController(
      text: widget.existing == null || widget.existing!.deposit == 0
          ? ''
          : editDA(widget.existing!.deposit));
  late final _quote = TextEditingController(
      text: widget.existing?.quote == null
          ? ''
          : editDA(widget.existing!.quote!));
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late String _status = widget.existing?.status ?? 'received';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _name, _phone, _device, _serial, _fault, _deposit, _quote, _notes
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.api.saveRepair({
        'customer_name': _name.text.trim(),
        'customer_phone':
            _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        'device': _device.text.trim(),
        'serial': _serial.text.trim().isEmpty ? null : _serial.text.trim(),
        'fault': _fault.text.trim(),
        'deposit': parseDA(_deposit.text) ?? 0,
        'quote': parseDA(_quote.text),
        'status': _status,
        'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      }, id: widget.existing?.id);
      if (widget.existing == null && mounted) {
        // Fresh intake: hand the customer their dépôt slip.
        _printSlip(saved);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _printSlip(Repair x) async {
    try {
      final company = await widget.api.settings();
      final sans = pw.Font.ttf(
          await rootBundle.load('assets/fonts/PlusJakartaSans-Regular.ttf'));
      final bold = pw.Font.ttf(
          await rootBundle.load('assets/fonts/PlusJakartaSans-Bold.ttf'));
      final mono = pw.Font.ttf(
          await rootBundle.load('assets/fonts/IBMPlexMono-Regular.ttf'));
      const ink = PdfColor.fromInt(0xFF0F1113);
      pw.Widget row(String l, String r) => pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 2),
            child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(l,
                      style:
                          pw.TextStyle(font: sans, fontSize: 8, color: ink)),
                  pw.Text(r,
                      style:
                          pw.TextStyle(font: mono, fontSize: 8, color: ink)),
                ]),
          );
      final pdf = pw.Document();
      pdf.addPage(pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Center(
                child: pw.Text(company['company_name'] ?? 'Mon commerce',
                    style:
                        pw.TextStyle(font: bold, fontSize: 11, color: ink))),
            pw.Center(
                child: pw.Text('BON DE DÉPÔT — RÉPARATION',
                    style: pw.TextStyle(font: bold, fontSize: 9, color: ink))),
            pw.SizedBox(height: 6),
            row('N°', x.number),
            row('Date', x.createdAt.length >= 10
                ? x.createdAt.substring(0, 10)
                : ''),
            row('Client', x.customerName),
            if (x.customerPhone != null) row('Tél', x.customerPhone!),
            row('Appareil', x.device),
            if (x.serial != null) row('IMEI / N°', x.serial!),
            pw.SizedBox(height: 3),
            pw.Text('Panne déclarée : ${x.fault}',
                style: pw.TextStyle(font: sans, fontSize: 8, color: ink)),
            pw.SizedBox(height: 3),
            if (x.deposit > 0) row('Acompte versé', fmtDA(x.deposit)),
            if (x.quote != null) row('Devis estimé', fmtDA(x.quote!)),
            pw.SizedBox(height: 8),
            pw.Text(
                'À présenter au retrait de l\'appareil. Les appareils non '
                'réclamés sous 90 jours ne sont plus garantis en stock.',
                style: pw.TextStyle(font: sans, fontSize: 6.5, color: ink)),
          ],
        ),
      ));
      await saveAndOpenPdf(await pdf.save(), 'depot-${x.number}');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                        widget.existing == null
                            ? 'Nouveau dépôt'
                            : widget.existing!.number,
                        style: T.h2),
                  ),
                  if (widget.existing != null)
                    TextButton.icon(
                      onPressed: () => _printSlip(widget.existing!),
                      icon: const Icon(Icons.print_outlined,
                          size: 14, color: T.muted),
                      label: Text('Bon de dépôt',
                          style: T.small.copyWith(color: T.muted)),
                    ),
                ]),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: _F(label: 'Client', c: _name)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _F(label: 'Téléphone', c: _phone, mono: true)),
                ]),
                Row(children: [
                  Expanded(
                      child:
                          _F(label: 'Appareil (ex. Samsung A54)', c: _device)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _F(label: 'IMEI / N° série', c: _serial, mono: true)),
                ]),
                _F(label: 'Panne déclarée', c: _fault),
                Row(children: [
                  Expanded(
                      child:
                          _F(label: 'Acompte (DA)', c: _deposit, mono: true)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _F(
                          label: 'Devis estimé (DA)', c: _quote, mono: true)),
                ]),
                _F(label: 'Notes', c: _notes),
                if (widget.existing != null) ...[
                  const MicroLabel('Statut'),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final e in _statusMeta.entries)
                      ChoiceChip(
                        label: Text(e.value.$1,
                            style: TextStyle(
                                fontFamily: T.sans,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _status == e.key
                                    ? T.mintDark
                                    : T.muted)),
                        selected: _status == e.key,
                        selectedColor: T.mintTint,
                        backgroundColor: T.bg,
                        side: BorderSide(
                            color:
                                _status == e.key ? T.mintDeep : T.border),
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _status = e.key),
                      ),
                  ]),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: T.small.copyWith(color: T.dangerDark)),
                ],
                const SizedBox(height: 16),
                Row(children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text('Fermer',
                        style: T.small.copyWith(color: T.muted)),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 140,
                    child: PrimaryButton(
                      label: _busy ? '…' : 'Enregistrer',
                      onPressed: _busy ? null : _save,
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// IMEI lookup: who bought this device, when, and is it still under warranty?
class _ImeiLookupDialog extends StatefulWidget {
  const _ImeiLookupDialog({required this.api});
  final ApiClient api;

  @override
  State<_ImeiLookupDialog> createState() => _ImeiLookupDialogState();
}

class _ImeiLookupDialogState extends State<_ImeiLookupDialog> {
  final _ctrl = TextEditingController();
  ProductUnit? _unit;
  Product? _product;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    setState(() {
      _error = null;
      _unit = null;
      _product = null;
    });
    try {
      final u = await widget.api.unitBySerial(_ctrl.text.trim());
      Product? p;
      try {
        p = await widget.api.getProduct(u.productId);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _unit = u;
          _product = p;
        });
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Serveur injoignable.');
    }
  }

  String? get _warrantyText {
    final u = _unit;
    final p = _product;
    if (u == null || p == null || p.warrantyMonths == 0 || u.saleDate == null) {
      return null;
    }
    final sold = DateTime.tryParse(u.saleDate!);
    if (sold == null) return null;
    final end = DateTime(sold.year, sold.month + p.warrantyMonths, sold.day);
    final left = end.difference(DateTime.now()).inDays;
    return left >= 0
        ? 'Sous garantie — expire le ${end.toIso8601String().substring(0, 10)} ($left j)'
        : 'Garantie expirée le ${end.toIso8601String().substring(0, 10)}';
  }

  @override
  Widget build(BuildContext context) {
    final u = _unit;
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 440,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Recherche IMEI / N° de série', style: T.h2),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: T.bg,
                      borderRadius: BorderRadius.circular(T.rInner),
                      border: Border.all(color: T.border),
                    ),
                    child: TextField(
                      controller: _ctrl,
                      autofocus: true,
                      style: T.monoBody,
                      onSubmitted: (_) => _lookup(),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Scannez ou saisissez le numéro…',
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                    width: 110,
                    child:
                        PrimaryButton(label: 'Chercher', onPressed: _lookup)),
              ]),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: T.small.copyWith(color: T.dangerDark)),
              ],
              if (u != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: T.bg,
                    borderRadius: BorderRadius.circular(T.rInner),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(u.productName, style: T.h2.copyWith(fontSize: 14)),
                      const SizedBox(height: 6),
                      _kv('N° de série', u.serial),
                      _kv('Statut', switch (u.status) {
                        'in_stock' => 'En stock',
                        'sold' => 'Vendu',
                        'returned' => 'Retourné',
                        'repair' => 'En réparation',
                        _ => 'Rebuté',
                      }),
                      if (u.saleDocNumber != null)
                        _kv('Vente', '${u.saleDocNumber} · ${u.saleDate ?? ''}'),
                      if (u.partnerName != null) _kv('Client', u.partnerName!),
                      if (u.isUsed) _kv('Provenance', 'Occasion / reprise'),
                      if (_warrantyText != null) ...[
                        const SizedBox(height: 6),
                        Text(_warrantyText!,
                            style: T.small.copyWith(
                                color: _warrantyText!.startsWith('Sous')
                                    ? T.mintDark
                                    : T.dangerDark,
                                fontWeight: FontWeight.w700)),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child:
                      Text('Fermer', style: T.small.copyWith(color: T.muted)),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(children: [
          SizedBox(width: 110, child: Text(k, style: T.small)),
          Expanded(child: Text(v, style: T.monoBody.copyWith(fontSize: 12))),
        ]),
      );
}

class _Pill extends StatelessWidget {
  const _Pill(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? T.ink : T.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? T.ink : T.border),
        ),
        child: Text(label,
            style: TextStyle(
              fontFamily: T.sans,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : T.muted,
            )),
      ),
    );
  }
}

class _F extends StatelessWidget {
  const _F({required this.label, required this.c, this.mono = false});
  final String label;
  final TextEditingController c;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MicroLabel(label),
        const SizedBox(height: 4),
        Container(
          height: 38,
          decoration: BoxDecoration(
            color: T.bg,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border),
          ),
          child: TextField(
            controller: c,
            style: mono ? T.monoBody : T.body,
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ),
      ]),
    );
  }
}
