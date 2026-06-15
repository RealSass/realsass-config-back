# =============================================================================
# Dockerfile — Config Service
# Stack: NestJS · Prisma · PostgreSQL · Redis · pnpm · Node 22
# =============================================================================

# ── Etapa 1: builder ──────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

RUN pnpm install --frozen-lockfile --ignore-scripts

RUN pnpm prisma generate

COPY . .

# nest es un shell script — llamarlo directamente, sin "node" adelante
RUN node_modules/.bin/nest build

RUN test -f dist/main.js \
  && echo "✓ dist/main.js ok" \
  || (echo "✗ dist/main.js no existe" && exit 1)

# ── Etapa 2: production ───────────────────────────────────────────────────────
FROM node:22-alpine AS production

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

RUN pnpm install --frozen-lockfile --ignore-scripts --prod

COPY --from=builder /app/node_modules/.prisma        ./node_modules/.prisma
COPY --from=builder /app/node_modules/@prisma/client ./node_modules/@prisma/client

COPY --from=builder /app/dist ./dist

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

RUN chown -R appuser:appgroup /app/node_modules/.prisma \
 && chown -R appuser:appgroup /app/node_modules/@prisma

USER appuser

EXPOSE 3001

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:${PORT:-3001}/health || exit 1

# sh -c es necesario para encadenar comandos con &&
CMD ["sh", "-c", "npx prisma migrate deploy && node dist/main"]