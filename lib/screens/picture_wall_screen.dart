import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
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
          if (_uploading)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green)),
            )
          else
            IconButton(
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

  const _FullScreenPhoto({
    required this.photos,
    required this.initialIndex,
    required this.onLike,
    required this.timeAgo,
    required this.currentUid,
  });

  @override
  State<_FullScreenPhoto> createState() => _FullScreenPhotoState();
}

class _FullScreenPhotoState extends State<_FullScreenPhoto> {
  late int currentIndex;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
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
            icon: const Icon(Icons.download_outlined, color: Colors.white),
            onPressed: () => showComingSoon(context, 'Download'),
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
