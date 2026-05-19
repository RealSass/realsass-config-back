# =============================================================================
# Dockerfile — Config Service
# Stack: NestJS 11 · Prisma 7.8.0 · PostgreSQL · Redis · pnpm · Node 22
#
# Fix ERR_PNPM_IGNORED_BUILDS: la lista de builds permitidos va en package.json
# bajo pnpm.onlyBuiltDependencies — pnpm v9 la lee sin ambigüedad.
#
# Railway: Release Command → pnpm prisma migrate deploy
# =============================================================================

# ── Etapa 1: deps + prisma generate ──────────────────────────────────────────
FROM node:22-alpine AS deps

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

# package.json incluye pnpm.onlyBuiltDependencies con la lista de scripts aprobados
COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

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

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

RUN pnpm install --frozen-lockfile

RUN pnpm prisma generate

COPY --from=builder /app/dist ./dist

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 3001

CMD ["node", "dist/main"]