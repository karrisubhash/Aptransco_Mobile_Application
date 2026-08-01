/// Record models returned by the line-inspection read/aggregate endpoints:
/// subdivisions, inspection summaries + details, defect tickets, support
/// requests, and the dashboard payload.
library;

class Subdivision {
  final int id;
  final String name;
  final String circle;
  final String division;
  final String zone;

  const Subdivision({
    required this.id,
    required this.name,
    required this.circle,
    required this.division,
    required this.zone,
  });

  factory Subdivision.fromJson(Map<String, dynamic> j) => Subdivision(
        id: j['id'] as int,
        name: j['name'] as String? ?? '',
        circle: j['circle'] as String? ?? '',
        division: j['division'] as String? ?? '',
        zone: j['zone'] as String? ?? '',
      );
}

/// One row in the inspections list.
class InspectionSummary {
  final int id;
  final int towerId;
  final String towerNumber;
  final String towerType;
  final String lineName;
  final String date;
  final String inspector;
  final String worst;
  final int defectCount;

  const InspectionSummary({
    required this.id,
    required this.towerId,
    required this.towerNumber,
    required this.towerType,
    required this.lineName,
    required this.date,
    required this.inspector,
    required this.worst,
    required this.defectCount,
  });

  factory InspectionSummary.fromJson(Map<String, dynamic> j) =>
      InspectionSummary(
        id: j['id'] as int,
        towerId: j['tower_id'] as int? ?? 0,
        towerNumber: j['tower_number'] as String? ?? '',
        towerType: j['tower_type'] as String? ?? '',
        lineName: j['line_name'] as String? ?? '',
        date: j['date'] as String? ?? '',
        inspector: j['inspector_employee_id'] as String? ?? '',
        worst: j['worst_criticality'] as String? ?? 'ok',
        defectCount: j['defect_count'] as int? ?? 0,
      );
}

/// A recorded defect within an inspection detail.
class DefectEntryDetail {
  final int defectId;
  final String defectLabel;
  final Map<String, dynamic> answers;
  final String criticality;
  final String note;
  final String? photo;

  const DefectEntryDetail({
    required this.defectId,
    required this.defectLabel,
    required this.answers,
    required this.criticality,
    required this.note,
    required this.photo,
  });

  factory DefectEntryDetail.fromJson(Map<String, dynamic> j) =>
      DefectEntryDetail(
        defectId: j['defect_id'] as int? ?? 0,
        defectLabel: j['defect_label'] as String? ?? '',
        answers: (j['answers'] as Map?)?.cast<String, dynamic>() ?? const {},
        criticality: j['criticality'] as String? ?? 'minor',
        note: j['note'] as String? ?? '',
        photo: j['photo'] as String?,
      );
}

/// One checklist item's result within an inspection detail.
class ItemResultDetail {
  final int itemId;
  final String itemLabel;
  final int sno;
  final String groupKey;
  final String position;
  final String status;
  final String? photo;
  final List<DefectEntryDetail> entries;

  const ItemResultDetail({
    required this.itemId,
    required this.itemLabel,
    required this.sno,
    required this.groupKey,
    required this.position,
    required this.status,
    required this.photo,
    required this.entries,
  });

