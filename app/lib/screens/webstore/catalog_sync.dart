import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../api/client.dart';
import '../../api/cloud.dart';
import '../../api/models.dart';
import '../../api/webstore_api.dart';
import '../../theme/tokens.dart';
import 'image_prep.dart';

/// Catalogue snapshot + product photos sent to the online store.
///
/// The site lives on its own (even with this PC off): « Publier le
/// catalogue » sends a full SNAPSHOT of the products (PUT /store/catalog),
/// then the photos are synchronised by content hash so only new or changed
/// images travel (DESKTOP_API.md §7–8).

String? _cut(String? s, int max) {
  if (s == null) return null;
  final t = s.trim();
  if (t.isEmpty) return null;
  return t.length <= max ? t : t.substring(0, max);
}

String _packLabel(Packaging k, String unit) {
  final n = fmtQty(k.factorMilli);
  final u = unit == 'piece' || unit.isEmpty ? '' : ' $unit';
  return '${k.name} de $n$u';
}

/// One product of the PUT /store/catalog snapshot.
Map<String, dynamic> snapshotProduct(Product p, Map<String, Category> cats,
    Map<String, int> qty) {
  final packs = [
    for (final k in p.packagings)
      if (k.factorMilli > 1000 && k.name.trim().isNotEmpty) k
  ]..sort((a, b) => a.factorMilli.compareTo(b.factorMilli));
  final cat = p.categoryId == null ? null : cats[p.categoryId];
  return {
    'id': p.id,
    'name': p.name,
    'name_ar': p.nameAr,
    'barcode': p.barcode,
    'category': cat?.name,
    // Parent category feeds the two-level navigation of the site.
    'category_parent': cat?.parentId == null ? null : cats[cat!.parentId]?.name,
    'unit': p.unit,
    'is_weighable': p.isWeighable,
    'price_centimes': p.priceRetail,
    'promo_price_centimes': p.promoActive ? p.promoPrice : null,
    'promo_end': p.promoActive ? p.promoEnd : null,
    'qty_milli': qty[p.id] ?? 0,
    'description': p.description,
    'warranty_months': p.warrantyMonths,
    'parent_product_id': p.parentProductId,
    'variant_label': p.variantLabel,
    // v3 — optional
    'brand': _cut(p.brand, 80),
    'pack_size': packs.isEmpty ? null : _cut(_packLabel(packs.first, p.unit), 80),
    'packaging': packs.isEmpty
        ? null
        : _cut(packs.map((k) => _packLabel(k, p.unit)).join(' · '), 80),
    // Stored for the future pro portal, never shown publicly.
    'wholesale_price_centimes':
        (p.priceWholesale ?? 0) > 0 ? p.priceWholesale : null,
  };
}

/// Builds and sends the catalogue snapshot. Returns the published count.
Future<int> publishCatalogSnapshot(ApiClient api, CloudClient client) async {
  final products = await api.allProducts();
  final levels = await api.stockLevels();
  final catList = await api.categories();
  final cats = {for (final c in catList) c.id: c};
  final qty = <String, int>{};
  for (final l in levels) {
    qty[l.productId] = (qty[l.productId] ?? 0) + l.qtyMilli;
  }
  final snapshot = [for (final p in products) snapshotProduct(p, cats, qty)];
  return client.webPublishCatalog(snapshot);
}

// ---------------------------------------------------------------------------
// Product photos
// ---------------------------------------------------------------------------

class PhotoSyncResult {
  int products = 0; // published products checked
  int withPhotos = 0;
  int uploaded = 0;
  int deleted = 0;
  int unchanged = 0;
  final errors = <String>[];

  String get summary {
    final parts = <String>[
      if (uploaded > 0) '$uploaded photo(s) envoyée(s)',
      if (deleted > 0) '$deleted retirée(s)',
      if (unchanged > 0) '$unchanged déjà à jour',
    ];
    if (parts.isEmpty) return 'Aucune photo à envoyer.';
    return '${parts.join(', ')}.';
  }
}

/// Result of the last photo sync of this session (shown in « Photos produits »).
PhotoSyncResult? lastPhotoSync;

typedef SyncProgress = void Function(String step, int done, int total);

/// Local cache of the prepared (resized) photos, so a photo is resized and
/// hashed once: %APPDATA%\ElixirGestion\webstore_photos\.
class _PhotoCache {
  _PhotoCache._(this.dir, this.index);

  final Directory dir;

  /// `productId@imageRev` → sha256 per position.
  final Map<String, List<String>> index;

  static Future<_PhotoCache> open() async {
    final appData = Platform.environment['APPDATA'] ?? '.';
    final dir = Directory('$appData\\ElixirGestion\\webstore_photos');
    await dir.create(recursive: true);
    final f = File('${dir.path}\\index.json');
    final index = <String, List<String>>{};
    try {
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        for (final e in j.entries) {
          index[e.key] = [for (final s in e.value as List) '$s'];
        }
      }
    } catch (_) {}
    return _PhotoCache._(dir, index);
  }

  Future<void> save() async {
    final f = File('${dir.path}\\index.json');
    await f.writeAsString(jsonEncode(index));
  }

  static const _exts = {'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp'};

  File _file(String sha, String ext) => File('${dir.path}\\$sha.$ext');

  Future<(Uint8List, String)?> read(String sha) async {
    for (final e in _exts.entries) {
      final f = _file(sha, e.value);
      if (await f.exists()) return (await f.readAsBytes(), e.key);
    }
    return null;
  }

  Future<bool> has(String sha) async {
    for (final ext in _exts.values) {
      if (await _file(sha, ext).exists()) return true;
    }
    return false;
  }

  Future<void> write(PreparedImage im, String sha) async {
    await _file(sha, _exts[im.contentType] ?? 'jpg').writeAsBytes(im.bytes);
  }

  /// Drops entries of old photo revisions and their files.
  Future<void> prune(Set<String> liveKeys) async {
    index.removeWhere((k, _) => !liveKeys.contains(k));
    final live = {for (final l in index.values) ...l};
    await for (final f in dir.list()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (name == 'index.json') continue;
      final sha = name.split('.').first;
      if (!live.contains(sha)) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }
}

