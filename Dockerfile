# =============================================================================
# Dockerfile — Config Service
# Stack: NestJS 11 · Prisma 7.4.2 · PostgreSQL · Redis · pnpm · Node 22
#
# Fix principal: prisma generate debe correr DESPUÉS de pnpm install
# y ANTES de nest build, porque @prisma/client no existe hasta ese momento.
#
# Railway: este Dockerfile reemplaza al railpack automático.
# Variables requeridas en Railway:
#   DATABASE_URL · REDIS_URL · CONFIG_MASTER_KEY
#   FIREBASE_PROJECT_ID · FIREBASE_CLIENT_EMAIL · FIREBASE_PRIVATE_KEY
# =============================================================================

# ── Etapa 1: deps ─────────────────────────────────────────────────────────────
FROM node:22-alpine AS deps

WORKDIR /app

# pnpm via corepack (viene con Node 22)
RUN corepack enable && corepack prepare pnpm@latest --activate

# Copiar manifiestos primero para aprovechar cache de capas
COPY package.json pnpm-lock.yaml ./

# Copiar schema ANTES de install para que prisma postinstall
# no falle si el schema no está presente
COPY prisma ./prisma

# Instalar todas las deps (incluyendo devDeps necesarias para el build)
RUN pnpm install --frozen-lockfile

# Generar el cliente de Prisma — PASO CRÍTICO
# Sin esto @prisma/client está vacío y el build de TS falla con 62 errores
RUN pnpm prisma generate

# ── Etapa 2: build ────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

# Traer deps + cliente generado desde la etapa anterior
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/prisma ./prisma

# Copiar el resto del código fuente
COPY . .

# Compilar TypeScript
RUN pnpm run build

# ── Etapa 3: producción ───────────────────────────────────────────────────────
FROM node:22-alpine AS production

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

# Solo deps de producción
COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma
RUN pnpm install --frozen-lockfile --prod

# Regenerar el cliente en la imagen final (prod no tiene devDeps pero sí prisma CLI)
RUN pnpm prisma generate

# Copiar el build compilado
COPY --from=builder /app/dist ./dist

# Usuario no-root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 3001

# Railway inyecta DATABASE_URL en runtime; migrate deploy antes de levantar
# Si preferís correr las migraciones como Release Command en Railway,
# quitá la línea de migrate y configurá:
#   Release Command: pnpm prisma migrate deploy
CMD ["sh", "-c", "node dist/main"]