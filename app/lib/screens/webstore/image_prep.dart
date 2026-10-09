import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;

/// Image preparation before sending to the online store: the server does not
/// resize (DESKTOP_API.md §6/§8), so we do it here — WebP/JPEG/PNG only,
/// ≤ 2 Mo, ideally much less.

class PreparedImage {
  const PreparedImage(this.bytes, this.contentType, this.width, this.height);
  final Uint8List bytes;
  final String contentType;
  final int width;
  final int height;

  String get sha256 => sha256Hex(bytes);
}

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// Content type from the magic bytes (null = not png/jpeg/webp).
String? sniffImageType(Uint8List b) {
  if (b.length >= 8 &&
      b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

/// Presets of the contract.
class ImagePreset {
  const ImagePreset(this.maxSide, this.maxBytes, {this.flatten = true});

  /// Product photos: ~1000 px, ideally < 300 Ko, JPEG on white.
  static const product = ImagePreset(1000, 300 * 1024);

  /// Banners, carousel slides, social image: ≤ 1600 px wide.
  static const banner = ImagePreset(1600, 600 * 1024, flatten: false);

  /// Logo / brand logos: small, keep transparency.
  static const logo = ImagePreset(600, 300 * 1024, flatten: false);

  final int maxSide;
  final int maxBytes;

  /// True = transparent pixels become white and the result is a JPEG.
  final bool flatten;
}

/// Resizes/compresses [bytes]. Keeps the original file when it is already a
/// small enough png/jpeg/webp. Returns null when the file is not a readable
/// image.
Future<PreparedImage?> prepareImage(Uint8List bytes, ImagePreset p) async {
  final ui.ImmutableBuffer buf;
  final ui.ImageDescriptor desc;
  try {
    buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    desc = await ui.ImageDescriptor.encoded(buf);
  } catch (_) {
    return null;
  }
  try {
    final w = desc.width, h = desc.height;
    final type = sniffImageType(bytes);
    final longest = w > h ? w : h;
    // Already fine: keep the exact bytes (stable hash, no quality loss) —
    // except PNG when transparency must become white.
    if (type != null &&
        (!p.flatten || type != 'image/png') &&
        longest <= p.maxSide &&
        bytes.length <= p.maxBytes) {
      return PreparedImage(bytes, type, w, h);
    }
    var side = longest > p.maxSide ? p.maxSide : longest;
    for (var attempt = 0; attempt < 4; attempt++) {
      final scale = side / longest;
      final tw = (w * scale).round().clamp(1, 100000);
      final th = (h * scale).round().clamp(1, 100000);
      final codec =
          await desc.instantiateCodec(targetWidth: tw, targetHeight: th);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final raw =
            await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        if (raw == null) return null;
        final rgba = raw.buffer.asUint8List();
        var alpha = false;
        for (var i = 3; i < rgba.length; i += 4) {
          if (rgba[i] != 255) {
            alpha = true;
            break;
          }
        }
        if (alpha && !p.flatten) {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          if (png != null && png.lengthInBytes <= p.maxBytes) {
            return PreparedImage(
                png.buffer.asUint8List(), 'image/png', tw, th);
          }
        }
        for (final q in const [84, 74, 64]) {
          final jpg = await Isolate.run(() => _encodeJpeg(rgba, tw, th, q));
          if (jpg.length <= p.maxBytes) {
            return PreparedImage(jpg, 'image/jpeg', tw, th);
          }
        }
      } finally {
        image.dispose();
        codec.dispose();
      }
      side = (side * 0.75).round();
    }
    return null;
  } finally {
    desc.dispose();
    buf.dispose();
  }
}

/// RGBA → JPEG, transparent pixels blended on white. Runs in an isolate.
Uint8List _encodeJpeg(Uint8List rgba, int w, int h, int quality) {
  final rgb = Uint8List(w * h * 3);
  for (var i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
    final a = rgba[i + 3];
    if (a == 255) {
      rgb[j] = rgba[i];
      rgb[j + 1] = rgba[i + 1];
      rgb[j + 2] = rgba[i + 2];
    } else {
      final inv = 255 - a;
      rgb[j] = (rgba[i] * a + 255 * inv) ~/ 255;
      rgb[j + 1] = (rgba[i + 1] * a + 255 * inv) ~/ 255;
      rgb[j + 2] = (rgba[i + 2] * a + 255 * inv) ~/ 255;
    }
  }
  final im = img.Image.fromBytes(
      width: w, height: h, bytes: rgb.buffer, numChannels: 3);
  return img.encodeJpg(im, quality: quality);
}
