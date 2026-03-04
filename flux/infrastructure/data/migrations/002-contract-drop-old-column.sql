-- ╔══════════════════════════════════════════════════════════════════╗
-- ║  WARNING: DESTRUCTIVE MIGRATION — CONTRACT PHASE               ║
-- ║                                                                 ║
-- ║  DO NOT RUN until:                                              ║
-- ║  1. All app instances use login_method_v2 (flag fully enabled)  ║
-- ║  2. Rollback window has passed with stable SLO                  ║
-- ║  3. Backup verified: ScheduledBackup ran after expand phase     ║
-- ║  4. Explicit go/no-go approval documented                       ║
-- ╚══════════════════════════════════════════════════════════════════╝
--
-- Migration 002: CONTRACT — Drop old login_method column
-- Phase: Contract (destructive, NOT backward-compatible)
-- Rollback: Requires point-in-time restore from backup
--
-- Run via: kubectl exec -it app-postgres-1 -n develop -- psql -U app -d app -f -

BEGIN;

-- Rename v2 column to canonical name
ALTER TABLE IF EXISTS users
  RENAME COLUMN login_method_v2 TO login_method_new;

ALTER TABLE IF EXISTS users
  DROP COLUMN IF EXISTS login_method;

ALTER TABLE IF EXISTS users
  RENAME COLUMN login_method_new TO login_method;

COMMIT;
