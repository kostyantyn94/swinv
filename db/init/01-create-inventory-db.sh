#!/bin/bash
# Runs once on first Postgres start: creates the separate "inventory" database
# (n8n metadata stays in $POSTGRES_DB). Schema is applied by db/schema.sql (idempotent).
set -e
INV_DB="${INVENTORY_DB:-inventory}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT 'CREATE DATABASE $INV_DB' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$INV_DB')\gexec
EOSQL
if [ -f /db/schema.sql ]; then
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$INV_DB" -f /db/schema.sql
fi
if [ -f /db/seed.sql ]; then
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$INV_DB" -f /db/seed.sql
fi
