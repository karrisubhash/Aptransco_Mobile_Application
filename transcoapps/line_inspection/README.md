# line_inspection

Backend for APTRANSCO's transmission line patrolling & tower inspection system
(Django web dashboard + Flutter field app, built in phases). This app owns
the GIS master data, the editable inspection checklist, jurisdiction/role
assignment, the custom admin panel, and all inspection/ticket records.

Reference proof-of-concept UX/data shapes: `transcoapps/gisdata/clearpoc.html`
and `transcoapps/poc_v2.html` (single-file HTML/JS prototypes — not wired up
to this app, kept for reference only). The **Phase 4 base** is the Flutter field app
`transcoapps/Aptransco_TIS-main/drone_inspection_app` (+ a reference Django backend
`aptransco_backend` whose `line_inspection` app is an auth-less `managed=False` mirror of THIS
app's `clear`-schema tables). Its inspection **questionnaire is fully data-driven from our
`GET /catalog/`**. We take its *contract + patterns* (data-driven form, `client_id` idempotency,
offline outbox, atomic multi-photo create, thumbnailing) and re-home the backend role onto this
app — we do NOT reuse its code. Full details + the mobile API contract are in
"Phase 4 — Flutter field app" near the end of this README.

## Ground rules (do not violate these without re-confirming with the user)

- **Only the `clear` schema** on the shared Postgres server (`10.96.76.172`)
  is read or written by this app. No other schema there (`telecom_cps`,
  `lines`, `gismaps`, `keycloak`, etc.) is touched.
- **`line_inspection` must not depend on any other app in this Django
  project at runtime** — not `gisapp`, not `gisdata`, nothing. Some server
  deployments won't even have those apps installed. Where gisapp already had
  working code we wanted (ArcGIS client, Keycloak OIDC flow), we **copied**
  it into `line_inspection/services/` rather than importing it — some
  duplication is the accepted tradeoff for deployment independence. If you
  fix a bug in `gisapp/arcgis_client.py`, port the fix by hand into
  `line_inspection/services/arcgis_client.py` too (and vice versa for
  Keycloak logic in `gisapp/views.py`).
- **No `django.contrib.auth`, ever.** Identity is a bare SAP `employee_id`
  resolved via Keycloak, stored directly in Django's session framework
  (`request.session` — independent of `contrib.auth`). Authorization is our
  own three-tier model (see below), not Django permissions/groups.
- **No `django.contrib.admin`, ever.** The custom admin panel (`auth.py` +
  `admin_views.py` + templates) is server-rendered Django templates +
  vanilla JS, matching this project's existing style (`contacts`/`gisapp`/
  `gisdata`) — no new frontend toolchain. The Phase 3 field-engineer
  dashboard will be built the same way.
- **Tower/Line/Substation master data comes only from ArcGIS**, synced into
  our own tables — never fetched live per request, never read from the
  legacy `lines.infom`/`towr_master`/`cond_master` tables on the shared
  server (explicitly out of scope).
- **The checklist (items/defects/follow-up questions/criticality
  thresholds) is DB-backed and editable**, not hardcoded Python — it is not
  finalised and field engineers will request changes after reviewing the
  app. Edit it via the checklist editor admin screen, not by hand-editing
  `seed_checklist_catalog.py` after the first run.
- **SAP↔ArcGIS line mapping is a real, ongoing data-integration effort**,
  not a one-time import. `import_sap_lines` only loads raw SAP data (no
  mapping); `map_sap_lines` / the mapping admin page is what actually links
  `Line.sap_line`.

## Login (active: legacy checkCred — Keycloak deferred)

`services/keycloak_client.py` is fully built (see "Ground rules" above) but
**dormant** — the Keycloak client's registered "Valid Redirect URIs" needs a
change in the Keycloak admin console that's outside our control, so
Keycloak integration is deferred to a later phase. The **active** login
mechanism is APTRANSCO's legacy employee-credential gateway:

