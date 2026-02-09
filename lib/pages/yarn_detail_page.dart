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
  final bool isAddMode;
  final int? binId;
  final int? rackId;

  const YarnDataPage({
    super.key,
    required this.qr,
    this.expectedQr,
    this.isAddMode = false,
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
          });
      } else {
          final doc = await yarnService.findYarnByContent(widget.qr);
          if (doc != null && doc.exists) {
            setState(() => yarnData = doc.data() as Map<String, dynamic>);
          } else {
            setState(() => yarnData = {'id': widget.qr, 'notFound': true});
          }
      }
    } catch (_) {
      setState(() => yarnData = {'id': widget.qr, 'error': 'Failed to fetch'});
    } finally {
      setState(() => isLoading = false);
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
      
      // Pass the explicit bin/rack IDs if available
      String systemId = await yarnService.addYarn(
          widget.qr, 
          yarnData!, 
          binId: widget.binId, 
          rackId: widget.rackId
      );

      if (!mounted) return;

      // Show acknowledgment
      showAck(context, 'Yarn confirmed successfully!');
      
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



  /// Navigate to QR scanner page
  void _rescan() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => const ScanCodePage(),
      ),
    );
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
    // Styling inspired by ReservedListPage
    final primaryColor = Colors.green.shade700;
    
    return SafeArea(child: Scaffold(
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
          : yarnData == null
          ? const Center(child: Text('No Data Found'))
          : SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ================== CARD STYLE (Like Reserved List) ==================
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
                border: Border.all(color: Colors.grey.shade100)
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
                                  color: Colors.black87
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
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
                    const Divider(height: 1),
                    const SizedBox(height: 16),
                    
                    // Detailed List inside Card
                    ...yarnData!.entries
                    .where((e) => ![
                  'notFound', 'status', 'createdAt', 'rawQr', 'qrimage',
                  'originalQrId', 'last_state_change', 'id', 'yarnId'
                ].contains(e.key.toLowerCase()))
                    .map(
                      (e) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _capitalize(e.key),
                              style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  fontSize: 14,
                                  color: Colors.grey.shade600),
                            ),
                            Flexible(
                              child: Text(
                                e.value.toString(),
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                    color: Colors.black87),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ).toList(),
                ],
              ),
            ),
            
            const SizedBox(height: 30),
            
            // ================== ACTION BUTTONS ==================
            if (isProcessing)
              const Center(
                  child:
                  CircularProgressIndicator(color: Colors.orange))
            else
              Row(
                children: [
                  // CANCEL / RESCAN Button
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
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),

                  // CONFIRM Button (Only in Add Mode or if action available)
                  if (widget.isAddMode)
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Colors.greenAccent, Colors.green],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(15),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.greenAccent.withOpacity(0.6),
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
                          onTap: _confirmYarn,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Center(
                              child: Text(
                                'Confirm Add',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16),
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
    ));
  }
}
