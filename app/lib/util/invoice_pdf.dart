import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../api/models.dart';
import '../theme/tokens.dart' show fmtDA, fmtQty;
import 'lettres.dart';

const _titles = {
  'SALE_INVOICE': 'FACTURE',
  'QUOTE': 'DEVIS',
  'DELIVERY_NOTE': 'BON DE LIVRAISON',
  'SALE_CREDIT_NOTE': 'AVOIR',
  'PURCHASE_ORDER': 'BON DE COMMANDE',
};

bool canPdf(String docType) => _titles.containsKey(docType);

/// Renders an A4 PDF for the document (facture légale 05-468 layout with the
/// montant en lettres), saves it under Documents\Elixir\documents and opens it.
Future<String> openDocumentPdf({
  required Map<String, String> company,
  required DocDetail doc,
  Partner? partner,
}) async {
  final sans = pw.Font.ttf(
      await rootBundle.load('assets/fonts/PlusJakartaSans-Regular.ttf'));
  final sansBold = pw.Font.ttf(
      await rootBundle.load('assets/fonts/PlusJakartaSans-Bold.ttf'));
  final mono = pw.Font.ttf(
      await rootBundle.load('assets/fonts/IBMPlexMono-Regular.ttf'));

  const ink = PdfColor.fromInt(0xFF0F1113);
  const muted = PdfColor.fromInt(0xFF5D6462);
  const border = PdfColor.fromInt(0xFFE4E2DC);
  const mintDark = PdfColor.fromInt(0xFF00795C);

  final title = _titles[doc.docType] ?? 'DOCUMENT';
  final body = pw.TextStyle(font: sans, fontSize: 9.5, color: ink);
  final small = pw.TextStyle(font: sans, fontSize: 8.5, color: muted);
  final monoS = pw.TextStyle(font: mono, fontSize: 9, color: ink);

  pw.Widget totalRow(String label, String value, {bool big = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label,
                style: big
                    ? pw.TextStyle(font: sansBold, fontSize: 11, color: ink)
                    : small),
            pw.Text(value,
                style: big
                    ? pw.TextStyle(font: sansBold, fontSize: 12, color: ink)
                    : monoS),
          ],
        ),
      );

  final fiscal = [
    if ((company['company_nif'] ?? '').isNotEmpty)
      'NIF ${company['company_nif']}',
    if ((company['company_nis'] ?? '').isNotEmpty)
      'NIS ${company['company_nis']}',
    if ((company['company_rc'] ?? '').isNotEmpty)
      'RC ${company['company_rc']}',
    if ((company['company_ai'] ?? '').isNotEmpty)
      'AI ${company['company_ai']}',
  ].join('   ·   ');

  final pdf = pw.Document();
  pdf.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 36),
    build: (context) => [
      // ---- Header ----
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                    company['company_name']?.isNotEmpty == true
                        ? company['company_name']!
                        : 'Mon commerce',
                    style: pw.TextStyle(
                        font: sansBold, fontSize: 16, color: ink)),
                if ((company['company_address'] ?? '').isNotEmpty)
                  pw.Text(company['company_address']!, style: small),
                if ((company['company_phone'] ?? '').isNotEmpty)
                  pw.Text('Tél : ${company['company_phone']}', style: small),
                if (fiscal.isNotEmpty)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 4),
                    child: pw.Text(fiscal,
                        style: pw.TextStyle(
                            font: mono, fontSize: 7.5, color: muted)),
                  ),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(title,
                  style: pw.TextStyle(
                      font: sansBold, fontSize: 19, color: mintDark)),
              pw.SizedBox(height: 3),
              pw.Text(doc.number ?? 'BROUILLON',
                  style: pw.TextStyle(font: mono, fontSize: 11, color: ink)),
              pw.Text('Date : ${doc.docDate}', style: small),
            ],
          ),
        ],
      ),
      pw.SizedBox(height: 14),
      // ---- Client ----
      if (partner != null)
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: border),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                  doc.docType.startsWith('PURCHASE')
                      ? 'FOURNISSEUR'
                      : 'CLIENT',
                  style: pw.TextStyle(
                      font: sansBold, fontSize: 7.5, color: muted)),
              pw.SizedBox(height: 2),
              pw.Text(partner.name,
                  style:
                      pw.TextStyle(font: sansBold, fontSize: 11, color: ink)),
              if ((partner.address ?? '').isNotEmpty)
                pw.Text(partner.address!, style: small),
              pw.Text(
                  [
                    if ((partner.nif ?? '').isNotEmpty) 'NIF ${partner.nif}',
                    if ((partner.rc ?? '').isNotEmpty) 'RC ${partner.rc}',
                    if ((partner.ai ?? '').isNotEmpty) 'AI ${partner.ai}',
                  ].join('   ·   '),
                  style:
                      pw.TextStyle(font: mono, fontSize: 7.5, color: muted)),
            ],
          ),
        ),
      pw.SizedBox(height: 14),
      // ---- Lines ----
      pw.TableHelper.fromTextArray(
        headers: ['Désignation', 'Qté', 'PU HT', 'Rem.', 'TVA', 'Total TTC'],
        headerStyle: pw.TextStyle(font: sansBold, fontSize: 8.5, color: ink),
        headerDecoration:
            const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF0EFE9)),
        cellStyle: body,
        border: pw.TableBorder.symmetric(
            inside: const pw.BorderSide(color: border, width: 0.5),
            outside: const pw.BorderSide(color: border, width: 0.5)),
        columnWidths: {
          0: const pw.FlexColumnWidth(4),
          1: const pw.FlexColumnWidth(0.9),
          2: const pw.FlexColumnWidth(1.4),
          3: const pw.FlexColumnWidth(0.8),
          4: const pw.FlexColumnWidth(0.8),
          5: const pw.FlexColumnWidth(1.5),
        },
        cellAlignments: {
          1: pw.Alignment.centerRight,
          2: pw.Alignment.centerRight,
          3: pw.Alignment.centerRight,
          4: pw.Alignment.centerRight,
          5: pw.Alignment.centerRight,
        },
        data: [
          for (final l in doc.lines)
            [
              l.description,
              fmtQty(l.qtyMilli),
              fmtDA(l.unitPrice).replaceAll(' DA', ''),
              l.discountPct == 0 ? '—' : '${l.discountPct ~/ 100}%',
              '${l.vatRate ~/ 100}%',
              fmtDA(l.lineTTC).replaceAll(' DA', ''),
            ],
        ],
      ),
      pw.SizedBox(height: 12),
      // ---- Totals ----
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4, right: 20),
              child: pw.Text(
                'Arrêtée la présente ${title.toLowerCase()} à la somme de :\n'
                '${montantEnLettres(doc.totalTTC).toUpperCase()}',
                style: pw.TextStyle(
                    font: sans,
                    fontSize: 8.5,
                    color: ink,
                    lineSpacing: 2),
              ),
            ),
          ),
          pw.SizedBox(
            width: 190,
            child: pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: border),
                borderRadius: pw.BorderRadius.circular(6),
              ),
              child: pw.Column(children: [
                totalRow('Total HT', fmtDA(doc.totalHT)),
                if (doc.totalDiscount > 0)
                  totalRow('Remise', fmtDA(doc.totalDiscount)),
                totalRow('TVA', fmtDA(doc.totalVAT)),
                if (doc.timbre > 0)
                  totalRow('Timbre fiscal', fmtDA(doc.timbre)),
                pw.Divider(color: border, height: 8),
                totalRow('TOTAL TTC', fmtDA(doc.totalTTC), big: true),
              ]),
            ),
          ),
        ],
      ),
      pw.SizedBox(height: 20),
      pw.Text(
          'Document généré par Elixir Gestion Commerciale',
          style: pw.TextStyle(font: sans, fontSize: 7, color: muted)),
    ],
  ));

  final home = Platform.environment['USERPROFILE'] ?? '.';
  final dir = Directory('$home\\Documents\\Elixir\\documents');
  await dir.create(recursive: true);
  final safeName = (doc.number ?? 'brouillon-${doc.id.substring(0, 8)}')
      .replaceAll(RegExp(r'[^\w\-]'), '_');
  final file = File('${dir.path}\\$safeName.pdf');
  await file.writeAsBytes(await pdf.save());
  await Process.run('cmd', ['/c', 'start', '', file.path]);
  return file.path;
}
