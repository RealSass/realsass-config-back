# =============================================================================
# Dockerfile — Config Service — MODO DIAGNÓSTICO
# =============================================================================
FROM node:22-alpine AS builder

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma

RUN pnpm install --frozen-lockfile --ignore-scripts

RUN pnpm prisma generate

COPY . .

# Ver tsconfig que está usando
RUN cat tsconfig.json
RUN cat tsconfig.build.json 2>/dev/null || echo "NO HAY tsconfig.build.json"

# Correr nest build con output completo, sin suprimir errores
RUN node node_modules/@nestjs/cli/bin/nest.js build --debug 2>&1; echo "EXIT CODE: $?"

# Ver qué hay en el directorio después del build
RUN ls -la
RUN ls -la dist 2>/dev/null || echo "=== dist NO EXISTE ==="

# Intentar compilar directamente con tsc como diagnóstico
RUN node node_modules/typescript/bin/tsc --version
RUN node node_modules/typescript/bin/tsc -p tsconfig.build.json 2>&1; echo "TSC EXIT: $?"
RUN ls -la dist 2>/dev/null || echo "=== dist SIGUE SIN EXISTIR después de tsc ==="