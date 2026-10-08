import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart' show fmtDA, fmtQty;
import 'lettres.dart';

/// Document titles, French and Arabic.
const _titles = {
  'SALE_INVOICE': ('FACTURE', 'فاتورة'),
  'QUOTE': ('DEVIS', 'عرض سعر'),
  'DELIVERY_NOTE': ('BON DE LIVRAISON', 'وصل تسليم'),
  'SALE_CREDIT_NOTE': ('AVOIR', 'فاتورة إرجاع'),
  'PURCHASE_ORDER': ('BON DE COMMANDE', 'طلبية'),
  'SALE_TICKET': ('TICKET', 'تذكرة'), // rendered as an 80mm roll, not A4
};

bool canPdf(String docType) => _titles.containsKey(docType);

/// Optional columns of the lines table (Paramètres › Documents).
const invoiceColumnLabels = {
  'barcode': 'Code-barres',
  'lot': 'Lot',
  'expiry': 'Péremption',
  'discount': 'Remise',
  'unit': 'Unité',
};

/// How invoices are printed — read from the shop settings:
/// `invoice_language` fr|ar|both, `invoice_format` a4|a5, `invoice_columns`
/// ("discount|unit"), `invoice_amount_words` '1'/'0', `company_footer`,
/// `quote_validity_days`.
class InvoiceOptions {
  InvoiceOptions({
    this.language = 'fr',
    this.format = 'a4',
    this.columns = const {'discount'},
    this.amountInWords = true,
    this.footer = '',
    this.quoteValidityDays = 15,
  });

  final String language; // fr | ar | both
  final String format; // a4 | a5
  final Set<String> columns;
  final bool amountInWords;
  final String footer;
  final int quoteValidityDays;

  factory InvoiceOptions.fromSettings(Map<String, String> s) {
    final lang = s['invoice_language'] ?? 'fr';
    final cols = s['invoice_columns'];
    return InvoiceOptions(
      language: const {'fr', 'ar', 'both'}.contains(lang) ? lang : 'fr',
      format: s['invoice_format'] == 'a5' ? 'a5' : 'a4',
      columns: cols == null
          ? const {'discount'}
          : {for (final c in cols.split('|')) if (invoiceColumnLabels.containsKey(c.trim())) c.trim()},
      amountInWords: (s['invoice_amount_words'] ?? '1') != '0',
      footer: (s['company_footer'] ?? '').trim(),
      quoteValidityDays: int.tryParse(s['quote_validity_days'] ?? '') ?? 15,
    );
  }
}

/// Renders the PDF for the document (facture légale 05-468 layout with the
/// montant en lettres), saves it under Documents\Elixir\documents and opens it.
/// With [api], the company logo and the products' barcode / unit are fetched
/// (needed by the optional columns); [logo] / [products] can be given instead.
Future<String> openDocumentPdf({
  required Map<String, String> company,
  required DocDetail doc,
  Partner? partner,
  ApiClient? api,
  List<int>? logo,
  Map<String, Product>? products,
}) async {
  final bytes = await buildDocumentPdf(
      company: company, doc: doc, partner: partner, api: api, logo: logo, products: products);
  return _saveAndOpen(bytes, doc.number ?? 'brouillon-${doc.id.substring(0, 8)}');
}

