import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  final _db = FirebaseFirestore.instance;

  final TextEditingController _maxRollsController = TextEditingController();
  final TextEditingController _maxWeightController = TextEditingController();
  final TextEditingController _maxBinsController = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  int _initialMaxRolls = 0;
  int _initialMaxBins = 0;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    try {
      final doc = await _db.collection('config').doc('inventory_rules').get();
      if (doc.exists) {
        final data = doc.data()!;
        _maxRollsController.text = (data['bin_capacity'] ?? 10).toString(); // Mapped to existing field
        _maxWeightController.text = (data['max_bin_weight'] ?? 500.0).toString();
        _maxBinsController.text = (data['max_bins'] ?? 50).toString();
        
        _initialMaxRolls = data['bin_capacity'] ?? 10;
        _initialMaxBins = data['max_bins'] ?? 50;
      } else {
        // Defaults
        _maxRollsController.text = '10';
        _maxWeightController.text = '500.0';
        _maxBinsController.text = '50';
        
        _initialMaxRolls = 10;
        _initialMaxBins = 50;
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error loading settings: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => _isSaving = true);
    try {
      await _db.collection('config').doc('inventory_rules').set({
        'bin_capacity': int.tryParse(_maxRollsController.text) ?? 10,
        'max_bin_weight': double.tryParse(_maxWeightController.text) ?? 500.0,
        'max_bins': int.tryParse(_maxBinsController.text) ?? 50,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved successfully!'), backgroundColor: Colors.green),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving settings: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Inventory Settings')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Global Configuration',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                        'These rules apply to the auto-allocation logic when adding new yarn rolls.',
                        style: TextStyle(color: Colors.grey)),
                    const SizedBox(height: 20),
                    
                    const SizedBox(height: 24),
                    _buildSectionHeader('Bin Capacity Limits'),
                    const SizedBox(height: 10),
                    
                    TextFormField(
                      controller: _maxRollsController,
                      decoration: const InputDecoration(
                        labelText: 'Max Rolls per Bin (Count)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.numbers),
                      ),
                      keyboardType: TextInputType.number,
                      validator: (val) {
                          if (val == null || val.isEmpty) return 'Required';
                          final n = int.tryParse(val) ?? 0;
                          if (n < _initialMaxRolls) return 'Capacity cannot be reduced (Current: $_initialMaxRolls)';
                          return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _maxWeightController,
                      decoration: const InputDecoration(
                        labelText: 'Max Weight per Bin (kg)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.scale),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (val) => val == null || val.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _maxBinsController,
                      decoration: const InputDecoration(
                        labelText: 'Max Bins per Rack (Count)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.grid_goldenratio),
                        helperText: 'Limits how many bins the auto-allocator searches per rack.',
                      ),
                      keyboardType: TextInputType.number,
                      validator: (val) {
                          if (val == null || val.isEmpty) return 'Required';
                          final n = int.tryParse(val) ?? 0;
                          if (n < _initialMaxBins) return 'Bin count cannot be reduced (Current: $_initialMaxBins)';
                          return null;
                      },
                    ),

                    const SizedBox(height: 40),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        icon: _isSaving
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.save),
                        label: Text(_isSaving ? 'Saving...' : 'Save Settings'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                          foregroundColor: Colors.white,
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        onPressed: _isSaving ? null : _saveSettings,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          color: Colors.blueAccent,
          margin: const EdgeInsets.only(right: 8),
        ),
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
