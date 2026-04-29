import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils.dart';

// ── Theme palette ──────────────────────────────────────────────
// Light + dark variants for the four surface colors; accents stay the same.
// Instance getters inside each State class pick the right variant from
// Theme.of(context) at build time, so the screen follows the ThemeNotifier.
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

class CreateTemplateScreen extends StatefulWidget {
  const CreateTemplateScreen({super.key});
  @override
  State<CreateTemplateScreen> createState() => _CreateTemplateScreenState();
}

class _CreateTemplateScreenState extends State<CreateTemplateScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _itemNameController = TextEditingController();
  final TextEditingController _itemPriceController = TextEditingController();
  final TextEditingController _itemQtyController = TextEditingController();

  EventType? _selectedEventType;
  // See create_event_screen for the rationale — defaults to Checklist
  // when the Wishlist beta gate is closed so the form's initial state
  // matches the visible chip set.
  String _listType = kWishlistEnabled ? 'Wishlist' : 'Checklist';
  final List<Map<String, dynamic>> _checklistItems = [];
  final List<Map<String, dynamic>> _wishlistItems = [];
  bool _saving = false;
  String? _nameError;

  // Theme-aware colors — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _itemNameController.dispose();
    _itemPriceController.dispose();
    _itemQtyController.dispose();
    super.dispose();
  }

  void _addItem() {
    final name = _itemNameController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      if (_listType == 'Checklist') {
        final qty = _itemQtyController.text.trim();
        if (qty.isEmpty) return;
        _checklistItems.add({'name': name, 'quantity': qty, 'claimed': 0});
        _itemQtyController.clear();
      } else if (_listType == 'Wishlist') {
        final priceStr = _itemPriceController.text.trim();
        final price = double.tryParse(priceStr);
        if (price == null) return;
        _wishlistItems.add({'name': name, 'price': price, 'contributed': 0.0, 'bought': false});
        _itemPriceController.clear();
      }
      _itemNameController.clear();
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Template name is required');
      return;
    }
    if (_selectedEventType == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Pick an event type'), backgroundColor: Colors.redAccent,
      ));
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    setState(() { _saving = true; _nameError = null; });
    try {
      await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('templates').add({
        'templateName': name,
        // Alias for back-compat with existing template reads (BusinessHomeFeedScreen templates tab, CreateEventScreen templateData).
        'title': name,
        'eventType': _selectedEventType!.name,
        'eventEmoji': _selectedEventType!.emoji,
        'description': _descController.text.trim(),
        'listType': _listType,
        'checklist': _checklistItems,
        'wishlist':  _wishlistItems,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('📋 Template saved'),
          backgroundColor: _gold,
          behavior: SnackBarBehavior.floating,
        ));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not save: $e'),
          backgroundColor: Colors.redAccent,
        ));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isChecklist = _listType == 'Checklist';
    final isWishlist  = _listType == 'Wishlist';
    final isNoList    = _listType == 'No List';

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: _fg),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Create Template',
          style: TextStyle(fontFamily: 'FredokaOne', fontSize: 20, color: _fg),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                children: [
                  _fieldLabel('Template Name'),
                  TextField(
                    controller: _nameController,
                    style: TextStyle(color: _fg),
                    decoration: _inputDecoration('e.g. Weekly Team Standup').copyWith(
                      errorText: _nameError,
                      errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 11),
                    ),
                    onChanged: (_) {
                      if (_nameError != null) setState(() => _nameError = null);
                    },
                  ),
                  const SizedBox(height: 20),

                  _fieldLabel('Event Type'),
                  _buildEventTypeGrid(),
                  const SizedBox(height: 20),

                  _fieldLabel('Description  (optional)'),
                  TextField(
                    controller: _descController,
                    style: TextStyle(color: _fg),
                    maxLines: 3,
                    decoration: _inputDecoration('What is this template for?'),
                  ),
                  const SizedBox(height: 20),

                  _fieldLabel('List Type'),
                  Row(children: [
                    if (kWishlistEnabled) ...[
                      _listTypeChip('Wishlist',  Icons.card_giftcard_outlined),
                      const SizedBox(width: 8),
                    ],
                    _listTypeChip('Checklist', Icons.checklist_outlined),
                    const SizedBox(width: 8),
                    _listTypeChip('No List',   Icons.block_outlined),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    isNoList
                        ? 'No list will be included when this template is used.'
                        : isChecklist
                            ? 'Guests sign up to bring items — great for potlucks.'
                            : 'Guests can contribute money or buy items.',
                    style: TextStyle(fontSize: 12, color: _muted),
                  ),

                  if (!isNoList) ...[
                    const SizedBox(height: 16),
                    _fieldLabel(isChecklist ? 'Checklist Items' : 'Wishlist Items'),
                    _buildItemAdder(isChecklist: isChecklist),
                    const SizedBox(height: 12),
                    if (isChecklist) ..._checklistItems.asMap().entries.map((e) => _buildItemRow(
                          index: e.key,
                          primary: e.value['name'] as String,
                          secondary: 'Qty: ${e.value['quantity']}',
                          onRemove: () => setState(() => _checklistItems.removeAt(e.key)),
                        )),
                    if (isWishlist) ..._wishlistItems.asMap().entries.map((e) => _buildItemRow(
                          index: e.key,
                          primary: e.value['name'] as String,
                          secondary: '\$${(e.value['price'] as double).toStringAsFixed(2)}',
                          onRemove: () => setState(() => _wishlistItems.removeAt(e.key)),
                        )),
                    if ((isChecklist && _checklistItems.isEmpty) || (isWishlist && _wishlistItems.isEmpty))
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          isChecklist
                              ? 'Add items guests can claim (e.g. chips, soda, plates).'
                              : 'Add gift ideas guests can contribute toward.',
                          style: TextStyle(fontSize: 12, color: _muted),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            // ── Save button ───────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: const Color(0xFF1A1A1A),
                    disabledBackgroundColor: _border,
                    disabledForegroundColor: _muted,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                  child: _saving
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                      : const Text('Save Template', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────

  Widget _fieldLabel(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _fg, letterSpacing: 0.2)),
      );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _muted),
        filled: true,
        fillColor: _card,
        border:        OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _purple, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      );

  Widget _buildEventTypeGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.1,
      ),
      itemCount: eventTypes.length,
      itemBuilder: (_, i) {
        final t = eventTypes[i];
        final selected = _selectedEventType?.name == t.name;
        return GestureDetector(
          onTap: () => setState(() => _selectedEventType = t),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: selected ? t.primary.withValues(alpha: 0.18) : _card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? t.primary : _border, width: selected ? 2 : 1),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(t.emoji, style: const TextStyle(fontSize: 26)),
                const SizedBox(height: 6),
                Text(
                  t.name,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: selected ? t.primary : Colors.white,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _listTypeChip(String label, IconData icon) {
    final selected = _listType == label;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _listType = label),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? _purple : _card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? _purple : _border, width: selected ? 1.5 : 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: selected ? Colors.white : _muted),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: selected ? Colors.white : _muted)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItemAdder({required bool isChecklist}) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _itemNameController,
            style: TextStyle(color: _fg),
            decoration: _inputDecoration(isChecklist ? 'Item to bring' : 'Item name'),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 96,
          child: isChecklist
              ? TextField(
                  controller: _itemQtyController,
                  style: TextStyle(color: _fg),
                  decoration: _inputDecoration('Qty'),
                )
              : TextField(
                  controller: _itemPriceController,
                  keyboardType: TextInputType.number,
                  style: TextStyle(color: _fg),
                  decoration: _inputDecoration('\$ Price'),
                ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: _addItem,
            style: ElevatedButton.styleFrom(
              backgroundColor: _purple,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  Widget _buildItemRow({
    required int index,
    required String primary,
    required String secondary,
    required VoidCallback onRemove,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(primary, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _fg)),
                const SizedBox(height: 2),
                Text(secondary, style: TextStyle(fontSize: 13, color: _muted)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