/// « Aperçu » of the settings screen: a sample invoice printed with the
/// given (possibly unsaved) settings.
Future<String> openSampleInvoicePdf({required Map<String, String> settings, ApiClient? api}) async {
  final today = DateTime.now().toIso8601String().substring(0, 10);
  Map<String, dynamic> line(String d, int qty, int pu, int disc, int vat, String lot, String exp) {
    final gross = (pu * qty + 500) ~/ 1000;
    final ht = (gross * (10000 - disc) + 5000) ~/ 10000;
    final tva = (ht * vat + 5000) ~/ 10000;
    return {
      'description': d, 'qty_milli': qty, 'unit_price': pu, 'discount_pct': disc,
      'vat_rate': vat, 'line_ht': ht, 'line_vat': tva, 'line_ttc': ht + tva,
      'lot_number': lot, 'expiry_date': exp,
    };
  }

  final lines = [
    line('Huile de table 5 L', 2000, 115000, 0, 900, 'L2405', '2027-03-31'),
    line('Café moulu 250 g', 6000, 32000, 500, 1900, 'C118', '2026-12-15'),
    line('Eau minérale 1,5 L (pack de 6)', 3000, 21000, 0, 1900, '', ''),
  ];
  final ht = lines.fold<int>(0, (a, l) => a + (l['line_ht'] as int));
  final tva = lines.fold<int>(0, (a, l) => a + (l['line_vat'] as int));
  final doc = DocDetail.fromJson({
    'id': 'apercu-00000000',
    'doc_type': 'SALE_INVOICE',
    'number': _sampleNumber(settings),
    'status': 'posted',
    'doc_date': today,
    'total_ht': ht,
    'total_vat': tva,
    'total_discount': 960,
    'timbre': 0,
    'total_ttc': ht + tva,
    'notes': 'Exemple : ceci est un aperçu, pas une vraie facture.',
    'due_date': today,
    'lines': lines,
  });
  final partner = Partner.fromJson({
    'id': 'x', 'kind': 'customer', 'name': 'Client exemple SARL',
    'address': '12 rue des Frères, Alger', 'nif': '000016000000000', 'rc': '16/00-0000000B00',
    'active': true,
  });
  final bytes = await buildDocumentPdf(
      company: settings, doc: doc, partner: partner, api: api, products: const {});
  return _saveAndOpen(bytes, 'apercu-facture');
}

String _sampleNumber(Map<String, String> s) {
  const t = 'SALE_INVOICE';
  final prefix = s['number_${t}_prefix'] ?? 'FV';
  final year = (s['number_${t}_year'] ?? '1') != '0';
  final digits = int.tryParse(s['number_${t}_digits'] ?? '') ?? 6;
  final parts = [
    if (prefix.isNotEmpty) prefix,
    if (year) '${DateTime.now().year}',
    '124'.padLeft(digits.clamp(4, 8), '0'),
  ];
  return parts.join('-');
}

