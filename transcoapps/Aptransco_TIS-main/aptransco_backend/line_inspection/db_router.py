class ClearDbRouter:
    """Route the ``line_inspection`` app to the PostgreSQL ``clear`` schema.

    Those tables are owned and migrated by a separate project; here they are
    mapped with ``managed = False`` models. Everything else — the legacy
    ``inspections`` app plus Django's own auth/admin/session tables — stays on
    the ``default`` (SQLite) connection.
    """

    app_label = 'line_inspection'
    db = 'clear_db'

    def db_for_read(self, model, **hints):
        return self.db if model._meta.app_label == self.app_label else None

    def db_for_write(self, model, **hints):
        return self.db if model._meta.app_label == self.app_label else None

    def allow_relation(self, obj1, obj2, **hints):
        labels = {obj1._meta.app_label, obj2._meta.app_label}
        if labels == {self.app_label}:
            return True
        # Don't allow relations that cross the clear-schema boundary.
        if self.app_label in labels:
            return False
        return None

    def allow_migrate(self, db, app_label, model_name=None, **hints):
        # Never migrate the externally-owned clear-schema tables, and keep
        # every other app off the clear_db connection.
        if app_label == self.app_label:
            return False
        if db == self.db:
            return False
        return None
