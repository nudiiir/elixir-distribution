import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../theme/tokens.dart' show fmtDA, fmtQty;
import 'order_common.dart';

/// A4 PDFs of the distribution screens: bon de commande, liste de
/// préparation, feuille de route. Same approach as util/invoice_pdf.dart:
/// built with package:pdf, saved under Documents\Elixir\documents, opened.

const _ink = PdfColor.fromInt(0xFF0F1113);
const _muted = PdfColor.fromInt(0xFF5D6462);
const _border = PdfColor.fromInt(0xFFE4E2DC);
const _headBg = PdfColor.fromInt(0xFFF0EFE9);

class _Fonts {
  _Fonts(this.sans, this.bold, this.mono);
  final pw.Font sans;
  final pw.Font bold;
  final pw.Font mono;
}

Future<_Fonts> _fonts() async => _Fonts(
      pw.Font.ttf(await rootBundle.load('assets/fonts/PlusJakartaSans-Regular.ttf')),
      pw.Font.ttf(await rootBundle.load('assets/fonts/PlusJakartaSans-Bold.ttf')),
      pw.Font.ttf(await rootBundle.load('assets/fonts/IBMPlexMono-Regular.ttf')),
    );

Future<Map<String, String>> _company(ApiClient api) async {
  try {
    return await api.settings();
  } catch (_) {
    return const {};
  }
}

Future<String> _saveAndOpen(Uint8List bytes, String name) async {
  final home = Platform.environment['USERPROFILE'] ?? '.';
  final dir = Directory('$home\\Documents\\Elixir\\documents');
  await dir.create(recursive: true);
  final safe = name.replaceAll(RegExp(r'[^\w\-]'), '_');
  final file = File('${dir.path}\\$safe.pdf');
  await file.writeAsBytes(bytes);
  await Process.run('cmd', ['/c', 'start', '', file.path]);
  return file.path;
}

pw.Widget _header(_Fonts f, Map<String, String> company, String title, String number, List<String> right) {
  final name = (company['company_name'] ?? '').trim();
  final lines = [
    (company['company_address'] ?? '').trim(),
    (company['company_phone'] ?? '').trim(),
  ].where((s) => s.isNotEmpty).toList();
  return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Expanded(
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(name.isEmpty ? 'Mon commerce' : name, style: pw.TextStyle(font: f.bold, fontSize: 14, color: _ink)),
        for (final l in lines) pw.Text(l, style: pw.TextStyle(font: f.sans, fontSize: 9, color: _muted)),
      ]),
    ),
    pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
      pw.Text(title, style: pw.TextStyle(font: f.bold, fontSize: 16, color: _ink)),
      if (number.isNotEmpty) pw.Text(number, style: pw.TextStyle(font: f.mono, fontSize: 11, color: _ink)),
      for (final r in right) pw.Text(r, style: pw.TextStyle(font: f.sans, fontSize: 9, color: _muted)),
    ]),
  ]);
}

pw.Widget _table(_Fonts f, List<String> headers, List<List<String>> rows,
    {Map<int, pw.TableColumnWidth> widths = const {}, Set<int> numeric = const {}, double fontSize = 9}) {
  pw.Widget cell(String t, int i, {bool head = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: pw.Text(t,
            textAlign: numeric.contains(i) ? pw.TextAlign.right : pw.TextAlign.left,
            style: pw.TextStyle(font: head ? f.bold : f.sans, fontSize: head ? fontSize - 0.5 : fontSize, color: _ink)),
      );
  return pw.Table(
    border: pw.TableBorder.all(color: _border, width: 0.6),
    columnWidths: widths,
    children: [
      pw.TableRow(
          decoration: const pw.BoxDecoration(color: _headBg),
          children: [for (var i = 0; i < headers.length; i++) cell(headers[i], i, head: true)]),
      for (final r in rows) pw.TableRow(children: [for (var i = 0; i < r.length; i++) cell(r[i], i)]),
    ],
  );
}

pw.Widget _facts(_Fonts f, List<(String, String)> facts) => pw.Wrap(spacing: 18, runSpacing: 6, children: [
      for (final (k, v) in facts)
        if (v.trim().isNotEmpty)
          pw.SizedBox(
            width: 160,
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(k, style: pw.TextStyle(font: f.sans, fontSize: 8, color: _muted)),
              pw.Text(v, style: pw.TextStyle(font: f.bold, fontSize: 9.5, color: _ink)),
            ]),
          ),
    ]);

pw.Widget _signatures(_Fonts f, List<String> labels) => pw.Row(children: [
      for (final l in labels)
        pw.Expanded(
          child: pw.Container(
            margin: const pw.EdgeInsets.only(right: 8),
            height: 60,
            padding: const pw.EdgeInsets.all(5),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _border)),
            child: pw.Text(l, style: pw.TextStyle(font: f.sans, fontSize: 8, color: _muted)),
          ),
        ),
    ]);

