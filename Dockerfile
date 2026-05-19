# =============================================================================
# Dockerfile — Config Service
# Stack: NestJS 11 · Prisma 7.8.0 · PostgreSQL · Redis · pnpm · Node 22
#
# Fix ERR_PNPM_IGNORED_BUILDS: pnpm bloquea postinstall scripts por defecto.
# El .npmrc con approve-builds resuelve el bloqueo de prisma, bcrypt, etc.
#
# Railway: Release Command → pnpm prisma migrate deploy
# =============================================================================

# ── Etapa 1: deps + prisma generate ──────────────────────────────────────────
FROM node:22-alpine AS deps

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

# .npmrc DEBE copiarse antes de install para que pnpm lo lea
COPY package.json pnpm-lock.yaml .npmrc ./
COPY prisma ./prisma

# install completo (con devDeps) — prisma CLI está en devDependencies
RUN pnpm install --frozen-lockfile

# Generar el cliente de Prisma DESPUÉS del install
RUN pnpm prisma generate

# ── Etapa 2: build ────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY --from=deps /app/node_modules ./node_modules
COPY . .

RUN pnpm run build

# ── Etapa 3: runtime ──────────────────────────────────────────────────────────
FROM node:22-alpine AS production

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml .npmrc ./
COPY prisma ./prisma

# install completo en runtime también (necesitamos prisma client en node_modules)
RUN pnpm install --frozen-lockfile

# Re-generar client en imagen final para asegurar consistencia
RUN pnpm prisma generate

COPY --from=builder /app/dist ./dist

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 3001

CMD ["node", "dist/main"]