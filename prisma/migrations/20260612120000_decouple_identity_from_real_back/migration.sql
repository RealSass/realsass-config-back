-- =============================================================================
-- decouple_identity_from_real_back
--
-- real-config-back deja de tener su propia copia de users/organizations/
-- memberships/invitations/affiliate_data/audit_logs (calcada del template
-- del ecosistema). real-back pasa a ser la única fuente de verdad; este
-- servicio resuelve identidad/permisos vía HTTP (GET /auth/organization-access).
--
-- IMPORTANTE: ejecutar contra la base de datos propia de real-config-back.
-- Si esta migración corre sobre una base que NUNCA tuvo estas tablas
-- (porque la migración inicial 20260501005631 no llegó a aplicarse),
-- los DROP fallarán — en ese caso, aplicar solo desde la sección
-- "recrear api_keys sin FK" en adelante, o limpiar manualmente.
-- =============================================================================

-- 1) Quitar FKs hacia organizations/users
ALTER TABLE "memberships"        DROP CONSTRAINT IF EXISTS "memberships_userId_fkey";
ALTER TABLE "memberships"        DROP CONSTRAINT IF EXISTS "memberships_organizationId_fkey";
ALTER TABLE "invitations"        DROP CONSTRAINT IF EXISTS "invitations_organizationId_fkey";
ALTER TABLE "invitations"        DROP CONSTRAINT IF EXISTS "invitations_acceptedByUserId_fkey";
ALTER TABLE "api_keys"           DROP CONSTRAINT IF EXISTS "api_keys_organizationId_fkey";
ALTER TABLE "audit_logs"         DROP CONSTRAINT IF EXISTS "audit_logs_organizationId_fkey";
ALTER TABLE "audit_logs"         DROP CONSTRAINT IF EXISTS "audit_logs_userId_fkey";
ALTER TABLE "affiliate_data"     DROP CONSTRAINT IF EXISTS "affiliate_data_userId_fkey";
ALTER TABLE "theme_configs"      DROP CONSTRAINT IF EXISTS "theme_configs_organizationId_fkey";
ALTER TABLE "secret_configs"     DROP CONSTRAINT IF EXISTS "secret_configs_organizationId_fkey";
ALTER TABLE "feature_flags"      DROP CONSTRAINT IF EXISTS "feature_flags_organizationId_fkey";
ALTER TABLE "content_templates"  DROP CONSTRAINT IF EXISTS "content_templates_organizationId_fkey";
ALTER TABLE "quota_configs"      DROP CONSTRAINT IF EXISTS "quota_configs_organizationId_fkey";
ALTER TABLE "webhook_endpoints"  DROP CONSTRAINT IF EXISTS "webhook_endpoints_organizationId_fkey";
ALTER TABLE "config_audit_logs"  DROP CONSTRAINT IF EXISTS "config_audit_logs_organizationId_fkey";

-- 2) Eliminar tablas de identidad duplicadas (y api_keys vieja, se recrea abajo)
DROP TABLE IF EXISTS "memberships";
DROP TABLE IF EXISTS "invitations";
DROP TABLE IF EXISTS "affiliate_data";
DROP TABLE IF EXISTS "audit_logs";
DROP TABLE IF EXISTS "api_keys";
DROP TABLE IF EXISTS "users";
DROP TABLE IF EXISTS "organizations";

-- 3) Eliminar enums de identidad ya no usados
DROP TYPE IF EXISTS "MembershipRole";
DROP TYPE IF EXISTS "InvitationStatus";
DROP TYPE IF EXISTS "ApiKeyScope";

-- 4) Recrear api_keys sin FK a organizations (organizationId referencia
--    Organization.id en real-back, validado vía API, no vía FK local)
CREATE TABLE "api_keys" (
    "id"             TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "name"           TEXT NOT NULL,
    "keyHash"        TEXT NOT NULL,
    "keyPrefix"      TEXT NOT NULL,
    "scopes"         JSONB NOT NULL DEFAULT '[]',
    "description"    TEXT,
    "lastUsedAt"     TIMESTAMP(3),
    "expiresAt"      TIMESTAMP(3),
    "revokedAt"      TIMESTAMP(3),
    "createdAt"      TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "api_keys_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "api_keys_keyHash_key" ON "api_keys"("keyHash");
CREATE INDEX "api_keys_organizationId_idx" ON "api_keys"("organizationId");
CREATE INDEX "api_keys_keyPrefix_idx" ON "api_keys"("keyPrefix");
