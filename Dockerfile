# =============================================================================
# Dockerfile — Config Service
# Stack: NestJS 11 · Prisma 7.8.0 · PostgreSQL · Redis · pnpm · Node 22
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

RUN node node_modules/@nestjs/cli/bin/nest.js build

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

EXPOSE 3001

CMD ["node", "dist/main"]