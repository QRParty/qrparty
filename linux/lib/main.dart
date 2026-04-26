import 'package:flutter/material.dart';

void main() {
  runApp(const QRPartyApp());
}

class QRPartyApp extends StatelessWidget {
  const QRPartyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QR Party',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF52796F),
          primary: const Color(0xFF52796F),
          secondary: const Color(0xFF84A98C),
        ),
        scaffoldBackgroundColor: const Color(0xFFF8F7FC),
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          color: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      home: const WelcomeScreen(),
    );
  }
}

// ─── CONSTANTS ───────────────────────────────────────────────
class AppColors {
  static const green = Color(0xFF52796F);
  static const greenLight = Color(0xFF84A98C);
  static const greenPale = Color(0xFFCAD2C5);
  static const purple = Color(0xFF9C7FD4);
  static const purplePale = Color(0xFFEDE7F6);
  static const gold = Color(0xFFE9C46A);
  static const surface = Color(0xFFF8F7FC);
  static const dark = Color(0xFF2D3047);
  static const muted = Color(0xFF8892A4);
}

class AppNotifications {
  static final List<Map<String, dynamic>> sentNotifications = [];
}

// ─── SCREEN 1 — WELCOME ──────────────────────────────────────
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const Spacer(flex: 2),
              // Logo card
              Container(
                height: 130,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.green.withOpacity(0.12),
                      blurRadius: 40,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Image.asset(
                    'assets/logo.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 36),
              const Text(
                'can.party.connect.',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: AppColors.dark, letterSpacing: -0.5),
              ),
              const SizedBox(height: 10),
              const Text(
                'Your party, one scan away',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, color: AppColors.muted, height: 1.5),
              ),
              const Spacer(flex: 3),
              // CTA buttons
              SizedBox(
                width: double.infinity,
                height: 58,
                child: ElevatedButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HomeFeedScreen())),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  child: const Text('Get Started', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 58,
                child: OutlinedButton(
                  onPressed: () => _showComingSoon(context, 'Login'),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.green, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  child: const Text('Already have an account? Log in', style: TextStyle(fontSize: 16, color: AppColors.green)),
                ),
              ),
              const SizedBox(height: 32),
              const Text('© 2026 QR Party · partywithqr.com', style: TextStyle(fontSize: 12, color: AppColors.muted)),
              const SizedBox(height: 16),
              _debugLabel('Screen 1 — Shared'),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── SCREEN 2 — HOME FEED ────────────────────────────────────
class HomeFeedScreen extends StatefulWidget {
  const HomeFeedScreen({super.key});
  @override
  State<HomeFeedScreen> createState() => _HomeFeedScreenState();
}

class _HomeFeedScreenState extends State<HomeFeedScreen> {
  int selectedTab = 0;

  final List<Map<String, dynamic>> allEvents = [
    {'title': "Sarah's Birthday Bash", 'date': DateTime(2026, 4, 25, 18, 30), 'host': 'Sarah Chen', 'isPast': false, 'yes': 25, 'maybe': 8, 'no': 3},
    {'title': "Mike & Emily Wedding", 'date': DateTime(2026, 3, 15, 16, 0), 'host': 'Mike Rodriguez', 'isPast': true, 'yes': 45, 'maybe': 5, 'no': 2},
    {'title': "Graduation Party", 'date': DateTime(2026, 5, 10, 14, 0), 'host': 'You', 'isPast': false, 'yes': 12, 'maybe': 3, 'no': 0},
  ];

