import 'package:drone_inspection_app/models/li_records.dart';
import 'package:drone_inspection_app/screens/li_tabs/tickets_tab.dart';
import 'package:drone_inspection_app/utils/li_format.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Tickets tab reorders what the server sends. `GET /tickets/` sorts by
/// `-raised_at` only, so a critical defect from last month sits below any number
/// of minor ones raised since — the opposite of how a backlog is worked. These
/// pin the triage order and the date labels that replaced the raw ISO strings.

TicketRecord _ticket({
  required int id,
  required String criticality,
  required String raisedAt,
  String status = 'open',
}) =>
    TicketRecord(
      id: id,
      towerId: id,
      towerNumber: '$id',
      lineName: 'L',
      itemLabel: 'Insulator string',
      position: '',
      defectLabel: 'Broken disc',
      answers: const {},
      criticality: criticality,
      status: status,
      raisedAt: raisedAt,
      raisedBy: 'AEE1',
      closedBy: '',
      closeNote: '',
    );

void main() {
  group('ticketsForTriage', () {
    test('puts the worst severity first regardless of age', () {
      final ordered = ticketsForTriage([
        _ticket(id: 1, criticality: 'minor', raisedAt: '2026-07-20T10:00:00Z'),
        _ticket(id: 2, criticality: 'critical', raisedAt: '2026-06-01T10:00:00Z'),
        _ticket(id: 3, criticality: 'major', raisedAt: '2026-07-25T10:00:00Z'),
      ]);
      expect(ordered.map((t) => t.id), [2, 3, 1],
          reason: 'the oldest ticket is critical and must lead');
    });

    test('newest first within one severity', () {
      final ordered = ticketsForTriage([
        _ticket(id: 1, criticality: 'major', raisedAt: '2026-07-01T10:00:00Z'),
        _ticket(id: 2, criticality: 'major', raisedAt: '2026-07-28T10:00:00Z'),
        _ticket(id: 3, criticality: 'major', raisedAt: '2026-07-14T10:00:00Z'),
      ]);
      expect(ordered.map((t) => t.id), [2, 3, 1]);
    });

    test('orders a mixed backlog worst-first, newest within each severity', () {
      final ordered = ticketsForTriage([
        _ticket(id: 1, criticality: 'minor', raisedAt: '2026-07-20T10:00:00Z'),
        _ticket(id: 2, criticality: 'critical', raisedAt: '2026-07-21T10:00:00Z'),
        _ticket(id: 3, criticality: 'critical', raisedAt: '2026-07-22T10:00:00Z'),
        _ticket(id: 4, criticality: 'ok', raisedAt: '2026-07-28T10:00:00Z'),
        _ticket(id: 5, criticality: 'major', raisedAt: '2026-07-02T10:00:00Z'),
      ]);
      expect(ordered.map((t) => t.id), [3, 2, 5, 1, 4]);
    });

    test('does not mutate its input', () {
      final input = [
        _ticket(id: 1, criticality: 'minor', raisedAt: '2026-07-20T10:00:00Z'),
        _ticket(id: 2, criticality: 'critical', raisedAt: '2026-06-01T10:00:00Z'),
      ];
      ticketsForTriage(input);
      expect(input.map((t) => t.id), [1, 2]);
    });

    test('an unknown criticality sorts last rather than throwing', () {
      final ordered = ticketsForTriage([
        _ticket(id: 1, criticality: 'something_new', raisedAt: '2026-07-28T10:00:00Z'),
        _ticket(id: 2, criticality: 'minor', raisedAt: '2026-07-01T10:00:00Z'),
      ]);
      expect(ordered.map((t) => t.id), [2, 1]);
    });

    test('empty in, empty out', () {
      expect(ticketsForTriage(const []), isEmpty);
    });
  });

  group('closedAt', () {
    test('is read from the payload the API already sent', () {
      final t = TicketRecord.fromJson(const {
        'id': 7,
        'criticality': 'major',
        'status': 'closed',
        'raised_at': '2026-07-01T10:00:00Z',
        'closed_at': '2026-07-04T09:30:00Z',
        'closed_by_employee_id': 'EE1',
        'close_note': 'Replaced',
      });
      expect(t.closedAt, '2026-07-04T09:30:00Z');
      expect(t.isOpen, isFalse);
    });

    test('is empty while the ticket is open', () {
      final t = TicketRecord.fromJson(const {
        'id': 8,
        'status': 'open',
        'raised_at': '2026-07-01T10:00:00Z',
      });
      expect(t.closedAt, isEmpty);
    });
  });

  group('date labels', () {
    final now = DateTime.parse('2026-07-29T12:00:00Z');

    test('names today and yesterday', () {
      expect(liDayLabel('2026-07-29T08:00:00Z', now: now), 'Today');
      expect(liDayLabel('2026-07-28T08:00:00Z', now: now), 'Yesterday');
    });

    test('drops the year within the current year, keeps it otherwise', () {
      expect(liDayLabel('2026-07-14T08:00:00Z', now: now), '14 Jul');
      expect(liDayLabel('2025-12-02T08:00:00Z', now: now), '2 Dec 2025');
    });

    test('age is coarse and ordered by magnitude', () {
      expect(liAgeLabel('2026-07-29T08:00:00Z', now: now), '4h');
      expect(liAgeLabel('2026-07-24T12:00:00Z', now: now), '5d');
      expect(liAgeLabel('2026-07-01T12:00:00Z', now: now), '4w');
      expect(liAgeLabel('2026-02-01T12:00:00Z', now: now), '5mo');
      expect(liAgeLabel('2023-07-29T12:00:00Z', now: now), '3y');
    });

    test('a future or unparseable timestamp yields no age', () {
      expect(liAgeLabel('2026-12-01T12:00:00Z', now: now), isEmpty);
      expect(liAgeLabel('not a date', now: now), isEmpty);
    });

    test('an unparseable timestamp falls back to the raw value', () {
      // Better a odd-looking string than an exception inside a list builder.
      expect(liDayLabel('sometime', now: now), 'sometime');
    });

    test('day-and-time keeps the clock', () {
      expect(liDayTimeLabel('2026-07-14T08:05:00Z', now: now),
          matches(r'^14 Jul · \d{2}:\d{2}$'));
    });
  });
}