/// Sends the shop's product photos (product_images, up to 8 per product) to
/// the online store: resize ~1000 px JPEG, SHA-256, check, upload only
/// what changed, delete what was removed.
Future<PhotoSyncResult> syncProductPhotos(
  ApiClient api,
  CloudClient client, {
  SyncProgress? onProgress,
  bool Function()? cancelled,
}) async {
  final r = PhotoSyncResult();
  void progress(String s, int d, int t) => onProgress?.call(s, d, t);
  bool stop() => cancelled?.call() == true;

  progress('Lecture des produits…', 0, 0);
  final products = await api.allProducts();
  final published = {
    for (final p in await client.webStoreProducts()) p.productId
  };
  final todo = [for (final p in products) if (published.contains(p.id)) p];
  r.products = todo.length;
  final cache = await _PhotoCache.open();
  final http.Client hc = http.Client();
  final failed = <String>{};

  try {
    // 1. Prepare (resize + hash) photos not yet in the local cache.
    final withPhotos = [for (final p in todo) if (p.imageCount > 0) p];
    r.withPhotos = withPhotos.length;
    for (var i = 0; i < withPhotos.length; i++) {
      if (stop()) return r;
      final p = withPhotos[i];
      progress('Préparation des photos', i, withPhotos.length);
      final key = '${p.id}@${p.imageRev}';
      final known = cache.index[key];
      if (known != null && known.isNotEmpty) {
        var ok = true;
        for (final sha in known) {
          if (!await cache.has(sha)) {
            ok = false;
            break;
          }
        }
        if (ok) continue;
      }
      final hashes = <String>[];
      final count = p.imageCount > 8 ? 8 : p.imageCount;
      try {
        for (var k = 0; k < count; k++) {
          final res = await hc
              .get(
                  Uri.parse(api.productImageUrl(p.id, p.imageRev,
                      thumb: false, index: k)),
                  headers: api.authHeaders)
              .timeout(const Duration(seconds: 30));
          if (res.statusCode == 404) break;
          if (res.statusCode != 200) {
            throw Exception('photo ${k + 1} : erreur ${res.statusCode}');
          }
          final im = await prepareImage(res.bodyBytes, ImagePreset.product);
          if (im == null) throw Exception('photo ${k + 1} illisible');
          final sha = im.sha256;
          await cache.write(im, sha);
          hashes.add(sha);
        }
        cache.index[key] = hashes;
      } catch (e) {
        failed.add(p.id);
        r.errors.add('${p.name} : $e');
      }
      if (i % 25 == 24) await cache.save();
    }
    await cache.save();
    if (stop()) return r;

    // 2. Ask the store what changed.
    progress('Comparaison avec la boutique…', 0, 0);
    final items = <Map<String, dynamic>>[
      for (final p in todo)
        if (!failed.contains(p.id))
          {
            'product_id': p.id,
            'sha256': p.imageCount > 0
                ? (cache.index['${p.id}@${p.imageRev}'] ?? const <String>[])
                : const <String>[],
          }
    ];
    final check = await client.webCheckProductImages(items);
    r.unchanged = check.unchanged;

    // 3. Upload (3 at a time).
    final names = {for (final p in todo) p.id: p.name};
    var done = 0;
    final queue = [...check.upload];
    Future<void> worker() async {
      while (queue.isNotEmpty && !stop()) {
        final u = queue.removeLast();
        try {
          final f = await cache.read(u.sha256);
          if (f == null) throw Exception('photo préparée introuvable');
          await client.webPutProductImage(
              u.productId, u.position, f.$1, f.$2, u.sha256);
          r.uploaded++;
        } catch (e) {
          r.errors.add('${names[u.productId] ?? u.productId} : ${e is CloudException ? e.message : e}');
        }
        done++;
        progress('Envoi des photos', done, check.upload.length);
      }
    }

    await Future.wait([worker(), worker(), worker()]);
    if (stop()) return r;

    // 4. Remove photos deleted in the shop.
    for (var i = 0; i < check.delete.length; i++) {
      if (stop()) return r;
      final d = check.delete[i];
      progress('Retrait des anciennes photos', i, check.delete.length);
      try {
        await client.webDeleteProductImage(d.productId, d.position);
        r.deleted++;
      } catch (e) {
        r.errors.add('${names[d.productId] ?? d.productId} : ${e is CloudException ? e.message : e}');
      }
    }

    await cache.prune({
      for (final p in products)
        if (p.imageCount > 0) '${p.id}@${p.imageRev}'
    });
    await cache.save();
  } finally {
    hc.close();
  }
  return r;
}