- `services/checkcred_client.py` — `verify_credentials(user_id, passwd)`
  (calls `POST /qath/checkCred` with HTTP Basic Auth using app-level
  credentials, distinct from the employee's own id/password), plus
  `forgot_password(user_id)` and `save_password(user_id, passwd, oldpass)`.
  Same service `gisapp/views.py`'s `login_proxy` already calls — a fresh,
  standalone copy here, not an import.
- `auth.login_view` now renders a real login form (`templates/line_inspection/login.html`)
  and verifies credentials directly — no redirect to an external identity
  provider. `auth.forgot_password_view` / `auth.change_password_view` wrap
  the other two endpoints with their own small forms.
- Verified end-to-end (Django test client + the real service): correct
  credentials set the session and unlock `@login_required` views; wrong
  credentials re-render the form with an error and never touch the session;
  logout clears it.
- **To re-enable Keycloak later**: add back a thin `callback_view` in
  `auth.py` (redirect to `keycloak_client.get_authorize_url(...)`, then on
  return call `keycloak_client.exchange_code(...)` and set the session —
  `keycloak_client.py` itself was never touched, only the ~15-line view
  glue was removed) and re-point `login_view`/the URL — once the redirect
  URI is registered in Keycloak.

## Three-tier authorization model (no django.contrib.auth)

1. **Super Admin** — decides who counts as an Admin. Bootstrapped via
   `manage.py grant_super_admin` (CLI-only escape hatch — an empty
   permissions table would otherwise lock everyone out), managed thereafter
   through the "Manage Admins" screen.
2. **Admin** (EE cadre holding a position granted in `FieldEECadrePosition`)
   — assigns **Users** (AEE/DEE cadre) to lines/towers via `RoleAssignment`;
   edits the checklist catalog; manages the SAP↔ArcGIS line mapping.
3. **User** — an employee with an active `RoleAssignment` — sees/inspects
   only their assigned jurisdiction (`jurisdiction.py`).

## App structure

```
line_inspection/
  models.py                 Domain models (see "Data model" below)
  db_router.py               LineInspectionRouter — routes this app's models
                              to the line_inspection_db connection/clear schema
  jurisdiction.py             visible_lines()/visible_towers()/can_edit_tower()
                              — server-side equivalent of the POC's
                              App.visibleLines()/visibleTowers()/canEdit().
                              This is the OWN-ASSIGNMENT (edit/capture) scope. visible_towers /
                              can_edit_tower also union in from/to-tower ranges
                              (range_tower_ids()) — see LineTowerAssignment.
  viewing.py                  Phase 3 reporting-hierarchy OVERSIGHT (read) scope:
                              subordinate_snapshots()/oversight_lines()/
                              oversight_towers()/cadre_tier()/is_management()/
                              circuits_at() (all circuits on a physical structure).
                              Widens jurisdiction.py up the reporting tree WITHOUT
                              granting edit rights (kept deliberately separate).
  status.py                   Tower inspection-status helpers + STATUS_COLORS +
                              bump_tower_cache() (maintains the Tower.last_* cache) +
                              latest_inspections() (latest Inspection per tower, prefetched)
  schedule.py                 Tower schedule — project_onto_line() (geometry projection) +
                              line_schedule(line) (towers ordered along the line by line_sequence)
  register.py                 Line inspection register builder — build_register(line, cycle)
                              (per-line item×tower matrix, incl. VT columns) + register_to_xlsx()
  auth.py                     Session-based login/callback/logout + the
                              @login_required/@admin_required/@super_admin_required
                              decorators
  context_processors.py       Injects session_employee_id/is_admin/is_super_admin
                              into every template (registered in settings.py)
  forms.py                    ModelForms for the admin panel screens
  admin_views.py               All custom admin-panel views (no django-admin)
  dashboard_views.py           Phase 3 field-engineer / oversight dashboard views
                              (map / tickets / inspections / rollup) — read-only
  admin.py                    Deliberately empty — no django-admin usage
  services/
    arcgis_client.py           Standalone copy of gisapp/arcgis_client.py
    checkcred_client.py         Legacy employee-credential gateway client — ACTIVE login mechanism
    keycloak_client.py         Standalone copy/adaptation of gisapp's OIDC flow — DORMANT, deferred
    sap_client.py               Live SAP employee-cadre-details RFC client
    sap_matching.py              Shared Line<->SapLine name-similarity scoring
                                 (used by map_sap_lines AND the mapping admin page)
    lilo_matching.py             LILO reconcile — propose_matches()/apply_reconcile()
                                 (coordinate-resilient tower re-identification) + detect_churn()
    criticality.py               Evaluates CriticalityRule rows against submitted
                                 answers (data-driven replacement for the POC's
                                 hardcoded critRule() JS)
  management/commands/
    seed_checklist_catalog.py  Loads/refreshes the checklist catalog
    sync_gis_towers.py         ArcGIS -> Postgres sync (towers incl. VT/lines/substations);
                              promotes tower-master columns + links real↔VT structures
    sync_employee_cadre.py     Live SAP service -> EmployeeCadreSnapshot sync
    run_sync_scheduler.py      Long-running loop that reruns both syncs on an interval
    grant_super_admin.py       CLI-only bootstrap for the first Super Admin
    import_sap_lines.py        Raw SAP line Excel import (creates NO mapping)
    map_sap_lines.py           Auto-matches Line<->SapLine (high-confidence only)
    warm_tower_status.py       Rebuilds the Tower.last_* status cache from Inspection
    build_tower_schedule.py    Assigns Tower.line_sequence along each line (schedule order)
    lilo_reconcile.py          Report/apply a LILO event's tower reconcile (Super-Admin)
    detect_tower_churn.py      Flags undeclared object_id churn (stranded history)
  api/
    authentication.py           SessionEmployeeAuthentication (browser) +
                                KeycloakBearerAuthentication (mobile/external)
    serializers.py, views.py, urls.py   REST API, mounted at /inspection/api/
  templates/line_inspection/    login.html/forgot_password.html/change_password.html (standalone,
                                no base.html — pre-login) + base.html + one template per admin screen
                                + dashboard_map/tickets/inspections/register/rollup.html (Phase 3)
  tests/test_dashboard.py       Phase 3 oversight-scope / status / rollup / gating /
                                map-security tests (need a Postgres test DB — see file header)
```

## Data model

**1. GIS master data** (synced from ArcGIS, `sync_gis_towers`)
- `Subdivision`, `Line`, `Tower`, `Substation` — each keyed by
  `(source_layer, arcgis_object_id)`, soft-deleted via `is_active` (never
  hard-deleted, so `Inspection`/`DefectTicket` FKs never orphan). Every
  ArcGIS field is preserved in a `raw_properties` JSONField in addition to
  the columns promoted for querying (name, voltage, zone/circle/division,
  lat/lng, geometry, etc).
- `Line.sap_line` — FK to `SapLine`, populated by `map_sap_lines` or the
  mapping admin page (302/1212 lines currently mapped — see Current status).
  **`unique=True`** enforces a one-to-one SAP↔ArcGIS line mapping: a unique
  *nullable* FK allows unlimited unmapped lines (`NULL`) but forbids mapping the
  same `SapLine` to two `Line`s. The surrogate `id` remains the PK on purpose —
  SAP codes can be corrected and lines get LILO-split, so the SAP identifier must
  stay a natural key beside `id`, never the PK (a mutable PK would cascade through
  `Tower.line` ~113k rows and the `RoleAssignment.lines` M2M). This is the join
  key for future SAP↔ArcGIS / GIS→SAP integration.
- `Tower.line_sequence` / `line_offset_m` (schedule step) — the tower's ordered
  position along its line and perpendicular offset, assigned by `build_tower_schedule`
  (geometry projection onto `Line.geometry`, numeric `tower_number` fallback for
  branched Tap/LILO lines). `schedule.line_schedule(line)` reads it back. Ranges
  (`LineTowerAssignment`) reference boundary towers, not this raw value, so a rebuild
  can't drift an assigned stretch.
- `Tower.last_inspection_at` / `last_worst_criticality` / `last_inspection_type`
  (Phase 3) — denormalized cache of the tower's latest inspection, maintained in
  `api.views._create_inspection` and rebuildable via `warm_tower_status`. Lets
  the map/rollups colour and count towers without a per-tower Inspection join.
- **Virtual towers & physical structures (Data-Foundation step).** A physical
  tower can carry 1/2/4 circuits; ArcGIS stores each additional circuit as a
  **VT ("virtual") tower** co-located with the real tower. The sync now imports
  VT rows too (`Tower.is_virtual`), and links every co-located real + VT row into
  one physical structure via `Tower.structure_key` (assigned by coordinate
  proximity, ~33 m, in `sync_gis_towers`). `viewing.circuits_at(tower)` returns
  all circuits/lines strung on a structure (the tower's own line + co-located
  ones) — surfaced by `GET /api/towers/<id>/` and the map pop-up. **Only real
  towers (`is_virtual=False`) are ever inspected or counted** — every jurisdiction/
  oversight/map/register/rollup queryset filters `is_virtual=False`; VT rows are
  informational mirrors for the line/tower schedule.
- **Tower master columns** promoted from the ArcGIS tower layers: `cp_sp`
  (CP/SP/Boom role), `tower_ckts_conductor`, `circuit_type`, `circuit_count`
  (parsed 1/2/4), `conductor_type`, `no_of_conductors_per_phase`,
  `relay_setting_length_in_km`, `span_km` (132kV only), `date_of_commissioning`.
  `insulator_type` / `type_of_earthing` are **manually maintained** (empty/absent
  in ArcGIS) — the sync never overwrites them.

**2. Checklist catalog** (DB-backed & editable, `seed_checklist_catalog` +
   the checklist editor admin screen)
- `ChecklistItemGroup` (5), `ChecklistItem` (25, `sno` 4–28 + Remarks at 29),
  `Defect` (75), `FollowUpQuestion` (22, types: choice/multichoice/number/text),
  `CriticalityRule` (16 — data-driven replacement for the POC's hardcoded
  `critRule()` JS functions, evaluated by `services/criticality.py`).
- `ChecklistItem.applicable_tower_types` is a JSON list gating which tower
  types an item applies to (empty = all types). **Known gap, not yet fixed:**
  still seeded with the POC's placeholder `DA/DB/DC/DD` codes, but real
  ArcGIS `Tower.tower_type` values look like `"Boom"`. The checklist editor's
  item form now presents checkboxes populated from
  `Tower.objects.values_list('tower_type', flat=True).distinct()` (the real
  observed values) so an Admin can correct this without a code change — it
  just hasn't been corrected yet.
- `CatalogVersion` — singleton counter bumped on every catalog change
  (including every save from the checklist editor), stamped onto each
  `Inspection.catalog_version` so historical records stay traceable to the
  catalog shape that produced them.

**3. Cadre / role / jurisdiction / SAP-line mapping** (no `django.contrib.auth`)
- `EmployeeCadreSnapshot` — synced from the live SAP RFC service
  (`sync_employee_cadre`), never queried live per request. Includes
  `reporting_manager_id`/`reporting_manager_name` (added Phase 2) so the
  role-assignment screen can show an Admin their own reporting-hierarchy
  subordinates first.
- `SuperAdmin` — see "Three-tier authorization model" above.
- `FieldEECadrePosition` — admin-curated allow-list of EE position ids
  granted Admin rights. Candidates are surfaced automatically on the "Manage
  Admins" screen via `emp_sub_grp='DE/EE'` (the real combined cadre code —
  **not** two separate `'DE'`/`'EE'` values, confirmed against live synced
  data) `AND position_text__icontains='O&M'`.
