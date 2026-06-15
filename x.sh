#!/usr/bin/env bash
# =============================================================================
# fix-real-config-back.sh
# Soluciona:
#   1. 404 en /api/v1/config/flags  → ruta pública con orgId param
#   2. 503 en Railway               → PORT dinámico + FIREBASE_PRIVATE_KEY
#                                     + health-check endpoint
# Ejecutar desde la raíz del repo real-config-back
# =============================================================================
set -euo pipefail

echo "══════════════════════════════════════════════════════════"
echo "  Fix real-config-back — 404 + 503 en Railway"
echo "══════════════════════════════════════════════════════════"

# ─── 1. main.ts — PORT dinámico (Railway inyecta $PORT) ──────────────────────
echo ""
echo "▶ [1/4] Parcheando src/main.ts — PORT dinámico + health-check route..."

cat > src/main.ts << 'EOF'
import { NestFactory } from '@nestjs/core';
import { ValidationPipe, Logger } from '@nestjs/common';
import { AppModule } from './app.module';
import helmet from 'helmet';

async function bootstrap() {
  const logger = new Logger('Bootstrap');
  const app    = await NestFactory.create(AppModule);

  app.use(helmet());

  // ── Health-check sin auth (Railway lo usa para detectar si el pod está vivo)
  // Registramos ANTES del prefijo global para que quede en GET /health
  const httpAdapter = app.getHttpAdapter();
  httpAdapter.get('/health', (_req: any, res: any) => {
    res.status(200).json({ status: 'ok', service: 'real-config-back' });
  });

  app.useGlobalPipes(
    new ValidationPipe({
      whitelist:            true,
      forbidNonWhitelisted: true,
      transform:            true,
      disableErrorMessages: process.env['NODE_ENV'] === 'production',
    }),
  );

  app.setGlobalPrefix('api/v1');

  // CORS — acepta lista de orígenes separados por coma desde env
  const rawOrigins = process.env['ALLOWED_ORIGINS'] ?? '';
  const origins = rawOrigins
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean);

  app.enableCors({
    // Si no hay origins configurados en env, rechazar todo origen desconocido
    origin: origins.length > 0 ? origins : false,
    methods:     ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'x-organization-id', 'x-api-key'],
    credentials: true,
  });

  // Railway inyecta PORT dinámicamente; NUNCA hardcodear 3001 en prod
  const port = parseInt(process.env['PORT'] ?? '3001', 10);
  await app.listen(port, '0.0.0.0');
  logger.log(`Config Service corriendo en http://0.0.0.0:${port}/api/v1`);
  logger.log(`Health-check disponible en http://0.0.0.0:${port}/health`);
}

bootstrap();
EOF

echo "   ✓ src/main.ts actualizado"

# ─── 2. firebase/firebase.module.ts — PRIVATE_KEY con \\n → \n ───────────────
echo ""
echo "▶ [2/4] Parcheando FirebaseModule para normalizar FIREBASE_PRIVATE_KEY..."

# Buscamos el archivo (puede variar el path exacto)
FIREBASE_MODULE_PATH="src/firebase/firebase.module.ts"

if [ ! -f "$FIREBASE_MODULE_PATH" ]; then
  echo "   ⚠ No encontré $FIREBASE_MODULE_PATH, buscando..."
  FIREBASE_MODULE_PATH=$(find src -name "firebase.module.ts" | head -1)
  echo "   Encontrado en: $FIREBASE_MODULE_PATH"
fi

# Leemos el contenido actual para detectar si ya tiene el replace
if grep -q 'replace' "$FIREBASE_MODULE_PATH" 2>/dev/null; then
  echo "   ℹ FirebaseModule ya parece tener normalización de PRIVATE_KEY, saltando patch."
else
  # Patch: reemplazar la línea que usa FIREBASE_PRIVATE_KEY directamente
  # por una que normalice \\n → \n (Railway escapa las newlines)
  python3 - << 'PYEOF'
import re, sys

path = None
import subprocess
result = subprocess.run(['find', 'src', '-name', 'firebase.module.ts'], capture_output=True, text=True)
path = result.stdout.strip().split('\n')[0]

with open(path, 'r') as f:
    content = f.read()

