import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../api/models.dart';
import '../theme/tokens.dart' show fmtDA, fmtQty;
import '../util/lettres.dart';
import 'template_model.dart';

/// Renders a designer template to PDF. Elements are placed absolutely, in
/// millimetres, exactly as laid out on the canvas.

class _Fonts {
  _Fonts(this.sans, this.sansBold, this.mono, this.ar, this.arBold);
  final pw.Font sans, sansBold, mono, ar, arBold;
}

_Fonts? _cache;

Future<_Fonts> _fonts() async {
  if (_cache != null) return _cache!;
  Future<pw.Font> load(String p) async =>
      pw.Font.ttf(await rootBundle.load('assets/fonts/$p'));
  _cache = _Fonts(
    await load('PlusJakartaSans-Regular.ttf'),
    await load('PlusJakartaSans-Bold.ttf'),
    await load('IBMPlexMono-Regular.ttf'),
    await load('IBMPlexSansArabic-Regular.ttf'),
    await load('IBMPlexSansArabic-Bold.ttf'),
  );
  return _cache!;
}

final _arabicRe = RegExp(r'[؀-ۿ]');

bool _validEan13(String v) {
  if (!RegExp(r'^\d{13}$').hasMatch(v)) return false;
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    final d = v.codeUnitAt(i) - 48;
    sum += i.isOdd ? d * 3 : d;
  }
  return (10 - sum % 10) % 10 == v.codeUnitAt(12) - 48;
}

const _ink = PdfColor.fromInt(0xFF0F1113);
const _border = PdfColor.fromInt(0xFFB0B5B2);

Future<Uint8List> renderTemplateBytes(
  TplDoc tpl, {
  required String lang,
  required Map<String, String> data,
  List<List<String>> tableRows = const [],
}) =>
    renderTemplatePages(tpl, lang: lang, pages: [data], tableRows: tableRows);

/// Same as [renderTemplateBytes], one page per data map (e.g. a sheet of
/// shelf labels for several products) in a single PDF.
Future<Uint8List> renderTemplatePages(
  TplDoc tpl, {
  required String lang,
  required List<Map<String, String>> pages,
  List<List<String>> tableRows = const [],
}) async {
  var data = pages.isEmpty ? const <String, String>{} : pages.first;
  final f = await _fonts();
  const mm = PdfPageFormat.mm;

  pw.TextStyle style(TplElement e, String content) {
    final arabic = lang == 'ar' || _arabicRe.hasMatch(content);
    final font = e.mono
        ? f.mono
        : arabic
            ? (e.bold ? f.arBold : f.ar)
            : (e.bold ? f.sansBold : f.sans);
    return pw.TextStyle(
      font: font,
      fontFallback: [f.ar, f.sans, f.mono],
      fontSize: e.fontSize,
      fontStyle: e.italic ? pw.FontStyle.italic : pw.FontStyle.normal,
      color: _ink,
    );
  }

  pw.Widget textWidget(TplElement e, String content) => pw.Text(
        content,
        style: style(e, content),
        textAlign: switch (e.align) {
          'center' => pw.TextAlign.center,
          'right' => pw.TextAlign.right,
          _ => pw.TextAlign.left,
        },
        textDirection: _arabicRe.hasMatch(content)
            ? pw.TextDirection.rtl
            : pw.TextDirection.ltr,
      );

  pw.Widget barcodeWidget(TplElement e) {
    final value = data[e.field.isEmpty ? 'product.barcode' : e.field] ?? '';
    if (value.isEmpty) {
      return pw.Center(child: textWidget(e, '(pas de code-barres)'));
    }
    // EAN-13 only for a 13-digit code whose checksum is actually valid —
    // anything else (typed codes, refs) falls back to Code 128.
    return pw.BarcodeWidget(
      barcode: _validEan13(value) ? pw.Barcode.ean13() : pw.Barcode.code128(),
      data: value,
      drawText: true,
      textStyle: pw.TextStyle(font: f.mono, fontSize: 6, color: _ink),
      color: _ink,
    );
  }

  pw.Widget tableWidget(TplElement e) {
    final ar = lang == 'ar';
    final headers = ar
        ? ['المبلغ', 'سعر الوحدة', 'الكمية', 'البيان']
        : ['Désignation', 'Qté', 'PU HT', 'Montant HT'];
    final rows = [
      for (final r in tableRows) ar ? r.reversed.toList() : r,
    ];
    final flexDesc = const pw.FlexColumnWidth(4);
    final flexNum = const pw.FlexColumnWidth(1.3);
    return pw.TableHelper.fromTextArray(
      headers: headers,
      headerStyle: pw.TextStyle(
          font: ar ? f.arBold : f.sansBold,
          fontFallback: [f.ar, f.sans],
          fontSize: e.fontSize,
          color: _ink),
      cellStyle: pw.TextStyle(
          font: ar ? f.ar : f.sans,
          fontFallback: [f.ar, f.sans, f.mono],
          fontSize: e.fontSize,
          color: _ink),
      headerDecoration:
          const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF0EFE9)),
      border: pw.TableBorder.all(color: _border, width: 0.4),
      columnWidths: ar
          ? {0: flexNum, 1: flexNum, 2: flexNum, 3: flexDesc}
          : {0: flexDesc, 1: flexNum, 2: flexNum, 3: flexNum},
      cellAlignments: ar
          ? {0: pw.Alignment.centerLeft, 1: pw.Alignment.centerLeft,
             2: pw.Alignment.centerLeft, 3: pw.Alignment.centerRight}
          : {1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight,
             3: pw.Alignment.centerRight},
      data: rows,
    );
  }

  // Widgets are built eagerly per page so each page keeps its own data.
  pw.Widget pageContent() => pw.Stack(children: [
      for (final e in tpl.elements)
        pw.Positioned(
          left: e.x * mm,
          top: e.y * mm,
          child: pw.SizedBox(
            width: e.w * mm,
            height: e.type == 'line' ? null : e.h * mm,
            child: switch (e.type) {
              'text' => textWidget(e, e.text),
              'field' => textWidget(e, data[e.field] ?? ''),
              'barcode' => barcodeWidget(e),
              'line' => pw.Container(height: e.borderWidth, color: _ink),
              'rect' => pw.Container(
                  decoration: pw.BoxDecoration(
                    color: e.filled
                        ? const PdfColor.fromInt(0xFFF0EFE9)
                        : null,
                    border:
                        pw.Border.all(color: _ink, width: e.borderWidth),
                  ),
                ),
              'table' => tableWidget(e),
              _ => pw.SizedBox(),
            },
          ),
        ),
    ]);

  final pdf = pw.Document();
  for (final d in pages.isEmpty ? [data] : pages) {
    data = d;
    final content = pageContent();
    pdf.addPage(pw.Page(
      pageFormat: PdfPageFormat(tpl.widthMm * mm, tpl.heightMm * mm),
      margin: pw.EdgeInsets.zero,
      build: (context) => content,
    ));
  }
  return pdf.save();
}