- `RoleAssignment` — `employee_id` + role (`FIELD_INSPECTOR`) + jurisdiction
  (`subdivision` FK and/or specific `lines` M2M), stamped with who assigned
  it. `jurisdiction.py` reads this to filter everything else.
- `LineTowerAssignment` — a **from-tower → to-tower stretch** of one line assigned to a
  User (for when a line is shared). Complements `RoleAssignment` (whole-line grants), it
  doesn't replace it. Membership = the line's real towers whose `line_sequence` is between
  the two boundary towers' sequences; `jurisdiction.range_tower_ids()` unions these into
  `visible_towers`/`can_edit_tower` (and `viewing.oversight_towers`), so a range genuinely
  restricts what the User inspects. Assigned from the Roles & Jurisdiction screen using the
  line's tower schedule as the picker.
- `SapLine` — raw SAP line master data (`functional_location`, `description`,
  `voltage`), imported from `EHT LINES SAP DATA *.XLSX` via `import_sap_lines`.
  Importing creates **no mapping** by itself.

**5. LILO lineage (line reorganisation)**
- `LiloEvent` — a recorded LILO: `old_line`, `new_lines` (M2M), `split_tower`, `lilo_date`,
  `performed_by_employee_id`, `applied_at`. `LiloTowerRemap` — per-tower audit of each reconcile
  decision (surviving Tower PK kept, old/new `arcgis_object_id`, distance, method auto/manual/new).
  Populated only by the Super-Admin LILO reconcile (`services/lilo_matching.py`); the routine sync
  never touches them. Physical towers keep their coordinates through a LILO, so survivors are
  revived in place (PK kept → history preserved) rather than recreated.

**4. Transactional inspection data**
- `Inspection` has `inspection_type` (Phase 3, nullable — `ground_patrol`/`pmi`,
  the twice-yearly Ground-Patrolling vs Pre-Monsoon-Inspection cycles; the
  Flutter app populates it, existing rows stay NULL). Also has `client_id`,
  unique/nullable — idempotency key for the REST API, same contract as the
  reference Flutter app's backend) ->
  `ItemResult` (one per item, or per item+position) -> `DefectEntry` (one per
  recorded defect, keeps both `suggested_criticality` and inspector-confirmed
  `criticality`).
- `DefectTicket` — auto-raised per `DefectEntry` by the `POST /inspections/`
  API endpoint. Has a `source` field (`human_inspection`/`drone_inspection`)
  and a `drone_metadata` JSONField, schema-only, since drone inspection is
  being built in parallel — no ingestion pipeline exists yet.
- `SupportRequest` — dispute/admin-contact requests.
- All FKs from transactional models to `Tower`/`Line`/`Inspection` use
  `on_delete=PROTECT` — deleting a Tower with Inspections/Tickets raises
  instead of silently cascading (a bug present in the original POC).

## Admin panel (custom, no django.contrib.admin)

Login: `/inspection/login/` -> redirects to Keycloak -> `/inspection/auth/callback/`
sets `request.session['employee_id']`. Logout: `/inspection/logout/`.

