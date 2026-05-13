import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:http/http.dart' as http;
import 'package:gal/gal.dart';
import '../utils.dart';

// ── Theme palette ──────────────────────────────────────────────
// Light + dark variants for the four surface colors; accents stay the same.
// Instance getters inside each State class pick the right variant from
// Theme.of(context) at build time, so the screen follows the ThemeNotifier.
const _bgDark      = Color(0xFF2D3047); // dark-mode scaffold
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);

// ─── SCREEN 11 — PICTURE WALL ────────────────────────────────
class PictureWallScreen extends StatefulWidget {
  final String eventId;
  final String eventTitle;
  const PictureWallScreen({super.key, required this.eventId, required this.eventTitle});
  @override
  State<PictureWallScreen> createState() => _PictureWallScreenState();
}

class _PictureWallScreenState extends State<PictureWallScreen> {
  StreamSubscription<QuerySnapshot>? _photosSub;
  List<Map<String, dynamic>> _photos = [];
  bool _uploading = false;
  // Batch download progress. _downloadingAll flips true while the
  // bulk save is running; _downloadDone counts successes so the
  // AppBar action can show "12/40" instead of an indeterminate
  // spinner — useful on big galleries where the whole save can take
  // a minute over cell data.
  bool _downloadingAll = false;
  int _downloadDone = 0;

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;

