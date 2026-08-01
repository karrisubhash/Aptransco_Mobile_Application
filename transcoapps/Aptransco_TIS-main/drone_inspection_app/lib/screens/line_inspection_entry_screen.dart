import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/inspection_catalog.dart';
import '../models/li_asset.dart';
import '../services/line_inspection_api.dart';
import 'line_inspection_form_screen.dart';

/// Entry point for the new line-inspection flow: identify the inspector, find a
/// line, pick a Loc No, and open the adaptive inspection form. This is a slim
/// stand-in for the POC's login + map/selectors while that flow is being built.
class LineInspectionEntryScreen extends StatefulWidget {
  const LineInspectionEntryScreen({super.key});

  @override
  State<LineInspectionEntryScreen> createState() =>
      _LineInspectionEntryScreenState();
}

class _LineInspectionEntryScreenState extends State<LineInspectionEntryScreen> {
  static const _inspectorKey = 'li_inspector_id';

  InspectionCatalog? _catalog;
  String? _catalogError;

  final _inspectorCtl = TextEditingController();
  final _searchCtl = TextEditingController();

  List<LiLine> _lines = [];
  bool _searching = false;

  LiLine? _selectedLine;
  List<LiTower> _towers = [];
  bool _loadingTowers = false;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
    _restoreInspector();
  }

  @override
  void dispose() {
    _inspectorCtl.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    try {
      final cat = await LineInspectionApi.loadCatalog();
      if (mounted) setState(() => _catalog = cat);
    } catch (e) {
      if (mounted) setState(() => _catalogError = '$e');
    }
  }

  Future<void> _restoreInspector() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_inspectorKey);
    if (v != null && mounted) _inspectorCtl.text = v;
  }

  Future<void> _saveInspector(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_inspectorKey, v);
  }

  Future<void> _search() async {
    final q = _searchCtl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _selectedLine = null;
      _towers = [];
    });
    try {
      final lines = await LineInspectionApi.searchLines(q);
      if (mounted) setState(() => _lines = lines);
    } catch (e) {
      if (mounted) _toast('Search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _selectLine(LiLine line) async {
    setState(() {
      _selectedLine = line;
      _loadingTowers = true;
      _towers = [];
    });
    try {
      final towers = await LineInspectionApi.towersForLine(line.id);
      if (mounted) setState(() => _towers = towers);
    } catch (e) {
      if (mounted) _toast('Could not load towers: $e');
    } finally {
      if (mounted) setState(() => _loadingTowers = false);
    }
  }

  Future<void> _openForm(LiTower tower) async {
    final cat = _catalog;
    if (cat == null) {
      _toast('Catalog still loading…');
      return;
    }
    final inspector = _inspectorCtl.text.trim();
    await _saveInspector(inspector);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LineInspectionFormScreen(
        tower: tower,
        catalog: cat,
        inspectorEmployeeId: inspector.isEmpty ? 'unknown' : inspector,
      ),
    ));
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Line Inspection'),
      ),
      body: _catalogError != null
          ? _errorState()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_catalog == null) _catalogLoading(),
                TextField(
                  controller: _inspectorCtl,
                  decoration: const InputDecoration(
                    labelText: 'Inspector employee ID',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _searchCtl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    labelText: 'Search transmission line',
                    hintText: 'e.g. Maradam, 220KV Bobbili…',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : IconButton(
                            icon: const Icon(Icons.arrow_forward),
                            onPressed: _search,
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                if (_selectedLine == null) ..._lineResults(),
                if (_selectedLine != null) ..._towerPicker(),
              ],
            ),
    );
  }

  Widget _catalogLoading() => const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 10),
          Text('Loading questionnaire catalog…',
              style: TextStyle(fontSize: 12)),
        ]),
      );

  Widget _errorState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 40, color: Colors.grey),
              const SizedBox(height: 12),
              Text('Could not load the catalog.\n$_catalogError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  setState(() => _catalogError = null);
                  _loadCatalog();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );

  List<Widget> _lineResults() {
    if (_lines.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.only(top: 24),
          child: Text('Search for a line to begin.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey)),
        )
      ];
    }
    return _lines
        .map((l) => Card(
              child: ListTile(
                title: Text(l.name, style: const TextStyle(fontSize: 14)),
                subtitle: Text('${l.voltage} · ${l.subdivisionName}',
                    style: const TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _selectLine(l),
              ),
            ))
        .toList();
  }

  List<Widget> _towerPicker() {
    return [
      Card(
        color: const Color(0xFFEEF3FA),
        child: ListTile(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() {
              _selectedLine = null;
              _towers = [];
            }),
          ),
          title: Text(_selectedLine!.name,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          subtitle: Text('${_selectedLine!.voltage} · pick a Loc No',
              style: const TextStyle(fontSize: 12)),
        ),
      ),
      const SizedBox(height: 8),
      if (_loadingTowers)
        const Center(
            child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator()))
      else if (_towers.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('No towers found on this line.',
              style: TextStyle(color: Colors.grey)),
        )
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _towers
              .map((t) => ActionChip(
                    label: Text('${t.towerNumber}  ·  ${t.towerType}'),
                    onPressed: () => _openForm(t),
                  ))
              .toList(),
        ),
    ];
  }
}
