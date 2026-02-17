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

  // ================= AUTO-ALLOCATION =================

  /// Gets the inventory rules from Firestore
  Future<Map<String, dynamic>> _getInventoryRules() async {
    try {
      final doc = await _db.collection('config').doc('inventory_rules').get();
      if (doc.exists) {
        final data = doc.data()!;
        final rules = {
          'max_rolls': (data['bin_capacity'] is int) ? data['bin_capacity'] : (int.tryParse(data['bin_capacity'].toString()) ?? 10),
          'max_weight': (data['max_bin_weight'] is num) ? data['max_bin_weight'].toDouble() : 500.0,
          'max_bins': (data['max_bins'] is int) ? data['max_bins'] : (int.tryParse(data['max_bins'].toString()) ?? 50),
        };
        print('DEBUG: Inventory Rules Loaded: $rules');
        return rules;
      }
    } catch (e) {
      print('DEBUG: Error reading config: $e');
    }
    return {'max_rolls': 10, 'max_weight': 500.0, 'max_bins': 50};
  }

  /// Finds the next available bin with sufficient capacity (Count & Weight).
  /// [minRackId] and [minBinId] restrict the search to monotonic increasing locations.
  /// [localOccupancy] is an optional map to track "theoretical" capacity during a batch.
  Future<Map<String, int>?> getNextAvailableBin({
      int count = 1, 
      double weightPerRoll = 25.0,
      int minRackId = 1,
      int minBinId = 1,
      Map<String, Map<String, dynamic>>? localOccupancy,
      Map<String, Map<String, Map<String, dynamic>>>? rackOccupancyCache
  }) async {
    final rules = await _getInventoryRules();
    final int maxRolls = rules['max_rolls'];
    final double maxBinWeight = rules['max_weight'];
    final int maxBinsPerRack = rules['max_bins'];
    
    final double requiredWeight = count * weightPerRoll;
    
    // We search through racks starting from minRackId
    // We search up to a reasonable limit or until we find space
    for (int rId = minRackId; rId <= (minRackId + 50); rId++) {
        
        // Use cache if available to avoid redundant DB hits in batch
        Map<String, Map<String, dynamic>> rackOccupancy;
        if (rackOccupancyCache != null && rackOccupancyCache.containsKey(rId.toString())) {
            rackOccupancy = rackOccupancyCache[rId.toString()]!;
        } else {
            rackOccupancy = await _getRackOccupancy(rId.toString());
            rackOccupancyCache?[rId.toString()] = rackOccupancy;
        }

        int vBinId = (rId == minRackId) ? minBinId : 1;

        // Search up to maxBinsPerRack per rack
        for (int bId = vBinId; bId <= maxBinsPerRack; bId++) {
            // Normalize binKey to match what's in occupancy map (B1, B2, etc.)
            final binKey = 'B$bId';
            
            // Get current DB usage. We check for 'B1' and '1' and 'Bin 1' variations
            int currentCount = 0;
            double currentWeight = 0.0;

            if (rackOccupancy.containsKey(binKey)) {
                currentCount = rackOccupancy[binKey]?['count'] ?? 0;
                currentWeight = (rackOccupancy[binKey]?['weight'] ?? 0.0).toDouble();
            } else if (rackOccupancy.containsKey(bId.toString())) {
                currentCount = rackOccupancy[bId.toString()]?['count'] ?? 0;
                currentWeight = (rackOccupancy[bId.toString()]?['weight'] ?? 0.0).toDouble();
            } else if (rackOccupancy.containsKey('Bin $bId')) {
                currentCount = rackOccupancy['Bin $bId']?['count'] ?? 0;
                currentWeight = (rackOccupancy['Bin $bId']?['weight'] ?? 0.0).toDouble();
            }

            // Apply local offsets (from current batch calculation)
            if (localOccupancy != null) {
                final localKey = '$rId-$bId';
                if (localOccupancy.containsKey(localKey)) {
                    currentCount += (localOccupancy[localKey]!['count'] as int);
                    currentWeight += (localOccupancy[localKey]!['weight'] as double);
                }
            }

            if ((currentCount + count <= maxRolls) && (currentWeight + requiredWeight <= maxBinWeight)) {
                print('DEBUG: Found space in Rack $rId, Bin $bId (Occupancy: $currentCount rolls)');
                return {'rackId': rId, 'binId': bId};
            }
        }
    }

    return null; // Return null if no space found after searching
  }

  /// Helper to get counts and weights for all bins in a rack in ONE query
  Future<Map<String, Map<String, dynamic>>> _getRackOccupancy(String rackId) async {
      final snap = await _db.collection('yarnRolls')
          .where('rack_id', isEqualTo: rackId)
          .where('state', whereIn: ['IN STOCK', 'RESERVED', 'MOVED', 'waiting for dispatch', 'reserved', 'moved', 'WAITING FOR DISPATCH']) 
          .get();
      
      final Map<String, Map<String, dynamic>> occupancy = {};
      
      for (var doc in snap.docs) {
          final data = doc.data();
          final bin = data['bin']?.toString() ?? 'Unknown';
          final weight = (data['weight'] is num) ? data['weight'].toDouble() : 0.0;
          
          if (!occupancy.containsKey(bin)) {
              occupancy[bin] = {'count': 0, 'weight': 0.0};
          }
          
          occupancy[bin]!['count'] = (occupancy[bin]!['count'] as int) + 1;
          occupancy[bin]!['weight'] = (occupancy[bin]!['weight'] as double) + weight;
      }
      return occupancy;
  }


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
        .where('state', whereIn: ['moved', 'MOVED', 'waiting for dispatch'])
        .snapshots();
  }

  Future<void> updateYarnStatus(String docId, String newStatus) {
    return _db.collection('reserved_collection').doc(docId).update({
      'state': newStatus,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateYarnRollStatus(String docId, String newStatus) {
    return _db.collection('yarnRolls').doc(docId).update({
      'state': newStatus,
      'last_state_change': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> deleteReservedYarnById(String docId) async {
    await _db.collection('reserved_collection').doc(docId).delete();
  }

  // ================= ADD YARN =================

  // ================= ADD YARN (BATCH SMART ALLOC) =================

  /// Adds yarn(s) to Firestore.
  /// Loops `count` times. For each roll, finds the next available bin sequentially.
  /// Uses a local occupancy map to prevent race conditions during batch processing.
  Future<String> addYarn(String qr, Map<String, dynamic> data, {int? binId, int? rackId, int count = 1, double? weightOverride}) async {
    final batch = _db.batch();
    final rules = await _getInventoryRules();
    
    // Local tracking to avoid race conditions during the loop
    final Map<String, Map<String, dynamic>> localOccupancy = {};
    // Performance optimization: cache rack data within THIS batch session
    final Map<String, Map<String, Map<String, dynamic>>> rackOccupancyCache = {};
    
    // Initial pointer for the WHOLE batch
    final int startRack = rackId ?? 1;
    final int startBin = binId ?? 1;

    // === NEW: MANUAL OVERRIDE SAFETY CHECK ===
    // If a specific bin was requested, ensure it has room for AT LEAST the first roll.
    // This prevents entering a 'full' bin manually.
    if (binId != null && rackId != null) {
        final rackOccupancy = await _getRackOccupancy(rackId.toString());
        final binKey = 'B$binId';
        final int currentCount = rackOccupancy[binKey]?['count'] ?? 0;
        final double currentWeight = (rackOccupancy[binKey]?['weight'] ?? 0.0).toDouble();
        final double w1 = weightOverride ?? (data['weight'] is num ? data['weight'].toDouble() : rules['default_weight']);

        if (currentCount >= rules['max_rolls']) {
            throw Exception("No space in Bin $binId (Capacity: ${rules['max_rolls']} rolls reached)");
        }
        if (currentWeight + w1 > rules['max_weight']) {
            throw Exception("No space in Bin $binId (Weight limit: ${rules['max_weight']}kg reached)");
        }
        if (binId > rules['max_bins'] && rackId == 1) { // Apply limit check
            throw Exception("Invalid Bin: Rack $rackId only supports up to ${rules['max_bins']} bins.");
        }
        // General limit check for any rack
        if (binId > rules['max_bins']) {
            throw Exception("Bin $binId exceeds the maximum allowed bins per rack (${rules['max_bins']})");
        }
    }

    // Prefetch starting IDs
    final nextIds = await _generateUniqueYarnIds(count);
    
    for (int i = 0; i < count; i++) {
        double? w = weightOverride;
        if (data['weight'] is num) w = data['weight'].toDouble(); 
        
        if (w == null) throw Exception("Weight is missing for roll ${i+1}. Every roll must have a weight.");

        // Find best bin for THIS roll, ALWAYS searching from the START of the sequence 
        // to catch any holes created by partial bins or manual edits.
        final allocation = await getNextAvailableBin(
            count: 1, 
            weightPerRoll: w,
            minRackId: startRack,
            minBinId: startBin,
            localOccupancy: localOccupancy,
            rackOccupancyCache: rackOccupancyCache
        );

        int currentRack;
        int currentBin;

        if (allocation != null) {
            currentRack = allocation['rackId']!;
            currentBin = allocation['binId']!;
        } else {
            // This should only happen if warehouse is completely full
            throw Exception("Warehouse Capacity Exhausted: No space found after Rack $startRack Bin $startBin");
        }

        // Update local occupancy for subsequent rolls in this loop
        final localKey = '$currentRack-$currentBin';
        if (!localOccupancy.containsKey(localKey)) {
            localOccupancy[localKey] = {'count': 0, 'weight': 0.0};
        }
        localOccupancy[localKey]!['count'] = (localOccupancy[localKey]!['count'] as int) + 1;
        localOccupancy[localKey]!['weight'] = (localOccupancy[localKey]!['weight'] as double) + w;

        // Prepare data
        final systemId = nextIds[i];
        final filteredData = Map<String, dynamic>.from(data);
        filteredData.removeWhere((k, v) => v.toString().toLowerCase() == 'unknown');
        filteredData.remove('binId'); filteredData.remove('Bin Id'); filteredData.remove('Bin');

        final now = DateTime.now().toUtc().toIso8601String();
        final fullData = {
          'lot_number': filteredData['lot_number'] ?? 'LOT-GEN-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}',
          'order_id': filteredData['order_id'] ?? 'ORD-NONE',
          'supplier_name': filteredData['supplier_name'] ?? 'ABC Textiles',
          'quality_grade': filteredData['quality_grade'] ?? 'A',
          'weight': w, 
          'production_date': filteredData['production_date'] ?? now,
          ...filteredData,
          'id': systemId,
          'originalQrId': data['id'] ?? data['yarnId'] ?? qr.trim(),
          'bin': 'B$currentBin',
          'state': 'IN STOCK',
          'createdAt': now,
          'last_state_change': now,
          'rack_id': currentRack.toString(),
          'rawQr': qr.trim(),
        };

        batch.set(_db.collection('yarnRolls').doc(systemId), fullData);
        print('DEBUG: Added Roll ${i+1}/$count to Batch (Rack $currentRack, Bin B$currentBin)');
    }

    await batch.commit();
    return nextIds.last;
  }

  Future<List<String>> _generateUniqueYarnIds(int count) async {
    final year = DateTime.now().year.toString();
    int lastNum = 0;

    try {
      final snapshot = await _db
          .collection('yarnRolls')
          .orderBy('id', descending: true)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        final lastId = snapshot.docs.first.get('id') as String;
        final parts = lastId.split('-');
        if (parts.length >= 3) {
            lastNum = int.tryParse(parts.last) ?? 0;
        } else if (parts.length == 2) {
            lastNum = int.tryParse(parts.last) ?? 0;
        }
      }
    } catch (e) {
      print('DEBUG ERROR in ID generation pre-fetch: $e');
    }

    return List.generate(count, (i) => 'YR-$year-${lastNum + i + 1}');
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