/// Saves the rendered bytes under Documents\Elixir and opens the PDF.
Future<String> saveAndOpenPdf(Uint8List bytes, String baseName) async {
  final home = Platform.environment['USERPROFILE'] ?? '.';
  final dir = Directory('$home\\Documents\\Elixir\\documents');
  await dir.create(recursive: true);
  final safe = baseName.replaceAll(RegExp(r'[^\w\-]'), '_');
  final file = File('${dir.path}\\$safe.pdf');
  await file.writeAsBytes(bytes);
  await Process.run('cmd', ['/c', 'start', '', file.path]);
  return file.path;
}

// ---- Data builders: shop objects -> the flat map the renderer consumes ----

Map<String, String> _shopData(Map<String, String> company) => {
      'shop.name': company['company_name']?.isNotEmpty == true
          ? company['company_name']!
          : 'Mon commerce',
      'shop.address': company['company_address'] ?? '',
      'shop.phone': company['company_phone'] ?? '',
      'shop.nif': company['company_nif'] ?? '',
      'shop.rc': company['company_rc'] ?? '',
      'shop.ai': company['company_ai'] ?? '',
    };

Map<String, String> labelData(Product p, Map<String, String> company) => {
      ..._shopData(company),
      'product.name': p.name,
      'product.name_ar': p.nameAr ?? p.name,
      'product.price': fmtDA(p.effectivePriceTTC),
      'product.barcode': p.barcode ?? (p.barcodes.isEmpty ? '' : p.barcodes.first),
      'date': DateTime.now().toIso8601String().substring(0, 10),
    };

Map<String, String> warrantyData({
  required Product product,
  required DocDetail doc,
  Partner? client,
  required Map<String, String> company,
}) {
  final sold = DateTime.tryParse(doc.docDate) ?? DateTime.now();
  final end = DateTime(
      sold.year, sold.month + product.warrantyMonths, sold.day);
  String iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  return {
    ..._shopData(company),
    'doc.number': doc.number ?? '',
    'doc.date': doc.docDate,
    'client.name': client?.name ?? '—',
    'product.name': product.name,
    'product.barcode': product.barcode ?? '',
    'warranty.months': '${product.warrantyMonths}',
    'warranty.end': iso(end),
  };
}

Map<String, String> invoiceData({
  required DocDetail doc,
  Partner? client,
  required Map<String, String> company,
  required String title,
}) =>
    {
      ..._shopData(company),
      'doc.title': title,
      'doc.number': doc.number ?? 'BROUILLON',
      'doc.date': doc.docDate,
      'client.name': client?.name ?? '',
      'client.address': client?.address ?? '',
      'client.nif': (client?.nif ?? '').isEmpty ? '' : 'NIF ${client!.nif}',
      'client.rc': (client?.rc ?? '').isEmpty ? '' : 'RC ${client!.rc}',
      'total.ht': fmtDA(doc.totalHT),
      'total.vat': fmtDA(doc.totalVAT),
      'total.timbre': fmtDA(doc.timbre),
      'total.ttc': fmtDA(doc.totalTTC),
      'total.lettres':
          'Arrêté à la somme de : ${montantEnLettres(doc.totalTTC)}',
    };

List<List<String>> invoiceTableRows(DocDetail doc) => [
      for (final l in doc.lines)
        [
          l.description,
          fmtQty(l.qtyMilli),
          fmtDA(l.unitPrice).replaceAll(' DA', ''),
          fmtDA(l.lineHT).replaceAll(' DA', ''),
        ],
    ];
