import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

class YarnService {
  final _db = FirebaseFirestore.instance;

  String _getSafeId(String qr) {
    if (qr.trim().isEmpty) throw ArgumentError('QR code cannot be empty');
    final bytes = utf8.encode(qr.trim());
    return sha256.convert(bytes).toString();
  }

  // ================= RACK & BIN OPS =================
  Future<bool> checkRackExists(int rackId) async {
    final doc = await _db.collection('racks').doc(rackId.toString()).get();
    return doc.exists;
  }

  Future<void> createRack(int rackId) async {
      await _db.collection('racks').doc(rackId.toString()).set({
          'id': rackId,
          'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
  }

  Future<void> linkBinToRack(int binId, int rackId) async {
      // Check if bin exists in another rack?
      final binDoc = await _db.collection('bins').doc(binId.toString()).get();
      if (binDoc.exists) {
          final existingRack = binDoc.get('rackId');
          if (existingRack != null && existingRack != rackId) {
             throw Exception('Bin $binId is already assigned to Rack $existingRack');
          }
      }
      
      await _db.collection('bins').doc(binId.toString()).set({
          'id': binId,
          'rackId': rackId,
          'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
  }
  
  // Future<int?> getBinRack(int binId) async {
  //     final doc = await _db.collection('bins').doc(binId.toString()).get();
  //     if (doc.exists) return doc.get('rackId') as int?;
  //     return null;
  // }

  // ================= YARN OPS =================

  Future<DocumentSnapshot> getYarn(String qr) {
    return _db.collection('yarnRolls').doc(_getSafeId(qr)).get();
  }

  Future<DocumentSnapshot?> findYarnByContent(String content) async {
    final raw = content.trim();
    if (raw.isEmpty) return null;

    try {
      final doc = await getYarn(raw);
      if (doc.exists) return doc;
    } catch (_) {}

    final qRaw = await _db
        .collection('yarnRolls')
        .where('rawQr', isEqualTo: raw)
        .limit(1)
        .get();
    if (qRaw.docs.isNotEmpty) return qRaw.docs.first;

    try {
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) {
        final possibleId = decoded['id'] ?? decoded['yarnId'] ?? decoded['ID'];
        if (possibleId != null) {
          final qJson = await _db
              .collection('yarnRolls')
              .where('id', isEqualTo: possibleId.toString())
              .limit(1)
              .get();
          if (qJson.docs.isNotEmpty) return qJson.docs.first;
        }
      }
    } catch (_) {}

    return null;
  }

  // ================= RESERVED COLLECTION =================

  Stream<QuerySnapshot> getReservedYarns() {
    return _db
        .collection('reserved_collection')
        .where('state', whereIn: ['reserved', 'RESERVED'])
        .snapshots();
  }

  Stream<QuerySnapshot> getMovedYarns() {
    return _db
        .collection('reserved_collection')
        .where('state', whereIn: ['moved', 'MOVED'])
        .snapshots();
  }

  Future<void> updateYarnStatus(String docId, String newStatus) {
    return _db.collection('reserved_collection').doc(docId).update({
      'state': newStatus,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> deleteReservedYarnById(String docId) async {
    await _db.collection('reserved_collection').doc(docId).delete();
  }

  // ================= ADD YARN =================

  Future<String> addYarn(String qr, Map<String, dynamic> data, {int? binId, int? rackId}) async {
    try {
      print('DEBUG: addYarn called for qr: $qr');
      String systemId = await _generateUniqueYarnId();
      print('DEBUG: Generated systemId: $systemId');

      final filteredData = Map<String, dynamic>.from(data);
      filteredData.removeWhere(
              (key, value) => value.toString().toLowerCase() == 'unknown');

      // Ensure bin info is stored consistently as "bin" (string)
      String? finalBin;
      if (binId != null) {
        finalBin = binId.toString();
      } else {
        // Check if data already has bin info in various formats
        finalBin = (filteredData['bin'] ?? filteredData['binId'] ?? filteredData['Bin'] ?? filteredData['Bin Id'])?.toString();
      }
      
      // Prefix bin with 'B' if it's just a number
      if (finalBin != null && RegExp(r'^\d+$').hasMatch(finalBin)) {
        finalBin = 'B$finalBin';
      }

      // Clean up redundant bin fields
      filteredData.remove('binId');
      filteredData.remove('Bin Id');
      filteredData.remove('Bin');

      // Ensure all requested fields are present or defaulted
      final now = DateTime.now().toUtc().toIso8601String();

      final fullData = {
        'lot_number': filteredData['lot_number'] ?? filteredData['Lot Number'] ?? 'LOT-GEN-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}',
        'order_id': filteredData['order_id'] ?? filteredData['Order Id'] ?? 'ORD-NONE',
        'supplier_name': filteredData['supplier_name'] ?? filteredData['Supplier Name'] ?? 'ABC Textiles',
        'quality_grade': filteredData['quality_grade'] ?? filteredData['Quality Grade'] ?? 'A',
        'weight': filteredData['weight'] ?? filteredData['Weight'] ?? 25,
        'production_date': filteredData['production_date'] ?? filteredData['Production Date'] ?? now,
        ...filteredData,
        'id': systemId,
        'originalQrId': data['id'] ?? data['yarnId'] ?? data['ID'] ?? qr.trim(),
        'bin': finalBin ?? 'B1',
        'state': 'IN STOCK', // Set state to "IN STOCK" as requested
        'createdAt': now,
        'last_state_change': now,
        'rack_id': (rackId ?? data['rack_id'] ?? data['rackId'] ?? '1').toString(),
      };
      
      fullData['rawQr'] = qr.trim();

      print('DEBUG: Saving to Firestore document: $systemId in collection: yarnRolls');
      print('DEBUG: Data payload: ${jsonEncode(fullData)}');
       await _db.collection('yarnRolls').doc(systemId).set(fullData);
       print('DEBUG: Firestore set SUCCESSFUL for $systemId');
       return systemId;
    } catch (e) {
      print('DEBUG ERROR in addYarn: $e');
      rethrow;
    }
  }

  Future<String> _generateUniqueYarnId() async {
    final year = DateTime.now().year.toString();
    try {
      final snapshot = await _db
          .collection('yarnRolls')
          .orderBy('id', descending: true)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        print('DEBUG: No existing yarns found, starting with 001');
        return 'YR-$year-001';
      }

      final lastId = snapshot.docs.first.get('id') as String;
      print('DEBUG: Last ID in DB: $lastId');
      final parts = lastId.split('-');
      int lastNum = 0;
      if (parts.length >= 3) {
          lastNum = int.tryParse(parts.last) ?? 0;
      } else if (parts.length == 2) {
          lastNum = int.tryParse(parts.last) ?? 0;
      }
      
      final nextNum = lastNum + 1;
      return 'YR-$year-$nextNum';
    } catch (e) {
      print('DEBUG ERROR in _generateUniqueYarnId: $e');
      return 'YR-$year-${DateTime.now().millisecondsSinceEpoch.toString().substring(10)}';
    }
  }

  /// ✅ UPDATED parseYarnData TO RETURN READABLE FIELDS
  Map<String, dynamic> parseYarnData(String qr) {
    final trimmed = qr.trim();
    try {
      final decoded = json.decode(trimmed);
      if (decoded is Map<String, dynamic>) {
        final Map<String, dynamic> humanReadable = {};
        decoded.forEach((key, value) {
          if (value != null && value.toString().toLowerCase() != 'unknown') {
            humanReadable[_snakeCaseKey(key)] = value;
          }
        });
        return humanReadable;
      }
    } catch (_) {}
    return {};
  }

  String _snakeCaseKey(String key) {
    return key
        .toLowerCase()
        .replaceAll(' ', '_')
        .replaceAll('-', '_')
        .replaceAll(RegExp(r'[^a-z0-9_]'), '');
  }

  Future<void> deleteYarn(String qr) {
    return _db.collection('yarnRolls').doc(_getSafeId(qr)).delete();
  }
}