/// Builds the PDF bytes of a document (A4 / A5 facture, or the 80 mm ticket).
Future<Uint8List> buildDocumentPdf({
  required Map<String, String> company,
  required DocDetail doc,
  Partner? partner,
  ApiClient? api,
  List<int>? logo,
  Map<String, Product>? products,
}) async {
  final sans = pw.Font.ttf(await rootBundle.load('assets/fonts/PlusJakartaSans-Regular.ttf'));
  final sansBold = pw.Font.ttf(await rootBundle.load('assets/fonts/PlusJakartaSans-Bold.ttf'));
  final mono = pw.Font.ttf(await rootBundle.load('assets/fonts/IBMPlexMono-Regular.ttf'));
  final arabic = pw.Font.ttf(await rootBundle.load('assets/fonts/IBMPlexSansArabic-Regular.ttf'));
  final arabicBold = pw.Font.ttf(await rootBundle.load('assets/fonts/IBMPlexSansArabic-Bold.ttf'));

  // Tickets get a receipt-shaped page, not a facture.
  if (doc.docType == 'SALE_TICKET') {
    return _buildTicketPdf(
            company: company, doc: doc, sans: sans, sansBold: sansBold, mono: mono, arabic: arabic)
        .save();
  }

  final opt = InvoiceOptions.fromSettings(company);
  if (api != null) {
    if (logo == null) {
      try {
        logo = await api.companyLogoBytes();
      } catch (_) {}
    }
    if (products == null &&
        (opt.columns.contains('barcode') || opt.columns.contains('unit'))) {
      products = {};
      for (final id in {for (final l in doc.lines) ?l.productId}) {
        try {
          products[id] = await api.getProduct(id);
        } catch (_) {}
      }
    }
  }
  products ??= const {};

  const ink = PdfColor.fromInt(0xFF0F1113);
  const muted = PdfColor.fromInt(0xFF5D6462);
  const border = PdfColor.fromInt(0xFFE4E2DC);
  const mintDark = PdfColor.fromInt(0xFF00795C);
  const headBg = PdfColor.fromInt(0xFFF0EFE9);

  final a5 = opt.format == 'a5';
  final k = a5 ? 0.86 : 1.0; // font scale
  final lang = opt.language;
  final rtl = lang == 'ar';
  final dir = rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr;
  final start = rtl ? pw.CrossAxisAlignment.end : pw.CrossAxisAlignment.start;
  final endX = rtl ? pw.CrossAxisAlignment.start : pw.CrossAxisAlignment.end;

  pw.TextStyle st(double size, {bool bold = false, PdfColor color = ink, bool m = false}) =>
      pw.TextStyle(
        font: m ? mono : (bold ? sansBold : sans),
        fontSize: size * k,
        color: color,
        fontFallback: [bold ? arabicBold : arabic],
      );
  pw.TextStyle stAr(double size, {bool bold = false, PdfColor color = ink}) =>
      pw.TextStyle(font: bold ? arabicBold : arabic, fontSize: size * k, color: color);

  final body = st(9.5);
  final small = st(8.5, color: muted);
  final monoS = st(9, m: true);

  /// A label in the chosen language(s): French, Arabic, or both stacked.
  pw.Widget lbl(String fr, String ar, {double size = 8.5, bool bold = false, PdfColor color = muted,
      pw.CrossAxisAlignment? align}) {
    switch (lang) {
      case 'ar':
        return pw.Text(ar, style: stAr(size, bold: bold, color: color), textDirection: pw.TextDirection.rtl);
      case 'both':
        return pw.Column(crossAxisAlignment: align ?? pw.CrossAxisAlignment.start, children: [
          pw.Text(fr, style: st(size, bold: bold, color: color)),
          pw.Text(ar, style: stAr(size * 0.92, bold: bold, color: color), textDirection: pw.TextDirection.rtl),
        ]);
      default:
        return pw.Text(fr, style: st(size, bold: bold, color: color));
    }
  }

  String txt(String fr, String ar) => switch (lang) { 'ar' => ar, 'both' => '$fr / $ar', _ => fr };

  final (titleFr, titleAr) = _titles[doc.docType] ?? ('DOCUMENT', 'وثيقة');

  pw.Widget totalRow(String fr, String ar, String value, {bool big = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            big ? lbl(fr, ar, size: 11, bold: true, color: ink) : lbl(fr, ar),
            pw.Text(value, style: big ? st(12, bold: true) : monoS),
          ],
        ),
      );

  final fiscal = [
    if ((company['company_nif'] ?? '').isNotEmpty) 'NIF ${company['company_nif']}',
    if ((company['company_nis'] ?? '').isNotEmpty) 'NIS ${company['company_nis']}',
    if ((company['company_rc'] ?? '').isNotEmpty) 'RC ${company['company_rc']}',
    if ((company['company_ai'] ?? '').isNotEmpty) 'AI ${company['company_ai']}',
  ].join('   ·   ');

  pw.MemoryImage? logoImg;
  if (logo != null && logo.isNotEmpty) {
    try {
      logoImg = pw.MemoryImage(Uint8List.fromList(logo));
    } catch (_) {}
  }

  // ---- Lines table: fixed + optional columns ----
  final cols = opt.columns;
  final showDiscount = cols.contains('discount');
  final heads = <(String, String, double, bool)>[
    ('Désignation', 'التعيين', 4, false),
    if (cols.contains('barcode')) ('Code-barres', 'الرمز الشريطي', 1.9, false),
    if (cols.contains('lot')) ('Lot', 'الحصة', 1.1, false),
    if (cols.contains('expiry')) ('Péremption', 'تاريخ الانتهاء', 1.3, false),
    ('Quantité', 'الكمية', 1.0, true),
    if (cols.contains('unit')) ('Unité', 'الوحدة', 0.9, false),
    ('PU HT', 'سعر الوحدة', 1.4, true),
    if (showDiscount) ('Remise', 'التخفيض', 0.9, true),
    ('TVA', 'الرسم', 0.8, true),
    ('Total TTC', 'المجموع', 1.5, true),
  ];
  String fmtDate(String? d) {
    if (d == null || d.length < 10) return '—';
    return '${d.substring(8, 10)}/${d.substring(5, 7)}/${d.substring(0, 4)}';
  }

  List<String> cells(DocLine l) {
    final p = l.productId == null ? null : products![l.productId!];
    return [
      l.description,
      if (cols.contains('barcode')) (p?.barcode ?? '').isEmpty ? '—' : p!.barcode!,
      if (cols.contains('lot')) (l.lotNumber ?? '').isEmpty ? '—' : l.lotNumber!,
      if (cols.contains('expiry')) fmtDate(l.expiryDate),
      fmtQty(l.qtyMilli),
      if (cols.contains('unit')) p?.unit ?? '—',
      fmtDA(l.unitPrice).replaceAll(' DA', ''),
      if (showDiscount) l.discountPct == 0 ? '—' : _pct(l.discountPct),
      '${l.vatRate ~/ 100}%',
      fmtDA(l.lineTTC).replaceAll(' DA', ''),
    ];
  }

  final orderedHeads = rtl ? heads.reversed.toList() : heads;
  final table = pw.Table(
    border: pw.TableBorder.symmetric(
        inside: const pw.BorderSide(color: border, width: 0.5),
        outside: const pw.BorderSide(color: border, width: 0.5)),
    columnWidths: {
      for (var i = 0; i < orderedHeads.length; i++) i: pw.FlexColumnWidth(orderedHeads[i].$3),
    },
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: headBg),
        children: [
          for (final h in orderedHeads)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: pw.Align(
                alignment: h.$4 ? pw.Alignment.centerRight : (rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft),
                child: lbl(h.$1, h.$2, size: 8, bold: true, color: ink,
                    align: h.$4 ? pw.CrossAxisAlignment.end : pw.CrossAxisAlignment.start),
              ),
            ),
        ],
      ),
      for (final l in doc.lines)
        pw.TableRow(children: [
          for (final (i, c) in (rtl ? cells(l).reversed.toList() : cells(l)).indexed)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              child: pw.Align(
                alignment: orderedHeads[i].$4 || rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
                child: pw.Text(c,
                    style: orderedHeads[i].$4 ? monoS : body,
                    textDirection: orderedHeads[i].$4 ? pw.TextDirection.ltr : dir),
              ),
            ),
        ]),
    ],
  );

  // ---- Quote validity ----
  String? validUntil;
  if (doc.docType == 'QUOTE' && opt.quoteValidityDays > 0) {
    final d = DateTime.tryParse(doc.docDate);
    if (d != null) {
      validUntil = fmtDate(d.add(Duration(days: opt.quoteValidityDays)).toIso8601String());
    }
  }

  final header = pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      if (logoImg != null) ...[
        pw.Container(
          height: (a5 ? 42 : 54).toDouble(),
          width: (a5 ? 70 : 90).toDouble(),
          alignment: pw.Alignment.topLeft,
          child: pw.Image(logoImg, fit: pw.BoxFit.contain),
        ),
        pw.SizedBox(width: 12),
      ],
      pw.Expanded(
        child: pw.Column(crossAxisAlignment: start, children: [
          pw.Text(
              company['company_name']?.isNotEmpty == true ? company['company_name']! : 'Mon commerce',
              style: st(16, bold: true), textDirection: dir),
          if ((company['company_address'] ?? '').isNotEmpty)
            pw.Text(company['company_address']!, style: small, textDirection: dir),
          if ((company['company_phone'] ?? '').isNotEmpty)
            pw.Text('${txt('Tél', 'الهاتف')} : ${company['company_phone']}', style: small, textDirection: dir),
          if (fiscal.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Text(fiscal, style: st(7.5, m: true, color: muted)),
            ),
        ]),
      ),
      pw.Column(crossAxisAlignment: endX, children: [
        if (lang != 'ar') pw.Text(titleFr, style: st(19, bold: true, color: mintDark)),
        if (lang != 'fr')
          pw.Text(titleAr,
              style: stAr(lang == 'ar' ? 19 : 14, bold: true, color: mintDark),
              textDirection: pw.TextDirection.rtl),
        pw.SizedBox(height: 3),
        pw.Text(doc.number ?? txt('BROUILLON', 'مسودة'), style: st(11, m: true)),
        pw.Text('${txt('Date', 'التاريخ')} : ${fmtDate(doc.docDate)}', style: small, textDirection: dir),
        if (validUntil != null)
          pw.Text('${txt('Valable jusqu’au', 'صالح إلى غاية')} : $validUntil',
              style: st(8.5, bold: true), textDirection: dir),
      ]),
    ],
  );

  final client = partner == null
      ? null
      : pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: border),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(crossAxisAlignment: start, children: [
            doc.docType.startsWith('PURCHASE')
                ? lbl('FOURNISSEUR', 'المورد', size: 7.5, bold: true)
                : lbl('CLIENT', 'الزبون', size: 7.5, bold: true),
            pw.SizedBox(height: 2),
            pw.Text(partner.name, style: st(11, bold: true), textDirection: dir),
            if ((partner.address ?? '').isNotEmpty)
              pw.Text(partner.address!, style: small, textDirection: dir),
            pw.Text(
                [
                  if ((partner.nif ?? '').isNotEmpty) 'NIF ${partner.nif}',
                  if ((partner.rc ?? '').isNotEmpty) 'RC ${partner.rc}',
                  if ((partner.ai ?? '').isNotEmpty) 'AI ${partner.ai}',
                ].join('   ·   '),
                style: st(7.5, m: true, color: muted)),
          ]),
        );

  final words = opt.amountInWords
      ? pw.Padding(
          padding: pw.EdgeInsets.only(top: 4, right: rtl ? 0 : 20, left: rtl ? 20 : 0),
          child: pw.Column(crossAxisAlignment: start, children: [
            if (lang != 'ar')
              pw.Text('Arrêtée la présente ${titleFr.toLowerCase()} à la somme de :',
                  style: st(8.5)),
            if (lang != 'fr')
              pw.Text('حُدِّدت هذه الوثيقة بمبلغ :',
                  style: stAr(8.5), textDirection: pw.TextDirection.rtl),
            pw.SizedBox(height: 2),
            // TODO(fiscal): montant en lettres arabe — le libellé arabe est
            // traduit, le montant reste en lettres françaises.
            pw.Text(montantEnLettres(doc.totalTTC).toUpperCase(),
                style: st(8.5, bold: true).copyWith(lineSpacing: 2)),
          ]),
        )
      : pw.SizedBox();

  final totals = pw.SizedBox(
    width: a5 ? 170 : 200,
    child: pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: border),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(children: [
        totalRow('Total HT', 'المجموع خارج الرسم', fmtDA(doc.totalHT)),
        if (doc.totalDiscount > 0) totalRow('Remise', 'التخفيض', fmtDA(doc.totalDiscount)),
        totalRow('TVA', 'الرسم على القيمة المضافة', fmtDA(doc.totalVAT)),
        if (doc.timbre > 0) totalRow('Timbre fiscal', 'طابع جبائي', fmtDA(doc.timbre)),
        pw.Divider(color: border, height: 8),
        totalRow('TOTAL TTC', 'المجموع مع الرسوم', fmtDA(doc.totalTTC), big: true),
      ]),
    ),
  );

  final pdf = pw.Document(
    theme: pw.ThemeData.withFont(base: sans, bold: sansBold, fontFallback: [arabic]),
  );
  pdf.addPage(pw.MultiPage(
    pageFormat: a5 ? PdfPageFormat.a5 : PdfPageFormat.a4,
    margin: a5 ? const pw.EdgeInsets.fromLTRB(24, 22, 24, 22) : const pw.EdgeInsets.fromLTRB(40, 36, 40, 36),
    textDirection: dir,
    footer: (context) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      if (opt.footer.isNotEmpty) ...[
        pw.Divider(color: border, height: 6),
        pw.Text(opt.footer, style: st(7.5, color: muted), textAlign: pw.TextAlign.center, textDirection: dir),
      ],
      pw.SizedBox(height: 3),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('Elixir Gestion Commerciale', style: st(6.5, color: muted)),
        if (context.pagesCount > 1)
          pw.Text('${context.pageNumber} / ${context.pagesCount}', style: st(6.5, color: muted)),
      ]),
    ]),
    build: (context) => [
      header,
      pw.SizedBox(height: 14),
      ?client,
      pw.SizedBox(height: 14),
      table,
      pw.SizedBox(height: 12),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: rtl ? [totals, pw.Expanded(child: words)] : [pw.Expanded(child: words), totals],
      ),
      // ---- Note imprimée (la note interne ne sort jamais) ----
      if ((doc.notes ?? '').trim().isNotEmpty) ...[
        pw.SizedBox(height: 12),
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: border),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(crossAxisAlignment: start, children: [
            lbl('NOTE', 'ملاحظة', size: 7.5, bold: true),
            pw.SizedBox(height: 2),
            pw.Text(doc.notes!.trim(), style: body, textDirection: dir),
          ]),
        ),
      ],
      if (doc.dueDate != null && (doc.docType == 'SALE_INVOICE' || doc.docType == 'PURCHASE_INVOICE'))
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 8),
          child: pw.Text('${txt('Échéance de paiement', 'تاريخ الاستحقاق')} : ${fmtDate(doc.dueDate)}',
              style: small, textDirection: dir),
        ),
    ],
  ));
  return pdf.save();
}

