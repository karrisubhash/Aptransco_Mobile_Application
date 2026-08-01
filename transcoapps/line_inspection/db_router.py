"""Routes every line_inspection model to its own connection/schema
(line_inspection_db -> the `clear` schema on the shared Postgres server) and
keeps every other app off that connection."""

APP_LABEL = 'line_inspection'
DB_ALIAS = 'line_inspection_db'


class LineInspectionRouter:
    def db_for_read(self, model, **hints):
        if model._meta.app_label == APP_LABEL:
            return DB_ALIAS
        return None

    def db_for_write(self, model, **hints):
        if model._meta.app_label == APP_LABEL:
            return DB_ALIAS
        return None

    def allow_relation(self, obj1, obj2, **hints):
        labels = {obj1._meta.app_label, obj2._meta.app_label}
        if APP_LABEL in labels:
            return labels == {APP_LABEL}
        return None

    def allow_migrate(self, db, app_label, model_name=None, **hints):
        if app_label == APP_LABEL:
            return db == DB_ALIAS
        if db == DB_ALIAS:
            return False
        return None
