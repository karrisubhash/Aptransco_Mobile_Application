import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/inspection_catalog.dart';
import '../models/inspection_draft.dart';
import '../models/li_asset.dart';
import '../services/criticality_engine.dart';
import '../services/offline/offline_actions.dart';
import '../utils/uuid.dart';
import '../utils/li_style.dart';
import '../widgets/li_photo_thumbnail.dart';

/// The adaptive tower-inspection form — a Flutter port of the POC's `Inspect`
/// engine. Exception-based: every applicable item starts Normal; the inspector
/// marks only defects. The defect editor is adaptive — the chosen defect
/// decides which follow-up questions appear, and the criticality is suggested
/// from the answers (overridable) via the server's declarative rules.
///
/// Photos are captured in a later increment; this build records the full
/// questionnaire structure and saves it to the `clear` schema.
///
/// Styling draws entirely from `li_style.dart` + `buildLiTheme()` — the spacing
/// and radius scale, the criticality palette and the shared section header — so
/// the form reads as the same product as the Home, History and Tickets tabs.
/// Card shape, input borders, chips and buttons all come from the theme; this
/// file only sets what is specific to the questionnaire.
class LineInspectionFormScreen extends StatefulWidget {
  final LiTower tower;
  final InspectionCatalog catalog;
  final String inspectorEmployeeId;

  // GPS proof of presence, captured by the presence gate (see
  // launchInspection) before opening the form. presenceFlag is
  // 'in_range' | 'out_of_range' | 'no_fix'; an overrideReason is required
  // (and non-empty) unless in_range.
  final double? inspectorLat;
  final double? inspectorLng;
  final double? gpsAccuracyM;
  final String presenceFlag;
  final String overrideReason;

  const LineInspectionFormScreen({
    super.key,
    required this.tower,
    required this.catalog,
    required this.inspectorEmployeeId,
    this.inspectorLat,
    this.inspectorLng,
    this.gpsAccuracyM,
    this.presenceFlag = 'in_range',
    this.overrideReason = '',
  });

  @override
  State<LineInspectionFormScreen> createState() =>
      _LineInspectionFormScreenState();
}

class _LineInspectionFormScreenState extends State<LineInspectionFormScreen> {
  final Map<int, ItemDraft> _drafts = {};
  final Set<String> _openGroups = {};
  final String _clientId = generateUuidV4();
  final ImagePicker _picker = ImagePicker();
  String _remarks = '';
  bool _saving = false;

  // Collected during payload build: multipart file key -> file to upload.
  final Map<String, File> _photoUploads = {};
  int _photoCounter = 0;

  InspectionCatalog get _cat => widget.catalog;

  @override
  void initState() {
    super.initState();
    _buildDrafts();
  }

  void _buildDrafts() {
    for (final item in _cat.allItems) {
      final applies =
          CriticalityEngine.itemApplies(item, widget.tower.towerType);
      final String itemStatus = !applies
          ? 'na'
          : item.isAvailabilityGated
              ? 'not_provided'
              : 'normal';
      final main = SlotDraft(itemStatus);
      final positions = <String, SlotDraft>{};
      if (item.hasPositions) {
        for (final p in item.positions) {
          final slot = SlotDraft(
              item.isPositionAvailabilityGated ? 'not_provided' : 'normal');
          if (item.posMeta != null) {
            slot.meta[item.posMeta!.id] = item.posMeta!.defaultValue;
          }
          positions[p] = slot;
        }
      }
      _drafts[item.id] = ItemDraft(item, main, positions);
    }
  }

  // --------------------------- derived helpers ------------------------------
  Iterable<DefectEntryDraft> _allEntries() =>
      _drafts.values.expand((d) => d.allEntries);

  String _worstAll() =>
      CriticalityEngine.worstOf(_allEntries().map((e) => e.criticality));

  /// Whether the inspector has put anything into this form worth losing — used
  /// by the discard guard. A tower inspection is minutes of work at a structure
  /// they had to walk to, so a stray back-swipe must not silently drop it.
  bool get _hasWork {
    if (_remarks.trim().isNotEmpty) return true;
    for (final d in _drafts.values) {
      if (d.photo != null) return true;
      if (_slotHasWork(d.main)) return true;
      for (final p in d.positions.values) {
        if (_slotHasWork(p)) return true;
      }
    }
    return false;
  }