Future<String> _saveAndOpen(Uint8List bytes, String name) async {
  final home = Platform.environment['USERPROFILE'] ?? '.';
  final dir = Directory('$home\\Documents\\Elixir\\documents');
  await dir.create(recursive: true);
  final safeName = name.replaceAll(RegExp(r'[^\w\-]'), '_');
  final file = File('${dir.path}\\$safeName.pdf');
  await file.writeAsBytes(bytes);
  await Process.run('cmd', ['/c', 'start', '', file.path]);
  return file.path;
}

/// 80mm receipt PDF — for reprints, sharing, or shops without a thermal
/// printer. Mirrors the ESC/POS layout.
pw.Document _buildTicketPdf({
  required Map<String, String> company,
  required DocDetail doc,
  required pw.Font sans,
  required pw.Font sansBold,
  required pw.Font mono,
  required pw.Font arabic,
}) {
  const ink = PdfColor.fromInt(0xFF0F1113);
  const muted = PdfColor.fromInt(0xFF5D6462);
  final body = pw.TextStyle(font: sans, fontSize: 8, color: ink);
  final monoS = pw.TextStyle(font: mono, fontSize: 8, color: ink);
  final tiny = pw.TextStyle(font: sans, fontSize: 7, color: muted);

  pw.Widget row(String l, String r, {bool bold = false, double size = 8}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(l, style: pw.TextStyle(font: bold ? sansBold : sans, fontSize: size, color: ink)),
            pw.Text(r, style: pw.TextStyle(font: mono, fontSize: size, color: ink)),
          ],
        ),
      );

  pw.Widget divider() => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Container(height: 0.7, color: const PdfColor.fromInt(0xFFB0B5B2)),
      );

  final footer = (company['company_footer'] ?? '').trim();
  final pdf = pw.Document(theme: pw.ThemeData.withFont(base: sans, bold: sansBold, fontFallback: [arabic]));
  pdf.addPage(pw.Page(
    pageFormat: PdfPageFormat.roll80,
    margin: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    build: (context) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Center(
          child: pw.Text(
              company['company_name']?.isNotEmpty == true ? company['company_name']! : 'ELIXIR',
              style: pw.TextStyle(font: sansBold, fontSize: 11, color: ink)),
        ),
        if ((company['company_address'] ?? '').isNotEmpty)
          pw.Center(child: pw.Text(company['company_address']!, style: tiny)),
        if ((company['company_phone'] ?? '').isNotEmpty)
          pw.Center(child: pw.Text('Tél : ${company['company_phone']}', style: tiny)),
        if ((company['company_nif'] ?? '').isNotEmpty)
          pw.Center(child: pw.Text('NIF : ${company['company_nif']}', style: tiny)),
        divider(),
        row(doc.number ?? '', doc.docDate),
        divider(),
        for (final l in doc.lines) ...[
          pw.Text(l.description, style: body),
          row('  ${fmtQty(l.qtyMilli)} x ${fmtDA(_unitTTC(l)).replaceAll(' DA', '')}',
              fmtDA(l.lineTTC).replaceAll(' DA', '')),
        ],
        divider(),
        row('Sous-total HT', fmtDA(doc.totalHT).replaceAll(' DA', '')),
        row('TVA', fmtDA(doc.totalVAT).replaceAll(' DA', '')),
        if (doc.timbre > 0) row('Timbre fiscal', fmtDA(doc.timbre).replaceAll(' DA', '')),
        pw.SizedBox(height: 2),
        row('TOTAL', fmtDA(doc.totalTTC), bold: true, size: 11),
        divider(),
        if ((doc.notes ?? '').trim().isNotEmpty) ...[
          pw.Text(doc.notes!.trim(), style: tiny),
          divider(),
        ],
        pw.Center(
            child: pw.Text(footer.isNotEmpty ? footer : 'Merci de votre visite !',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(font: sans, fontSize: 8, color: ink))),
        pw.SizedBox(height: 4),
        pw.Center(child: pw.Text(doc.id.substring(0, 8), style: monoS)),
      ],
    ),
  ));
  return pdf;
}

/// 1250 → « 12,5 % », 500 → « 5 % ».
String _pct(int x100) =>
    x100 % 100 == 0 ? '${x100 ~/ 100}%' : '${(x100 / 100).toStringAsFixed(2).replaceAll(RegExp(r'0$'), '').replaceAll('.', ',')}%';

int _unitTTC(DocLine l) => l.qtyMilli == 0 ? 0 : (l.lineTTC * 1000 + l.qtyMilli ~/ 2) ~/ l.qtyMilli;
