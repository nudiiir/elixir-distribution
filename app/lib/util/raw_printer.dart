import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Lists the printers installed on this machine.
List<String> listPrinters() {
  final names = <String>[];
  const flags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;
  final needed = calloc<DWORD>();
  final returned = calloc<DWORD>();
  try {
    EnumPrinters(flags, nullptr, 4, nullptr, 0, needed, returned);
    if (needed.value == 0) return names;
    final buf = calloc<BYTE>(needed.value);
    try {
      if (EnumPrinters(flags, nullptr, 4, buf, needed.value, needed, returned) !=
          0) {
        final infos = buf.cast<PRINTER_INFO_4>();
        for (var i = 0; i < returned.value; i++) {
          final name = infos[i].pPrinterName;
          if (name != nullptr) names.add(name.toDartString());
        }
      }
    } finally {
      calloc.free(buf);
    }
  } finally {
    calloc.free(needed);
    calloc.free(returned);
  }
  return names;
}

/// Sends raw bytes (ESC/POS) straight to a Windows printer queue.
/// Throws with a readable message on failure.
Future<void> rawPrint(String printerName, List<int> bytes) async {
  final hPrinter = calloc<HANDLE>();
  final name = printerName.toNativeUtf16();
  try {
    if (OpenPrinter(name, hPrinter, nullptr) == 0) {
      throw Exception('Imprimante « $printerName » introuvable.');
    }
    final docInfo = calloc<DOC_INFO_1>();
    final docName = 'Ticket Elixir'.toNativeUtf16();
    final dataType = 'RAW'.toNativeUtf16();
    docInfo.ref.pDocName = docName;
    docInfo.ref.pOutputFile = nullptr;
    docInfo.ref.pDatatype = dataType;
    try {
      if (StartDocPrinter(hPrinter.value, 1, docInfo) == 0) {
        throw Exception("Impossible de démarrer l'impression.");
      }
      StartPagePrinter(hPrinter.value);
      final data = calloc<Uint8>(bytes.length);
      final written = calloc<DWORD>();
      try {
        data.asTypedList(bytes.length).setAll(0, bytes);
        if (WritePrinter(
                hPrinter.value, data.cast(), bytes.length, written) ==
            0) {
          throw Exception("Échec d'envoi vers l'imprimante.");
        }
      } finally {
        calloc.free(data);
        calloc.free(written);
      }
      EndPagePrinter(hPrinter.value);
      EndDocPrinter(hPrinter.value);
    } finally {
      calloc.free(docInfo);
      calloc.free(docName);
      calloc.free(dataType);
    }
  } finally {
    if (hPrinter.value != 0) ClosePrinter(hPrinter.value);
    calloc.free(hPrinter);
    calloc.free(name);
  }
}
