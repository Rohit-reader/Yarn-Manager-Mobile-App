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
          'default_weight': (data['default_weight'] is num) ? data['default_weight'].toDouble() : 25.0,
          'max_rolls': (data['bin_capacity'] is int) ? data['bin_capacity'] : (int.tryParse(data['bin_capacity'].toString()) ?? 10),
          'max_weight': (data['max_bin_weight'] is num) ? data['max_bin_weight'].toDouble() : 100.0,
        };
        print('DEBUG: Inventory Rules Loaded: $rules');
        return rules;
      }
    } catch (e) {
      print('DEBUG: Error reading config: $e');
    }
    return {'default_weight': 25.0, 'max_rolls': 10, 'max_weight': 100.0};
  }

  /// Finds the next available bin with sufficient capacity (Count & Weight).
  /// [minRackId] and [minBinId] restrict the search to monotonic increasing locations.
  Future<Map<String, int>?> getNextAvailableBin({
      int count = 1, 
      double weightPerRoll = 25.0,
      int minRackId = 1,
      int minBinId = 1
  }) async {
    final rules = await _getInventoryRules();
    final int maxRolls = rules['max_rolls'];
    final double maxBinWeight = rules['max_weight'];
    
    final double requiredWeight = count * weightPerRoll;
    
    int maxRackId = 0;
    int maxBinId = 0;
    int lastSeenRackId = 1;

    // 1. Get all Racks (sorted)
    final racksSnaps = await _db.collection('racks').orderBy('id').get();
    
    // FAILSAFE: If no racks exist, default to Rack 1, Bin 1
    if (racksSnaps.docs.isEmpty) {
        return {'rackId': 1, 'binId': 1};
    }

    for (var rackDoc in racksSnaps.docs) {
      // Robust ID parsing
      final data = rackDoc.data();
      int? rackId;
      if (data.containsKey('id') && data['id'] is int) {
          rackId = data['id'];
      } else {
          rackId = int.tryParse(rackDoc.id);
      }
      
      if (rackId == null) continue;
      
      // Skip Racks below minRackId
      if (rackId < minRackId) continue;
      
      if (rackId > maxRackId) maxRackId = rackId;
      lastSeenRackId = rackId; 
      
      // ... rest of logic

      // 2. Get all Bins for this Rack
      // NOTE: Removed orderBy('id') here to avoid composite index error.
      // We sort in memory instead.
      final binsSnaps = await _db
          .collection('bins')
          .where('rackId', isEqualTo: rackId)
          .get();
      
      final sortedBins = binsSnaps.docs.toList();
      sortedBins.sort((a, b) {
            final idA = (a.data().containsKey('id') && a.data()['id'] is int) ? a.data()['id'] : (int.tryParse(a.id) ?? 9999);
            final idB = (b.data().containsKey('id') && b.data()['id'] is int) ? b.data()['id'] : (int.tryParse(b.id) ?? 9999);
            return idA.compareTo(idB);
      });
      
      // If Rack exists but has no defined bins in 'bins' collection, 
      // we must check "Virtual Bins" starting from 1 until we find space.
      if (sortedBins.isEmpty) {
           print('DEBUG: Rack $rackId has no bin docs. Checking virtual bins...');
           int vBinId = 1;
           while (true) {
                // Check occupancy for vBinId
                final yarnCheck = await _checkBinCapacity(rackId, vBinId, count, requiredWeight, maxRolls, maxBinWeight);
                if (yarnCheck) {
                     print('DEBUG: Found space in Virtual Bin $vBinId (Rack $rackId)');
                     return {'rackId': rackId, 'binId': vBinId};
                }
                
                print('DEBUG: Virtual Bin $vBinId is FULL. Checking next...');
                vBinId++;
                
                // Infinite loop guard (reasonable limit? 100?)
                if (vBinId > 50) break; 
           }
           // If we exceeded logical limit for this rack, move to next rack?
           // For now, let's just break to "Overflow" logic at end of function.
           maxBinId = vBinId; 
      } else {

      for (var binDoc in sortedBins) {
        final bData = binDoc.data();
        int? binId;
        if (bData.containsKey('id') && bData['id'] is int) {
            binId = bData['id'];
        } else {
            binId = int.tryParse(binDoc.id);
        }
        
        if (binId == null) continue;
        
        // Skip Bins below minBinId ONLY if we are in the minRack
        if (rackId == minRackId && binId < minBinId) continue;
        
        if (binId > maxBinId) maxBinId = binId;

        // 3. Check occupancy (Count & Weight)
        // Refactored helper check
        if (await _checkBinCapacity(rackId, binId, count, requiredWeight, maxRolls, maxBinWeight)) {
             print('DEBUG: Found space in Rack $rackId, Bin $binId');
             return {'rackId': rackId, 'binId': binId};
        } else {
             print('DEBUG: Bin $binId Full or Overweight. Checking next...');
        }
      }
      } // End else
    }
    
    // OVERFLOW: Create a new Bin ID in the last Rack
    final nextBinId = maxBinId + 1;
    print('DEBUG: All full. Overflowing to New Bin $nextBinId in Rack $lastSeenRackId');
    return {'rackId': lastSeenRackId, 'binId': nextBinId};
  }

  /// Helper to check if a specific bin has space
  Future<bool> _checkBinCapacity(int rackId, int binId, int count, double requiredWeight, int maxRolls, double maxBinWeight) async {
        final yarnQuery = await _db
            .collection('yarnRolls')
            .where('bin', isEqualTo: 'B$binId') 
            .get();
        
        final currentCount = yarnQuery.docs.length;
        double currentTotalWeight = 0.0;
        
        for (var doc in yarnQuery.docs) {
            final data = doc.data();
            final w = data['weight'];
            if (w is num) {
                currentTotalWeight += w.toDouble();
            } else if (w is String) {
                currentTotalWeight += double.tryParse(w) ?? 0.0;
            }
        }

        print('DEBUG: Bin $binId (Rack $rackId) -> Count: $currentCount/$maxRolls, Weight: $currentTotalWeight/$maxBinWeight');

        return (currentCount + count <= maxRolls) && (currentTotalWeight + requiredWeight <= maxBinWeight);
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

  // ================= ADD YARN (BATCH SMART ALLOC) =================

  /// Adds yarn(s) to Firestore.
  /// Loops `count` times. For each roll, finds the next available bin sequentially.
  Future<String> addYarn(String qr, Map<String, dynamic> data, {int? binId, int? rackId, int count = 1, double? weightOverride}) async {
    String lastId = '';
    
    // We maintain a "pointer" to the current best bin
    // initialized with the passed manual overrides or defaults.
    int currentRack = rackId ?? 1;
    int currentBin = binId ?? 1;
    
    for (int i = 0; i < count; i++) {
        try {
          print('DEBUG: Processing Roll $i/$count');
          
          // Dynamic lookup: Check if current pointer is valid or needs to move forward
          final rules = await _getInventoryRules();
          double w = weightOverride ?? rules['default_weight'];
          if (data['weight'] is num) w = data['weight'].toDouble(); 
          
          // Check capacity of CURRENT pointer specifically
          bool fitsInCurrent = await _checkBinCapacity(
              currentRack, currentBin, 1, w, 
              rules['max_rolls'], rules['max_weight']
          );
          
          if (!fitsInCurrent) {
               // Must find NEXT available bin, starting search strictly AFTER current
               // Actually, search inclusive from current? No, we know current failed.
               // Search from currentRack, currentBin + 1?
               // But minBinId logic in check is inclusive.
               // So let's ask for next available starting from current.
               // If it returns same bin, we're stuck? 
               // Wait, `getNextAvailableBin` checks capacity. So if current is full, it WONT return it.
               
               print('DEBUG: Bin $currentBin (Rack $currentRack) full/invalid. Searching forward...');
               final next = await getNextAvailableBin(
                   count: 1, 
                   weightPerRoll: w,
                   minRackId: currentRack,
                   minBinId: currentBin
               );
               
               if (next != null) {
                   currentRack = next['rackId']!;
                   currentBin = next['binId']!;
               } else {
                   // Overflow logic is inside getNext... so this implies major failure
                   // Fallback to purely incrementing bin ID if needed
                   currentBin++; 
               }
          }
          
          // At this point, currentRack/currentBin *should* be valid
          
          String systemId = await _generateUniqueYarnId();
          lastId = systemId; 
          
          // ... rest of save logic ...
          final filteredData = Map<String, dynamic>.from(data);
          filteredData.removeWhere(
                  (key, value) => value.toString().toLowerCase() == 'unknown');

          // cleanup
          filteredData.remove('binId'); filteredData.remove('Bin Id'); filteredData.remove('Bin');

          final now = DateTime.now().toUtc().toIso8601String();
          final weight = weightOverride ?? (filteredData['weight'] is num ? filteredData['weight'] : double.tryParse(filteredData['weight'].toString()) ?? 25.0);

          final fullData = {
            'lot_number': filteredData['lot_number'] ?? 'LOT-GEN-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}',
            'order_id': filteredData['order_id'] ?? 'ORD-NONE',
            'supplier_name': filteredData['supplier_name'] ?? 'ABC Textiles',
            'quality_grade': filteredData['quality_grade'] ?? 'A',
            'weight': weight, 
            'production_date': filteredData['production_date'] ?? now,
            ...filteredData,
            'id': systemId,
            'originalQrId': data['id'] ?? data['yarnId'] ?? qr.trim(),
            'bin': 'B$currentBin', // Enforce B prefix
            'state': 'IN STOCK',
            'createdAt': now,
            'last_state_change': now,
            'rack_id': currentRack.toString(),
          };
          
          fullData['rawQr'] = qr.trim();

          await _db.collection('yarnRolls').doc(systemId).set(fullData);
          print('DEBUG: Saved Roll $i to Rack $currentRack, Bin B$currentBin');
          
        } catch (e) {
          print('DEBUG ERROR in addYarn batch $i: $e');
          rethrow;
        }
    }
    return lastId;
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