# Patrón: FIREBASE_PRIVATE_KEY usado directamente sin replace
old1 = "process.env['FIREBASE_PRIVATE_KEY']"
new1 = "(process.env['FIREBASE_PRIVATE_KEY'] ?? '').replace(/\\\\n/g, '\\n')"

old2 = 'process.env["FIREBASE_PRIVATE_KEY"]'
new2 = '(process.env["FIREBASE_PRIVATE_KEY"] ?? "").replace(/\\\\n/g, "\\n")'

changed = False
if old1 in content and 'replace' not in content:
    content = content.replace(old1, new1)
    changed = True
elif old2 in content and 'replace' not in content:
    content = content.replace(old2, new2)
    changed = True

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print(f"   ✓ {path} parcheado — FIREBASE_PRIVATE_KEY normalizado")
else:
    print(f"   ℹ {path} no requirió cambios o patrón no encontrado")
    print("   → Verificar manualmente que FIREBASE_PRIVATE_KEY use .replace(/\\\\n/g, '\\n')")
PYEOF
fi

# ─── 3. config-flags.controller.ts — ruta pública correcta ───────────────────
echo ""
echo "▶ [3/4] Verificando config-flags.controller.ts..."
echo ""
echo "   El endpoint GET /api/v1/config/flags/:orgId ya existe con @Public()."
echo "   El problema más probable del frontend es que llama SIN el parámetro :orgId."
echo ""
echo "   Si el frontend llama a /api/v1/config/flags (sin orgId):"
echo "   → Esa ruta requiere FirebaseAuthGuard + TenantGuard → 401/403, no 404."
echo "   → Railway puede convertir ese 401 en 404 según su proxy config."
echo ""
echo "   Agregando ruta de fallback pública con orgId desde header x-organization-id..."

# Patch para agregar una ruta pública adicional que lee orgId desde query o header
CONTROLLER_PATH="src/config-flags/config-flags.controller.ts"

cat > "$CONTROLLER_PATH" << 'EOF'
import {
  Controller, Get, Patch, Param, Body,
  UseGuards, Query, Headers, NotFoundException,
} from '@nestjs/common';
import { ConfigFlagsService } from './config-flags.service';
import { UpdateFlagDto } from './dto/update-flag.dto';
import { Tenant } from '../common/decorators/tenant.decorator';
import type { TenantContext } from '../common/types/tenant-context';
import { Roles } from '../common/decorators/roles.decorator';
import { TenantGuard } from '../common/guards/tenant.guard';
import { RolesGuard } from '../common/guards/roles.guard';
import { ApiKeyGuard } from '../common/guards/api-key.guard';
import { Public } from '../common/decorators/public.decorator';

@Controller('config/flags')
export class ConfigFlagsController {
  constructor(private readonly svc: ConfigFlagsService) {}

  // ── Ruta autenticada: lista flags del tenant actual (vía FirebaseAuthGuard + TenantGuard)
  @Get()
  @UseGuards(TenantGuard, RolesGuard)
  list(@Tenant() tenant: TenantContext) {
    return this.svc.list(tenant.organizationId);
  }

  // ── Ruta pública por orgId en path (usada por frontends con API key)
  @Public()
  @Get(':orgId')
  @UseGuards(ApiKeyGuard)
  getForOrg(
    @Param('orgId') orgId: string,
    @Query('role')  role?: string,
    @Query('plan')  plan?: string,
  ) {
    return this.svc.getForOrg(orgId, role, plan);
  }

  // ── Ruta pública por orgId en header x-organization-id (para llamadas server-side)
  // Útil cuando el frontend no puede poner orgId en el path
  @Public()
  @Get('public/by-org')
  @UseGuards(ApiKeyGuard)
  getForOrgByHeader(
    @Headers('x-organization-id') orgId: string,
    @Query('role') role?: string,
    @Query('plan') plan?: string,
  ) {
    if (!orgId) throw new NotFoundException('x-organization-id header requerido');
    return this.svc.getForOrg(orgId, role, plan);
  }

  // ── Mutaciones (solo OWNER autenticado)
  @Patch(':id')
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER')
  update(
    @Tenant() tenant: TenantContext,
    @Param('id') id: string,
    @Body() dto: UpdateFlagDto,
  ) {
    return this.svc.update(tenant.organizationId, id, dto);
  }
}
EOF

echo "   ✓ config-flags.controller.ts actualizado con ruta pública by-org"

