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
