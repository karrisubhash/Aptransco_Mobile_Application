/// In-progress inspection state held by the form while it is being filled.
/// Ported from the POC's `Inspect.cur` structure: an inspection is a map of
/// per-item drafts; positional items hold one [SlotDraft] per position, plain
/// items use a single item-level slot.
library;

import 'dart:io';

import 'inspection_catalog.dart';

/// One recorded (or being-edited) defect within a slot.
class DefectEntryDraft {
  int defectId;
  String defectKey;
  Map<String, dynamic> answers;
  String criticality;
  String suggestedCriticality;
  String note;

  /// Optional evidence photo for this defect (uploaded on save).
  File? photo;

  DefectEntryDraft({
    required this.defectId,
    required this.defectKey,
    Map<String, dynamic>? answers,
    this.criticality = '',
    this.suggestedCriticality = '',
    this.note = '',
    this.photo,
  }) : answers = answers ?? {};
}

/// A "slot" is either a whole non-positional item or one position of a
/// positional item. It carries a status, its committed defect entries, any
/// per-position select value, and the transient state of the entry currently
/// being added.
class SlotDraft {
  /// normal | defect | na | not_provided
  String status;
  final List<DefectEntryDraft> entries = [];

  /// Per-position select value(s), e.g. {'insType': 'Fog Disc'}.
  final Map<String, String> meta = {};

  // Transient editor state for the entry being added (null draftDefectId =
  // not started).
  bool editing = false;
  int? draftDefectId;
  final Map<String, dynamic> draftAnswers = {};
  String? draftCriticality;
  String draftNote = '';
  File? draftPhoto;

  SlotDraft(this.status);

  void resetDraft() {
    editing = false;
    draftDefectId = null;
    draftAnswers.clear();
    draftCriticality = null;
    draftNote = '';
    draftPhoto = null;
  }
}

/// Draft state for one checklist item.
class ItemDraft {
  final ChecklistItem item;

  /// For non-positional items this is the item's slot. For positional items it
  /// only carries the item-level gate status ('na' / 'not_provided' / 'normal').
  final SlotDraft main;

  /// Positional slots, keyed by position name (e.g. 'Top').
  final Map<String, SlotDraft> positions;

  /// Optional item-level photo (any item, normal or defective).
  File? photo;

  ItemDraft(this.item, this.main, this.positions);

  bool get isPositional => item.hasPositions;

  /// Every committed entry across this item's slots.
  Iterable<DefectEntryDraft> get allEntries sync* {
    if (isPositional) {
      for (final p in positions.values) {
        yield* p.entries;
      }
    } else {
      yield* main.entries;
    }
  }
}
