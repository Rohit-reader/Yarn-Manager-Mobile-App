import 'package:flutter/material.dart';
import 'package:qr_reader/pages/qr_code.dart';
import 'package:shimmer/shimmer.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // Simulate loading
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Yarn Scanner')),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: _isLoading ? _shimmerLoader() : _mainContent(context),
      ),
    );
  }

  Widget _mainContent(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Empty space at top to center cards
        const SizedBox(height: 0),

        // Cards in the middle
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _fancyCard(
              context,
              title: 'Reserved List',
              subtitle: 'Move yarn from rack to floor',
              icon: Icons.inventory_2_outlined,
              colors: [Colors.greenAccent, Colors.green.shade700],
              onTap: () => Navigator.pushNamed(context, '/reserved'),
            ),
            const SizedBox(height: 16),
            _fancyCard(
              context,
              title: 'Dispatch List',
              subtitle: 'Verify and dispatch moved yarn',
              icon: Icons.local_shipping_outlined,
              colors: [Colors.orangeAccent, Colors.deepOrange],
              onTap: () => Navigator.pushNamed(context, '/dispatch'),
            ),
            const SizedBox(height: 16),
            _fancyCard(
              context,
              title: 'Add Yarn',
              subtitle: 'Scan QR to add yarn to inventory',
              icon: Icons.qr_code_scanner,
              colors: [Colors.pinkAccent.shade100, Colors.red.shade700],
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ScanCodePage(
                    title: 'Add New Yarn',
                    isAddMode: true,
                  ),
                ),
              ),
            ),
          ],
        ),

        // Footer text at the bottom
        Text(
          '© 2026 Yarn Manager. All rights reserved.',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          textAlign: TextAlign.center
        ),
      ],
    );
  }

  Widget _fancyCard(
      BuildContext context, {
        required String title,
        required String subtitle,
        required IconData icon,
        required List<Color> colors,
        required VoidCallback onTap,
      }) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          ClipPath(
            clipper: DiagonalClipper(),
            child: Container(
              height: 180,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: colors,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: colors.last.withOpacity(0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: -30,
            top: -30,
            child: Icon(icon, color: Colors.white24, size: 110),
          ),
          Container(
            height: 180,
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(subtitle,
                    style: const TextStyle(color: Colors.white70, fontSize: 15)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _shimmerLoader() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.max,
      children: List.generate(3, (index) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Shimmer.fromColors(
            baseColor: Colors.grey.shade300,
            highlightColor: Colors.grey.shade100,
            child: ClipPath(
              clipper: DiagonalClipper(),
              child: Container(
                height: 180,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class DiagonalClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.moveTo(0, size.height * 0.15);
    path.lineTo(size.width, 0);
    path.lineTo(size.width, size.height * 0.85);
    path.lineTo(0, size.height);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
