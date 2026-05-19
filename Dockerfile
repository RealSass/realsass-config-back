FROM node:22-alpine

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml ./
COPY prisma ./prisma
COPY . .

RUN pnpm install --frozen-lockfile --ignore-scripts

RUN pnpm prisma generate

RUN echo "=== tsconfig.json ===" && cat tsconfig.json
RUN echo "=== tsconfig.build.json ===" && cat tsconfig.build.json 2>/dev/null || echo "NO EXISTE"
RUN echo "=== nest-cli.json ===" && cat nest-cli.json 2>/dev/null || echo "NO EXISTE"

RUN echo "=== CORRIENDO nest build ===" && \
    node node_modules/@nestjs/cli/bin/nest.js build 2>&1; \
    echo "=== EXIT: $? ===" && \
    ls -la dist 2>/dev/null || echo "=== dist NO EXISTE ==="

RUN echo "=== CORRIENDO tsc directo ===" && \
    node node_modules/typescript/bin/tsc -p tsconfig.build.json --listEmittedFiles 2>&1; \
    echo "=== TSC EXIT: $? ==="

RUN ls -la dist 2>/dev/null || echo "dist sigue sin existir"

CMD ["sh", "-c", "echo 'contenedor vivo' && sleep 3600"]