# ─── 4. Dockerfile — EXPOSE dinámico + healthcheck ───────────────────────────
echo ""
echo "▶ [4/4] Actualizando Dockerfile para Railway..."

cat > Dockerfile << 'EOF'
# =============================================================================
# Dockerfile — Config Service
# Stack: NestJS · Prisma · PostgreSQL · Redis · pnpm · Node 22
# Railway: Release Command → pnpm prisma migrate deploy
# =============================================================================

# ── Etapa 1: build ────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

RUN pnpm install --frozen-lockfile --ignore-scripts

RUN pnpm prisma generate

COPY . .

RUN node node_modules/typescript/bin/tsc -p tsconfig.build.json && \
    echo "=== dist contents ===" && \
    ls -la dist/ || echo "dist/ vacío o no existe"

RUN test -f dist/main.js && echo "✓ dist/main.js ok" || (echo "✗ dist/main.js no existe" && exit 1)

# ── Etapa 2: runtime ──────────────────────────────────────────────────────────
FROM node:22-alpine AS production

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

RUN pnpm install --frozen-lockfile --ignore-scripts
RUN pnpm prisma generate

COPY --from=builder /app/dist ./dist

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

# Railway asigna PORT dinámicamente; no hardcodear
# EXPOSE es solo documentativo para Railway — el valor real viene de $PORT
EXPOSE 3001

# Health-check para que Railway/Docker detecte si el pod está vivo
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://localhost:${PORT:-3001}/health || exit 1

CMD ["node", "dist/main"]
EOF

echo "   ✓ Dockerfile actualizado con HEALTHCHECK"

# ─── Resumen de variables de entorno necesarias en Railway ───────────────────
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Variables de entorno requeridas en Railway"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  Verificar que estas variables estén configuradas en el"
echo "  servicio realsass-config-back en Railway:"
echo ""
echo "  DATABASE_URL          → postgresql://... (Railway Postgres)"
echo "  REDIS_URL             → redis://...      (Railway Redis)"
echo "  FIREBASE_PROJECT_ID   → tu-proyecto-id"
echo "  FIREBASE_CLIENT_EMAIL → firebase-adminsdk@....iam.gserviceaccount.com"
echo "  FIREBASE_PRIVATE_KEY  → -----BEGIN PRIVATE KEY-----\\n..."
echo "                          ⚠ En Railway copiar la key RAW (con saltos reales)"
echo "                            o usar el valor con \\n literales; el código ahora"
echo "                            los normaliza automáticamente."
echo "  ALLOWED_ORIGINS       → https://tu-dashboard-front.up.railway.app,https://tu-otro-front.up.railway.app"
echo "                          (separados por coma, SIN espacios)"
echo "  CONFIG_MASTER_KEY     → clave de 32+ chars para AES-256 (secrets)"
echo "  API_KEY_HASH          → hash sha256 del api key para ApiKeyGuard"
echo ""
echo "  Railway Release Command (en Settings → Deploy):"
echo "  → pnpm prisma migrate deploy"
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Llamadas correctas del frontend"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  ❌ ANTES (causa 404):"
echo "     GET /api/v1/config/flags"
echo "         → ruta autenticada, requiere Bearer token"
echo ""
echo "  ✅ AHORA (opción A — orgId en path + API key):"
echo "     GET /api/v1/config/flags/:orgId"
echo "     Header: x-api-key: <tu-api-key>"
echo ""
echo "  ✅ AHORA (opción B — orgId en header + API key):"
echo "     GET /api/v1/config/flags/public/by-org"
echo "     Header: x-organization-id: <orgId>"
echo "     Header: x-api-key: <tu-api-key>"
echo ""
echo "  ✅ ANTES (si ya tenés token Firebase en el frontend):"
echo "     GET /api/v1/config/flags"
echo "     Header: Authorization: Bearer <firebaseIdToken>"
echo "     Header: x-organization-id: <orgId>"
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Script finalizado. Próximos pasos:"
echo "  1. git add -A && git commit -m 'fix: 404+503 railway config-back'"
echo "  2. git push  → Railway redespliega automáticamente"
echo "  3. Verificar logs en Railway → debe aparecer:"
echo "     'Config Service corriendo en http://0.0.0.0:PORT/api/v1'"
echo "  4. Probar: curl https://realsass-config-back-production.up.railway.app/health"
echo "══════════════════════════════════════════════════════════"