  bool _slotHasWork(SlotDraft s) =>
      s.entries.isNotEmpty || s.editing || s.status == 'defect';

  // ------------------------------ mutations ---------------------------------
  void _setSlotStatus(SlotDraft slot, ChecklistItem item, String status) {
    if (slot.status == status) return;
    setState(() {
      if (status != 'defect') {
        slot.entries.clear();
        slot.resetDraft();
        slot.status = status;
        // If a positional item is switched to not_provided/na at item level,
        // clear its positions too.
        if (status == 'not_provided' && item.hasPositions) {
          final d = _drafts[item.id]!;
          for (final p in d.positions.values) {
            p.status = item.isPositionAvailabilityGated ? 'not_provided' : 'normal';
            p.entries.clear();
            p.resetDraft();
          }
        }
      } else {
        slot.status = 'defect';
        if (slot.entries.isEmpty && !slot.editing) {
          slot.editing = true;
        }
      }
    });
  }

  void _startDraft(SlotDraft slot) => setState(() {
        slot.editing = true;
      });

  void _cancelDraft(SlotDraft slot) => setState(() {
        slot.resetDraft();
        if (slot.entries.isEmpty) slot.status = 'normal';
      });

  void _chooseDefect(SlotDraft slot, int defectId) => setState(() {
        if (slot.draftDefectId != defectId) {
          slot.draftDefectId = defectId;
          slot.draftAnswers.clear();
          slot.draftCriticality = null;
        }
      });

  void _setChoiceAnswer(SlotDraft slot, String fuKey, String value) =>
      setState(() {
        slot.draftAnswers[fuKey] = value;
        slot.draftCriticality = null; // re-suggest
      });

  void _toggleMultiAnswer(SlotDraft slot, String fuKey, String value) =>
      setState(() {
        final cur = (slot.draftAnswers[fuKey] as List?)?.cast<String>() ?? [];
        if (cur.contains(value)) {
          cur.remove(value);
        } else {
          cur.add(value);
        }
        slot.draftAnswers[fuKey] = cur;
        slot.draftCriticality = null;
      });

  // Number/text answers rebuild too, so the next follow-up reveals as soon as
  // this one is answered. The fields carry a stable ValueKey (defect+key), so
  // the rebuild preserves their text and cursor.
  void _setTextAnswer(SlotDraft slot, String fuKey, dynamic value) =>
      setState(() {
        slot.draftAnswers[fuKey] = value;
        slot.draftCriticality = null;
      });

  bool _isAnswered(dynamic v) {
    if (v == null) return false;
    if (v is String) return v.trim().isNotEmpty;
    if (v is List) return v.isNotEmpty;
    return true;
  }