  List<Map<String, dynamic>> get filteredEvents {
    final now = DateTime.now();
    if (selectedTab == 0) return allEvents.where((e) => (e['date'] as DateTime).isAfter(now)).toList();
    if (selectedTab == 1) return allEvents.where((e) => (e['date'] as DateTime).isBefore(now)).toList();
    return allEvents;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: SizedBox(
          height: 36,
          child: Image.asset('assets/logo.png', fit: BoxFit.contain),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_outlined, color: AppColors.dark),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HostNotificationsScreen())),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Tab bar
          Container(
            color: Colors.white,
            child: Row(children: [
              _buildTab(0, 'Upcoming'),
              _buildTab(1, 'Past'),
              _buildTab(2, 'Explore'),
            ]),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: filteredEvents.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                    itemCount: filteredEvents.length,
                    itemBuilder: (context, index) => _buildEventCard(context, filteredEvents[index]),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateEventScreen())),
        backgroundColor: AppColors.green,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Event', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      bottomNavigationBar: _debugLabel('Screen 2 — Host View'),
    );
  }

  Widget _buildTab(int index, String label) {
    final isSelected = selectedTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => selectedTab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? AppColors.green : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                color: isSelected ? AppColors.green : AppColors.muted,
                fontSize: 15,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('🎈', style: TextStyle(fontSize: 56)),
          const SizedBox(height: 16),
          const Text('No events here yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.dark)),
          const SizedBox(height: 8),
          const Text('Tap + to create your first event', style: TextStyle(fontSize: 14, color: AppColors.muted)),
        ],
      ),
    );
  }

  Widget _buildEventCard(BuildContext context, Map<String, dynamic> event) {
    final bool isPast = event['isPast'] as bool;
    final DateTime date = event['date'] as DateTime;
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withOpacity(0.05)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                // Date badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isPast ? const Color(0xFFF0F0F0) : AppColors.greenPale,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Text(
                        months[date.month - 1].toUpperCase(),
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: isPast ? AppColors.muted : AppColors.green),
                      ),
                      Text(
                        '${date.day}',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: isPast ? AppColors.muted : AppColors.green),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(event['title'] as String, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.dark)),
                      const SizedBox(height: 4),
                      Text('Hosted by ${event['host']}', style: const TextStyle(fontSize: 13, color: AppColors.muted)),
                    ],
                  ),
                ),
                if (isPast)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFFF0F0F0), borderRadius: BorderRadius.circular(100)),
                    child: const Text('Past', style: TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w500)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            // RSVP pills
            Row(children: [
              _buildPill('${event['yes']} Yes', AppColors.green),
              const SizedBox(width: 8),
              _buildPill('${event['maybe']} Maybe', AppColors.gold),
              const SizedBox(width: 8),
              _buildPill('${event['no']} No', Colors.redAccent),
            ]),
            const SizedBox(height: 16),
            // Action buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GuestEventScreen())),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('View Event', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: isPast
                      ? ElevatedButton(
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ThankYouScreen())),
                          style: ElevatedButton.styleFrom(backgroundColor: AppColors.gold, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
                          child: const Text('Thank You', style: TextStyle(fontWeight: FontWeight.w600)),
                        )
                      : OutlinedButton(
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GenerateQRCodeScreen())),
                          style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.green), padding: const EdgeInsets.symmetric(vertical: 12)),
                          child: const Text('QR Code', style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w600)),
                        ),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: () => _confirmDelete(context, event['title'] as String),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                  ),
                  child: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, String title) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete event?'),
        content: Text('Are you sure you want to delete "$title"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"$title" deleted'), backgroundColor: Colors.redAccent));
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Widget _buildPill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(100)),
        child: Text(text, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
      );
}

// ─── SCREEN 3 — CREATE EVENT ─────────────────────────────────
class CreateEventScreen extends StatefulWidget {
  const CreateEventScreen({super.key});
  @override
  State<CreateEventScreen> createState() => _CreateEventScreenState();
}

class _CreateEventScreenState extends State<CreateEventScreen> {
  int currentStep = 0;
  DateTime? selectedDate;
  TimeOfDay? selectedTime;
  final titleController = TextEditingController(text: "Sarah's Birthday Bash");
  final descController = TextEditingController(text: "Join us for a fun celebration!");
  final newItemNameController = TextEditingController();
  final newItemPriceController = TextEditingController();

  List<Map<String, dynamic>> wishlistItems = [
    {'name': 'Wireless Earbuds', 'price': 129.99, 'contributed': 45.0, 'bought': false},
    {'name': 'Gift Card - Amazon', 'price': 100.0, 'contributed': 100.0, 'bought': true},
    {'name': 'Party Decorations', 'price': 75.0, 'contributed': 0.0, 'bought': false},
  ];

  Future<void> _pickDate() async {
    final picked = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime.now(), lastDate: DateTime(2027));
    if (picked != null) setState(() => selectedDate = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (picked != null) setState(() => selectedTime = picked);
  }

  void _addWishlistItem() {
    if (newItemNameController.text.isEmpty || newItemPriceController.text.isEmpty) return;
    setState(() {
      wishlistItems.add({'name': newItemNameController.text, 'price': double.tryParse(newItemPriceController.text) ?? 0.0, 'contributed': 0.0, 'bought': false});
      newItemNameController.clear();
      newItemPriceController.clear();
    });
  }

