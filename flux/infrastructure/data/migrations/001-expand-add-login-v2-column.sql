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

-- Backfill: copy existing login_method values into the new column.
-- In production this is critical — without it, existing users with non-default
-- login methods (e.g. 'oauth', 'saml') would revert to 'password' when the
-- feature flag is enabled.
UPDATE users SET login_method_v2 = login_method WHERE login_method IS NOT NULL;

COMMENT ON COLUMN users.login_method_v2 IS
  'New login method field (expand phase). Safe to coexist with login_method.';

COMMIT;
