-- migrate:up
-- Unqualified name: the role's search_path (set by provisioning, e.g.
-- `<namespace>, public`) decides the schema, so this migration isn't tied to a
-- specific schema name. The schema itself is provisioned out of band.
CREATE TABLE processed_orders (
    order_id     TEXT PRIMARY KEY,
    item         TEXT NOT NULL,
    quantity     INTEGER NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- migrate:down
DROP TABLE processed_orders;