  factory ItemResultDetail.fromJson(Map<String, dynamic> j) => ItemResultDetail(
        itemId: j['item_id'] as int? ?? 0,
        itemLabel: j['item_label'] as String? ?? '',
        sno: j['sno'] as int? ?? 0,
        groupKey: j['group_key'] as String? ?? '',
        position: j['position'] as String? ?? '',
        status: j['status'] as String? ?? 'normal',
        photo: j['photo'] as String?,
        entries: (j['entries'] as List? ?? const [])
            .map((e) => DefectEntryDetail.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class InspectionDetail {
  final int id;
  final String towerNumber;
  final String towerType;
  final String lineName;
  final String date;
  final String inspector;
  final String remarks;
  final String worst;
  final List<ItemResultDetail> itemResults;

  const InspectionDetail({
    required this.id,
    required this.towerNumber,
    required this.towerType,
    required this.lineName,
    required this.date,
    required this.inspector,
    required this.remarks,
    required this.worst,
    required this.itemResults,
  });

  factory InspectionDetail.fromJson(Map<String, dynamic> j) => InspectionDetail(
        id: j['id'] as int,
        towerNumber: j['tower_number'] as String? ?? '',
        towerType: j['tower_type'] as String? ?? '',
        lineName: j['line_name'] as String? ?? '',
        date: j['date'] as String? ?? '',
        inspector: j['inspector_employee_id'] as String? ?? '',
        remarks: j['remarks'] as String? ?? '',
        worst: j['worst_criticality'] as String? ?? 'ok',
        itemResults: (j['item_results'] as List? ?? const [])
            .map((e) => ItemResultDetail.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// A defect ticket.
class TicketRecord {
  final int id;
  final int towerId;
  final String towerNumber;
  final String lineName;
  final String itemLabel;
  final String position;
  final String defectLabel;
  final Map<String, dynamic> answers;
  final String criticality;
  final String status; // open | closed
  final String raisedAt;
  final String raisedBy;

  /// When it was signed off. The API has always sent `closed_at`; it is read here
  /// so a closed ticket can say when, not just by whom. Empty while open.
  final String closedAt;
  final String closedBy;
  final String closeNote;

  const TicketRecord({
    required this.id,
    required this.towerId,
    required this.towerNumber,
    required this.lineName,
    required this.itemLabel,
    required this.position,
    required this.defectLabel,
    required this.answers,
    required this.criticality,
    required this.status,
    required this.raisedAt,
    required this.raisedBy,
    this.closedAt = '',
    required this.closedBy,
    required this.closeNote,
  });

  bool get isOpen => status == 'open';

  factory TicketRecord.fromJson(Map<String, dynamic> j) => TicketRecord(
        id: j['id'] as int,
        towerId: j['tower_id'] as int? ?? 0,
        towerNumber: j['tower_number'] as String? ?? '',
        lineName: j['line_name'] as String? ?? '',
        itemLabel: j['item_label'] as String? ?? '',
        position: j['position'] as String? ?? '',
        defectLabel: j['defect_label'] as String? ?? '',
        answers: (j['answers'] as Map?)?.cast<String, dynamic>() ?? const {},
        criticality: j['criticality'] as String? ?? 'minor',
        status: j['status'] as String? ?? 'open',
        raisedAt: j['raised_at'] as String? ?? '',
        raisedBy: j['raised_by_employee_id'] as String? ?? '',
        closedAt: j['closed_at'] as String? ?? '',
        closedBy: j['closed_by_employee_id'] as String? ?? '',
        closeNote: j['close_note'] as String? ?? '',
      );
}

/// A support / dispute request.
class SupportRequest {
  final int id;
  final String raisedBy;
  final String category;
  final String subject;
  final String text;
  final String status; // open | resolved
  final String createdAt;
  final String response;
  final String resolvedBy;
  final int? subdivisionId;
  final String subdivisionName;

  const SupportRequest({
    required this.id,
    required this.raisedBy,
    required this.category,
    required this.subject,
    required this.text,
    required this.status,
    required this.createdAt,
    required this.response,
    required this.resolvedBy,
    required this.subdivisionId,
    required this.subdivisionName,
  });

  bool get isOpen => status == 'open';

  factory SupportRequest.fromJson(Map<String, dynamic> j) => SupportRequest(
        id: j['id'] as int,
        raisedBy: j['raised_by_employee_id'] as String? ?? '',
        category: j['category'] as String? ?? '',
        subject: j['subject'] as String? ?? '',
        text: j['text'] as String? ?? '',
        status: j['status'] as String? ?? 'open',
        createdAt: j['created_at'] as String? ?? '',
        response: j['response'] as String? ?? '',
        resolvedBy: j['resolved_by_employee_id'] as String? ?? '',
        subdivisionId: j['subdivision_id'] as int?,
        subdivisionName: j['subdivision_name'] as String? ?? '',
      );
}

// ------------------------------ dashboard ----------------------------------
class DashLine {
  final int lineId;
  final String name;
  final int towerCount;
  final int inspected;
  final int pct;
  final int openDefects;

  const DashLine({
    required this.lineId,
    required this.name,
    required this.towerCount,
    required this.inspected,
    required this.pct,
    required this.openDefects,
  });

  factory DashLine.fromJson(Map<String, dynamic> j) => DashLine(
        lineId: j['line_id'] as int? ?? 0,
        name: j['name'] as String? ?? '',
        towerCount: j['tower_count'] as int? ?? 0,
        inspected: j['inspected'] as int? ?? 0,
        pct: j['pct'] as int? ?? 0,
        openDefects: j['open_defects'] as int? ?? 0,
      );
}

class DashSubdivision {
  final int id;
  final String name;
  final int towerCount;
  final int inspected;
  final int open;
  final int critical;

  const DashSubdivision({
    required this.id,
    required this.name,
    required this.towerCount,
    required this.inspected,
    required this.open,
    required this.critical,
  });

  factory DashSubdivision.fromJson(Map<String, dynamic> j) => DashSubdivision(
        id: j['id'] as int? ?? 0,
        name: j['name'] as String? ?? '',
        towerCount: j['tower_count'] as int? ?? 0,
        inspected: j['inspected'] as int? ?? 0,
        open: j['open'] as int? ?? 0,
        critical: j['critical'] as int? ?? 0,
      );
}

class DashboardData {
  final int towerTotal;
  final int inspected;
  final int coveragePct;
  final int openTotal;
  final int closedTotal;
  final Map<String, int> criticality; // critical/major/minor
  final List<MapEntry<String, int>> byComponent;
  final List<DashLine> lines;
  final List<DashSubdivision> subdivisions; // empty unless HQ view

  const DashboardData({
    required this.towerTotal,
    required this.inspected,
    required this.coveragePct,
    required this.openTotal,
    required this.closedTotal,
    required this.criticality,
    required this.byComponent,
    required this.lines,
    required this.subdivisions,
  });

  factory DashboardData.fromJson(Map<String, dynamic> j) => DashboardData(
        towerTotal: j['tower_total'] as int? ?? 0,
        inspected: j['inspected'] as int? ?? 0,
        coveragePct: j['coverage_pct'] as int? ?? 0,
        openTotal: j['open_total'] as int? ?? 0,
        closedTotal: j['closed_total'] as int? ?? 0,
        criticality:
            (j['criticality'] as Map?)?.map((k, v) => MapEntry(k.toString(),
                    (v as num?)?.toInt() ?? 0)) ??
                const {'critical': 0, 'major': 0, 'minor': 0},
        byComponent: (j['by_component'] as List? ?? const [])
            .map((e) => MapEntry(
                (e as Map)['item'].toString(), (e['count'] as num).toInt()))
            .toList(),
        lines: (j['lines'] as List? ?? const [])
            .map((e) => DashLine.fromJson(e as Map<String, dynamic>))
            .toList(),
        subdivisions: (j['subdivisions'] as List? ?? const [])
            .map((e) => DashSubdivision.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
