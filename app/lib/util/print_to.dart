import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'escpos.dart';
import 'raw_printer.dart';

/// Sends a PDF file to a given Windows printer with the shell « PrintTo »
/// verb (null printer = « Print » on the Windows default printer). Falls
/// back to opening the PDF when no PDF reader handles printing.
/// Used by Paramètres → Impression (test pages); the A4 / label printers of
/// LocalConfig can use it too.
Future<void> printPdfTo(String path, String? printer) async {
  final ps = printer == null || printer.isEmpty
      ? 'Start-Process -FilePath "$path" -Verb Print'
      : 'Start-Process -FilePath "$path" -Verb PrintTo -ArgumentList \'"${printer.replaceAll("'", "''")}"\'';
  final r = await Process.run('powershell', ['-NoProfile', '-Command', ps]);
  if (r.exitCode != 0) {
    await Process.run('cmd', ['/c', 'start', '', path]);
    throw Exception('Windows n’a pas pu imprimer directement le PDF : il a été ouvert, '
        'imprimez-le depuis la fenêtre qui s’affiche.');
  }
}

String _stamp() {
  final d = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Test page for an A4 or label printer: a PDF in %TEMP% sent to [printer].
Future<void> printTestPdf({required String? printer, required bool label}) async {
  final sans = pw.Font.ttf(await rootBundle.load('assets/fonts/PlusJakartaSans-Regular.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/PlusJakartaSans-Bold.ttf'));
  final doc = pw.Document(theme: pw.ThemeData.withFont(base: sans, bold: bold));
  final format = label
      ? const PdfPageFormat(50 * PdfPageFormat.mm, 30 * PdfPageFormat.mm, marginAll: 2 * PdfPageFormat.mm)
      : PdfPageFormat.a4.copyWith(
          marginLeft: 20 * PdfPageFormat.mm,
          marginRight: 20 * PdfPageFormat.mm,
          marginTop: 20 * PdfPageFormat.mm,
          marginBottom: 20 * PdfPageFormat.mm);
  doc.addPage(pw.Page(
    pageFormat: format,
    build: (_) => label
        ? pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              pw.Text('Elixir — étiquette test', style: pw.TextStyle(font: bold, fontSize: 8)),
              pw.SizedBox(height: 2),
              pw.BarcodeWidget(
                  barcode: pw.Barcode.ean13(), data: '2000000000008', width: 38 * PdfPageFormat.mm, height: 12 * PdfPageFormat.mm,
                  textStyle: const pw.TextStyle(fontSize: 6)),
              pw.Text(_stamp(), style: const pw.TextStyle(fontSize: 6)),
            ])
        : pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Page de test — Elixir Gestion', style: pw.TextStyle(font: bold, fontSize: 22)),
            pw.SizedBox(height: 8),
            pw.Text('Imprimée le ${_stamp()} sur « ${printer ?? 'imprimante par défaut'} ».',
                style: const pw.TextStyle(fontSize: 12)),
            pw.SizedBox(height: 18),
            pw.Text('Si vous lisez ceci correctement, l’imprimante est prête pour vos factures, '
                'devis et bons. Accents : é è à ç ù — chiffres : 0123456789 — 1 234,56 DA',
                style: const pw.TextStyle(fontSize: 12)),
            pw.SizedBox(height: 18),
            pw.Container(
              height: 60,
              decoration: pw.BoxDecoration(border: pw.Border.all(width: 1)),
              alignment: pw.Alignment.center,
              child: pw.Text('Le cadre doit être entier : les marges sont bonnes.',
                  style: const pw.TextStyle(fontSize: 11)),
            ),
          ]),
  ));
  final f = File('${Directory.systemTemp.path}\\elixir-test-${label ? 'etiquette' : 'a4'}-'
      '${DateTime.now().millisecondsSinceEpoch}.pdf');
  await f.writeAsBytes(await doc.save());
  await printPdfTo(f.path, printer);
}

/// Test ticket on the thermal printer (raw ESC/POS).
Future<void> printTestTicket(String printer, {bool openDrawer = false}) async {
  final p = EscPos();
  p.align(1);
  p.doubleSize(true);
  p.text('TEST');
  p.doubleSize(false);
  p.text('Elixir Gestion');
  p.text(_stamp());
  p.align(0);
  p.divider();
  p.text('Imprimante : $printer');
  p.row('Article exemple', '120,00 DA');
  p.row('Quantité', '2');
  p.divider('=');
  p.bold(true);
  p.row('TOTAL', '240,00 DA');
  p.bold(false);
  p.divider();
  p.align(1);
  p.text('Si ce ticket est lisible,');
  p.text('l’imprimante est prête.');
  p.feed(4);
  p.cut();
  await rawPrint(printer, openDrawer ? [...drawerKick, ...p.bytes] : p.bytes);
}
