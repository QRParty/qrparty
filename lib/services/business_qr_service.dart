import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Provisions and resolves the per-account business QR for Business and
/// Headquarters tier owners. The QR encodes a permanent short URL of the
/// form `https://partywithqr.com/biz/{slug}` which the public web page
/// `biz.html` resolves to a Firestore lookup against the `businesses`
/// collection (where the slug is the document id).
///
/// Two write targets per provision:
///   1. `businesses/{slug}` — the public-readable lookup doc the web
///      page reads. Slug-as-doc-id gives us atomic uniqueness.
///   2. `users/{uid}.businessSlug / .businessQRCode` — the per-user
///      pointer fields the app reads to skip re-provisioning on
///      subsequent visits. Idempotent: once these are set, the service
///      short-circuits and never writes again.
class BusinessQRResult {
  final String slug;
  final String url;
  const BusinessQRResult({required this.slug, required this.url});
}

class BusinessQRService {
  static const _hostBase = 'https://partywithqr.com/biz/';

  /// Idempotent: returns the existing slug+URL if already provisioned,
  /// otherwise generates a slug, writes both docs, and returns the new
  /// pair. Throws on terminal Firestore errors so the calling screen
  /// can surface them.
  static Future<BusinessQRResult> ensureForCurrentUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('No signed-in user — cannot provision business QR.');
    }
    final fs = FirebaseFirestore.instance;
    final userRef = fs.collection('users').doc(user.uid);
    final userSnap = await userRef.get();
    final data = userSnap.data() ?? const {};
    final existingSlug = (data['businessSlug'] as String?)?.trim();
    final existingUrl  = (data['businessQRCode'] as String?)?.trim();
    if (existingSlug != null && existingSlug.isNotEmpty
        && existingUrl != null && existingUrl.isNotEmpty) {
      return BusinessQRResult(slug: existingSlug, url: existingUrl);
    }

    // Seed the slug from displayName, then businessName, then email
    // local-part. Trimmed + lowercased + hyphenated; collapses runs of
    // non-alphanumeric chars and trims dangling hyphens. Falls back to
    // a 6-char random token if all seeds resolve to empty.
    final seedRaw = (data['displayName'] as String?)?.trim().isNotEmpty == true
        ? data['displayName'] as String
        : ((data['businessName'] as String?)?.trim().isNotEmpty == true
            ? data['businessName'] as String
            : (user.email ?? '').split('@').first);
    final base = _slugify(seedRaw);
    final baseSafe = base.isEmpty ? _randomSuffix(6) : base;

    // Try the bare slug first, then progressively suffix with a short
    // random token on collision. 6 attempts — plenty given the keyspace
    // and the small population of business accounts.
    final businesses = fs.collection('businesses');
    final displayName = (data['displayName'] as String?)?.trim().isNotEmpty == true
        ? data['displayName'] as String
        : (data['businessName'] as String?) ?? 'Business';

    String? chosen;
    for (var attempt = 0; attempt < 6 && chosen == null; attempt++) {
      final candidate = attempt == 0 ? baseSafe : '$baseSafe-${_randomSuffix(3)}';
      final ref = businesses.doc(candidate);
      try {
        await ref.set({
          'slug': candidate,
          'name': displayName,
          'ownerId': user.uid,
          'description': (data['businessName'] as String?) ?? '',
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: false));
        chosen = candidate;
      } on FirebaseException catch (e) {
        // permission-denied here means the slug doc already exists and
        // the create rule rejected the overwrite — try the next suffix.
        if (e.code != 'permission-denied' && e.code != 'already-exists') rethrow;
      }
    }
    if (chosen == null) {
      throw StateError('Could not allocate a unique business slug after 6 attempts.');
    }

    final url = '$_hostBase$chosen';
    await userRef.set({
      'businessSlug': chosen,
      'businessQRCode': url,
    }, SetOptions(merge: true));
    return BusinessQRResult(slug: chosen, url: url);
  }

  static String _slugify(String input) {
    var s = input.toLowerCase();
    s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'-+'), '-');
    s = s.replaceAll(RegExp(r'^-|-$'), '');
    if (s.length > 40) s = s.substring(0, 40);
    return s;
  }

  static String _randomSuffix(int len) {
    const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
    final r = math.Random.secure();
    return List.generate(len, (_) => alphabet[r.nextInt(alphabet.length)]).join();
  }
}