  Future<File?> _pickPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Take photo'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null) return null;
    // A denied camera/photos permission throws rather than returning null. Tell
    // the inspector instead of leaving the button looking broken.
    try {
      final x = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      return x == null ? null : File(x.path);
    } catch (e) {
      if (mounted) _toast("Couldn't open the camera or gallery: $e");
      return null;
    }
  }

  void _chooseCrit(SlotDraft slot, String crit) =>
      setState(() => slot.draftCriticality = crit);

  void _commitEntry(SlotDraft slot, ChecklistItem item) {
    final defectId = slot.draftDefectId;
    if (defectId == null) {
      _toast('Choose the defect type first');
      return;
    }
    final defect = item.defectById(defectId);
    if (defect == null) return;
    // required follow-ups answered?
    final missing = defect.ask.where((k) {
      final v = slot.draftAnswers[k];
      if (v == null) return true;
      if (v is String) return v.trim().isEmpty;
      if (v is List) return v.isEmpty;
      return false;
    }).toList();
    if (missing.isNotEmpty) {
      _toast('Answer the remaining questions');
      return;
    }
    final suggested = CriticalityEngine.suggestedCriticality(
        defect, slot.draftAnswers, _cat.criticalityRules);
    setState(() {
      slot.entries.add(DefectEntryDraft(
        defectId: defect.id,
        defectKey: defect.key,
        answers: Map<String, dynamic>.from(slot.draftAnswers),
        criticality: slot.draftCriticality ?? suggested,
        suggestedCriticality: suggested,
        note: slot.draftNote.trim(),
        photo: slot.draftPhoto,
      ));
      slot.resetDraft();
    });
  }

  void _removeEntry(SlotDraft slot, int index) =>
      setState(() => slot.entries.removeAt(index));

  // ------------------------------- save -------------------------------------
  Future<void> _save() async {
    // The button is only disabled from the *next* build, so two taps inside one
    // frame both reach here. Both would queue the same inspection (same
    // `_clientId`, so the server de-duplicates) but they also share the staged
    // photo paths: the first op to sync deletes those files, and the second then
    // fails `MultipartFile.fromPath` on every attempt until it is parked as
    // "didn't sync" — a permanent error banner over an inspection that actually
    // saved fine. Cheapest possible guard, checked before any state is touched.
    if (_saving) return;
    // Slots switched to Defect but with nothing recorded.
    final incomplete = <String>[];
    for (final d in _drafts.values) {
      if (d.isPositional) {
        for (final entry in d.positions.entries) {
          if (entry.value.status == 'defect' && entry.value.entries.isEmpty) {
            incomplete.add('${d.item.label} (${entry.key})');
          }
        }
      } else if (d.main.status == 'defect' && d.main.entries.isEmpty) {
        incomplete.add(d.item.label);
      }
    }
    if (incomplete.isNotEmpty) {
      for (final d in _drafts.values) {
        if (d.allEntries.isEmpty &&
            (d.main.status == 'defect' ||
                d.positions.values.any((p) => p.status == 'defect'))) {
          _openGroups.add(d.item.groupKey);
        }
      }
      setState(() {});
      _toast('Add defect details for: ${incomplete.join(', ')} — or mark Normal');
      return;
    }

    setState(() => _saving = true);
    try {
      final items = _buildPayloadItems(); // also fills _photoUploads
      final result = await OfflineActions.saveInspection(
        tower: widget.tower,
        inspectorEmployeeId: widget.inspectorEmployeeId,
        catalogVersion: _cat.version,
        date: _todayIso(),
        remarks: _remarks,
        clientId: _clientId,
        items: items,
        photos: _photoUploads,
        catalog: _cat,
        worst: _worstAll(),
        defectCount: _allEntries().length,
        inspectorLat: widget.inspectorLat,
        inspectorLng: widget.inspectorLng,
        gpsAccuracyM: widget.gpsAccuracyM,
        presenceFlag: widget.presenceFlag,
        overrideReason: widget.overrideReason,
      );
      if (!mounted) return;
      final n = result.ticketsRaised;
      final tower = widget.tower.towerNumber;
      final msg = result.synced
          ? 'Inspection saved — Tower $tower.'
              '${n > 0 ? ' $n defect ticket${n > 1 ? 's' : ''} raised.' : ''}'
          : 'Saved offline — Tower $tower. It will upload automatically when '
              'you\'re back online.${n > 0 ? ' ($n defect${n > 1 ? 's' : ''})' : ''}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Save failed: $e');
    }
  }

  List<Map<String, dynamic>> _buildPayloadItems() {
    _photoUploads.clear();
    _photoCounter = 0;
    final out = <Map<String, dynamic>>[];
    for (final d in _drafts.values) {
      final item = d.item;
      if (item.hasPositions) {
        if (d.main.status == 'na' || d.main.status == 'not_provided') {
          out.add({
            'item_id': item.id,
            'position': '',
            'status': d.main.status,
            'meta': {},
            'entries': [],
            'photo_key': _regPhoto(d.photo),
          });
        } else {
          for (var i = 0; i < item.positions.length; i++) {
            final pos = item.positions[i];
            final slot = d.positions[pos]!;
            out.add({
              'item_id': item.id,
              'position': pos,
              'status': slot.status,
              'meta': slot.meta,
              'entries': _entriesJson(slot),
              // The item-level photo rides on the first position's row.
              'photo_key': i == 0 ? _regPhoto(d.photo) : null,
            });
          }
        }
      } else {
        out.add({
          'item_id': item.id,
          'position': '',
          'status': d.main.status,
          'meta': d.main.meta,
          'entries': _entriesJson(d.main),
          'photo_key': _regPhoto(d.photo),
        });
      }
    }
    return out;
  }

  List<Map<String, dynamic>> _entriesJson(SlotDraft slot) => slot.entries
      .map((e) => {
            'defect_id': e.defectId,
            'answers': e.answers,
            'criticality': e.criticality,
            'suggested_criticality': e.suggestedCriticality,
            'note': e.note,
            'photo_key': _regPhoto(e.photo),
          })
      .toList();

  /// Registers a photo for upload and returns the multipart key referencing
  /// it, or null when there's no photo.
  String? _regPhoto(File? f) {
    if (f == null) return null;
    final key = 'photo_${_photoCounter++}';
    _photoUploads[key] = f;
    return key;
  }

  String _todayIso() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this inspection?'),
        content: const Text(
            'Nothing you have recorded for this tower has been saved yet. '
            'Leaving now discards it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep inspecting'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: kCritColor['critical']),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  // ------------------------------- build ------------------------------------
  @override
  Widget build(BuildContext context) {
    final t = widget.tower;
    final worst = _worstAll();
    final defectCount = _allEntries().length;
    // canPop is deliberately always false so the decision is made here, against
    // live state. Reading `_hasWork` into canPop would miss anything typed
    // without a rebuild — the remarks field and the defect note both assign
    // straight to state on change (the TextFormField holds its own text), so a
    // remarks-only edit would slip past the guard entirely.
    // An explicit Navigator.pop (a successful save, or Discard below) is not
    // routed through PopScope, so both still leave normally.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (!_hasWork) {
          Navigator.of(context).pop();
          return;
        }
        _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Inspect Tower ${t.towerNumber}'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(20),
            child: Padding(
              padding: const EdgeInsets.only(
                  bottom: kSpaceXs + 2, left: kSpaceLg, right: kSpaceLg),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(t.lineName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: kInkSoft)),
              ),
            ),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(
              kSpaceMd, kSpaceMd, kSpaceMd, kSpaceXl),
          children: [
            _metaCard(t),
            for (final g in _cat.groups) _groupCard(g),
            _remarksCard(),
          ],
        ),
        bottomNavigationBar: _footer(worst, defectCount),
      ),
    );
  }

  /// The register header. The numbered rows deliberately mirror the paper
  /// register's numbered header fields, so an inspector reads the same three
  /// facts in the same order they always have.
  Widget _metaCard(LiTower t) => Card(
        margin: const EdgeInsets.only(bottom: kSpaceMd),
        child: Padding(
          padding: const EdgeInsets.all(kSpaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _metaRow('1', 'Date of inspection', _todayIso()),
              _metaRow('2', 'Loc No', t.towerNumber),
              _metaRow('3', 'Type of tower', t.towerType),
              const SizedBox(height: kSpaceMd),
              _hintBox(
                'Open a group to inspect it. Items default to Normal — mark only '
                'what is defective. Top / Middle / Bottom are entered separately '
                'where shown. Fittings that may not exist default to Not available.',
              ),
            ],
          ),
        ),
      );

  /// A tinted advisory block — same accent-wash language as `liEmptyState`, so
  /// guidance reads as guidance rather than as body copy.
  Widget _hintBox(String text) => Container(
        padding: const EdgeInsets.all(kSpaceMd),
        decoration: BoxDecoration(
          color: kBrandAccent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 16, color: kBrandAccent),
            const SizedBox(width: kSpaceSm),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 12, color: kInkSoft, height: 1.4)),
            ),
          ],
        ),
      );

  Widget _metaRow(String sno, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
                width: 20,
                child: Text(sno,
                    style:
                        const TextStyle(fontSize: 11, color: kInkFaint))),
            Text('$label  ',
                style: const TextStyle(fontSize: 13, color: kInkSoft)),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: kInk)),
            ),
          ],
        ),
      );

  Widget _groupCard(ChecklistGroup g) {
    final open = _openGroups.contains(g.key);
    final entries =
        g.items.expand((i) => _drafts[i.id]!.allEntries).toList();
    final worst = CriticalityEngine.worstOf(entries.map((e) => e.criticality));
    return Card(
      margin: const EdgeInsets.only(bottom: kSpaceMd),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              open ? _openGroups.remove(g.key) : _openGroups.add(g.key);
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: kSpaceMd, vertical: kSpaceMd),
              // The shared section header the tabs use, so a group in the form
              // reads like a section anywhere else in the app.
              child: liSectionHeader(
                open ? Icons.expand_more : Icons.chevron_right,
                g.label,
                count: g.items.length,
                trailing: entries.isEmpty
                    ? Icon(Icons.check_circle,
                        size: 18, color: kCritColor['ok'])
                    : critChip(worst,
                        text:
                            '${entries.length} defect${entries.length > 1 ? 's' : ''}'),
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  kSpaceSm, 0, kSpaceSm, kSpaceSm),
              child: Column(
                children: [for (final item in g.items) _itemRow(item)],
              ),
            ),
        ],
      ),
    );
  }

  Widget _itemRow(ChecklistItem item) {
    final d = _drafts[item.id]!;
    final isNA = d.main.status == 'na';
    final isNP = d.main.status == 'not_provided';
    final hasDefects = d.allEntries.isNotEmpty;
    final accent = kCritColor['major']!;

    return Container(
      margin: const EdgeInsets.only(bottom: kSpaceSm),
      padding: const EdgeInsets.all(kSpaceMd),
      decoration: BoxDecoration(
        color: hasDefects ? accent.withValues(alpha: 0.06) : kCardBg,
        border: Border.all(color: hasDefects ? accent : kOutline),
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 24,
                  child: Text('${item.sno}',
                      style:
                          const TextStyle(fontSize: 11, color: kInkFaint))),
              Expanded(
                child: Text(item.label,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: kInk,
                        height: 1.3)),
              ),
            ],
          ),
          const SizedBox(height: kSpaceSm),
          _itemControl(item, d, isNA, isNP),
          if (!isNA)
            _photoControl(
              photo: d.photo,
              onPick: () async {
                final f = await _pickPhoto();
                // The camera runs in another activity, which Android may kill
                // this one behind — so re-check before touching state.
                if (f != null && mounted) setState(() => d.photo = f);
              },
              onClear: () => setState(() => d.photo = null),
            ),
          if (!item.hasPositions && d.main.status == 'defect')
            _defectEditor(item, d.main),
          if (item.hasPositions && !isNA && !isNP)
            ...item.positions.map((p) => _posRow(item, d, p)),
        ],
      ),
    );
  }

  Widget _itemControl(
      ChecklistItem item, ItemDraft d, bool isNA, bool isNP) {
    if (isNA) {
      return Text(
          'N/A — ${item.naReason.isNotEmpty ? item.naReason : 'not applicable'}',
          style: const TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: kInkSoft));
    }
    if (item.hasPositions && item.isAvailabilityGated) {
      return _seg([
        _SegOpt('Not available', d.main.status == 'not_provided',
            () => _setSlotStatus(d.main, item, 'not_provided'),
            tone: _SegTone.np),
        _SegOpt('Available', d.main.status != 'not_provided',
            () => _setSlotStatus(d.main, item, 'normal'),
            tone: _SegTone.ok),
      ]);
    }
    if (item.isAvailabilityGated) {
      return _seg([
        _SegOpt('Not available', isNP,
            () => _setSlotStatus(d.main, item, 'not_provided'),
            tone: _SegTone.np),
        _SegOpt('Normal', d.main.status == 'normal',
            () => _setSlotStatus(d.main, item, 'normal'),
            tone: _SegTone.ok),
        _SegOpt('Defect${d.main.entries.isNotEmpty ? ' (${d.main.entries.length})' : ''}',
            d.main.status == 'defect',
            () => _setSlotStatus(d.main, item, 'defect'),
            tone: _SegTone.bad),
      ]);
    }
    if (!item.hasPositions) {
      return _seg([
        _SegOpt('Normal', d.main.status != 'defect',
            () => _setSlotStatus(d.main, item, 'normal'),
            tone: _SegTone.ok),
        _SegOpt('Defect${d.main.entries.isNotEmpty ? ' (${d.main.entries.length})' : ''}',
            d.main.status == 'defect',
            () => _setSlotStatus(d.main, item, 'defect'),
            tone: _SegTone.bad),
      ]);
    }
    return const SizedBox.shrink(); // positional non-gated: positions carry it
  }

  Widget _posRow(ChecklistItem item, ItemDraft d, String pos) {
    final slot = d.positions[pos]!;
    final isNP = slot.status == 'not_provided';
    return Container(
      margin: const EdgeInsets.only(top: kSpaceSm),
      padding: const EdgeInsets.only(top: kSpaceSm),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: kOutline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 66,
                child: Text(pos,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isNP ? kInkFaint : kInkSoft)),
              ),
              if (item.posMeta != null) ...[
                Flexible(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    isDense: true,
                    value: slot.meta[item.posMeta!.id],
                    underline: const SizedBox.shrink(),
                    style: const TextStyle(fontSize: 12, color: kInk),
                    items: item.posMeta!.options
                        .map((o) =>
                            DropdownMenuItem(value: o, child: Text(o)))
                        .toList(),
                    onChanged: (v) => setState(
                        () => slot.meta[item.posMeta!.id] = v ?? ''),
                  ),
                ),
                const SizedBox(width: kSpaceSm),
              ] else
                const Spacer(),
            ],
          ),
          const SizedBox(height: kSpaceXs),
          _seg([
            if (item.isPositionAvailabilityGated)
              _SegOpt('Not available', isNP,
                  () => _setSlotStatus(slot, item, 'not_provided'),
                  tone: _SegTone.np),
            _SegOpt('Normal', slot.status == 'normal',
                () => _setSlotStatus(slot, item, 'normal'),
                tone: _SegTone.ok),
            _SegOpt(
                'Defect${slot.entries.isNotEmpty ? ' (${slot.entries.length})' : ''}',
                slot.status == 'defect',
                () => _setSlotStatus(slot, item, 'defect'),
                tone: _SegTone.bad),
          ]),
          if (slot.status == 'defect') _defectEditor(item, slot),
        ],
      ),
    );
  }

  // -------------------------- adaptive defect editor ------------------------
  Widget _defectEditor(ChecklistItem item, SlotDraft slot) {
    final children = <Widget>[];

    // committed entries
    for (var i = 0; i < slot.entries.length; i++) {
      final e = slot.entries[i];
      final def = item.defectById(e.defectId);
      children.add(Container(
        margin: const EdgeInsets.only(top: kSpaceSm),
        padding: const EdgeInsets.symmetric(
            horizontal: kSpaceSm, vertical: kSpaceSm),
        decoration: BoxDecoration(
          color: kSurface,
          border: Border.all(color: kOutline),
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                critChip(e.criticality),
                const SizedBox(width: kSpaceSm),
                Expanded(
                  child: Text(
                    '${def?.label ?? e.defectKey}${_entrySummary(e)}',
                    style: const TextStyle(fontSize: 12, color: kInk),
                  ),
                ),
                IconButton(
                  onPressed: () => _removeEntry(slot, i),
                  icon: const Icon(Icons.close, size: 16),
                  color: kInkFaint,
                  tooltip: 'Remove this defect',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                      minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
            if (e.photo != null)
              Padding(
                padding: const EdgeInsets.only(top: kSpaceSm),
                child: LiPhotoThumbnail.file(e.photo!,
                    size: 84, borderRadius: kRadiusSm),
              ),
          ],
        ),
      ));
    }

    if (!slot.editing) {
      children.add(Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => _startDraft(slot),
          icon: const Icon(Icons.add, size: 16),
          label: Text('Add ${slot.entries.isNotEmpty ? 'another ' : ''}defect'),
          style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: kSpaceSm)),
        ),
      ));
      return Padding(
          padding: const EdgeInsets.only(top: kSpaceSm),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: children));
    }

    // ---- editor: choose defect ----
    children.add(_editorLabel('What is the problem?'));
    children.add(Wrap(
      spacing: kSpaceXs + 2,
      runSpacing: kSpaceXs + 2,
      children: item.defects
          .map((def) => ChoiceChip(
                label: Text(def.label),
                selected: slot.draftDefectId == def.id,
                onSelected: (_) => _chooseDefect(slot, def.id),
              ))
          .toList(),
    ));

    final defectId = slot.draftDefectId;
    if (defectId != null) {
      final def = item.defectById(defectId)!;
      // Follow-ups revealed one at a time: render each, then stop after the
      // first one still unanswered (mirrors the POC's progressive disclosure).
      var pending = false;
      for (final fuKey in def.ask) {
        final fu = _cat.followUps[fuKey];
        if (fu == null) continue;
        children.add(_followUp(slot, fu));
        if (!_isAnswered(slot.draftAnswers[fuKey])) {
          pending = true;
          break;
        }
      }

      if (!pending) {
        // criticality
        final suggested = CriticalityEngine.suggestedCriticality(
            def, slot.draftAnswers, _cat.criticalityRules);
        final selected = slot.draftCriticality ?? suggested;
        children.add(_editorLabel(
            'Criticality  (suggested: ${critLabel(suggested)})'));
        children.add(Wrap(
          spacing: kSpaceXs + 2,
          runSpacing: kSpaceXs + 2,
          children: ['minor', 'major', 'critical']
              .map((c) => ChoiceChip(
                    label: Text(critLabel(c)),
                    selected: selected == c,
                    selectedColor: critColor(c).withValues(alpha: 0.25),
                    onSelected: (_) => _chooseCrit(slot, c),
                  ))
              .toList(),
        ));
        // defect photo
        children.add(_photoControl(
          photo: slot.draftPhoto,
          onPick: () async {
            final f = await _pickPhoto();
            if (f != null && mounted) setState(() => slot.draftPhoto = f);
          },
          onClear: () => setState(() => slot.draftPhoto = null),
          label: 'Add evidence photo (optional)',
        ));
        // note
        children.add(Padding(
          padding: const EdgeInsets.only(top: kSpaceSm),
          child: TextFormField(
            key: ValueKey('${identityHashCode(slot)}_${defectId}_note'),
            initialValue: slot.draftNote,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
            ),
            onChanged: (v) => slot.draftNote = v,
          ),
        ));
        children.add(Padding(
          padding: const EdgeInsets.only(top: kSpaceMd),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: () => _commitEntry(slot, item),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save defect'),
              ),
              const SizedBox(width: kSpaceSm),
              TextButton(
                  onPressed: () => _cancelDraft(slot),
                  child: const Text('Cancel')),
            ],
          ),
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: kSpaceSm),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  /// One question label inside the defect editor.
  Widget _editorLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: kSpaceMd, bottom: kSpaceXs + 2),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: kInk)),
      );

  Widget _followUp(SlotDraft slot, FollowUpQuestion fu) {
    final children = <Widget>[_editorLabel(fu.questionText)];
    if (fu.isChoice) {
      children.add(Wrap(
        spacing: kSpaceXs + 2,
        runSpacing: kSpaceXs + 2,
        children: fu.options
            .map((o) => ChoiceChip(
                  label: Text(o),
                  selected: slot.draftAnswers[fu.key] == o,
                  onSelected: (_) => _setChoiceAnswer(slot, fu.key, o),
                ))
            .toList(),
      ));
    } else if (fu.isMultiChoice) {
      final sel =
          (slot.draftAnswers[fu.key] as List?)?.cast<String>() ?? const [];
      children.add(Wrap(
        spacing: kSpaceXs + 2,
        runSpacing: kSpaceXs + 2,
        children: fu.options
            .map((o) => FilterChip(
                  label: Text(o),
                  selected: sel.contains(o),
                  onSelected: (_) => _toggleMultiAnswer(slot, fu.key, o),
                ))
            .toList(),
      ));
    } else if (fu.isNumber) {
      children.add(Row(
        children: [
          SizedBox(
            width: 140,
            child: TextFormField(
              // Key by follow-up so switching to a different defect (which
              // clears draftAnswers) also rebuilds this field from scratch —
              // otherwise Flutter reuses the field's State and leaves the
              // previous defect's typed value visible while state is empty.
              key: ValueKey('fu_num_${fu.key}'),
              initialValue: slot.draftAnswers[fu.key]?.toString() ?? '',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 13),
              onChanged: (v) => _setTextAnswer(
                  slot, fu.key, v.isEmpty ? '' : num.tryParse(v) ?? v),
            ),
          ),
          if (fu.unit.isNotEmpty) ...[
            const SizedBox(width: kSpaceSm),
            Text(fu.unit,
                style: const TextStyle(fontSize: 12, color: kInkSoft)),
          ],
        ],
      ));
    } else {
      children.add(TextFormField(
        key: ValueKey('fu_txt_${fu.key}'),
        initialValue: slot.draftAnswers[fu.key]?.toString() ?? '',
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(hintText: fu.placeholder),
        onChanged: (v) => _setTextAnswer(slot, fu.key, v),
      ));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  /// `answersText` from li_style, plus each answer's unit — the form is the one
  /// place a bare "3" needs to read as "3 discs".
  String _entrySummary(DefectEntryDraft e) {
    if (e.answers.isEmpty) return '';
    final parts = <String>[];
    e.answers.forEach((k, v) {
      final fu = _cat.followUps[k];
      final val = v is List ? v.join(', ') : v.toString();
      parts.add(fu != null && fu.unit.isNotEmpty ? '$val ${fu.unit}' : val);
    });
    return ' — ${parts.join(' · ')}';
  }

  /// A photo capture control: a thumbnail + remove button when a photo is set,
  /// otherwise a button that opens the camera/gallery chooser. Used for both
  /// item-level photos and per-defect evidence photos.
  Widget _photoControl({
    required File? photo,
    required VoidCallback onPick,
    required VoidCallback onClear,
    String label = 'Add photo (optional)',
  }) {
    if (photo != null) {
      return Padding(
        padding: const EdgeInsets.only(top: kSpaceSm),
        child: Row(
          children: [
            LiPhotoThumbnail.file(photo, size: 84, borderRadius: kRadiusSm),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Remove photo',
              onPressed: onClear,
            ),
          ],
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: kSpaceSm),
        child: OutlinedButton.icon(
          onPressed: onPick,
          icon: const Icon(Icons.photo_camera_outlined, size: 16),
          label: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
  }

  Widget _remarksCard() => Card(
        margin: const EdgeInsets.only(bottom: kSpaceMd),
        child: Padding(
          padding: const EdgeInsets.all(kSpaceMd),
          child: TextFormField(
            initialValue: _remarks,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Remarks (optional)',
            ),
            onChanged: (v) => _remarks = v,
          ),
        ),
      );

  /// The running tally plus the primary action.
  ///
  /// The tally sits on its own line above a full-width Save button rather than
  /// beside it: side by side, the button's intrinsic width squeezed the status
  /// pill to a few dozen pixels on a small phone, and a full-width primary
  /// action is a far easier target for a gloved hand at the base of a tower.
  Widget _footer(String worst, int defectCount) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(kSpaceMd),
        decoration: const BoxDecoration(
          color: kCardBg,
          border: Border(top: BorderSide(color: kOutline)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (defectCount == 0)
                  critChip('ok', text: 'All normal')
                else ...[
                  critChip(worst, text: 'worst: ${critLabel(worst)}'),
                  const SizedBox(width: kSpaceSm),
                  Flexible(
                    child: Text(
                      '$defectCount defect${defectCount > 1 ? 's' : ''} recorded',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: kInkSoft),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: kSpaceSm),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_outlined),
              label: Text(_saving ? 'Saving…' : 'Save inspection'),
            ),
          ],
        ),
      ),
    );
  }

  /// The status control: one joined pill of equal-width segments.
  ///
  /// The segments divide the available width and ellipsize rather than sitting
  /// at their intrinsic size — a three-option control ("Not available / Normal /
  /// Defect (12)") used to overflow a narrow screen, because the enclosing Wrap
  /// had a single un-splittable Row as its only child. Equal widths also give
  /// every option the same, larger tap target, which matters for gloved hands.
  Widget _seg(List<_SegOpt> opts) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: kOutline),
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          for (var i = 0; i < opts.length; i++) ...[
            if (i > 0) Container(width: 1, height: 34, color: kOutline),
            Expanded(child: _segButton(opts[i])),
          ],
        ],
      ),
    );
  }

  Widget _segButton(_SegOpt o) {
    Color bg = Colors.transparent;
    Color fg = kInkSoft;
    if (o.selected) {
      switch (o.tone) {
        case _SegTone.ok:
          bg = kCritColor['ok']!.withValues(alpha: 0.14);
          fg = kCritColor['ok']!;
          break;
        case _SegTone.bad:
          bg = kCritColor['critical']!.withValues(alpha: 0.14);
          fg = kCritColor['critical']!;
          break;
        case _SegTone.np:
          bg = kInkFaint.withValues(alpha: 0.14);
          fg = kInkSoft;
          break;
      }
    }
    return InkWell(
      onTap: o.onTap,
      child: Container(
        height: 34,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: kSpaceSm),
        color: bg,
        child: Text(
          o.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12,
              color: fg,
              fontWeight: o.selected ? FontWeight.w700 : FontWeight.w500),
        ),
      ),
    );
  }
}

enum _SegTone { ok, bad, np }

class _SegOpt {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final _SegTone tone;
  _SegOpt(this.label, this.selected, this.onTap, {required this.tone});
}