pw.Document _doc(_Fonts f) => pw.Document(theme: pw.ThemeData.withFont(base: f.sans, bold: f.bold));

final _page = PdfPageFormat.a4.copyWith(
    marginLeft: 14 * PdfPageFormat.mm,
    marginRight: 14 * PdfPageFormat.mm,
    marginTop: 12 * PdfPageFormat.mm,
    marginBottom: 12 * PdfPageFormat.mm);

/// « Bon de commande » of a customer order (what the client asked for, with
/// the resolved prices).
Future<String> printOrderPdf(ApiClient api, CustomerOrder o) async {
  final f = await _fonts();
  final company = await _company(api);
  final doc = _doc(f);
  final lines = o.activeLines;
  doc.addPage(pw.MultiPage(
    pageFormat: _page,
    build: (_) => [
      _header(f, company, 'BON DE COMMANDE', o.number, [
        'Date : ${frDate(o.orderDate)}',
        if (o.requestedDate != null) 'Livraison souhaitée : ${frDate(o.requestedDate)}',
        'Statut : ${orderStatusLabel(o.status)}',
      ]),
      pw.SizedBox(height: 14),
      _facts(f, [
        ('Client', o.partnerName),
        ('Téléphone', o.contactPhone.isNotEmpty ? o.contactPhone : o.partnerPhone),
        ('Contact', o.contactName),
        ('Adresse de livraison', [o.deliveryAddress, o.commune, o.wilaya].where((s) => s.isNotEmpty).join(', ')),
        ('Commercial', o.repName),
        ('Tournée', o.routeName),
        ('Paiement', o.paymentMode == 'cod' ? 'À la livraison' : 'Sur compte'),
        if (o.externalNumber != null) ('N° boutique web', o.externalNumber!),
      ]),
      pw.SizedBox(height: 12),
      _table(
        f,
        ['Produit', 'Qté', 'UG', 'Prix HT', 'Remise', 'TVA', 'Total TTC'],
        [
          for (final l in lines)
            [
              l.productName,
              fmtQty(o.status == 'new' ? l.qtyOrderedMilli : l.qtyValidatedMilli),
              l.qtyFreeMilli > 0 ? fmtQty(l.qtyFreeMilli) : '',
              fmtDA(l.unitPrice),
              l.discountPct > 0 ? pctText(l.discountPct) : '',
              pctText(l.vatRate),
              fmtDA(l.lineTTC),
            ]
        ],
        widths: const {
          0: pw.FlexColumnWidth(4),
          1: pw.FixedColumnWidth(40),
          2: pw.FixedColumnWidth(32),
          3: pw.FixedColumnWidth(70),
          4: pw.FixedColumnWidth(42),
          5: pw.FixedColumnWidth(36),
          6: pw.FixedColumnWidth(80),
        },
        numeric: const {1, 2, 3, 4, 5, 6},
      ),
      pw.SizedBox(height: 10),
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.SizedBox(
          width: 220,
          child: pw.Column(children: [
            for (final (k, v) in [
              ('Total HT', fmtDA(o.totalHT)),
              ('TVA', fmtDA(o.totalVAT)),
              if (o.shippingFee > 0) ('Frais de livraison', fmtDA(o.shippingFee)),
              if (o.extraDiscount > 0) ('Remise', '-${fmtDA(o.extraDiscount)}'),
              ('Total TTC', fmtDA(o.totalTTC)),
            ])
              pw.Row(children: [
                pw.Expanded(child: pw.Text(k, style: pw.TextStyle(font: f.sans, fontSize: 9.5))),
                pw.Text(v, style: pw.TextStyle(font: k == 'Total TTC' ? f.bold : f.mono, fontSize: 10)),
              ]),
          ]),
        ),
      ),
      if (o.notes.isNotEmpty) ...[
        pw.SizedBox(height: 10),
        pw.Text('Note : ${o.notes}', style: pw.TextStyle(font: f.sans, fontSize: 9)),
      ],
      pw.SizedBox(height: 18),
      _signatures(f, ['Cachet et signature du client', 'Visa du magasin']),
    ],
  ));
  return _saveAndOpen(await doc.save(), 'commande-${o.number}');
}

