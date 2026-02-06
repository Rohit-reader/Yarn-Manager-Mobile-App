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

  Future<void> addYarn(String qr, Map<String, dynamic> data, {int? binId}) async {
    String systemId = await _generateUniqueYarnId();

    final filteredData = Map<String, dynamic>.from(data);
    filteredData.removeWhere(
            (key, value) => value.toString().toLowerCase() == 'unknown');

    final fullData = {
      ...filteredData,
      'rawQr': qr.trim(),
      'id': systemId,
      'originalQrId': data['id'],
      'binId': binId, // Add binId relation
      'createdAt': FieldValue.serverTimestamp(),
    };
    
    // Also add to reserved_collection immediately? Or just yarnRolls?
    // Original code added to 'yarnRolls'.
    // NOTE: 'reserved_collection' seems to be a separate collection for the flow?
    // User Flow: "Each scan adds a yarn roll to the active bin"
    // Requirement: "All scanned data must be stored correctly... maintaining proper relationships"
    
     await _db.collection('yarnRolls').doc(systemId).set(fullData);
     
     // If we are in "Add Yarn" flow, it might imply adding to inventory implies 'active' state?
     // Or do we add to reserved?
     // Let's assume yarnRolls is the inventory.
  }

  Future<String> _generateUniqueYarnId() async {
    try {
      final snapshot = await _db
          .collection('yarnRolls')
          .orderBy('id', descending: true)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) return 'YR-00001';

      final lastId = snapshot.docs.first.get('id') as String;
      final num = int.parse(lastId.replaceAll('YR-', '')) + 1;
      return 'YR-${num.toString().padLeft(5, '0')}';
    } catch (_) {
      return 'YR-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
    }
  }

  /// ✅ UPDATED parseYarnData TO RETURN READABLE FIELDS
  Map<String, dynamic> parseYarnData(String qr) {
    final trimmed = qr.trim();
    try {
      final decoded = json.decode(trimmed);
      if (decoded is Map<String, dynamic>) {
        // Convert all keys to readable format
        final Map<String, dynamic> humanReadable = {};
        decoded.forEach((key, value) {
          if (value != null && value.toString().toLowerCase() != 'unknown') {
            humanReadable[_capitalizeKey(key)] = value;
          }
        });
        return humanReadable.isEmpty ? {'ID': trimmed} : humanReadable;
      }
    } catch (_) {
      // Not JSON? Treat as plain QR code
    }
    return {'ID': trimmed};
  }

  String _capitalizeKey(String key) {
    return key
        .replaceAll('_', ' ')
        .split(' ')
        .map((word) =>
    word.isNotEmpty ? '${word[0].toUpperCase()}${word.substring(1)}' : '')
        .join(' ');
  }

  Future<void> deleteYarn(String qr) {
    return _db.collection('yarnRolls').doc(_getSafeId(qr)).delete();
  }
}
