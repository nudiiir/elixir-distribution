import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'export.dart' as csv;

/// Export formats offered by every list's « Exporter » menu.
enum ExportFormat { xlsx, csv, pdf, print }

extension ExportFormatLabel on ExportFormat {
  String get label => switch (this) {
        ExportFormat.xlsx => 'Excel (.xlsx)',
        ExportFormat.csv => 'CSV',
        ExportFormat.pdf => 'PDF',
        ExportFormat.print => 'Imprimer',
      };
}

/// A table ready to export: headers + rows of cells. A cell is a [num]
/// (written as a number in Excel, right-aligned in PDF) or a [String].
class ExportTable {
  ExportTable({
    required this.title,
    required this.baseName,
    required this.headers,
    required this.rows,
    this.numeric = const {},
  });

  final String title; // « Produits », « Ventes — octobre 2026 »…
  final String baseName; // file name stem, no extension
  final List<String> headers;
  final List<List<Object?>> rows;
  final Set<int> numeric; // column indexes aligned right in the PDF
}

String _two(int n) => n.toString().padLeft(2, '0');

Future<Directory> _exportDir() async {
  final home = Platform.environment['USERPROFILE'] ?? '.';
  final dir = Directory('$home\\Documents\\Elixir\\exports');
  await dir.create(recursive: true);
  return dir;
}

String _stamp() {
  final t = DateTime.now();
  return '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';
}

String _cellText(Object? v) => v == null ? '' : v.toString();

/// Writes the table in the chosen format under Documents\Elixir\exports,
/// reveals it (or prints it) and returns the path.
Future<String> exportTable(ExportTable t, ExportFormat f,
    {Map<String, String> company = const {}}) async {
  switch (f) {
    case ExportFormat.csv:
      return csv.exportCsv(
        baseName: t.baseName,
        headers: t.headers,
        rows: [for (final r in t.rows) r.map(_cellText).toList()],
      );
    case ExportFormat.xlsx:
      final file = File('${(await _exportDir()).path}\\${t.baseName}-${_stamp()}.xlsx');
      await file.writeAsBytes(buildXlsx(t));
      Process.run('explorer.exe', ['/select,${file.path}']);
      return file.path;
    case ExportFormat.pdf:
    case ExportFormat.print:
      final file = File('${(await _exportDir()).path}\\${t.baseName}-${_stamp()}.pdf');
      await file.writeAsBytes(await buildListPdf(t, company: company));
      if (f == ExportFormat.print) {
        // Windows' « Imprimer » verb on the PDF; falls back to opening it.
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          'Start-Process -FilePath "${file.path}" -Verb Print',
        ]);
        if (r.exitCode != 0) {
          Process.run('cmd', ['/c', 'start', '', file.path]);
        }
      } else {
        Process.run('cmd', ['/c', 'start', '', file.path]);
      }
      return file.path;
  }
}

// ---------------------------------------------------------------- XLSX ----

