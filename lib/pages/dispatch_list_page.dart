import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/yarn_service.dart';
import './qr_code.dart';

class DispatchListPage extends StatefulWidget {
  const DispatchListPage({super.key});

  @override
  State<DispatchListPage> createState() => _DispatchListPageState();
}

class _DispatchListPageState extends State<DispatchListPage>
    with SingleTickerProviderStateMixin {
  final YarnService yarnService = YarnService();
  late AnimationController _listAnimationController;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _listAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _listAnimationController.forward();
  }

  @override
  void dispose() {
    _listAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Colors.orange.shade400;

    return SafeArea(child: Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        centerTitle: true,
        elevation: 0,
        title: const Text('Dispatch Yarn', style: TextStyle(color: Colors.black)),
        backgroundColor: Colors.white,
        automaticallyImplyLeading: false,
        iconTheme: IconThemeData(color: primaryColor),
      ),
      body: Column(
        children: [
          // ================== SEARCH FIELD ==================
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search by Yarn ID...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value.trim();
                });
              },
            ),
          ),

          // ================== LIST ==================
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: yarnService.getMovedYarns(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                var docs = snapshot.data?.docs ?? [];

                // Filter by search query
                if (_searchQuery.isNotEmpty) {
                  docs = docs.where((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final yarnId = (data['id'] ?? data['yarnId'] ?? data['ID'] ?? doc.id)
                        .toString()
                        .toLowerCase();
                    return yarnId.contains(_searchQuery.toLowerCase());
                  }).toList();
                }

                // ================= EMPTY STATE =================
                if (docs.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(26),
                            decoration: BoxDecoration(
                              color: primaryColor.withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.local_shipping_outlined,
                              size: 72,
                              color: Colors.orangeAccent,
                            ),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'No Yarn Ready for Dispatch',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'All items have been dispatched\nor none are ready.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final yarnId = data['id'] ?? data['yarnId'] ?? data['ID'] ?? doc.id;

                    // Animation for each item
                    final animation = Tween<Offset>(
                      begin: const Offset(0, 0.1),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(
                        parent: _listAnimationController,
                        curve: Interval(
                          (index / docs.length),
                          1.0,
                          curve: Curves.easeOut,
                        ),
                      ),
                    );

                    // Alternate tile colors
                    final tileColor = index % 2 == 0
                        ? Colors.white.withOpacity(0.65)
                        : Colors.white.withOpacity(0.55);

                    return FadeTransition(
                      opacity: _listAnimationController,
                      child: SlideTransition(
                        position: animation,
                        child: Dismissible(
                          key: ValueKey(doc.id),
                          background: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            alignment: Alignment.centerLeft,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Colors.orangeAccent, Colors.orange],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(Icons.qr_code_scanner, color: Colors.white),
                          ),
                          secondaryBackground: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            alignment: Alignment.centerRight,
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(Icons.delete_forever, color: Colors.white),
                          ),
                          confirmDismiss: (direction) async {
                            if (direction == DismissDirection.startToEnd) {
                              final scanSuccess = await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ScanCodePage(
                                    expectedQr: yarnId.toString(),
                                    title: 'Verify Dispatch - $yarnId',
                                  ),
                                ),
                              );

                              if (scanSuccess == true) {
                                if (!context.mounted) return false;
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => _buildGlassDialog(
                                    context,
                                    title: 'Confirm Dispatch',
                                    message: 'Final step: Dispatch Yarn $yarnId?',
                                    confirmColor: Colors.orangeAccent,
                                  ),
                                );

                                if (confirmed == true) {
                                  await yarnService.updateYarnStatus(doc.id, 'dispatched');
                                }
                              }
                              return false;
                            } else {
                              final confirmRemove = await showDialog<bool>(
                                context: context,
                                barrierColor: Colors.black.withOpacity(0.2),
                                builder: (ctx) => _buildGlassDialog(
                                  context,
                                  title: 'Remove Yarn',
                                  message: 'Are you sure you want to remove yarn $yarnId?',
                                  cancelRed: true,
                                ),
                              );

                              if (confirmRemove == true) {
                                await yarnService.updateYarnStatus(doc.id, 'cancelled');
                                return true;
                              }
                              return false;
                            }
                          },
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 14),
                                decoration: BoxDecoration(
                                  color: tileColor,
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.05),
                                      blurRadius: 12,
                                      offset: const Offset(0, 6),
                                    ),
                                  ],
                                ),
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  children: [
                                    Container(
                                      decoration: BoxDecoration(
                                        color: Colors.teal.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      padding: const EdgeInsets.all(12),
                                      child: const Icon(
                                        Icons.local_shipping,
                                        color: Colors.orangeAccent,
                                        size: 28,
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            yarnId.toString(),
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: Colors.orange.withOpacity(0.15),
                                              borderRadius: BorderRadius.circular(20),
                                            ),
                                            child: const Text(
                                              'READY TO DISPATCH',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.orange,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    )
    );
  }

  Widget _buildGlassDialog(BuildContext context,
      {required String title,
        required String message,
        Color confirmColor = Colors.orangeAccent,
        bool cancelRed = false}) {
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: MediaQuery.of(context).size.width * 0.8,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.3),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black87, fontSize: 16),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(120, 48),
                        backgroundColor: Colors.white.withOpacity(0.2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'CANCEL',
                        style: TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(120, 48),
                        backgroundColor: cancelRed
                            ? Colors.red.withOpacity(0.25)
                            : confirmColor.withOpacity(0.25),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        cancelRed ? 'REMOVE' : 'CONFIRM',
                        style: TextStyle(
                          color: cancelRed ? Colors.redAccent : confirmColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}
