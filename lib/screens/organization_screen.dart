import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../utils.dart';
import '../services/event_delete_helper.dart';
import 'business_upgrade_screen.dart';

// ── Theme palette ──────────────────────────────────────────────
const _bgDark      = Color(0xFF2D3047);
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);
const _gold        = Color(0xFFC8922A);

String orgPageUrl(String orgId) => 'https://partywithqr.com/org/$orgId';

class OrganizationScreen extends StatefulWidget {
  const OrganizationScreen({super.key});
  @override
  State<OrganizationScreen> createState() => _OrganizationScreenState();
}

class _OrganizationScreenState extends State<OrganizationScreen> {
  final GlobalKey _qrKey = GlobalKey();
  StreamSubscription<DocumentSnapshot>? _userSub;
  StreamSubscription<QuerySnapshot>? _orgSub;
  StreamSubscription<QuerySnapshot>? _eventsSub;
  StreamSubscription<QuerySnapshot>? _orgEventsSub;

  String? _accountType;
  String? _orgId;
  Map<String, dynamic>? _org;
  List<QueryDocumentSnapshot> _myEvents = [];
  Map<String, Map<String, dynamic>> _orgEventLinks = {}; // eventId -> {showOnOrgPage}

  bool _busyQr = false;
  bool _busyLogo = false;

  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;

  @override
  void initState() {
    super.initState();
    _subscribeAll();
  }

  @override
  void dispose() {
    _userSub?.cancel();
    _orgSub?.cancel();
    _eventsSub?.cancel();
    _orgEventsSub?.cancel();
    super.dispose();
  }

  void _subscribeAll() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _userSub = FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots().listen((snap) {
      if (!mounted) return;
      setState(() => _accountType = (snap.data()?['accountType'] as String?));
    });

