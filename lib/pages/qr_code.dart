import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/yarn_service.dart';
import './yarn_detail_page.dart';

class ScanCodePage extends StatefulWidget {
  final String? expectedQr;
  final bool isAddMode;
  final String? title;

  const ScanCodePage({
    super.key,
    this.expectedQr,
    this.isAddMode = false,
    this.title,
  });

  @override
  State<ScanCodePage> createState() => _ScanCodePageState();
}

class _ScanCodePageState extends State<ScanCodePage>
    with SingleTickerProviderStateMixin {
  final YarnService _yarnService = YarnService();
  MobileScannerController? controller;
  bool isScanning = true;
  bool isProcessing = false;
  
  // Rack/Bin Flow State
  int? currentRackId;
  int? currentBinId;
  
  late AnimationController animationController;
  late Animation<double> laserAnimation;
  Timer? idleTimer;

  @override
  void initState() {
    super.initState();
    controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      returnImage: false,
    );

    animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    laserAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: animationController, curve: Curves.linear),
    );

    // No idle timer for Add Mode to allow continuous scanning
    if (!widget.isAddMode) {
      _startIdleTimer();
    }
  }

  void _startIdleTimer() {
    idleTimer?.cancel();
    idleTimer = Timer(const Duration(seconds: 15), () {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  void dispose() {
    controller?.dispose();
    animationController.dispose();
    idleTimer?.cancel();
    super.dispose();
  }

  // ================= LOGIC =================

  void _handleScan(BarcodeCapture capture) async {
    if (!isScanning || isProcessing) return;

    final rawValue = capture.barcodes.first.rawValue;
    if (rawValue == null || rawValue.trim().isEmpty) return;
    
    final qrData = rawValue.trim();
    if (!widget.isAddMode) _startIdleTimer(); 

    setState(() => isProcessing = true);

    try {
        if (widget.isAddMode) {
            // Attempt to identify as Rack or Bin first
            final rackId = _tryParseRackId(qrData);
            if (rackId != null) {
                await _processRackAction(rackId);
                return;
            }

            final binId = _tryParseBinId(qrData);
            if (binId != null) {
                await _processBinAction(binId);
                return;
            }
        }
        
        // Fallback: Treat as Yarn Scan
        await _processYarnScan(qrData);

    } catch (e) {
        _showToast('Error: $e', isError: true);
    } finally {
        await Future.delayed(const Duration(milliseconds: 1000));
        if (mounted) {
            setState(() {
                isProcessing = false;
            });
        }
    }
  }

  // --- Parsing Helpers ---

  int? _tryParseRackId(String qr) {
      // 1. JSON-like structure or Strict JSON
      try {
          final decoded = _safeJsonDecode(qr);
          if (decoded != null && decoded is Map) {
              // Avoid false positives with yarn data
              if (decoded.containsKey('yarnId') || decoded.containsKey('color')) return null;

              final val = decoded['rack'] ?? decoded['Rack'];
              if (val != null) return int.tryParse(val.toString().trim());
          }
      } catch(_) {}

      // 2. Regex for "Rack : 1" or "{"rack": 1}"
      final regex = RegExp(r'(?:Rack|rack)\s*["\s]*[:\-\s]\s*["\s]*(\d+)', caseSensitive: false);
      final match = regex.firstMatch(qr);
      if (match != null) return int.tryParse(match.group(1)!);

      return null;
  }

  int? _tryParseBinId(String qr) {
      // 1. JSON-like structure or Strict JSON
      try {
          final decoded = _safeJsonDecode(qr);
          if (decoded != null && decoded is Map) {
               if (decoded.containsKey('yarnId') || decoded.containsKey('color')) return null;
               
              final val = decoded['bin'] ?? decoded['Bin'];
              if (val != null) return int.tryParse(val.toString().trim());
          }
      } catch(_) {}

      // 2. Regex for "Bin : 5" or "{"bin": 5}"
      final regex = RegExp(r'(?:Bin|bin)\s*["\s]*[:\-\s]\s*["\s]*(\d+)', caseSensitive: false);
      final match = regex.firstMatch(qr);
      if (match != null) return int.tryParse(match.group(1)!);

      return null;
  }

  // --- Actions ---

  Future<void> _processRackAction(int id) async {
      await _yarnService.createRack(id);
      setState(() {
        currentRackId = id;
        currentBinId = null; 
      });
      _showToast('✅ Rack $id Selected', isError: false);
  }

  Future<void> _processBinAction(int id) async {
      if (currentRackId == null) {
          _showToast('⚠️ Scan a Rack first!', isError: true);
          return;
      }
      
      try {
         await _yarnService.linkBinToRack(id, currentRackId!);
         setState(() {
            currentBinId = id;
         });
         _showToast('✅ Bin $id linked to Rack $currentRackId', isError: false);
      } catch(e) {
         _showToast('Error linking bin: $e', isError: true);
      }
  }

  dynamic _safeJsonDecode(String input) {
      try {
          return jsonDecode(input); // Requires import 'dart:convert'
      } catch(_) {
          return null;
      }
  }

  Future<void> _processYarnScan(String qr) async {

      // Default behavior (View Details / Verify)
      controller?.stop();
      setState(() => isScanning = false);

      await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => YarnDataPage(
              qr: qr,
              expectedQr: widget.expectedQr,
              isAddMode: widget.isAddMode,
                binId: currentBinId,
                rackId: currentRackId,
            ),
          ),
      );

      if (mounted) {
        setState(() => isScanning = true);
        controller?.start();
        if (!widget.isAddMode) _startIdleTimer();
      }
  }


  void _showToast(String msg, {bool isError = false}) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(msg, style: const TextStyle(fontSize: 16)), 
            backgroundColor: isError ? Colors.red.shade600 : Colors.green.shade600,
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
        )
      );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(child:Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Camera
          MobileScanner(
            controller: controller!,
            onDetect: _handleScan,
          ),
          
          // 2. Scanner Overlay (Darken outer area)
          _buildScannerOverlay(context),
          
          // 3. Scanning Animation (Corner Brackets + Moving Laser)
          Align(
            alignment: Alignment.center,
            child: SizedBox(
              width: MediaQuery.of(context).size.width * 0.7,
              height: MediaQuery.of(context).size.width * 0.7,
              child: Stack(
                children: [
                  // Corner brackets
                  _buildScannerCorners(),
                  // Moving laser
                  AnimatedBuilder(
                    animation: laserAnimation,
                    builder: (context, child) {
                      return Positioned(
                        top: laserAnimation.value * (MediaQuery.of(context).size.width * 0.7 - 2),
                        left: 0,
                        right: 0,
                        child: Container(
                          height: 2,
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withOpacity(0.8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.redAccent.withOpacity(0.5),
                                blurRadius: 10,
                                spreadRadius: 1,
                              )
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),

          // 4. Top Bar (Back button + Title)
           Positioned(
            top: 40,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                CircleAvatar(
                  backgroundColor: Colors.black45,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                Text(
                  widget.isAddMode ? 'Scan to Add' : 'Scan to Verify',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                  ),
                ),
                const SizedBox(width: 40), // Balance spacing
              ],
            ),
          ),

          // 5. Bottom Workflow Control
          if (widget.isAddMode) 
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildBottomPanel(),
            ),

          // 6. Processing Indicator
          if (isProcessing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    )
    );
  }

  Widget _buildBottomPanel() {
      return Container(
          padding: const EdgeInsets.all(20),
          decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, -4))]
          ),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                  // Current Context
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                          _infoChip('Rack', currentRackId?.toString() ?? 'None', Icons.grid_view, currentRackId != null),
                          Container(width: 1, height: 40, color: Colors.grey.shade300),
                          _infoChip('Bin', currentBinId?.toString() ?? 'None', Icons.inventory_2, currentBinId != null),
                      ],
                  ),
                  const SizedBox(height: 20),
                  // Instructions / Status
                  if (currentRackId == null)
                       const Text('Scan a Rack QR (Rack : 1)', style: TextStyle(color: Colors.grey, fontSize: 16)),
                  if (currentRackId != null && currentBinId == null)
                       const Text('Scan a Bin QR (Bin : 5)', style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 16)),
                  if (currentRackId != null && currentBinId != null)
                       const Text('Scan Yarn to Add to Bin', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 16)),

                  const SizedBox(height: 10),
                  
                  // Helper Manual Buttons? 
                  // "Display option '+ Add Rack'"
                  if (currentRackId == null)
                      SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                              icon: const Icon(Icons.qr_code),
                              label: const Text('Scan Rack QR Code'),
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blueAccent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12)
                              ),
                              onPressed: () {}, // Handled by scan, this is just visual cue mostly? Or we could pop manual input dialog?
                          ),
                      ),
              ],
          ),
      );
  }
  
  Widget _infoChip(String label, String value, IconData icon, bool active) {
      return Column(
          children: [
              Icon(icon, color: active ? Colors.black87 : Colors.grey),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: active ? Colors.blue : Colors.grey)),
          ],
      );
  }

  Widget _buildScannerOverlay(BuildContext context) {
    return ColorFiltered(
      colorFilter: ColorFilter.mode(
        Colors.black.withOpacity(0.6),
        BlendMode.srcOut,
      ),
      child: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              color: Colors.transparent,
              backgroundBlendMode: BlendMode.dstOut,
            ),
          ),
          Align(
            alignment: Alignment.center,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.7,
              height: MediaQuery.of(context).size.width * 0.7,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScannerCorners() {
      const double cornerSize = 30;
      const double strokeWidth = 5;
      const Color cornerColor = Colors.white;

      return Stack(
          children: [
              // Top Left
              Positioned(
                  top: 0, left: 0,
                  child: Container(
                      width: cornerSize, height: cornerSize,
                      decoration: const BoxDecoration(
                          border: Border(
                              top: BorderSide(color: cornerColor, width: strokeWidth),
                              left: BorderSide(color: cornerColor, width: strokeWidth),
                          ),
                      ),
                  ),
              ),
              // Top Right
              Positioned(
                  top: 0, right: 0,
                  child: Container(
                      width: cornerSize, height: cornerSize,
                      decoration: const BoxDecoration(
                          border: Border(
                              top: BorderSide(color: cornerColor, width: strokeWidth),
                              right: BorderSide(color: cornerColor, width: strokeWidth),
                          ),
                      ),
                  ),
              ),
              // Bottom Left
              Positioned(
                  bottom: 0, left: 0,
                  child: Container(
                      width: cornerSize, height: cornerSize,
                      decoration: const BoxDecoration(
                          border: Border(
                              bottom: BorderSide(color: cornerColor, width: strokeWidth),
                              left: BorderSide(color: cornerColor, width: strokeWidth),
                          ),
                      ),
                  ),
              ),
              // Bottom Right
              Positioned(
                  bottom: 0, right: 0,
                  child: Container(
                      width: cornerSize, height: cornerSize,
                      decoration: const BoxDecoration(
                          border: Border(
                              bottom: BorderSide(color: cornerColor, width: strokeWidth),
                              right: BorderSide(color: cornerColor, width: strokeWidth),
                          ),
                      ),
                  ),
              ),
          ],
      );
  }
}
