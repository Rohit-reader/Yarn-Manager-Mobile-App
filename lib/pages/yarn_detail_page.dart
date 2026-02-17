import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'dart:convert';
import '../services/yarn_service.dart';
import './qr_code.dart';

class YarnDataPage extends StatefulWidget {
  final String qr;
  final String? expectedQr;
  final String? reservedDocId;
  final bool isAddMode;
  final bool isDispatchMode;
  final int? binId;
  final int? rackId;

  const YarnDataPage({
    super.key,
    required this.qr,
    this.expectedQr,
    this.reservedDocId, 
    this.isAddMode = false,
    this.isDispatchMode = false,
    this.binId,
    this.rackId,
  });

  @override
  State<YarnDataPage> createState() => _YarnDataPageState();
}

class _YarnDataPageState extends State<YarnDataPage> {
  Map<String, dynamic>? yarnData;
  bool isLoading = true;
  bool isProcessing = false;
  bool isInvalidQr = false;
  String? yarnRollDocId;
  
  // Batch & Weight
  final TextEditingController _countController = TextEditingController(text: '1');
  final TextEditingController _weightController = TextEditingController(); // Fixed missing field
  // Removed weight controller as per previous request? 
  // Wait, previous request removed weight input from UI, but maybe we should keep the variable for logic?
  // The user only asked to "remove the weight / roll field in the confirmation".
  // I will keep the variable but not show it, or just re-read from settings/QR.
  // Actually, let's keep _weightController purely for internal state if needed, or better, 
  // just read from yarnData/Settings dynamically. 
  // But wait, the previous code still had _weightController defined, just removed the UI widget.
  // I'll leave _weightController alone (it's in lines 39).
  
  final TextEditingController _rackController = TextEditingController();
  final TextEditingController _binController = TextEditingController();

  // Auto-allocation state
  int? assignedRackId;
  int? assignedBinId;
  bool isAllocating = false;

  @override
  void initState() {
    super.initState();
    _fetchYarnData();
  }