| Screen | URL | Gate | What it does |
|---|---|---|---|
| Home | `/inspection/admin/` | any logged-in employee | Quick counts (towers, lines, assignments, unmapped lines, catalog version) |
| Manage Admins | `/inspection/admin/super/positions/` | `@super_admin_required` | Grant/revoke `FieldEECadrePosition`, from an auto-surfaced DE/EE-cadre O&M candidate list or manual position-id entry |
| Roles & Jurisdiction | `/inspection/admin/assignments/` | `@admin_required` | Assign `RoleAssignment`s (whole line / subdivision) **or** a from/to-tower range (`LineTowerAssignment`) picked from the line's tower schedule; candidates default to the Admin's reporting-hierarchy subordinates with a full-employee search fallback; shows jurisdiction coverage and active tower ranges |
| Checklist Catalog | `/inspection/admin/checklist/` | `@admin_required` | CRUD for groups/items/defects/follow-up questions/criticality rules; bumps `CatalogVersion` on every save |
| SAP ↔ ArcGIS Mapping | `/inspection/admin/sap-mapping/` | `@admin_required` | View/edit/create the `Line.sap_line` mapping; "Run auto-map" button; ranked suggestions per unmapped line |
| LILO | `/inspection/admin/lilo/` | `@super_admin_required` | Record a LILO (old line → new lines) and review the tower reconcile — surviving towers re-linked in place (history kept), loop towers created; plus a churn-detection safety net. Rare, explicitly triggered |

## Field-engineer / oversight dashboard (Phase 3, read-only)

