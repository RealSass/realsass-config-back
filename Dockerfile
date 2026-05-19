# =============================================================================
# Dockerfile — Config Service
# Stack: NestJS 11 · Prisma 7.8.0 · PostgreSQL · Redis · pnpm · Node 22
#
# Solución definitiva para ERR_PNPM_IGNORED_BUILDS:
# --ignore-scripts evita que pnpm bloquee el install por postinstall scripts.
# prisma generate se corre manualmente DESPUÉS del install.
#
# Railway: Release Command → pnpm prisma migrate deploy
# =============================================================================

# ── Etapa 1: deps + prisma generate ──────────────────────────────────────────
FROM node:22-alpine AS deps

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

# --ignore-scripts: pnpm instala todo sin correr ningún postinstall script
# Esto evita ERR_PNPM_IGNORED_BUILDS sin necesitar configuración extra
RUN pnpm install --frozen-lockfile --ignore-scripts

# Con --ignore-scripts prisma no auto-generó el cliente, lo corremos a mano
RUN pnpm prisma generate

# ── Etapa 2: build TypeScript ─────────────────────────────────────────────────
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

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

RUN pnpm install --frozen-lockfile --ignore-scripts

RUN pnpm prisma generate

COPY --from=builder /app/dist ./dist

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 3001

CMD ["node", "dist/main"]