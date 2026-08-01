/// The signed-in user's session for the line-inspection platform. Identity and
/// role now come from the backend login (`POST /auth/login/`, checkCred-verified)
/// rather than a free-text picker: [token] authenticates every request and the
/// server scopes all data by the resolved employee_id's jurisdiction.
class LiSession {
  final String employeeId;
  final String token; // mobile auth token (empty = signed out)
  final String displayName;
  final bool isAdmin;
  final bool isManagement;
  final String cadre; // display label, e.g. 'AEE'/'EE'
  final String tier; // 'field_user' | 'supervisor' | 'admin' | 'none'

  // Optional local scope hint for list filtering (a subdivision the user
  // chose to focus on). Server-side jurisdiction is authoritative regardless.
  final int? subdivisionId;
  final String? subdivisionName;

  const LiSession({
    required this.employeeId,
    required this.token,
    this.displayName = '',
    this.isAdmin = false,
    this.isManagement = false,
    this.cadre = '',
    this.tier = '',
    this.subdivisionId,
    this.subdivisionName,
  });

  /// Built from the `/auth/login/` (or `/auth/me/`) response.
  factory LiSession.fromLogin(Map<String, dynamic> j, {required String token}) => LiSession(
        employeeId: j['employee_id'] as String? ?? '',
        token: token,
        displayName: j['display_name'] as String? ?? '',
        isAdmin: j['is_admin'] as bool? ?? false,
        isManagement: j['is_management'] as bool? ?? false,
        cadre: j['cadre'] as String? ?? '',
        tier: j['tier'] as String? ?? '',
      );

  LiSession copyWith({int? subdivisionId, String? subdivisionName}) => LiSession(
        employeeId: employeeId,
        token: token,
        displayName: displayName,
        isAdmin: isAdmin,
        isManagement: isManagement,
        cadre: cadre,
        tier: tier,
        subdivisionId: subdivisionId ?? this.subdivisionId,
        subdivisionName: subdivisionName ?? this.subdivisionName,
      );

  bool get isManagementOrAdmin => isAdmin || isManagement;

  /// Cadres that work at a single structure, so the map should open on the tower
  /// nearest them.
  ///
  /// These are [cadre] labels as the backend reports them (`viewing.CADRE_LABELS`
  /// maps the raw SAP `emp_sub_grp` codes onto these), so match them exactly —
  /// `'ADE/AEE'` maps to `DEE` and must not be caught by a substring test against
  /// `AEE`.
  static const Set<String> fieldCadres = {'AEE', 'EE'};

  /// Whether Home should open on the tower nearest this user rather than on a
  /// fitted overview of everything in their scope.
  ///
  /// The two roles do different jobs: an AEE or EE walks to a structure, so the
  /// map is most useful opened there at working zoom; a DEE, SE or admin
  /// supervises whole lines, and opening them at one tower hides their job.
  ///
  /// Keyed on [cadre] rather than [tier] because the requirement is about grade.
  /// `tier` is deliberately *functional* — the backend derives it from who holds
  /// the role assignments in the reporting subtree — so it puts any cadre with
  /// subordinates in `supervisor` and any cadre without them in `field_user`.
  /// That splits EEs and DEEs the wrong way round for this decision.
  ///
  /// Admins and top-cadre management are always given the overview regardless of
  /// label. An unknown or empty cadre also gets the overview: showing too much is
  /// a mild inconvenience, whereas pinning a supervisor to a single structure
  /// hides most of what they are responsible for.
  bool get opensAtNearestTower {
    if (isAdmin || isManagement) return false;
    return fieldCadres.contains(cadre.trim().toUpperCase());
  }

  /// The subdivision id used to scope list queries (null = no local filter).
  int? get scopeSubdivisionId => subdivisionId;

  String get jurisdictionLabel {
    final label = cadre.isNotEmpty ? cadre : (isAdmin ? 'Admin' : 'Field');
    return subdivisionName != null ? '$label — $subdivisionName' : label;
  }

  Map<String, dynamic> toJson() => {
        'employeeId': employeeId,
        'token': token,
        'displayName': displayName,
        'isAdmin': isAdmin,
        'isManagement': isManagement,
        'cadre': cadre,
        'tier': tier,
        'subdivisionId': subdivisionId,
        'subdivisionName': subdivisionName,
      };

  factory LiSession.fromJson(Map<String, dynamic> j) => LiSession(
        employeeId: j['employeeId'] as String? ?? '',
        token: j['token'] as String? ?? '',
        displayName: j['displayName'] as String? ?? '',
        isAdmin: j['isAdmin'] as bool? ?? false,
        isManagement: j['isManagement'] as bool? ?? false,
        cadre: j['cadre'] as String? ?? '',
        tier: j['tier'] as String? ?? '',
        subdivisionId: j['subdivisionId'] as int?,
        subdivisionName: j['subdivisionName'] as String?,
      );
}