  @override
  void initState() {
    super.initState();
    _photosSub = FirebaseFirestore.instance
        .collection('events')
        .doc(widget.eventId)
        .collection('photos')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _photos = snap.docs.map((d) => <String, dynamic>{'id': d.id, ...d.data()}).toList();
      });
    });
  }

  @override
  void dispose() {
    _photosSub?.cancel();
    super.dispose();
  }

  Future<void> _addPhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _uploading = true);
    try {
      final bytes = await picked.readAsBytes();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ref = FirebaseStorage.instance
          .ref('events/${widget.eventId}/photos/${user.uid}_$ts.jpg');
      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();
      final displayName = user.displayName ?? user.email?.split('@').first ?? 'Guest';
      await FirebaseFirestore.instance
          .collection('events')
          .doc(widget.eventId)
          .collection('photos')
          .add({
        'url': url,
        'uploaderUid': user.uid,
        'uploaderName': displayName,
        'timestamp': FieldValue.serverTimestamp(),
        'likes': [],
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Photo added to the wall!'),
          backgroundColor: AppColors.green,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Upload failed: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// Saves every photo on the wall to the device's camera roll. Runs
  /// sequentially to avoid hammering Storage with 50+ parallel
  /// downloads on a slow connection — order is preserved (newest
  /// first, matching the grid). Per-photo failures are tolerated;
  /// the final SnackBar reports the success/total counts so a guest
  /// who lost a few to network blips knows what got saved.
  ///
  /// Filenames look like `qrparty_<sanitized-event-title>_NN.jpg`
  /// so the saved set sorts together in the user's gallery.
  Future<void> _downloadAllPhotos() async {
    if (_downloadingAll) return;
    if (_photos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Nothing to download yet.'),
        backgroundColor: AppColors.muted,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    // Confirmation step on big galleries — over cell data this can
    // pull 100+ MB. Auto-skipped for small albums (≤10) so the
    // single-tap flow stays fast.
    if (_photos.length > 10) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Download ${_photos.length} photos?',
              style: TextStyle(fontFamily: 'FredokaOne', fontSize: 18,
                  color: _isDark ? Colors.white : AppColors.dark)),
          content: Text(
            'They\'ll save to your camera roll. May use a lot of data on cellular.',
            style: TextStyle(color: _muted, fontSize: 13.5, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: TextStyle(color: _muted)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Download',
                  style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    // Permission gate. `Gal.hasAccess` returns true if we can write,
    // so we only prompt when needed (matches the per-event QR
    // download flow in generate_qr_screen.dart).
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Gallery access denied. Enable Photos in Settings to download.'),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
            ));
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('[PictureWall] Gal.hasAccess failed: $e');
      // Fall through — putImageBytes will surface the real error.
    }

    setState(() {
      _downloadingAll = true;
      _downloadDone = 0;
    });

    final safeTitle = widget.eventTitle
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .toLowerCase();
    final total = _photos.length;
    var saved = 0;
    var failed = 0;

    for (var i = 0; i < total; i++) {
      // Bail out if the user closed the screen mid-download — no
      // setState calls would land anyway, and we don't want to keep
      // hammering Storage in the background.
      if (!mounted) break;
      final url = _photos[i]['url'] as String?;
      if (url == null || url.isEmpty) { failed++; continue; }
      try {
        final response = await http.get(Uri.parse(url));
        if (response.statusCode != 200) {
          failed++;
          debugPrint('[PictureWall] photo ${i + 1}/$total fetch failed status=${response.statusCode}');
          continue;
        }
        // 1-indexed, zero-padded so a user scrolling Photos sees a
        // natural ordering: ..._01, ..._02, ..., ..._99.
        final indexLabel = (i + 1).toString().padLeft(total.toString().length, '0');
        await Gal.putImageBytes(
          response.bodyBytes,
          name: 'qrparty_${safeTitle}_$indexLabel',
        );
        saved++;
      } catch (e) {
        failed++;
        debugPrint('[PictureWall] photo ${i + 1}/$total save failed: $e');
      }
      if (mounted) setState(() => _downloadDone = saved + failed);
    }

    if (!mounted) return;
    setState(() => _downloadingAll = false);

    final messenger = ScaffoldMessenger.of(context);
    if (saved == total) {
      messenger.showSnackBar(SnackBar(
        content: Text('📸 Saved $saved photo${saved == 1 ? '' : 's'} to your camera roll'),
        backgroundColor: AppColors.green,
        behavior: SnackBarBehavior.floating,
      ));
    } else if (saved > 0) {
      messenger.showSnackBar(SnackBar(
        content: Text('Saved $saved of $total — $failed failed. Check your connection and try again.'),
        backgroundColor: AppColors.gold,
        behavior: SnackBarBehavior.floating,
      ));
    } else {
      messenger.showSnackBar(const SnackBar(
        content: Text('Could not save any photos. Check your connection and try again.'),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _toggleLike(String photoId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final photoIndex = _photos.indexWhere((p) => p['id'] == photoId);
    if (photoIndex == -1) return;
    final photo = Map<String, dynamic>.from(_photos[photoIndex]);
    final likes = List<String>.from((photo['likes'] as List?) ?? []);
    final isLiked = likes.contains(user.uid);

    // Optimistic update — flip immediately so the UI responds on tap
    setState(() {
      if (isLiked) {
        likes.remove(user.uid);
      } else {
        likes.add(user.uid);
      }
      _photos[photoIndex] = {...photo, 'likes': likes};
    });

    final ref = FirebaseFirestore.instance
        .collection('events').doc(widget.eventId).collection('photos').doc(photoId);
    try {
      if (isLiked) {
        await ref.update({'likes': FieldValue.arrayRemove([user.uid])});
      } else {
        await ref.update({'likes': FieldValue.arrayUnion([user.uid])});
      }
    } catch (_) {
      // Revert optimistic update on failure
      if (mounted) setState(() => _photos[photoIndex] = photo);
    }
  }

  String _timeAgo(dynamic timestamp) {
    if (timestamp == null) return '';
    final dt = (timestamp as Timestamp).toDate();
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _card,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: _isDark ? Colors.white : AppColors.dark),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Picture Wall', style: TextStyle(fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
            Text('${_photos.length} photos · ${widget.eventTitle}',
                style: TextStyle(fontSize: 12, color: _muted, fontWeight: FontWeight.w400)),
          ],
        ),
        actions: [
          // Bulk download — disabled while a download is already in
          // progress or while the wall is empty. Mid-download the
          // icon turns into an X/Y progress label so the user has
          // visible feedback even if the SnackBar at the end is the
          // ultimate confirmation.
          if (_downloadingAll)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Row(children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green)),
                const SizedBox(width: 8),
                Text('$_downloadDone/${_photos.length}',
                    style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w800,
                      color: _isDark ? Colors.white : AppColors.dark,
                    )),
              ]),
            )
          else
            IconButton(
              tooltip: 'Download all',
              icon: const Icon(Icons.download_for_offline_outlined, color: AppColors.green),
              onPressed: _photos.isEmpty ? null : _downloadAllPhotos,
            ),
          if (_uploading)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green)),
            )
          else
            IconButton(
              tooltip: 'Add photo',
              icon: const Icon(Icons.add_a_photo_outlined, color: AppColors.green),
              onPressed: _addPhoto,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _photos.isEmpty
          ? Center(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Text('📷', style: TextStyle(fontSize: 56)),
                const SizedBox(height: 16),
                Text('No photos yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                const SizedBox(height: 8),
                Text('Be the first to share a photo!', style: TextStyle(fontSize: 14, color: _muted)),
              ]),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: _photos.length,
              itemBuilder: (context, index) {
                final photo = _photos[index];
                final likes = List<String>.from((photo['likes'] as List?) ?? []);
                final isLiked = uid != null && likes.contains(uid);
                return GestureDetector(
                  onTap: () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => _FullScreenPhoto(
                      photos: _photos,
                      initialIndex: index,
                      onLike: _toggleLike,
                      timeAgo: _timeAgo,
                      currentUid: uid,
                      eventId: widget.eventId,
                      eventTitle: widget.eventTitle,
                    ),
                  )),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(photo['url'] as String, fit: BoxFit.cover),
                      ),
                      Positioned(
                        bottom: 0, left: 0, right: 0,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [Colors.black.withValues(alpha: 0.5), Colors.transparent],
                            ),
                          ),
                          padding: const EdgeInsets.fromLTRB(6, 12, 6, 4),
                          child: Row(children: [
                            GestureDetector(
                              onTap: () => _toggleLike(photo['id'] as String),
                              child: Icon(
                                isLiked ? Icons.favorite : Icons.favorite_border,
                                color: isLiked ? Colors.redAccent : Colors.white,
                                size: 16,
                              ),
                            ),
                            const SizedBox(width: 3),
                            Text('${likes.length}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: _uploading
          ? null
          : FloatingActionButton.extended(
              onPressed: _addPhoto,
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Add Photo', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
      bottomNavigationBar: debugLabel('Screen 11 — Guest View'),
    );
  }
}

class _FullScreenPhoto extends StatefulWidget {
  final List<Map<String, dynamic>> photos;
  final int initialIndex;
  final Future<void> Function(String photoId) onLike;
  final String Function(dynamic) timeAgo;
  final String? currentUid;
  /// Threaded through so the Report flow can stamp `eventId` on the
  /// report doc and the host-bound `notificationTasks` write. Not used
  /// for any rendering — just metadata.
  final String eventId;
  final String eventTitle;

  const _FullScreenPhoto({
    required this.photos,
    required this.initialIndex,
    required this.onLike,
    required this.timeAgo,
    required this.currentUid,
    required this.eventId,
    required this.eventTitle,
  });

  @override
  State<_FullScreenPhoto> createState() => _FullScreenPhotoState();
}

class _FullScreenPhotoState extends State<_FullScreenPhoto> {
  late int currentIndex;
  late PageController _pageController;
  bool _saving = false;
  bool _reporting = false;

  @override
  void initState() {
    super.initState();
    currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  /// Saves the currently-viewed photo to the camera roll. Mirrors the
  /// permission/fetch/save flow of the wall's bulk download but for a
  /// single image.
  Future<void> _saveCurrent() async {
    if (_saving) return;
    final url = widget.photos[currentIndex]['url'] as String?;
    if (url == null || url.isEmpty) return;
    setState(() => _saving = true);
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) throw Exception('Gallery access denied');
      }
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      await Gal.putImageBytes(
        response.bodyBytes,
        name: 'qrparty_photo_${DateTime.now().millisecondsSinceEpoch}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('📸 Saved to your camera roll'),
          backgroundColor: AppColors.green,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Save failed: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Opens a small dialog letting the viewer flag the current photo as
  /// inappropriate / spam / other. On submit, writes a `reports/{auto}`
  /// document for moderation triage AND a `notificationTasks` entry so
  /// the existing host-notification pipeline (Cloud Functions consume
  /// notificationTasks via Admin SDK) can alert the host.
  ///
  /// The dialog is non-destructive — closing it without picking a
  /// reason is a no-op. Reporters can't undo a submitted report from
  /// the client; they'd contact support. That's intentional: reports
  /// are meant to be sticky for the moderation queue.
  Future<void> _reportCurrent() async {
    if (_reporting) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final photo = widget.photos[currentIndex];
    final url = photo['url'] as String?;
    if (url == null || url.isEmpty) return;

    var selectedReason = 'inappropriate';
    final detailsController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF383B56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text(
            'Report photo',
            style: TextStyle(fontFamily: 'FredokaOne', fontSize: 20, color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Why are you reporting this photo?',
                style: TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.4),
              ),
              const SizedBox(height: 12),
              _reportReasonTile(
                value: 'inappropriate',
                label: 'Inappropriate content',
                groupValue: selectedReason,
                onChanged: (v) => setLocal(() => selectedReason = v!),
              ),
              _reportReasonTile(
                value: 'spam',
                label: 'Spam',
                groupValue: selectedReason,
                onChanged: (v) => setLocal(() => selectedReason = v!),
              ),
              _reportReasonTile(
                value: 'other',
                label: 'Other',
                groupValue: selectedReason,
                onChanged: (v) => setLocal(() => selectedReason = v!),
              ),
              if (selectedReason == 'other') ...[
                const SizedBox(height: 8),
                TextField(
                  controller: detailsController,
                  maxLines: 3,
                  maxLength: 280,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Tell us more (optional)',
                    hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
                    filled: true,
                    fillColor: const Color(0xFF2D3047),
                    counterStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.purple, width: 1.5),
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'Submit report',
                style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) {
      detailsController.dispose();
      return;
    }
    if (!mounted) return;
    setState(() => _reporting = true);

    final details = detailsController.text.trim();
    detailsController.dispose();

    try {
      // Write the report doc first so moderation has the source of
      // truth. The notificationTasks write is best-effort after — the
      // report is the durable record; the alert is the courtesy.
      final reportRef = await FirebaseFirestore.instance.collection('reports').add({
        'photoUrl': url,
        if (photo['id'] != null) 'photoId': photo['id'],
        'reportedBy': user.uid,
        'eventId': widget.eventId,
        'reason': selectedReason,
        if (details.isNotEmpty) 'details': details,
        'timestamp': FieldValue.serverTimestamp(),
      });

      // Best-effort host alert via the existing Cloud-Function-backed
      // notificationTasks pipeline. Type lets the consumer dispatch
      // the right push template + admin email. A failure here doesn't
      // fail the user-facing report — moderation already has the doc.
      try {
        final reasonLabel = switch (selectedReason) {
          'inappropriate' => 'inappropriate content',
          'spam' => 'spam',
          _ => 'a violation',
        };
        await FirebaseFirestore.instance.collection('notificationTasks').add({
          'type': 'photo_reported',
          'eventId': widget.eventId,
          'eventTitle': widget.eventTitle,
          'photoUrl': url,
          'reason': selectedReason,
          'reportId': reportRef.id,
          'reportedBy': user.uid,
          'message': 'A photo on "${widget.eventTitle}" was reported for $reasonLabel.',
          'scheduledFor': FieldValue.serverTimestamp(),
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('[PictureWall] notificationTasks write failed (non-fatal): $e');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Thanks — our team will take a look.'),
          backgroundColor: AppColors.green,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      debugPrint('[PictureWall] report submit failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not submit report: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  Widget _reportReasonTile({
    required String value,
    required String label,
    required String groupValue,
    required void Function(String?) onChanged,
  }) {
    final selected = value == groupValue;
    return InkWell(
      onTap: () => onChanged(value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 20,
            color: selected ? AppColors.purple : Colors.white54,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[currentIndex];
    final likes = List<String>.from((photo['likes'] as List?) ?? []);
    final isLiked = widget.currentUid != null && likes.contains(widget.currentUid);
    final uploaderName = (photo['uploaderName'] as String?) ?? 'Guest';
    final timeStr = widget.timeAgo(photo['timestamp']);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(uploaderName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
            Text(timeStr, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Save to camera roll',
            icon: _saving
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined, color: Colors.white),
            onPressed: _saving ? null : _saveCurrent,
          ),
          IconButton(
            tooltip: 'Report photo',
            icon: _reporting
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Icon(Icons.flag_outlined, color: Colors.white),
            onPressed: _reporting ? null : _reportCurrent,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: widget.photos.length,
              onPageChanged: (i) => setState(() => currentIndex = i),
              itemBuilder: (context, index) => Image.network(
                widget.photos[index]['url'] as String,
                fit: BoxFit.contain,
              ),
            ),
          ),
          Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () {
                    widget.onLike(photo['id'] as String);
                    setState(() {});
                  },
                  child: Row(children: [
                    Icon(isLiked ? Icons.favorite : Icons.favorite_border,
                        color: isLiked ? Colors.redAccent : Colors.white, size: 26),
                    const SizedBox(width: 6),
                    Text('${likes.length}', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  ]),
                ),
                const Spacer(),
                Text('${currentIndex + 1} of ${widget.photos.length}',
                    style: const TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
