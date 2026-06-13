#!/usr/bin/env bash
# =============================================================================
# Fix (real-config-back): OrganizationsClientService debe llamar a
#   /api/v1/auth/organization-access (real-back tiene setGlobalPrefix('api/v1')).
#   Esto causaba 503 (ServiceUnavailableException) en /config/flags y /config/quotas.
#
# Ejecutar desde la RAIZ del repo real-config-back.
# =============================================================================
set -euo pipefail

ORG_CLIENT="src/organizations-client/organizations-client.service.ts"

if [ ! -f "$ORG_CLIENT" ]; then
  echo "ERROR: no se encontró $ORG_CLIENT. Corré este script desde la raíz de real-config-back." >&2
  exit 1
fi

if grep -q "ORGANIZATIONS_SERVICE_PREFIX" "$ORG_CLIENT"; then
  echo "  [skip] $ORG_CLIENT ya tiene ORGANIZATIONS_SERVICE_PREFIX aplicado"
elif grep -q '${this.baseUrl}/auth/organization-access' "$ORG_CLIENT"; then
  sed -i 's#${this.baseUrl}/auth/organization-access#${this.baseUrl}${ORGANIZATIONS_SERVICE_PREFIX}/auth/organization-access#' "$ORG_CLIENT"

  perl -0pi -e "s/(const REQUEST_TIMEOUT_MS = 5000;\n)/\$1\n\/\/ real-back tiene setGlobalPrefix('api\/v1') — ver src\/main.ts de real-back.\n\/\/ Configurable por si alguna vez cambia (o se llama a una instancia sin prefijo).\nconst ORGANIZATIONS_SERVICE_PREFIX = process.env['ORGANIZATIONS_SERVICE_PREFIX'] ?? '\/api\/v1';\n/" "$ORG_CLIENT"

  echo "  [ok] $ORG_CLIENT -> ahora llama a \${ORGANIZATIONS_SERVICE_PREFIX}/auth/organization-access (default /api/v1)"
else
  echo "  [warn] no se encontró el patrón esperado en $ORG_CLIENT — revisar manualmente." >&2
  echo "         Buscar la línea con '/auth/organization-access' y prefijarla con /api/v1" >&2
  echo "         (o con la variable de entorno ORGANIZATIONS_SERVICE_PREFIX)." >&2
fi

cat << 'EOF'

==> Pasos manuales pendientes:

  1. Redeployá real-config-back (el fix requiere rebuild).

  2. Confirmá ORGANIZATIONS_SERVICE_URL SIN /api/v1 al final
     (el prefijo ahora lo agrega el código):
       ORGANIZATIONS_SERVICE_URL=https://<real-back>.up.railway.app

  3. Si tu instancia de real-back NO usa /api/v1 como prefijo (poco probable),
     seteá:
       ORGANIZATIONS_SERVICE_PREFIX=    (vacío)

EOF

echo "==> Listo."