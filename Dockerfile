# =============================================================================
# Dockerfile — Config Service
# Stack: NestJS 11 · Prisma 7.8.0 · PostgreSQL · Redis · pnpm · Node 22
# Railway: Release Command → pnpm prisma migrate deploy
# =============================================================================

# ── Etapa 1: build completo ───────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

# --ignore-scripts bypasea ERR_PNPM_IGNORED_BUILDS
RUN pnpm install --frozen-lockfile --ignore-scripts

# Generar cliente Prisma explícitamente (necesario antes del build TS)
RUN pnpm prisma generate

# Copiar el resto del código y compilar
COPY . .
RUN pnpm run build

# Verificar que el build produjo dist/main.js — falla el build si no existe
RUN test -f dist/main.js && echo "✓ dist/main.js existe" || (echo "✗ ERROR: dist/main.js no fue generado" && exit 1)

# ── Etapa 2: runtime ──────────────────────────────────────────────────────────
FROM node:22-alpine AS production

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

RUN pnpm install --frozen-lockfile --ignore-scripts
RUN pnpm prisma generate

# Copiar dist desde builder
COPY --from=builder /app/dist ./dist

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 3001

CMD ["node", "dist/main"]