Server-rendered (base.html + vanilla JS + Leaflet via CDN). **No inspection
capture here** — inspections are captured only in the Flutter field app
(Phase 4); this dashboard is read-only monitoring plus ticket actions. Every
screen is scoped by the **reporting-hierarchy oversight scope** (`viewing.py`),
NOT the own-assignment jurisdiction scope: a viewer sees their own towers plus
every tower assigned to Users beneath them in the reporting tree (an EE sees
their Users', an SE/CE sees their whole circle). Oversight is read-only and
never grants edit rights (that stays `jurisdiction.can_edit_tower`). Viewing
tier is functional (`viewing.cadre_tier`): `field_user` / `supervisor` /
`admin`; `viewing.is_management` (top cadre `emp_sub_grp` — `CE`/`DIRECTOR`/
`GM`/`JMD`/`CMD` — or super admin) gates the rollups.

| Screen | URL | Gate | What it does |
|---|---|---|---|
| Map | `/inspection/dashboard/map/` | any logged-in employee | Leaflet map of the viewer's towers, coloured by latest-inspection status; line overview + zoom-gated bbox tower loading via `/api/map/*`; status & Ground-Patrol/PMI filters |
| Tickets | `/inspection/dashboard/tickets/` | any logged-in employee | `DefectTicket`s in scope; filter by status / source (human vs drone) / criticality; close via the existing `/api/tickets/<id>/close/` |
| Inspections | `/inspection/dashboard/inspections/` | any logged-in employee | Read-only inspection history in scope. **`?tower=<id>`** shows one tower's full history newest-first, each inspection expandable (HTML `<details>`) into its item results + defect entries (criticality, follow-up answers, note, photo) + remarks; **`?cycle=`** filters Ground-Patrol/PMI. The all-towers list has a defect count and links each row to its tower's history; the map pop-up has a "View history" deep-link |
| Register | `/inspection/dashboard/register/` | any logged-in employee | Per-line **inspection register** — a digital replica of the field register: **all** towers as columns (real + VT, ordered by the tower schedule; VT columns badged), checklist items grouped as rows, ✓/N/A/defect+criticality cells. A VT tower's cells come from the **co-located real tower's** inspection (shared `structure_key`), so an inspected structure reads inspected on every circuit. Line + cycle (Latest / Ground Patrolling / PMI) selectors; **Print** + **Excel (.xlsx)** download. Line must be in the viewer's oversight scope (else 403). Mobile: one-tower-at-a-time view |
| Reports | `/inspection/dashboard/reports/` | management / admin | Zonal / Circle / Division rollups: inspected vs pending, criticality breakdown, open tickets, human-vs-drone split. Management sees all towers; other admins see their oversight scope |

## REST API (`/inspection/api/`)

Two DRF authentication classes (both resolve to a bare `employee_id`, since
there's no `django.contrib.auth.User`): `SessionEmployeeAuthentication`
(browser calls from our own templates) and `KeycloakBearerAuthentication`
(non-browser clients, e.g. the Phase 4 Flutter app, holding a Keycloak
access token directly).

| Method & path | Notes |
|---|---|
| `GET /health/` | Liveness probe |
| `POST /auth/keycloak/exchange/`, `POST /auth/keycloak/refresh/` | Thin wrappers over `services/keycloak_client.py` |
| `GET /catalog/` | Full nested checklist catalog + `catalog_version` |
| `GET /lines/`, `GET /towers/?line=<id>` | Jurisdiction-filtered via `jurisdiction.py` — never trusts a client-supplied filter (real towers only) |
| `GET /towers/<id>/` | Tower master detail + `circuits` (every line/circuit strung on the same physical structure, via `structure_key`). Oversight-scoped, real towers only. Backs the map pop-up |
| `GET /map/lines/` | GeoJSON of the viewer's **oversight** lines (Phase 3 dashboard overview) + per-line inspected/total rollup |
| `GET /map/towers/?bbox=xmin,ymin,xmax,ymax[&line=&…&status=&…&inspection_type=]` | GeoJSON towers in the viewer's **oversight** scope, narrowed by bbox/line, capped (`truncated` flag), status-coloured. Scope is always applied server-side first — a forged bbox cannot leak towers |
| `POST /inspections/create/` | Atomic nested create (Inspection + ItemResults + DefectEntries), auto-raises DefectTickets. `client_id` idempotency: same id on retry -> 200 (existing record), new -> 201 |
| `GET /inspections/?tower=<id>` | Jurisdiction-filtered history, newest first |
| `GET /tickets/?status=open`, `POST /tickets/<id>/close/` | Closing a ticket is allowed for the assigned field User (their own jurisdiction) **or** any Admin (oversight) |
| `GET/POST /support-requests/`, `POST /support-requests/<id>/resolve/` | Resolve is Admin-oversight, same as ticket-close |

## Environment variables

| Variable | Used by | Notes |
|---|---|---|
| `ARCGIS_USERNAME`, `ARCGIS_PASSWORD` | `services/arcgis_client.py` (via `sync_gis_towers`) | Same ArcGIS portal credentials `gisapp`/`gisdata` use. |
| `SAP_RFC_BASE_URL` | `services/sap_client.py` | Defaults to `https://poprdapp.hec.aptransco.gov.in:50001/RESTAdapter`. |
| `SAP_RFC_USER`, `SAP_RFC_PASSWORD` | `services/sap_client.py` | Basic auth for the SAP RFC adapter (same service `contacts` app uses for `ZHR_GET_EMP_CADER_DETAILS`). |
| `SAP_HIERARCHY_ROOT_EMPLOYEE_ID` | `services/sap_client.py` | Employee id whose full reporting subtree gets fetched (root of the org tree, e.g. CMD). Can be overridden per-run with `--root-employee-id`. |
| `KEYCLOAK_BASE_URL`, `KEYCLOAK_REALM`, `KEYCLOAK_CLIENT_ID`, `KEYCLOAK_CLIENT_SECRET` | `services/keycloak_client.py` | **Dormant, not currently used** (see "Login" above). Realm is case-sensitive — the real realm is `APTRANSCO-EMP`, confirmed live; `aptransco-realm` does not exist. Never hardcode `KEYCLOAK_CLIENT_SECRET` as a source default. |
| `APTRANSCO_AUTH_URL`, `APTRANSCO_AUTH_USER`, `APTRANSCO_AUTH_PASS` | `services/checkcred_client.py` | **Active login mechanism.** `APTRANSCO_AUTH_URL` defaults to `https://qaserv.aptransco.co.in/qath` (checkCred/forgotPass/savePass all hang off this base). `APTRANSCO_AUTH_USER`/`APTRANSCO_AUTH_PASS` are the app-level HTTP Basic Auth credentials for the gateway itself — distinct from any employee's own id/password — and must be set in the environment, never hardcoded. |

None of these have hardcoded fallback secrets in code — they must be set in
the environment wherever these commands/the web app run.

## Management commands

```bash
# Checklist catalog — one-time / re-run after editing ITEMS in the command file
# (day-to-day edits should go through the checklist editor admin screen instead):
python manage.py seed_checklist_catalog

# ArcGIS -> Postgres (towers/lines/substations, 132/220/400kV only):
python manage.py sync_gis_towers [--skip-towers] [--skip-lines] [--skip-substations]

# Live SAP service -> EmployeeCadreSnapshot:
python manage.py sync_employee_cadre [--root-employee-id 1000270]

# Keep both syncs refreshed on a loop (foreground process — run under a
# service wrapper / Task Scheduler for production):
python manage.py run_sync_scheduler [--gis-interval-minutes 60] [--cadre-interval-minutes 60] [--run-once]

# Bootstrap the first Super Admin (CLI-only — an empty SuperAdmin table would
# otherwise lock everyone out of the admin panel):
python manage.py grant_super_admin --employee-id 01073093

# Raw SAP line import (no mapping created) + auto-mapping:
python manage.py import_sap_lines [--file <path>]   # defaults to the checked-in Excel export
python manage.py map_sap_lines [--dry-run]           # writes only high-confidence matches

# Rebuild the Tower.last_* status cache from Inspection rows (Phase 3):
python manage.py warm_tower_status

# Compute the tower schedule (Tower.line_sequence) along every line (geometry
# projection, tower_number fallback) — run after a tower sync:
python manage.py build_tower_schedule

# LILO (Super-Admin, rare): report/apply a recorded LILO's tower reconcile, and
# flag undeclared object_id churn (deactivated-with-history + co-located twin):
python manage.py lilo_reconcile --event <id> [--apply]
python manage.py detect_tower_churn [--line <id>]
```

> **Migrations target the `line_inspection_db` connection, not `default`.**
> Because of the DB router, run migrations with the explicit database:
> `python manage.py migrate line_inspection --database=line_inspection_db`.
> A plain `migrate line_inspection` records the migration against the default
> (sqlite) connection but the router skips the operations there, so the `clear`
> schema never actually changes.

## Current status: Phase 4 complete

- [x] Phase 1 — schema, ArcGIS/SAP-cadre sync, checklist seed (67,128 towers /
      1,212 lines / 384 substations / 1,830 employees, all verified)
- [x] Fixed Phase 1's accidental `gisapp` runtime dependency — ArcGIS client
      copied into `line_inspection/services/`
- [x] Keycloak OIDC client copied/adapted into `line_inspection/services/`
- [x] Session-based auth (no `django.contrib.auth`) + three-tier authorization
      (Super Admin / Admin / User)
- [x] SAP line import + auto-mapping — verified: 1,167 SAP lines imported,
      302/1,212 ArcGIS lines auto-matched with high confidence (threshold
      tuned up from an initial 0.5 Jaccard to 0.75 after spot-checking caught
      false positives at the lower threshold), rest queued for manual review
      on the mapping page
- [x] `EmployeeCadreSnapshot` reporting-manager fields — verified against a
      live SAP payload (`REPORTING_MANAGER_ID`/`REPORTING_MANAGER_NAME`)
- [x] All three admin panel screens (manage Admins, roles & jurisdiction,
      checklist editor, SAP↔ArcGIS mapping) — verified end-to-end via Django
      test client with faked sessions: authorization gates, CRUD, catalog
      version bumps, hierarchy-based candidate lists, jurisdiction coverage
- [x] REST API — verified end-to-end: catalog fetch, jurisdiction-filtered
      towers (0 for an unassigned employee, correct count for an assigned
      one), inspection create + `client_id` idempotency (201 then 200, no
      duplicate), auto-raised ticket, ticket close (both as the assigned User
      and as an Admin), support request create + resolve
- [x] Phase 3 — read-only field-engineer / oversight web dashboard: reporting-
      hierarchy oversight scope (`viewing.py`, kept separate from the edit-scope
      `jurisdiction.py`), role-scoped Leaflet map (line overview + zoom-gated
      bbox tower loading + markercluster), management zonal/circle/division
      rollups, ticket views (human vs drone), the per-line **inspection register**
      (item×tower matrix, cycle filter, Print + Excel export), denormalized
      `Tower.last_*` status cache + `Inspection.inspection_type` (Ground-Patrol/PMI).
      Verified end-to-end (31 checks) against the real `clear` schema in a
      rolled-back transaction: scope widening, edit-scope isolation, status +
      per-type filtering, rollups, 403/200 tier gating, and the map bbox
      security invariant (a forged bbox cannot leak out-of-scope towers).
- [x] Phase 4 — Flutter field app re-homed onto THIS backend, with login,
      GPS-gated capture, and offline-first jurisdiction download. Backend:
      DB-backed revocable mobile token (`MobileAuthToken`) issued by
      `POST /api/auth/login/` (checkCred-verified; `Token` auth scheme, Keycloak
      stays dormant); the full mobile contract (`ping`/`subdivisions`/
      `lines/<id>/towers`/`line-inspections` multipart submit/`line-inspections/list`/
      `line-inspections/<pk>`/`dashboard` + reshaped `catalog` with top-level
      `criticality_rules`+`group_key`) jurisdiction-scoped via `viewing.oversight_*`
      (read) and `jurisdiction.can_edit_tower` (write); a unified `_create_inspection`
      that resolves items/defects by **numeric id OR slug key** so the mobile multipart
      path (`payload` JSON + `photo_key` file parts) and the legacy JSON path share one
      atomic core (idempotency, auto-tickets, VT rejection, `Tower.last_*` bump all kept);
      photos written to `ItemResult.photo`/`DefectEntry.photo` and served as absolute
      `/media/` URLs; **GPS proof of presence** on every inspection (`inspector_lat/lng`,
      `gps_accuracy_m`, server-recomputed `gps_distance_m`, `presence_flag`,
      `override_reason`) with a hard 50 m gate + audited override. App: real
      employee-ID/password login storing the token and sending it on every request;
      5-tab shell (**Home** view-only status map + coverage KPIs, **Inspection**
      GPS-gated capture, Tickets, History, Help); a live-GPS Inspection tab that lists
      towers within 50 m (in-range) vs an override-with-reason path; and a "Download my
      area" action that pre-warms lines+towers+catalog+**pinned** map tiles (excluded
      from the tile LRU) so capture works with no signal. Migration `0008` additive.
      Verified end-to-end (43 checks) against the real `clear` schema in a rolled-back
      transaction; `flutter analyze` clean.
- [ ] Phase 5: hardening, tests (CI Postgres test DB), drone-ticket ingestion, deployment settings

Full phased plan: see the plan doc from the Phase 1/2 planning sessions
(`lexical-seeking-beacon.md`) for the complete roadmap and the reasoning
behind each architectural decision above.

## Phase 4 — Flutter field app (`drone_inspection_app`)

**Base to build on:** `transcoapps/Aptransco_TIS-main/` — a working, **offline-first Flutter**
field app (`drone_inspection_app`, v1.1.0+2) + a **reference Django backend** (`aptransco_backend`).
The reference backend's `line_inspection` app is a thin, **auth-less, `managed=False` DRF mirror of
THIS app's `clear`-schema tables** (same catalog + inspection models) — it exists only to serve the
Flutter app. **Phase 4 re-homes that role onto our authenticated, jurisdiction-scoped,
migration-managed app** — we own the models + migrations and do NOT reuse the reference backend.
Its legacy `inspections` app (flat SQLite, free-text component/defect) is the older POC — ignore it.

**The questionnaire is already ours.** The Flutter form is **fully data-driven** from
`GET /api/catalog/`: groups → items (positions, `pos_meta`, availability gating,
`applicable_tower_types`) → defects (ordered `ask` follow-ups) → follow-up questions
(choice/multichoice/number/text) → criticality rules. That is exactly our
`CatalogVersion`/`ChecklistItemGroup`/`ChecklistItem`/`Defect`/`FollowUpQuestion`/`CriticalityRule`
(seeded by `seed_checklist_catalog`). Criticality is suggested client-side from `criticality_rules`
(mirrors `services/criticality.py`) and sent (`criticality` + `suggested_criticality`) for the
server to trust/re-derive. Exception-based UI: every item starts `normal` (or `na`/`not_provided`),
the inspector marks only defects; follow-ups reveal one-at-a-time.

**App capabilities:** durable offline **outbox** (FIFO, retry ≤8, `client_id` reused across
retries), cache-through GET reads, optimistic inserts, `flutter_map` with disk-cached tiles + tower
pins coloured by worst criticality, camera/gallery photos (item-level + per-defect), tabs
dashboard/inspections/map/register/tickets/support. **No GPS proximity gate** (device GPS is only a
"my location" dot; the tower's stored lat/long is used). **No auth today** — inspector identity is a
free-text string.

**Mobile API contract the app requires** (base must end in `/api`; photos at `/media/<path>` as
**absolute** URLs). App endpoint → our current equivalent:

| App endpoint | Purpose | Our current / action |
|---|---|---|
| `GET /api/ping/` | reachability probe | add |
| `GET /api/catalog/` | questionnaire catalog | have (`/inspection/api/catalog/`) — align keys: add `criticality_rules`, item `group_key`, `pos_meta` |
| `GET /api/subdivisions/` | login/scope picker | add |
| `GET /api/lines/?search=` | line search (empty = all) | have `lines/` — add `?search=` + `subdivision_name` |
| `GET /api/lines/<id>/towers/` | towers on a line | have `towers/?line=` — add path form + fields |
| `GET /api/line-inspections/list/?subdivision=&line=&tower=` | summaries incl. `defect_count` | have `inspections/?tower=` — add filters + summary fields |
| `GET /api/line-inspections/<id>/` | inspection detail | have `InspectionSerializer` — align keys |
| `GET /api/line-inspections/export/?format=xlsx\|pdf&…` | History tab **report download** | have — same filters + `-saved_at` order as `list/`, rendered by `exports.py` |
| **`POST /api/line-inspections/`** | **submit (multipart)** | **have `inspections/create/`** — adapt to the `payload`+`photo_key` shape below |
| `GET /api/tickets/?…`, `POST /api/tickets/<id>/close/` | tickets | have both — align filters/keys |
| `GET /api/tickets/export/?format=xlsx\|pdf&status=…` | Tickets tab **report download** | have — shares `_mobile_ticket_scope` with the list, so the file matches the screen |
| `GET/POST /api/support-requests/…`, `.../resolve/` | support requests | have — align |
| `GET /api/dashboard/?subdivision=` | aggregate KPIs | add (reuse `_rollup`) |

**Submit shape (load-bearing):** `multipart/form-data` — one text field **`payload`** (JSON:
`tower_id, inspector_employee_id, catalog_version, date, remarks, client_id, items[]`, each item =
`{item_id, position, status ∈ normal|defect|na|not_provided, meta, photo_key,
entries:[{defect_id, answers, criticality, suggested_criticality, note, photo_key}]}`) **plus zero+
file parts named by each `photo_key`** (`photo_0`, `photo_1`, …). **Idempotent on `client_id`**
(200 replay / 201 new); every defect entry **auto-raises a `DefectTicket`** (we already do). Map
`photo_key` parts → our `ItemResult.photo` / `DefectEntry.photo` ImageFields.

**Phase 4 build plan (next session):**
1. **Mobile API surface** in `line_inspection/api/` matching the exact paths + JSON keys above, all
   **jurisdiction-scoped** (`jurisdiction.py`/`viewing.py`) and reusing catalog/status/rollup/register
   logic. Add the missing endpoints (`ping`, `subdivisions`, `lines/<id>/towers`,
   `line-inspections/list`, `line-inspections/<id>`, `dashboard`). Reachable so its base ends in `/api`.
2. **Submit adapter** — accept the `payload` + `photo_key` multipart in `_create_inspection`, storing
   photos to our ImageFields; keep `client_id` idempotency, auto-ticket, `worst_criticality` rollup,
   and the `Tower.last_*` cache bump. Reject VT towers (already enforced).
3. **Auth** (the main gap) — the app is anonymous today; wire it to our
   `KeycloakBearerAuthentication` or a checkCred-issued token so the free-text inspector id becomes an
   authenticated `employee_id` and jurisdiction filtering applies. Update the app's `api_service`/login.
4. **Point the app** at our backend (`--dart-define=API_BASE_URL=https://<host>/…/api`) and verify the
   offline outbox drains into our idempotent create; serve `image`/`thumbnail` as absolute URLs
   (consider a thumbnailer like the reference's `generate_thumbnails`).

**Do not** reuse the reference backend code or its legacy `inspections` app — it is the **contract
spec + client**, not a dependency. We own the managed models and migrations.

## Changelog

- **Phase 4 shipped — mobile field app: login, GPS-gated capture, offline-first.**
  Backend (all in `line_inspection`, no new app): `MobileAuthToken` model +
  `MobileTokenAuthentication` (`Token` scheme, ordered first so a bad/revoked/expired
  token returns 401) + `auth/login|logout|me/` (checkCred-verified, Keycloak still
  dormant); the mobile contract endpoints (`ping`, `subdivisions`, `lines/<id>/towers`,
  multipart `line-inspections/` submit, `line-inspections/list`, `line-inspections/<pk>`,
  `dashboard`) + reshaped `catalog` (top-level `version`/`updated_at`/`criticality_rules`
  with `defect_key`, item `group_key`) — reads oversight-scoped, writes still
  `can_edit_tower`; `_create_inspection` unified to resolve item/defect by numeric id OR
  slug key (mobile sends ids), extended with photo write (`photo_key` parts →
  `ItemResult.photo`/`DefectEntry.photo`) and **GPS proof** (`inspector_lat/lng`,
  `gps_accuracy_m`, server-recomputed `gps_distance_m`, `presence_flag`,
  `override_reason`; hard 50 m gate + audited override — GPS-aware submits only, legacy
  JSON path exempt); `/media/` now served + photos returned as absolute URLs. App (edits
  in place to `drone_inspection_app`): real login + token transport on every request
  (401 → re-login), 5-tab shell (Home status map + coverage KPIs, GPS-gated Inspection,
  Tickets, History, Help), a live-GPS near-me tower picker enforcing the 50 m presence
  gate with a reason-required override, GPS carried through the offline outbox to the
  idempotent submit, and a "Download my area" prefetch (lines+towers+catalog+**pinned**
  tiles, excluded from the 160 MB tile LRU) so inspection works with no signal. Migration
  `0008` additive. Verified end-to-end (43 checks) against the real `clear` schema in a
  rolled-back transaction (login/token/revocation, catalog reshape, scope, multipart
  submit + photo + GPS in-range/out-of-range/override/VT-reject/out-of-jurisdiction,
  `client_id` idempotency, list/detail with absolute photo URLs, dashboard, legacy JSON
  path); `flutter analyze` clean.
- **Phase 4 base documented.** Added `transcoapps/Aptransco_TIS-main/` (offline-first Flutter
  `drone_inspection_app` + a reference `aptransco_backend`). Documented that its inspection
  questionnaire is **data-driven from our `/catalog/`**, the full **mobile API contract** the app
  requires (see "Phase 4 — Flutter field app"), and the plan to re-home the reference backend's
  auth-less `managed=False` role onto this authenticated, jurisdiction-scoped, managed app (submit
  = multipart `payload` JSON + `photo_key` file parts, idempotent on `client_id`; main gap = mobile
  auth). Documentation only — no code changes.
- **LILO handling (Super-Admin, coordinate-resilient).** New `LiloEvent` / `LiloTowerRemap` models
  + `services/lilo_matching.py` (`propose_matches` / `apply_reconcile` / `detect_churn`) + a
  Super-Admin LILO screen (`/inspection/admin/lilo/`, `lilo-reconcile`) and CLI
  (`lilo_reconcile`, `detect_tower_churn`). When a line is LILO'd (ArcGIS delete-recreates → its
  `arcgis_object_id`s churn), surviving physical towers are re-identified by **coordinates** (+
  `tower_number`) and **revived in place** — keeping their PK so inspections / schedule / range
  assignments / history persist — while genuine loop towers are created. Matching is auto for
  high-confidence pairs and operator-reviewed otherwise (absorbs road-shift/insertion drift). A
  standalone **churn detector** (Super-Admin home badge + screen + CLI) flags undeclared
  `object_id` churn so history is never silently stranded. The routine `sync_gis_towers` /
  `arcgis_client` path is **unchanged**; migration `0007` is additive. Verified end-to-end (14
  checks): propose classification, history-preserving revive, manual-override drift, loop-as-new,
  audit rows, schedule rebuild, churn flag, and super-admin gating.
- **Tower inspection history.** The Inspections dashboard screen now supports a per-tower history
  view (`?tower=<id>`, oversight-scoped): a tower's inspections newest-first, each expandable into
  its item results + defect entries (criticality, follow-up answers, note, photo) + remarks, with an
  optional `?cycle=` (Ground-Patrol/PMI) filter. The all-towers list gained a defect-count column
  and per-tower links, and the map tower pop-up a "View history" deep-link. **No schema change** —
  it's presentation over the existing `Inspection`/`ItemResult`/`DefectEntry` data.
- **Tower schedule + register completeness + from/to-tower assignment.** New
  `Tower.line_sequence`/`line_offset_m` + `build_tower_schedule` command order towers along
  each line (geometry projection onto `Line.geometry`, numeric `tower_number` fallback for
  branched Tap/LILO lines); `schedule.line_schedule()` reads it. The register now includes
  **all** towers (real + VT, schedule-ordered, VT badged) and sources a VT tower's cells from
  its co-located real tower (`structure_key`) — an inspected structure shows inspected on every
  circuit, and VT-only circuits render. New `LineTowerAssignment` (from-tower → to-tower stretch)
  makes jurisdiction range-aware: `jurisdiction.range_tower_ids()` unions ranges into
  `visible_towers`/`can_edit_tower` and `viewing.oversight_towers`; assigned from the Roles screen
  via a schedule-driven picker (`/admin/line/<id>/schedule/`). Also switched `Line.sap_line` from
  `ForeignKey(unique=True)` to `OneToOneField` (clears the `W342` check warning; semantics
  unchanged). Migration `0006` is additive.
- **Unique `Line.sap_line` (1:1 SAP↔ArcGIS mapping)** — added `unique=True` to the
  `Line.sap_line` FK (migration `0005`, additive) so a SAP line maps to exactly one
  ArcGIS line while the many still-unmapped lines stay `NULL` (Postgres allows multiple
  NULLs under a unique nullable column). Kept the surrogate `id` as the PK rather than
  switching to the SAP id — a PK can't be NULL during the long manual mapping, and a
  mutable natural key would cascade through `Tower.line`/`RoleAssignment.lines`. The
  SAP↔ArcGIS mapping admin view now catches the unique violation and shows a friendly
  message instead of a 500. Pre-checked (0 duplicates among 302 mapped) and verified
  (duplicate rejected, NULLs coexist, remap works) before applying.
- **Data Foundation expansion (virtual towers & tower master)** — `arcgis_client`
  no longer drops `tower_number LIKE 'VT%'`, so the sync imports **virtual (VT)
  towers** (the co-located other-circuit rows). New `Tower` columns promoted from
  the ArcGIS layers (`cp_sp`, `tower_ckts_conductor`, `circuit_type`,
  `circuit_count`, `conductor_type`, `no_of_conductors_per_phase`,
  `relay_setting_length_in_km`, `span_km`, `date_of_commissioning`) plus manual
  `insulator_type`/`type_of_earthing` (empty/absent in GIS; never touched by sync),
  `is_virtual`, and `structure_key`. `sync_gis_towers` strips tower numbers, parses
  the circuit count, and links every co-located real + VT row into one physical
  structure by coordinate proximity (~33 m). `viewing.circuits_at()` +
  `GET /api/towers/<id>/` expose "which circuits run through this tower"; the map
  pop-up lists them. Only real towers are inspected/counted — all existing
  jurisdiction/oversight/map/register/rollup querysets filter `is_virtual=False`
  and `_create_inspection` rejects a VT tower. Migration `0004` is additive-only.
  Verified on live ArcGIS (parser + co-location linking on a real DC corridor) and
  end-to-end in a rolled-back transaction (scopes exclude VT, `circuits_at` returns
  both circuits, VT inspection rejected). Chose ONE indexed Tower table (~113k rows
  incl. VT is small for Postgres) over three voltage tables to keep the
  Inspection/Ticket FKs intact. **Roadmap next:** tower inspection history →
  register completeness → from/to-tower assignment → LILO.
- **Phase 3** — Read-only field-engineer / oversight web dashboard. New
  `viewing.py` oversight scope (reporting-hierarchy walk unioning subordinates'
  RoleAssignments) kept deliberately separate from `jurisdiction.py`'s
  edit/capture scope, so a supervisor's wider *view* never grants *edit* rights;
  `jurisdiction.visible_lines` refactored to share `_lines_for_assignments`, and
  the subtree walk promoted from `admin_views._subordinates` into
  `viewing.subordinate_snapshots`. New `status.py` + denormalized `Tower.last_*`
  cache (maintained in `_create_inspection`, backfilled by `warm_tower_status`)
  and a nullable `Inspection.inspection_type` provision for the twice-yearly
  Ground-Patrol/PMI cycles. New `dashboard_views.py` + templates (Leaflet map with
  line overview / zoom-gated bbox loading / markercluster, tickets, inspections,
  zonal/circle/division rollups) and map API endpoints `/api/map/lines/` &
  `/api/map/towers/`. Also the **line inspection register** (`register.py` +
  `dashboard_register.html`): a per-line item×tower matrix (digital field-register
  replica) with a Latest/Ground-Patrol/PMI cycle filter, Print, and an Excel (.xlsx)
  download via openpyxl (already a dependency) — line access is oversight-scoped.
  Cadre tiers are functional (not grade-based); `emp_sub_grp`
  drives only display labels + the management gate (real codes enumerated from
  live data: AEE=`AAE`/`AE`, DEE=`ADE/AEE`, EE=`DE/EE`, `SE`, management=`CE`/
  `DIRECTOR`/`GM`/`JMD`/`CMD`). Migration `0003` is strictly additive/nullable.
- **Post-Phase-2 pivot** — Keycloak login was blocked on a Keycloak-admin-console
  redirect-URI registration outside our control (confirmed via live diagnostics:
  the realm name `aptransco-realm` the user tried doesn't exist — the real one
  is `APTRANSCO-EMP`; separately, once that was fixed, Keycloak still rejected
  the redirect_uri since it isn't registered on the `clear` client). Deferred
  Keycloak to a later phase and switched the active login mechanism to the
  legacy checkCred/forgotPass/savePass gateway instead — verified end-to-end
  with real test credentials. `keycloak_client.py` is untouched and ready for
  when the redirect URI gets registered.
- **Phase 2** — Standalone service clients (fixed the accidental `gisapp`
  dependency), session-based auth with a three-tier authorization model,
  three admin panel screens, SAP line import + auto-mapping, REST API. Two
  real bugs caught during verification and fixed: (1) the auto-match
  confidence threshold was initially too low (0.5) and produced wrong
  matches for lines sharing only a voltage+circuit-number token, raised to
  0.75; (2) ticket-close/support-request-resolve initially only checked the
  requester's own jurisdiction, which incorrectly locked out Admins acting
  in an oversight capacity over jurisdiction they'd assigned to others.
- **Phase 1** — Initial app: models, ArcGIS sync, SAP cadre sync, checklist
  seed, jurisdiction helper, DB router. See "Current status" above for
  verified counts.