  void _toggleBuy(int index) => setState(() {
        wishlistItems[index]['bought'] = !wishlistItems[index]['bought'];
        if (!(wishlistItems[index]['bought'] as bool)) wishlistItems[index]['contributed'] = 0.0;
      });

  void _contribute(int index, double amount) => setState(() {
        double c = (wishlistItems[index]['contributed'] as double) + amount;
        wishlistItems[index]['contributed'] = c.clamp(0.0, wishlistItems[index]['price'] as double);
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(currentStep == 0 ? 'Event Details' : 'Wishlist', style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.dark)),
        leading: currentStep == 1
            ? IconButton(icon: const Icon(Icons.arrow_back, color: AppColors.dark), onPressed: () => setState(() => currentStep = 0))
            : null,
      ),
      body: Column(
        children: [
          // Step indicator
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              children: [
                Row(
                  children: [
                    _stepDot(0, 'Details'),
                    Expanded(child: Divider(color: currentStep >= 1 ? AppColors.green : Colors.grey.shade300, thickness: 2)),
                    _stepDot(1, 'Wishlist'),
                  ],
                ),
              ],
            ),
          ),
          Expanded(child: currentStep == 0 ? _buildStep1() : _buildStep2()),
        ],
      ),
      bottomNavigationBar: _debugLabel('Screen 3 — Host View'),
    );
  }

  Widget _stepDot(int step, String label) => Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: currentStep >= step ? AppColors.green : Colors.grey.shade200,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: currentStep > step
                  ? const Icon(Icons.check, color: Colors.white, size: 16)
                  : Text('${step + 1}', style: TextStyle(color: currentStep == step ? Colors.white : AppColors.muted, fontWeight: FontWeight.w700, fontSize: 14)),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 11, color: currentStep >= step ? AppColors.green : AppColors.muted, fontWeight: FontWeight.w500)),
        ],
      );

  Widget _buildStep1() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel('Event Title'),
          TextField(
            controller: titleController,
            decoration: _inputDecoration('e.g. Sarah\'s Birthday Bash'),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Date'),
                  GestureDetector(
                    onTap: _pickDate,
                    child: _dateTimeBox(selectedDate != null ? '${selectedDate!.day}/${selectedDate!.month}/${selectedDate!.year}' : 'Pick Date', Icons.calendar_today_outlined),
                  ),
                ]),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Time'),
                  GestureDetector(
                    onTap: _pickTime,
                    child: _dateTimeBox(selectedTime != null ? selectedTime!.format(context) : 'Pick Time', Icons.access_time_outlined),
                  ),
                ]),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _fieldLabel('Description'),
          TextField(controller: descController, maxLines: 4, decoration: _inputDecoration('Tell your guests what to expect...')),
          const SizedBox(height: 40),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: () => setState(() => currentStep = 1),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Text('Next: Wishlist', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)), SizedBox(width: 8), Icon(Icons.arrow_forward)]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep2() {
    return Column(
      children: [
        // Add item row
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(child: TextField(controller: newItemNameController, decoration: _inputDecoration('Item name'))),
              const SizedBox(width: 10),
              SizedBox(width: 90, child: TextField(controller: newItemPriceController, keyboardType: TextInputType.number, decoration: _inputDecoration('\$ Price'))),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: _addWishlistItem,
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
                child: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: wishlistItems.length,
            itemBuilder: (context, index) => _buildWishlistItem(index),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GenerateQRCodeScreen())),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.qr_code_2), SizedBox(width: 10), Text('Generate Event QR Code', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWishlistItem(int index) {
    final item = wishlistItems[index];
    final isBought = item['bought'] as bool;
    final progress = (item['contributed'] as double) / (item['price'] as double);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.black.withOpacity(0.05))),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(item['name'] as String, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: isBought ? AppColors.muted : AppColors.dark, decoration: isBought ? TextDecoration.lineThrough : null)),
              Text('\$${(item['price'] as double).toStringAsFixed(2)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.dark)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(value: progress, minHeight: 8, backgroundColor: Colors.grey.shade100, color: isBought ? Colors.grey : AppColors.greenLight),
          ),
          const SizedBox(height: 6),
          Text('\$${(item['contributed'] as double).toStringAsFixed(0)} of \$${(item['price'] as double).toStringAsFixed(0)} contributed', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton(
                onPressed: () => _toggleBuy(index),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isBought ? Colors.grey.shade400 : AppColors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(isBought ? 'Undo' : 'Buy', style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  children: [20, 40, 60].map((amt) => OutlinedButton(
                        onPressed: () => _contribute(index, amt.toDouble()),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.green),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text('\$$amt', style: const TextStyle(color: AppColors.green, fontSize: 13)),
                      )).toList(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text('Unfulfilled contributions go to the host', style: TextStyle(fontSize: 11, color: AppColors.muted, fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }

  Widget _fieldLabel(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.dark)),
      );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppColors.muted),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE0E8E0))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE0E8E0))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      );

  Widget _dateTimeBox(String text, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE0E8E0))),
        child: Row(children: [Icon(icon, size: 18, color: AppColors.muted), const SizedBox(width: 8), Text(text, style: const TextStyle(fontSize: 14, color: AppColors.dark))]),
      );
}

