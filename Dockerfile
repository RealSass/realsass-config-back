# =============================================================================
# Dockerfile — real-config-back
# =============================================================================

# ── Etapa 1: deps ─────────────────────────────────────────────────────────────
FROM node:22-alpine AS deps

RUN corepack enable && corepack prepare pnpm@10.11.1 --activate

WORKDIR /app

COPY package.json .npmrc* ./

RUN pnpm install --no-frozen-lockfile

# ── Etapa 2: builder ──────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

RUN corepack enable && corepack prepare pnpm@10.11.1 --activate

WORKDIR /app

ARG DATABASE_URL="postgresql://build:build@localhost:5432/build"
ARG FIREBASE_PROJECT_ID
ARG FIREBASE_CLIENT_EMAIL
ARG FIREBASE_PRIVATE_KEY

ENV DATABASE_URL=$DATABASE_URL
ENV FIREBASE_PROJECT_ID=$FIREBASE_PROJECT_ID
ENV FIREBASE_CLIENT_EMAIL=$FIREBASE_CLIENT_EMAIL
ENV FIREBASE_PRIVATE_KEY=$FIREBASE_PRIVATE_KEY
ENV NODE_ENV=development

COPY --from=deps /app/node_modules ./node_modules
COPY . .

RUN pnpm prisma generate && pnpm run build

# tsconfig: rootDir=./src outDir=./dist → src/main.ts compila a dist/main.js
RUN test -f dist/main.js || (echo "ERROR: dist/main.js no generado" && exit 1)

# ── Etapa 3: runner ───────────────────────────────────────────────────────────
FROM node:22-alpine AS runner

RUN apk add --no-cache dumb-init

WORKDIR /app

ENV NODE_ENV=production

RUN addgroup --system --gid 1001 nodejs && adduser --system --uid 1001 nestjs

COPY --from=builder --chown=nestjs:nodejs /app/dist         ./dist
COPY --from=builder --chown=nestjs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nestjs:nodejs /app/prisma       ./prisma
COPY --from=builder --chown=nestjs:nodejs /app/package.json ./package.json

USER nestjs

EXPOSE 3001
ENV PORT=3001

CMD ["dumb-init", "sh", "-c", "node dist/main"]