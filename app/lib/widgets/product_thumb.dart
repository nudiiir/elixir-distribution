import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';

// Pastel avatar palette (from the Elixir handoff tiles) — same as the POS.
const _pastels = [
  (Color(0xFFB9F0DC), Color(0xFF00795C)),
  (Color(0xFFFFE3C2), Color(0xFFC97A1A)),
  (Color(0xFFCFDCFA), Color(0xFF4A63B8)),
  (Color(0xFFF9D3DC), Color(0xFFB8556B)),
  (Color(0xFFE4E6F9), Color(0xFF6B5AC2)),
];

(Color, Color) productPastel(String name) =>
    _pastels[name.codeUnits.fold(0, (s, c) => s + c) % _pastels.length];

/// A product's photo, or its pastel initial when it has none (or while the
/// photo cannot be loaded). Used by the product list, the sheet, pickers and
/// the POS tiles so a product looks the same everywhere.
class ProductThumb extends StatelessWidget {
  const ProductThumb({
    super.key,
    required this.api,
    required this.product,
    this.size = 32,
    this.radius,
    this.thumb = true,
  });

  final ApiClient api;
  final Product product;
  final double size;
  final double? radius;
  final bool thumb;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius ?? size * 0.28);
    final (bg, fg) = productPastel(product.name);
    final initial = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: r),
      child: Text(
        product.name.trim().isEmpty ? '?' : product.name.trim()[0].toUpperCase(),
        style: TextStyle(
            fontFamily: T.sans,
            fontWeight: FontWeight.w800,
            fontSize: size * 0.42,
            color: fg),
      ),
    );
    if (!product.hasImage) return initial;
    return ClipRRect(
      borderRadius: r,
      child: Image.network(
        api.productImageUrl(product.id, product.imageRev, thumb: thumb),
        headers: api.authHeaders,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => initial,
        loadingBuilder: (ctx, child, progress) =>
            progress == null ? child : initial,
      ),
    );
  }
}
