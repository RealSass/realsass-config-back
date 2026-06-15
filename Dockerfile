# =============================================================================
# Dockerfile — Config Service
# Stack: NestJS · Prisma · PostgreSQL · Redis · pnpm · Node 22
#
# FLUJO:
#   builder  → instala deps + genera cliente Prisma + compila TS
#   production → copia solo lo necesario, corre migrate deploy al arrancar
#
# Railway Start Command: node dist/main
# (migrate deploy ya está en CMD — no poner nada en Deploy Command de Railway)
# =============================================================================

# ── Etapa 1: builder ──────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

# --ignore-scripts es seguro acá; prisma generate se llama explícitamente
RUN pnpm install --frozen-lockfile --ignore-scripts

# generate corre como root en build → sin problemas de permisos
RUN pnpm prisma generate

COPY . .

# Compilar TypeScript con el compilador local (evita depender de nest CLI global)
RUN node node_modules/.bin/nest build

# Validar que el artefacto existe antes de continuar
RUN test -f dist/main.js && echo "✓ dist/main.js ok" || (echo "✗ dist/main.js no existe" && exit 1)

# ── Etapa 2: production ───────────────────────────────────────────────────────
FROM node:22-alpine AS production

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

# Solo manifiestos para instalar deps de producción
COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

# Instalar SOLO dependencias de producción
RUN pnpm install --frozen-lockfile --ignore-scripts --prod

# Copiar cliente Prisma generado desde el builder (ya compilado, sin regenerar)
# Esto evita correr prisma generate como appuser → EACCES
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder /app/node_modules/@prisma/client ./node_modules/@prisma/client

# Copiar binario compilado
COPY --from=builder /app/dist ./dist

# Usuario sin privilegios para runtime
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# node_modules/.prisma fue copiado como root — dar ownership a appuser
RUN chown -R appuser:appgroup /app/node_modules/.prisma \
 && chown -R appuser:appgroup /app/node_modules/@prisma

USER appuser

# Railway asigna PORT dinámicamente
EXPOSE 3001

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:${PORT:-3001}/health || exit 1

# migrate deploy aplica migraciones pendientes antes de arrancar el servidor.
# Requiere DATABASE_URL en el entorno (seteada en Railway → Variables).
# No requiere prisma generate porque el cliente ya está copiado desde builder.
CMD ["sh", "-c", "npx prisma migrate deploy && node dist/src/main"]