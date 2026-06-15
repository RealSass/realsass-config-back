# =============================================================================
# Dockerfile — Config Service
# Stack: NestJS · Prisma · PostgreSQL · Redis · pnpm · Node 22
#
# FLUJO:
#   builder    → instala deps + genera cliente Prisma + compila TS
#   production → copia solo lo necesario, corre migrate deploy al arrancar
#
# Railway: Deploy Command vacío — el CMD ya incluye migrate deploy
# =============================================================================

# ── Etapa 1: builder ──────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

RUN pnpm install --frozen-lockfile --ignore-scripts

# generate corre como root en build → sin problemas de permisos
RUN pnpm prisma generate

COPY . .

# nest build usa tsconfig.build.json (excluye node_modules, dist, tests)
RUN node node_modules/.bin/nest build


# ── Etapa 2: production ───────────────────────────────────────────────────────
FROM node:22-alpine AS production

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

# Solo dependencias de producción
RUN pnpm install --frozen-lockfile --ignore-scripts --prod

# Copiar cliente Prisma generado en builder (evita regenerar como appuser → EACCES)
COPY --from=builder /app/node_modules/.prisma        ./node_modules/.prisma
COPY --from=builder /app/node_modules/@prisma/client ./node_modules/@prisma/client

# Copiar binario compilado
COPY --from=builder /app/dist ./dist

# Usuario sin privilegios para runtime
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Dar ownership a appuser sobre los archivos copiados como root
RUN chown -R appuser:appgroup /app/node_modules/.prisma \
 && chown -R appuser:appgroup /app/node_modules/@prisma

USER appuser

EXPOSE 3001

# migrate deploy aplica migraciones pendientes con la DATABASE_URL del entorno
# NO poner Deploy Command en Railway — este CMD lo maneja todo
CMD ["npx prisma migrate deploy && node dist/src/main"]