// ─── SCREEN 4 — GENERATE QR CODE ─────────────────────────────
class GenerateQRCodeScreen extends StatelessWidget {
  const GenerateQRCodeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text('Event QR Code', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.dark)),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Unique to this event', style: TextStyle(fontSize: 14, color: AppColors.muted, letterSpacing: 1, fontWeight: FontWeight.w500)),
              const SizedBox(height: 16),
              Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppColors.green, width: 3),
                  boxShadow: [BoxShadow(color: AppColors.green.withOpacity(0.15), blurRadius: 40, spreadRadius: 4)],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.qr_code_2, size: 140, color: AppColors.dark),
                    const SizedBox(height: 8),
                    Text("Sarah's Birthday Bash", style: TextStyle(fontSize: 13, color: AppColors.muted, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'Guests scan this to RSVP, view\nthe wishlist, and upload photos',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: AppColors.muted, height: 1.6),
              ),
              const SizedBox(height: 40),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _showComingSoon(context, 'Download'),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Download'),
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _showComingSoon(context, 'Share'),
                      icon: const Icon(Icons.share_outlined),
                      label: const Text('Share'),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.green), foregroundColor: AppColors.green, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 20),
              const Text('Want something physical?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.dark)),
              const SizedBox(height: 6),
              const Text('Order printed invitations or stickers with your QR code — shipped to your door.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: AppColors.muted, height: 1.5)),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _showComingSoon(context, 'Invitation ordering'),
                      icon: const Icon(Icons.mail_outline_rounded),
                      label: const Text('Order Invitations', style: TextStyle(fontWeight: FontWeight.w600)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.dark,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _showComingSoon(context, 'Sticker ordering'),
                      icon: const Icon(Icons.star_outline_rounded),
                      label: const Text('Order Stickers', style: TextStyle(fontWeight: FontWeight.w600)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.gold,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text('Powered by Printably', style: TextStyle(fontSize: 11, color: AppColors.muted)),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _debugLabel('Screen 4 — Generate QR Code'),
    );
  }
}

// ─── SCREEN 10 — GUEST EVENT VIEW ────────────────────────────
class GuestEventScreen extends StatefulWidget {
  const GuestEventScreen({super.key});
  @override
  State<GuestEventScreen> createState() => _GuestEventScreenState();
}

class _GuestEventScreenState extends State<GuestEventScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String rsvpStatus = 'Not Responded';
  int adults = 1;
  int children = 0;
  List<String> uploadedPhotos = [];

  List<Map<String, dynamic>> wishlistItems = [
    {'name': 'Wireless Earbuds', 'price': 129.99, 'contributed': 45.0, 'bought': false},
    {'name': 'Gift Card - Amazon', 'price': 100.0, 'contributed': 100.0, 'bought': true},
    {'name': 'Party Decorations', 'price': 75.0, 'contributed': 0.0, 'bought': false},
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _uploadPhoto() {
    setState(() => uploadedPhotos.add('https://picsum.photos/id/${400 + uploadedPhotos.length}/300/300'));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('📸 Photo added to the wall!'), backgroundColor: AppColors.green));
  }

  void _toggleBuy(int index) => setState(() {
        wishlistItems[index]['bought'] = !wishlistItems[index]['bought'];
        if (!(wishlistItems[index]['bought'] as bool)) wishlistItems[index]['contributed'] = 0.0;
      });

  void _contribute(int index, double amount) => setState(() {
        double c = (wishlistItems[index]['contributed'] as double) + amount;
        wishlistItems[index]['contributed'] = c.clamp(0.0, wishlistItems[index]['price'] as double);
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text("Sarah's Birthday Bash", style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.dark, fontSize: 17)),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.green,
          unselectedLabelColor: AppColors.muted,
          indicatorColor: AppColors.green,
          indicatorWeight: 2.5,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          tabs: const [Tab(text: 'Info & RSVP'), Tab(text: 'Wishlist'), Tab(text: 'Photos')],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildInfoTab(), _buildWishlistTab(), _buildPhotosTab()],
      ),
      bottomNavigationBar: _debugLabel('Screen 10 — Guest View'),
    );
  }

  Widget _buildInfoTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Image.network('https://picsum.photos/id/1015/800/300', height: 200, width: double.infinity, fit: BoxFit.cover),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Sarah's Birthday Bash", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.dark)),
                const SizedBox(height: 8),
                Row(children: const [
                  Icon(Icons.calendar_today_outlined, size: 16, color: AppColors.muted),
                  SizedBox(width: 6),
                  Text('April 25, 2026 · 6:30 PM', style: TextStyle(fontSize: 15, color: AppColors.muted)),
                ]),
                const SizedBox(height: 6),
                Row(children: const [
                  Icon(Icons.location_on_outlined, size: 16, color: AppColors.muted),
                  SizedBox(width: 6),
                  Text('123 Celebration Lane, Seaside, CA', style: TextStyle(fontSize: 15, color: AppColors.muted)),
                ]),
                const SizedBox(height: 20),
                Row(children: [
                  _pill('25 Yes', AppColors.green),
                  const SizedBox(width: 8),
                  _pill('8 Maybe', AppColors.gold),
                  const SizedBox(width: 8),
                  _pill('3 No', Colors.redAccent),
                ]),
                const SizedBox(height: 28),
                const Text('Will you attend?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.dark)),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: _rsvpButton('Yes', AppColors.green)),
                  const SizedBox(width: 10),
                  Expanded(child: _rsvpButton('Maybe', AppColors.gold)),
                  const SizedBox(width: 10),
                  Expanded(child: _rsvpButton('No', Colors.redAccent)),
                ]),
                if (rsvpStatus == 'Yes' || rsvpStatus == 'Maybe') ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(14)),
                    child: Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Adults', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.dark)),
                        DropdownButton<int>(
                          value: adults,
                          underline: const SizedBox(),
                          items: List.generate(6, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
                          onChanged: (v) => setState(() => adults = v!),
                        ),
                      ])),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Children', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.dark)),
                        DropdownButton<int>(
                          value: children,
                          underline: const SizedBox(),
                          items: List.generate(5, (i) => DropdownMenuItem(value: i, child: Text('$i'))),
                          onChanged: (v) => setState(() => children = v!),
                        ),
                      ])),
                    ]),
                  ),
                ],
                if (rsvpStatus != 'No') ...[
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('🚀 Running Late notification sent!'), backgroundColor: AppColors.gold)),
                      icon: const Icon(Icons.directions_run, color: AppColors.gold),
                      label: const Text("I'm Running Late", style: TextStyle(color: AppColors.gold, fontWeight: FontWeight.w600)),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.gold), padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWishlistTab() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
          child: Row(children: [
            Text('Wishlist', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.dark)),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: wishlistItems.length,
            itemBuilder: (context, index) {
              final item = wishlistItems[index];
              final isBought = item['bought'] as bool;
              final progress = (item['contributed'] as double) / (item['price'] as double);
              return Container(
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.black.withOpacity(0.05))),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(item['name'] as String, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: isBought ? AppColors.muted : AppColors.dark, decoration: isBought ? TextDecoration.lineThrough : null)),
                        Text('\$${(item['price'] as double).toStringAsFixed(2)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(value: progress, minHeight: 8, backgroundColor: Colors.grey.shade100, color: isBought ? Colors.grey : AppColors.greenLight),
                    ),
                    const SizedBox(height: 6),
                    Text('\$${(item['contributed'] as double).toStringAsFixed(0)} of \$${(item['price'] as double).toStringAsFixed(0)} contributed', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: () => _toggleBuy(index),
                          style: ElevatedButton.styleFrom(backgroundColor: isBought ? Colors.grey.shade400 : AppColors.green, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
                          child: Text(isBought ? 'Undo' : 'Buy'),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            children: [20, 40, 60].map((amt) => OutlinedButton(
                                  onPressed: () => _contribute(index, amt.toDouble()),
                                  style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.green), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                                  child: Text('\$$amt', style: const TextStyle(color: AppColors.green, fontSize: 13)),
                                )).toList(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text('Unfulfilled contributions go to the host', style: TextStyle(fontSize: 11, color: AppColors.muted, fontStyle: FontStyle.italic)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPhotosTab() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: AppColors.greenPale,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: const Row(children: [
            Icon(Icons.camera_alt_outlined, color: AppColors.green, size: 18),
            SizedBox(width: 10),
            Text('Share your photos from the event!', style: TextStyle(color: AppColors.green, fontSize: 15, fontWeight: FontWeight.w600)),
          ]),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
            itemCount: uploadedPhotos.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return GestureDetector(
                  onTap: _uploadPhoto,
                  child: Container(
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.green, width: 1.5), color: AppColors.greenPale),
                    child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.add_a_photo_outlined, size: 28, color: AppColors.green), SizedBox(height: 4), Text('Add', style: TextStyle(fontSize: 12, color: AppColors.green, fontWeight: FontWeight.w500))]),
                  ),
                );
              }
              return ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(uploadedPhotos[i - 1], fit: BoxFit.cover));
            },
          ),
        ),
      ],
    );
  }

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(100)),
        child: Text(text, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
      );

  Widget _rsvpButton(String label, Color color) {
    final isSelected = rsvpStatus == label;
    return ElevatedButton(
      onPressed: () => setState(() => rsvpStatus = label),
      style: ElevatedButton.styleFrom(
        backgroundColor: isSelected ? color : Colors.grey.shade100,
        foregroundColor: isSelected ? Colors.white : AppColors.muted,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}

// ─── STUB SCREENS ─────────────────────────────────────────────
class HostNotificationsScreen extends StatelessWidget {
  const HostNotificationsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Notifications'), backgroundColor: Colors.white, elevation: 0),
        body: const Center(child: Text('Screen 7 — Notifications\n(Coming soon)', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted))),
        bottomNavigationBar: _debugLabel('Screen 7 — Host View'),
      );
}