    _orgSub = FirebaseFirestore.instance
        .collection('organizations')
        .where('ownerId', isEqualTo: user.uid)
        .limit(1)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      _orgEventsSub?.cancel();
      _orgEventsSub = null;
      if (snap.docs.isEmpty) {
        setState(() { _orgId = null; _org = null; _orgEventLinks = {}; });
        return;
      }
      final doc = snap.docs.first;
      setState(() { _orgId = doc.id; _org = doc.data(); });
      _orgEventsSub = FirebaseFirestore.instance
          .collection('organizations').doc(doc.id).collection('events')
          .snapshots()
          .listen((eSnap) {
        if (!mounted) return;
        setState(() {
          _orgEventLinks = { for (final d in eSnap.docs) d.id: d.data() };
        });
      });
    });

    _eventsSub = FirebaseFirestore.instance
        .collection('events')
        .where('hostId', isEqualTo: user.uid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() => _myEvents = snap.docs);
    });
  }

  Future<void> _createOrg(String name) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final docRef = FirebaseFirestore.instance.collection('organizations').doc();
    await docRef.set({
      'name': name,
      'description': '',
      'logoUrl': '',
      'ownerId': user.uid,
      'memberIds': [user.uid],
      'orgQrCode': orgPageUrl(docRef.id),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _updateOrg(Map<String, dynamic> patch) async {
    if (_orgId == null) return;
    await FirebaseFirestore.instance.collection('organizations').doc(_orgId).update(patch);
  }

  Future<void> _pickAndUploadLogo() async {
    if (_orgId == null || _busyLogo) return;
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024, imageQuality: 88);
    if (file == null) return;
    setState(() => _busyLogo = true);
    try {
      final ref = FirebaseStorage.instance.ref('organizations/$_orgId/logo.jpg');
      await ref.putFile(File(file.path), SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();
      await _updateOrg({'logoUrl': url});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Logo updated'), backgroundColor: AppColors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logo upload failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _busyLogo = false);
    }
  }

  bool _canDeleteEventDoc(Map<String, dynamic> data) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return EventDeleteHelper.canDelete(
      hostId: data['hostId'] as String?,
      eventOrgId: data['orgId'] as String?,
      myUid: uid,
      myOwnedOrgId: _orgId,
    );
  }

  Future<void> _openEventMenu({
    required String eventId,
    required String title,
    required Map<String, dynamic> data,
    required Offset position,
  }) async {
    if (!_canDeleteEventDoc(data)) return;
    final fg = _isDark ? Colors.white : AppColors.dark;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final result = await showMenu<String>(
      context: context,
      color: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(children: [
            const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
            const SizedBox(width: 8),
            Text('Delete event',
                style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13.5)),
          ]),
        ),
      ],
    );
    if (result == 'delete' && mounted) {
      await EventDeleteHelper.confirmAndDelete(
        context,
        eventId: eventId,
        eventTitle: title,
      );
    }
  }

  Widget _buildOverflowMenuButton({
    required String eventId,
    required String title,
    required Map<String, dynamic> data,
  }) {
    if (!_canDeleteEventDoc(data)) return const SizedBox.shrink();
    return Builder(builder: (ctx) {
      return InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          final box = ctx.findRenderObject() as RenderBox?;
          final pos = box?.localToGlobal(box.size.center(Offset.zero)) ?? Offset.zero;
          _openEventMenu(eventId: eventId, title: title, data: data, position: pos);
        },
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(Icons.more_vert, size: 20, color: _muted),
        ),
      );
    });
  }

  Future<void> _toggleEvent(String eventId, bool on) async {
    if (_orgId == null) return;
    final orgRef = FirebaseFirestore.instance.collection('organizations').doc(_orgId);
    final eventRef = FirebaseFirestore.instance.collection('events').doc(eventId);
    if (on) {
      await orgRef.collection('events').doc(eventId).set({
        'showOnOrgPage': true,
        'addedAt': FieldValue.serverTimestamp(),
      });
      await eventRef.update({'orgId': _orgId, 'showOnOrgPage': true});
    } else {
      await orgRef.collection('events').doc(eventId).delete();
      await eventRef.update({'orgId': FieldValue.delete(), 'showOnOrgPage': false});
    }
  }

  Future<Uint8List?> _captureQr() async {
    try {
      final boundary = _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[OrgQR] capture failed: $e');
      return null;
    }
  }

  String _safeFilename() {
    final name = (_org?['name'] as String?) ?? _orgId ?? 'org';
    return name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').toLowerCase();
  }

  Future<void> _downloadQr() async {
    if (_busyQr || _orgId == null) return;
    setState(() => _busyQr = true);
    try {
      final bytes = await _captureQr();
      if (bytes == null) throw Exception('Could not capture QR');
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) throw Exception('Gallery access denied');
      }
      await Gal.putImageBytes(bytes, name: 'qrparty_org_${_safeFilename()}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('📸 Org QR saved to your photos'),
          backgroundColor: AppColors.green, behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Save failed: $e'),
          backgroundColor: Colors.redAccent, behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _busyQr = false);
    }
  }

  Future<void> _shareQr() async {
    if (_busyQr || _orgId == null) return;
    setState(() => _busyQr = true);
    try {
      final bytes = await _captureQr();
      if (bytes == null) throw Exception('Could not capture QR');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/qrparty_org_${_safeFilename()}.png');
      await file.writeAsBytes(bytes);
      final orgName = (_org?['name'] as String?) ?? 'our organization';
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: 'Follow $orgName on QR Party — scan to see all our upcoming events.',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Share failed: $e'),
          backgroundColor: Colors.redAccent, behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _busyQr = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = _isDark ? Colors.white : AppColors.dark;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text('Organization', style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // BusinessPlus-only feature. Show upgrade prompt for Business; lock for everyone else.
    if (_accountType == null) {
      return const Center(child: CircularProgressIndicator(color: _purple));
    }
    if (_accountType != 'business' && _accountType != 'businessPlus') {
      return _buildUpgradePrompt();
    }
    if (_orgId == null) return _buildCreateOrg();
    return _buildOrgHome();
  }

  Widget _buildUpgradePrompt() {
    final fg = _isDark ? Colors.white : AppColors.dark;
    final isBusiness = _accountType == 'business';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('🏢', style: TextStyle(fontSize: 56)),
          const SizedBox(height: 14),
          Text('Organizations are a Headquarters feature',
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: fg)),
          const SizedBox(height: 10),
          Text(
            isBusiness
                ? 'Upgrade to Headquarters to publish a branded org page with all your upcoming events behind a single QR code.'
                : 'Get a Headquarters subscription to unlock a branded org page with all your upcoming events.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _muted, height: 1.5),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BusinessUpgradeScreen())),
              icon: const Text('✨', style: TextStyle(fontSize: 18)),
              label: Text(isBusiness ? 'Upgrade to Headquarters' : 'See Headquarters',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _purple, foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildCreateOrg() {
    final fg = _isDark ? Colors.white : AppColors.dark;
    final ctrl = TextEditingController();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 12),
        const Text('🏢', textAlign: TextAlign.center, style: TextStyle(fontSize: 56)),
        const SizedBox(height: 14),
        Text('Create your organization',
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: 'FredokaOne', fontSize: 24, color: fg)),
        const SizedBox(height: 10),
        Text(
          'Publish a branded org page with all your upcoming events behind a single QR code.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: _muted, height: 1.5),
        ),
        const SizedBox(height: 22),
        TextField(
          controller: ctrl,
          style: TextStyle(color: fg),
          decoration: InputDecoration(
            hintText: 'Organization name',
            hintStyle: TextStyle(color: _muted),
            filled: true,
            fillColor: _card,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _purple, width: 1.5)),
          ),
        ),
        const SizedBox(height: 14),
        ElevatedButton.icon(
          onPressed: () async {
            final name = ctrl.text.trim();
            if (name.isEmpty) return;
            try {
              await _createOrg(name);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Organization created'), backgroundColor: AppColors.green),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not create org: $e'), backgroundColor: Colors.redAccent),
                );
              }
            }
          },
          icon: const Icon(Icons.add),
          label: const Text('Create Organization', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          style: ElevatedButton.styleFrom(
            backgroundColor: _purple, foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ]),
    );
  }

  Widget _buildOrgHome() {
    final fg = _isDark ? Colors.white : AppColors.dark;
    final name = (_org?['name'] as String?) ?? '';
    final desc = (_org?['description'] as String?) ?? '';
    final logoUrl = (_org?['logoUrl'] as String?) ?? '';
    final url = orgPageUrl(_orgId!);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // Org info card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(18), border: Border.all(color: _border)),
          child: Column(children: [
            GestureDetector(
              onTap: _busyLogo ? null : _pickAndUploadLogo,
              child: Container(
                width: 96, height: 96,
                decoration: BoxDecoration(
                  color: _purple.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: _purple.withValues(alpha: 0.4)),
                ),
                clipBehavior: Clip.antiAlias,
                child: _busyLogo
                    ? const Center(child: CircularProgressIndicator(color: _purple, strokeWidth: 2))
                    : (logoUrl.isNotEmpty
                        ? Image.network(logoUrl, fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Center(child: Text('🏢', style: TextStyle(fontSize: 36))))
                        : const Center(child: Text('🏢', style: TextStyle(fontSize: 36)))),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _busyLogo ? null : _pickAndUploadLogo,
              icon: const Icon(Icons.photo_camera_outlined, size: 16, color: _purple),
              label: Text(logoUrl.isNotEmpty ? 'Change logo' : 'Add a logo',
                  style: const TextStyle(color: _purple, fontWeight: FontWeight.w700, fontSize: 13)),
            ),
            const SizedBox(height: 6),
            Text(name, textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'FredokaOne', fontSize: 24, color: fg)),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(desc, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: _muted, height: 1.5)),
            ],
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => _showEditDialog(name, desc),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Edit name & description'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _purple,
                side: const BorderSide(color: _purple),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
          ]),
        ),

        const SizedBox(height: 18),

        // QR code card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(18), border: Border.all(color: _border)),
          child: Column(children: [
            Text('Org QR Code', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 1.4)),
            const SizedBox(height: 14),
            RepaintBoundary(
              key: _qrKey,
              child: Container(
                width: 240, height: 240,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: _purple, width: 3),
                  boxShadow: [BoxShadow(color: _purple.withValues(alpha: 0.18), blurRadius: 36, spreadRadius: 4)],
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  QrImageView(
                    data: url,
                    version: QrVersions.auto,
                    size: 184,
                    backgroundColor: Colors.white,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(name.isEmpty ? 'Organization' : name,
                        textAlign: TextAlign.center,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: _mutedLight, fontWeight: FontWeight.w500)),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 10),
            Text(url, style: TextStyle(fontSize: 11.5, color: _muted), textAlign: TextAlign.center),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _busyQr ? null : _downloadQr,
                  icon: _busyQr
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.download_outlined, size: 18),
                  label: const Text('Download', style: TextStyle(fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold, foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _busyQr ? null : _shareQr,
                  icon: const Icon(Icons.share_outlined, size: 18),
                  label: const Text('Share', style: TextStyle(fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _purple, foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ]),
          ]),
        ),

        const SizedBox(height: 18),

        // Events list
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text('YOUR EVENTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 1.4)),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text('Toggle to publish events on your org page',
              style: TextStyle(fontSize: 12, color: _muted)),
        ),
        ..._buildEventTiles(),
      ],
    );
  }

  List<Widget> _buildEventTiles() {
    final fg = _isDark ? Colors.white : AppColors.dark;
    final now = DateTime.now();
    final upcoming = _myEvents.where((d) {
      final data = d.data() as Map<String, dynamic>;
      if ((data['isDraft'] as bool?) ?? false) return false;
      if ((data['isArchived'] as bool?) ?? false) return false;
      final ts = data['date'] as Timestamp?;
      if (ts == null) return false;
      return ts.toDate().isAfter(now);
    }).toList()
      ..sort((a, b) {
        final da = (a.data() as Map<String, dynamic>)['date'] as Timestamp?;
        final db = (b.data() as Map<String, dynamic>)['date'] as Timestamp?;
        return (da?.toDate() ?? DateTime(2099)).compareTo(db?.toDate() ?? DateTime(2099));
      });

    if (upcoming.isEmpty) {
      return [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _card, borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _border, style: BorderStyle.solid),
          ),
          child: Column(children: [
            Text('📅', style: TextStyle(fontSize: 32, color: _muted)),
            const SizedBox(height: 6),
            Text('No upcoming events yet', style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 4),
            Text('Create an event from the home feed and it will show up here.',
                textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 12)),
          ]),
        ),
      ];
    }

    final months = const ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return upcoming.map((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final id = doc.id;
      final emoji = (data['eventEmoji'] as String?) ?? '🎉';
      final title = (data['title'] as String?) ?? 'Untitled';
      final ts = data['date'] as Timestamp?;
      final date = ts?.toDate();
      final dateStr = date != null ? '${months[date.month - 1]} ${date.day}, ${date.year}' : 'Date TBD';
      final link = _orgEventLinks[id];
      final on = link != null && (link['showOnOrgPage'] as bool? ?? false);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (d) => _openEventMenu(
          eventId: id, title: title, data: data, position: d.globalPosition,
        ),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: on ? _purple.withValues(alpha: 0.55) : _border, width: on ? 1.5 : 1),
          ),
          child: Row(children: [
            Text(emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: fg),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(dateStr, style: TextStyle(fontSize: 12, color: _muted)),
            ])),
            Switch(
              value: on,
              onChanged: (v) => _toggleEvent(id, v),
              activeTrackColor: _purple,
              activeThumbColor: Colors.white,
            ),
            _buildOverflowMenuButton(eventId: id, title: title, data: data),
          ]),
        ),
      );
    }).toList();
  }

  Future<void> _showEditDialog(String currentName, String currentDesc) async {
    final fg = _isDark ? Colors.white : AppColors.dark;
    final nameCtrl = TextEditingController(text: currentName);
    final descCtrl = TextEditingController(text: currentDesc);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Edit organization', style: TextStyle(color: fg)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: nameCtrl,
            style: TextStyle(color: fg),
            decoration: InputDecoration(
              labelText: 'Name',
              labelStyle: TextStyle(color: _muted),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: descCtrl,
            style: TextStyle(color: fg),
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Description',
              labelStyle: TextStyle(color: _muted),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: _muted))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save', style: TextStyle(color: _purple, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (saved != true) return;
    final newName = nameCtrl.text.trim();
    if (newName.isEmpty) return;
    await _updateOrg({'name': newName, 'description': descCtrl.text.trim()});
  }
}
