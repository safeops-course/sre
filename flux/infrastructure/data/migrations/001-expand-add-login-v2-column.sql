-- Migration 001: EXPAND — Add login_method_v2 column
-- Phase: Expand (additive, backward-compatible)
-- Rollback: Safe — old app ignores new column, DROP COLUMN reverses this
--
-- This migration adds a new column without removing or renaming existing ones.
-- The old application version continues to work because it never references
-- the new column. The new application version reads login_method_v2 when the
-- feature flag FEATURE_LOGIN_V2 is enabled.
--
-- Run via: kubectl exec -it app-postgres-1 -n develop -- psql -U app -d app -f -

BEGIN;

ALTER TABLE IF EXISTS users
  ADD COLUMN IF NOT EXISTS login_method_v2 VARCHAR(64) DEFAULT 'password';

COMMENT ON COLUMN users.login_method_v2 IS
  'New login method field (expand phase). Safe to coexist with login_method.';

COMMIT;