  Future<void> _fetchYarnData() async {
    setState(() => isLoading = true);
    try {
      final yarnService = YarnService();
      
      if (widget.isAddMode) {
          // Parse directly from QR since it's not in DB yet
          final parsed = yarnService.parseYarnData(widget.qr);
          setState(() {
              yarnData = parsed;
              // Add temp display fields for Rack/Bin if passed
              if (widget.rackId != null) yarnData!['rack_id'] = widget.rackId;
              if (widget.binId != null) yarnData!['bin_id'] = widget.binId;
              
              // Pre-fill weight if available
              if (yarnData!.containsKey('weight')) {
                  _weightController.text = yarnData!['weight'].toString();
              } else {
                  // Fetch default weight
                  _fetchDefaultWeight();
              }
          });
          
          // Trigger Auto-Allocation lookup
          _fetchAutoAllocation();
      } else {
          final doc = await yarnService.findYarnByContent(widget.qr);
          if (doc != null && doc.exists) {
            setState(() {
              yarnData = doc.data() as Map<String, dynamic>;
              yarnRollDocId = doc.id;
            });
          } else {
            setState(() => yarnData = {'id': widget.qr, 'notFound': true});
          }

          // Validation Logic
          if (widget.expectedQr != null) {
              bool match = false;
              String scannedId = widget.qr.trim();

              // Try local JSON parse if not already a clean ID
              try {
                  final decoded = jsonDecode(scannedId);
                  if (decoded is Map) {
                      scannedId = (decoded['id'] ?? decoded['yarnId'] ?? decoded['ID'] ?? scannedId).toString();
                  }
              } catch (_) {}

              // 1. Cleaned scan ID vs Expected
              if (scannedId.toLowerCase() == widget.expectedQr!.trim().toLowerCase()) match = true;
              
              // 2. ID match in fetched data
              if (!match && yarnData != null) {
                  final id = yarnData!['id'] ?? yarnData!['yarnId'] ?? yarnData!['ID'];
                  if (id != null && id.toString().toLowerCase() == widget.expectedQr!.trim().toLowerCase()) match = true;
              }

              print("DEBUG VALIDATION: expected=${widget.expectedQr}, scannedRaw=${widget.qr}, parsedScanned=$scannedId, match=$match");
              setState(() => isInvalidQr = !match);
          }
      }
    } catch (_) {
      setState(() => yarnData = {'id': widget.qr, 'error': 'Failed to fetch'});
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _fetchDefaultWeight() async {
      // Logic removed: each roll must have its own weight.
  }

  Future<void> _fetchAutoAllocation() async {
      setState(() => isAllocating = true);
      try {
          final yarnService = YarnService();
          final int count = int.tryParse(_countController.text) ?? 1;
          final double weight = double.tryParse(_weightController.text) ?? 25.0;

          // We ask for space for 1 roll to find the STARTING bin. 
          // The addYarn process handles distribution for the rest.
          final allocation = await yarnService.getNextAvailableBin(count: 1, weightPerRoll: weight);
          
          if (mounted) {
              setState(() {
                  if (allocation != null) {
                      assignedRackId = allocation['rackId'];
                      assignedBinId = allocation['binId'];
                      
                      // Populate controllers for editing
                      _rackController.text = assignedRackId.toString();
                      _binController.text = assignedBinId.toString();
                  }
                  isAllocating = false;
              });
          }
      } catch (e) {
          if (mounted) setState(() => isAllocating = false);
          print('Error allocating: $e');
      }
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s
        .replaceAll('_', ' ')
        .split(' ')
        .map((str) =>
    str.isNotEmpty ? '${str[0].toUpperCase()}${str.substring(1)}' : '')
        .join(' ');
  }

  /// Show professional acknowledgment/toast
  void showAck(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(25),
        ),
        content: Row(
          children: [
            Image.asset(
              'assets/icon/app_icon.png', // Make sure logo exists in assets
              height: 24,
              width: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.black87,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Confirm yarn and go to main page
  Future<void> _confirmYarn() async {
    if (yarnData == null) return;
    setState(() => isProcessing = true);
    try {
      final yarnService = YarnService();
      
      final int count = int.tryParse(_countController.text) ?? 1;
      // Get Manual Rack/Bin
      final int? manualRack = int.tryParse(_rackController.text);
      final int? manualBin = int.tryParse(_binController.text);
      
      // Use weight from controller
      final double? weight = double.tryParse(_weightController.text);
      if (weight == null) {
          showAck(context, 'Error: Please provide a valid weight for the roll.');
          setState(() => isProcessing = false);
          return;
      }

      // Pass the explicit bin/rack IDs if available
      String systemId = await yarnService.addYarn(
          widget.qr, 
          yarnData!, 
          binId: manualBin ?? assignedBinId ?? widget.binId, 
          rackId: manualRack ?? assignedRackId ?? widget.rackId,
          count: count,
          weightOverride: weight
      );

      if (!mounted) return;

      // Show acknowledgment
      showAck(context, 'Success! $count rolls added.');
      
      // Navigate after close
      if (mounted) {
          Navigator.popUntil(context, (route) => route.isFirst);
      }
    } catch (e) {
      if (mounted) {
        showAck(context, 'Error saving yarn: ${e.toString()}');
        print('DEBUG ERROR in _confirmYarn: $e');
      }
    } finally {
      if (mounted) setState(() => isProcessing = false);
    }
  }

  Future<void> _confirmMove() async {
      if (widget.reservedDocId == null) return;
      setState(() => isProcessing = true);
      try {
          final yarnService = YarnService();
          
          if (widget.isDispatchMode) {
              // Mark as DISPATCHED instead of deleting
              // 1. Update status in reserved collection
              await yarnService.updateYarnStatus(widget.reservedDocId!, 'DISPATCHED');
              
              // 2. Update status in main inventory
              if (yarnRollDocId != null) {
                  await yarnService.updateYarnRollStatus(yarnRollDocId!, 'DISPATCHED');
              } else {
                  // Fallback: try to find it again if ID was lost
                  final doc = await yarnService.findYarnByContent(widget.qr);
                  if (doc != null) {
                      await yarnService.updateYarnRollStatus(doc.id, 'DISPATCHED');
                  }
              }
              
              if (!mounted) return;
              showAck(context, 'Yarn successfully dispatched!');
          } else {
              await yarnService.updateYarnStatus(widget.reservedDocId!, 'waiting for dispatch');
              if (!mounted) return;
              showAck(context, 'Yarn successfully moved to dispatch!');
          }
          
          await Future.delayed(const Duration(milliseconds: 500));
          if (mounted) {
               // Return success result to previous screen (Scanner) which will handle flow
               Navigator.pop(context, true);
          }
      } catch (e) {
          if (mounted) showAck(context, 'Error processing yarn: $e');
      } finally {
          if (mounted) setState(() => isProcessing = false);
      }
  }



  /// Navigate back to camera or rescan
  void _rescan() {
    if (widget.isAddMode || widget.reservedDocId != null) {
        // Return to ScanCodePage and signal a retry
        Navigator.pop(context, false); 
    } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ScanCodePage(
                expectedQr: widget.expectedQr,
                reservedDocId: widget.reservedDocId, 
                isAddMode: widget.isAddMode,
                isDispatchMode: widget.isDispatchMode,
            ),
          ),
        );
    }
  }

  /// Export yarn data as PDF
  Future<void> _exportAsPdf() async {
    if (yarnData == null) return;
    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Yarn Details',
                style: pw.TextStyle(
                  fontSize: 24,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 20),
              ...yarnData!.entries
                  .where((e) =>
              !['notFound', 'status', 'createdAt', 'rawQr', 'qrimage']
                  .contains(e.key.toLowerCase()))
                  .map(
                    (e) => pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      _capitalize(e.key),
                      style: pw.TextStyle(
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      e.value.toString(),
                      style: pw.TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              )
                  .toList(),
            ],
          );
        },
      ),
    );

    try {
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory('${dir.path}/YarnScanner');
      if (!await folder.exists()) await folder.create();

      final uniqueId = DateTime.now().millisecondsSinceEpoch.toString();
      final file = File('${folder.path}/yarn_$uniqueId.pdf');
      await file.writeAsBytes(await pdf.save());

      if (!mounted) return;
      showAck(context, 'PDF exported successfully!');
    } catch (_) {
      if (!mounted) return;
      showAck(context, 'Failed to export PDF');
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Colors.green.shade700;
    
    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          title: Text(widget.isAddMode ? 'Confirm Addition' : 'Yarn Details'),
          automaticallyImplyLeading: false,
          actions: [
            IconButton(
              onPressed: _exportAsPdf,
              icon: const Icon(Icons.picture_as_pdf, color: Colors.grey),
              tooltip: 'Export as PDF',
            ),
          ],
        ),
        body: isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.orange))
            : isInvalidQr 
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red, size: 80),
                        const SizedBox(height: 20),
                        const Text('Invalid QR Code', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.red)),
                        const SizedBox(height: 10),
                        Text('Expected: ${widget.expectedQr}', style: const TextStyle(fontSize: 16)),
                        const SizedBox(height: 40),
                        ElevatedButton.icon(
                          onPressed: _rescan,
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Try Again'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                          ),
                        ),
                      ],
                    ),
                  )
                : yarnData == null
                    ? const Center(child: Text('No Data Found'))
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 15,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                                border: Border.all(color: Colors.grey.shade100),
                              ),
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        decoration: BoxDecoration(
                                          color: Colors.green.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        padding: const EdgeInsets.all(16),
                                        child: Icon(
                                          Icons.inventory_2_outlined,
                                          color: primaryColor,
                                          size: 32,
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              yarnData!['id'] ?? yarnData!['yarnId'] ?? 'Unknown ID',
                                              style: const TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.black87,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: widget.isAddMode ? Colors.blue.withOpacity(0.15) : Colors.green.withOpacity(0.15),
                                                borderRadius: BorderRadius.circular(20),
                                              ),
                                              child: Text(
                                                widget.isAddMode ? 'NEW ENTRY' : 'RESERVED',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                  color: widget.isAddMode ? Colors.blue : Colors.green,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 24),
                                  if (widget.isAddMode) ...[
                                    if (isAllocating)
                                      const Padding(
                                        padding: EdgeInsets.only(bottom: 20),
                                        child: Row(
                                          children: [
                                            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                                            SizedBox(width: 10),
                                            Text("Finding best location...", style: TextStyle(color: Colors.blue, fontStyle: FontStyle.italic)),
                                          ],
                                        ),
                                      )
                                    else if (assignedRackId != null && assignedBinId != null)
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 20),
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: Colors.blue.shade50,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: Colors.blue.shade200),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text((int.tryParse(_countController.text) ?? 1) > 1 ? "Starting Location (Editable)" : "Assigned Location (Editable)", style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 12)),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: TextFormField(
                                                    controller: _rackController,
                                                    keyboardType: TextInputType.number,
                                                    decoration: const InputDecoration(
                                                      labelText: "Rack ID",
                                                      isDense: true,
                                                      border: OutlineInputBorder(),
                                                      prefixIcon: Icon(Icons.grid_view, size: 18),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: TextFormField(
                                                    controller: _binController,
                                                    keyboardType: TextInputType.number,
                                                    decoration: const InputDecoration(
                                                      labelText: "Bin ID",
                                                      isDense: true,
                                                      border: OutlineInputBorder(),
                                                      prefixIcon: Icon(Icons.shelves, size: 18),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      )
                                    else
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 20),
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: Colors.blue.shade50,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: Colors.blue.shade200),
                                        ),
                                        child: const Row(
                                          children: [
                                            Icon(Icons.info, color: Colors.blue, size: 20),
                                            SizedBox(width: 10),
                                            Expanded(child: Text("Defaulting to Rack 1, Bin 1", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold))),
                                          ],
                                        ),
                                      ),
                                  ],
                                  const Divider(height: 1),
                                  const SizedBox(height: 16),
                                  ...yarnData!.entries.where((e) => ![
                                    'notfound', 'status', 'createdat', 'rawqr', 'qrimage',
                                    'originalqrid', 'last_state_change', 'id', 'yarnid'
                                  ].contains(e.key.toLowerCase())).map(
                                    (e) => Padding(
                                      padding: const EdgeInsets.only(bottom: 12),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            _capitalize(e.key),
                                            style: TextStyle(fontWeight: FontWeight.w500, fontSize: 14, color: Colors.grey.shade600),
                                          ),
                                          Flexible(
                                            child: Text(
                                              e.value.toString(),
                                              textAlign: TextAlign.right,
                                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: Colors.black87),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ).toList(),
                                  if (widget.isAddMode) ...[
                                    const Divider(height: 30),
                                    const Text("Batch Inventory Details", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                    const SizedBox(height: 16),
                                    TextFormField(
                                      controller: _countController,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                        labelText: "Count",
                                        border: OutlineInputBorder(),
                                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      ),
                                      onChanged: (_) => _fetchAutoAllocation(),
                                    ),
                                    const SizedBox(height: 16),
                                    TextFormField(
                                      controller: _weightController,
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      decoration: const InputDecoration(
                                        labelText: "Weight per Roll (kg)",
                                        border: OutlineInputBorder(),
                                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      ),
                                      onChanged: (_) => _fetchAutoAllocation(),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 30),
                            if (isProcessing)
                              const Center(child: CircularProgressIndicator(color: Colors.orange))
                            else
                              Row(
                                children: [
                                  Expanded(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        gradient: const LinearGradient(
                                          colors: [Colors.redAccent, Colors.red],
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                        ),
                                        borderRadius: BorderRadius.circular(15),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.redAccent.withOpacity(0.6),
                                            blurRadius: 12,
                                            spreadRadius: 1,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(15),
                                          onTap: _rescan,
                                          child: const Padding(
                                            padding: EdgeInsets.symmetric(vertical: 14),
                                            child: Center(
                                              child: Text(
                                                'Rescan',
                                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  if (widget.isAddMode || widget.reservedDocId != null)
                                    Expanded(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: widget.reservedDocId != null 
                                              ? (widget.isDispatchMode ? [Colors.orangeAccent, Colors.deepOrange] : [Colors.blueAccent, Colors.blue])
                                              : [Colors.greenAccent, Colors.green],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          borderRadius: BorderRadius.circular(15),
                                          boxShadow: [
                                            BoxShadow(
                                              color: (widget.reservedDocId != null ? (widget.isDispatchMode ? Colors.orange : Colors.blue) : Colors.green).withOpacity(0.6),
                                              blurRadius: 12,
                                              spreadRadius: 1,
                                              offset: const Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(15),
                                            onTap: widget.reservedDocId != null ? _confirmMove : _confirmYarn,
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(vertical: 14),
                                              child: Center(
                                                child: Text(
                                                  widget.reservedDocId != null 
                                                    ? (widget.isDispatchMode ? 'Confirm Dispatch' : 'Confirm Move') 
                                                    : 'Confirm Add',
                                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
      ),
    );
  }
}