/// « Liste de préparation » : lines to pick, FEFO lots, check boxes.
Future<String> printPickingPdf(ApiClient api, PickingList pl, {String title = 'LISTE DE PRÉPARATION'}) async {
  final f = await _fonts();
  final company = await _company(api);
  final doc = _doc(f);
  final o = pl.order;
  doc.addPage(pw.MultiPage(
    pageFormat: _page,
    build: (_) => [
      _header(f, company, title, o?.number ?? '', [
        if (o != null) 'Client : ${o.partnerName}',
        if (o != null && o.routeName.isNotEmpty) 'Tournée : ${o.routeName}',
        'Imprimée le ${frDateTime(DateTime.now().toUtc().toIso8601String())}',
      ]),
      pw.SizedBox(height: 14),
      _table(
        f,
        ['', 'Produit', 'Catégorie', 'À prélever', 'Déjà fait', 'Lots conseillés (péremption)'],
        [
          for (final l in pl.lines)
            [
              '[  ]',
              '${l.productName}${l.barcode == null ? '' : '\n${l.barcode}'}'
                  '${l.orders.isEmpty ? '' : '\n${l.orders.map((x) => '${x.orderNumber} ${x.partnerName} : ${fmtQty(x.qtyRemainingMilli)}').join('\n')}'}',
              l.categoryName,
              '${fmtQty(l.qtyToPrepareMilli)}${l.qtyFreeMilli > 0 ? '\ndont ${fmtQty(l.qtyFreeMilli)} UG' : ''}',
              l.qtyPreparedMilli > 0 ? fmtQty(l.qtyPreparedMilli) : '',
              l.lots.isEmpty
                  ? (l.trackLots ? 'aucun lot disponible' : '')
                  : l.lots
                      .map((s) => '${s.lotNumber}${s.expiryDate == null ? '' : ' (${frDate(s.expiryDate)})'} : '
                          '${fmtQty(s.qtySuggestedMilli)}')
                      .join('\n'),
            ]
        ],
        widths: const {
          0: pw.FixedColumnWidth(24),
          1: pw.FlexColumnWidth(4),
          2: pw.FlexColumnWidth(1.6),
          3: pw.FixedColumnWidth(58),
          4: pw.FixedColumnWidth(48),
          5: pw.FlexColumnWidth(3),
        },
        numeric: const {3, 4},
      ),
      pw.SizedBox(height: 18),
      _signatures(f, ['Préparé par', 'Contrôlé par']),
    ],
  ));
  return _saveAndOpen(await doc.save(), 'preparation-${o?.number ?? 'groupee'}');
}

/// « Feuille de route » of a delivery run: stops in order, addresses,
/// phones, amounts to collect, signature boxes.
Future<String> printRunSheetPdf(ApiClient api, DeliveryRun run) async {
  final f = await _fonts();
  final company = await _company(api);
  final doc = _doc(f);
  final total = run.stops.fold<int>(0, (s, x) => s + x.codExpected);
  doc.addPage(pw.MultiPage(
    pageFormat: _page.landscape,
    build: (_) => [
      _header(f, company, 'FEUILLE DE ROUTE', frDate(run.runDate), [
        if (run.routeName.isNotEmpty) 'Tournée : ${run.routeName}',
        if (run.driverName.isNotEmpty) 'Chauffeur : ${run.driverName}',
        if (run.vehicleName.isNotEmpty) 'Véhicule : ${run.vehicleName}',
      ]),
      pw.SizedBox(height: 12),
      _table(
        f,
        ['N°', 'Client', 'Adresse', 'Téléphone', 'Commande / BL', 'À encaisser', 'Encaissé', 'Résultat', 'Signature client'],
        [
          for (final s in run.stops)
            [
              '${s.sequence}',
              s.partnerName,
              s.place,
              s.partnerPhone,
              '${s.orderNumber}${s.deliveryNoteNumber == null ? '' : '\n${s.deliveryNoteNumber}'}',
              s.codExpected > 0 ? fmtDA(s.codExpected) : '—',
              '',
              'Livré  /  Partiel  /  Échec',
              '\n\n',
            ]
        ],
        widths: const {
          0: pw.FixedColumnWidth(22),
          1: pw.FlexColumnWidth(2.4),
          2: pw.FlexColumnWidth(3),
          3: pw.FixedColumnWidth(70),
          4: pw.FixedColumnWidth(78),
          5: pw.FixedColumnWidth(70),
          6: pw.FixedColumnWidth(60),
          7: pw.FixedColumnWidth(90),
          8: pw.FlexColumnWidth(1.8),
        },
        numeric: const {5},
        fontSize: 8.5,
      ),
      pw.SizedBox(height: 8),
      pw.Text('${run.stops.length} arrêt(s) — total à encaisser : ${fmtDA(total)}',
          style: pw.TextStyle(font: f.bold, fontSize: 10)),
      pw.SizedBox(height: 14),
      _signatures(f, ['Remis au chauffeur (départ)', 'Argent remis au retour', 'Signature du chauffeur']),
    ],
  ));
  return _saveAndOpen(await doc.save(), 'feuille-de-route-${run.runDate}-${run.id.length > 6 ? run.id.substring(run.id.length - 6) : run.id}');
}