String _xml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _colName(int i) {
  var n = i + 1;
  var s = '';
  while (n > 0) {
    final m = (n - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

/// Minimal Office Open XML workbook: one sheet, bold header row (style 1),
/// inline strings, real numbers. Opens in Excel and LibreOffice.
List<int> buildXlsx(ExportTable t) {
  final sheet = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
    ..write('<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>')
    ..write('<cols>');
  for (var c = 0; c < t.headers.length; c++) {
    final width = t.numeric.contains(c) ? 14 : 28;
    sheet.write('<col min="${c + 1}" max="${c + 1}" width="$width" customWidth="1"/>');
  }
  sheet.write('</cols><sheetData>');

  void row(int r, List<Object?> cells, {bool header = false}) {
    sheet.write('<row r="$r">');
    for (var c = 0; c < cells.length; c++) {
      final ref = '${_colName(c)}$r';
      final v = cells[c];
      final style = header ? ' s="1"' : '';
      if (v is num && !header) {
        sheet.write('<c r="$ref"$style><v>$v</v></c>');
      } else {
        sheet.write('<c r="$ref" t="inlineStr"$style><is><t xml:space="preserve">${_xml(_cellText(v))}</t></is></c>');
      }
    }
    sheet.write('</row>');
  }

  row(1, t.headers, header: true);
  for (var i = 0; i < t.rows.length; i++) {
    row(i + 2, t.rows[i]);
  }
  sheet.write('</sheetData></worksheet>');

  const contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '</Types>';
  const rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>';
  final sheetName = _xml(t.title.length > 31 ? t.title.substring(0, 31) : t.title)
      .replaceAll(RegExp(r'[\\/?*\[\]:]'), ' ');
  final workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets><sheet name="$sheetName" sheetId="1" r:id="rId1"/></sheets></workbook>';
  const wbRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '</Relationships>';
  const styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
      '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
      '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>'
      '</styleSheet>';

  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('[Content_Types].xml', contentTypes);
  add('_rels/.rels', rels);
  add('xl/workbook.xml', workbook);
  add('xl/_rels/workbook.xml.rels', wbRels);
  add('xl/styles.xml', styles);
  add('xl/worksheets/sheet1.xml', sheet.toString());
  return ZipEncoder().encode(archive);
}

// ----------------------------------------------------------------- PDF ----

/// A4 landscape table with the shop name, the list title, the export date
/// and page numbers. Long tables flow over several pages, header repeated.
Future<List<int>> buildListPdf(ExportTable t,
    {Map<String, String> company = const {}}) async {
  final sans = pw.Font.ttf(
      await rootBundle.load('assets/fonts/PlusJakartaSans-Regular.ttf'));
  final bold = pw.Font.ttf(
      await rootBundle.load('assets/fonts/PlusJakartaSans-Bold.ttf'));
  final arabic = pw.Font.ttf(
      await rootBundle.load('assets/fonts/IBMPlexSansArabic-Regular.ttf'));
  const muted = PdfColor.fromInt(0xFF5D6462);
  const border = PdfColor.fromInt(0xFFE4E2DC);
  const head = PdfColor.fromInt(0xFFF0EFE9);

  final now = DateTime.now();
  final stamp = '${_two(now.day)}/${_two(now.month)}/${now.year} ${_two(now.hour)}:${_two(now.minute)}';
  final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: sans, bold: bold, fontFallback: [arabic]));
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(28),
    header: (ctx) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 10),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                if ((company['company_name'] ?? '').isNotEmpty)
                  pw.Text(company['company_name']!,
                      style: pw.TextStyle(font: bold, fontSize: 11)),
                pw.Text(t.title, style: pw.TextStyle(font: bold, fontSize: 15)),
              ],
            ),
          ),
          pw.Text('${t.rows.length} lignes · $stamp',
              style: const pw.TextStyle(fontSize: 8.5, color: muted)),
        ],
      ),
    ),
    footer: (ctx) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('Page ${ctx.pageNumber} / ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: muted)),
    ),
    build: (ctx) => [
      pw.TableHelper.fromTextArray(
        headers: t.headers,
        data: [for (final r in t.rows) r.map(_cellText).toList()],
        headerStyle: pw.TextStyle(font: bold, fontSize: 8.5),
        headerDecoration: const pw.BoxDecoration(color: head),
        cellStyle: const pw.TextStyle(fontSize: 8.5),
        cellAlignments: {
          for (final c in t.numeric) c: pw.Alignment.centerRight,
        },
        headerAlignments: {
          for (final c in t.numeric) c: pw.Alignment.centerRight,
        },
        border: const pw.TableBorder(
          horizontalInside: pw.BorderSide(color: border, width: 0.5),
          bottom: pw.BorderSide(color: border, width: 0.5),
        ),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      ),
    ],
  ));
  return doc.save();
}