class ThankYouScreen extends StatelessWidget {
  const ThankYouScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Thank You'), backgroundColor: Colors.white, elevation: 0),
        body: const Center(child: Text('Screen 8 — Thank You\n(Coming soon)', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted))),
        bottomNavigationBar: _debugLabel('Screen 8 — Host View'),
      );
}

class ViewFullEventScreen extends StatelessWidget {
  const ViewFullEventScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Event Details'), backgroundColor: Colors.white, elevation: 0),
        body: const Center(child: Text('Screen 5 — View Full Event\n(Coming soon)', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted))),
        bottomNavigationBar: _debugLabel('Screen 5 — Host View'),
      );
}

class OrderPrintsScreen extends StatelessWidget {
  const OrderPrintsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Order Prints'), backgroundColor: Colors.white, elevation: 0),
        body: const Center(child: Text('Screen 6 — Order Prints\n(Coming soon)', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted))),
        bottomNavigationBar: _debugLabel('Screen 6 — Host View'),
      );
}

class PictureWallScreen extends StatelessWidget {
  const PictureWallScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Picture Wall'), backgroundColor: Colors.white, elevation: 0),
        body: const Center(child: Text('Screen 11 — Picture Wall\n(Coming soon)', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted))),
        bottomNavigationBar: _debugLabel('Screen 11 — Guest View'),
      );
}

class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Analytics'), backgroundColor: Colors.white, elevation: 0),
        body: const Center(child: Text('Screen 12 — Analytics\n(Coming soon)', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted))),
        bottomNavigationBar: _debugLabel('Screen 12 — Admin View'),
      );
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings'), backgroundColor: Colors.white, elevation: 0),
        body: const Center(child: Text('Screen 13 — Settings\n(Coming soon)', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted))),
        bottomNavigationBar: _debugLabel('Screen 13 — Host View'),
      );
}

// ─── HELPERS ──────────────────────────────────────────────────
void _showComingSoon(BuildContext context, String feature) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$feature coming soon!'), backgroundColor: AppColors.green, behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));
}

Widget _debugLabel(String label) => Padding(
      padding: const EdgeInsets.all(10),
      child: Text(label, style: const TextStyle(fontSize: 10, color: AppColors.muted), textAlign: TextAlign.center),
    );