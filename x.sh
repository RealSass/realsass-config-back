#!/usr/bin/env bash
# =============================================================================
# fix-redis-econnreset.sh
# Corrige RedisService para manejar ECONNRESET gracefully.
#
# Problema: Redis free tier (Railway/Upstash) cierra conexiones idle.
# ioredis emite un evento 'error' sin handler → Node crashea con
# "Unhandled error event".
#
# Solución:
#   - retryStrategy con backoff exponencial → reconecta automáticamente
#   - reconnectOnError → reconecta en ECONNRESET específicamente
#   - handler 'error' explícito → el proceso no crashea por evento no manejado
#   - keepAlive + connectTimeout → evita drops silenciosos
#
# Uso:
#   chmod +x fix-redis-econnreset.sh
#   ./fix-redis-econnreset.sh [ruta/al/repo]
# =============================================================================

set -euo pipefail

REPO_DIR="${1:-.}"
REDIS_SERVICE="$REPO_DIR/src/redis/redis.service.ts"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok()  { echo -e "${GREEN}✓${NC} $1"; }
err() { echo -e "${RED}✗${NC} $1"; exit 1; }

[[ -f "$REDIS_SERVICE" ]] || err "No se encontró $REDIS_SERVICE"

cat > "$REDIS_SERVICE" << 'EOF'
// src/redis/redis.service.ts
//
// Manejo de reconexión para Redis en free tier (Railway / Upstash).
// El proveedor cierra conexiones idle → ioredis emite 'error' con ECONNRESET.
// Sin handler explícito Node trata el evento como unhandled y crashea el proceso.

import { Injectable, OnModuleDestroy, OnModuleInit, Logger } from '@nestjs/common';
import Redis, { type RedisOptions } from 'ioredis';

const REDIS_OPTIONS: RedisOptions = {
  // Reconexión automática con backoff exponencial.
  // retries → número de intentos acumulados desde el último connect exitoso.
  // Tope en 30 s para no saturar en caso de outage prolongado.
  retryStrategy: (retries: number) => {
    if (retries > 20) return null; // detener reconexión tras 20 intentos seguidos
    return Math.min(retries * 200, 30_000);
  },

  // Reconectar específicamente en ECONNRESET (Redis cierra la conexión idle).
  reconnectOnError: (err: Error) => {
    const shouldReconnect =
      err.message.includes('ECONNRESET') ||
      err.message.includes('ETIMEDOUT') ||
      err.message.includes('ECONNREFUSED');
    return shouldReconnect ? 2 : false; // 2 = reconectar Y reenviar el comando pendiente
  },

  lazyConnect:        true,
  maxRetriesPerRequest: 3,
  connectTimeout:     10_000, // 10 s para establecer conexión inicial
  keepAlive:          10_000, // TCP keepalive cada 10 s — previene drops silenciosos
  enableOfflineQueue: true,   // encolar comandos mientras reconecta
};

@Injectable()
export class RedisService extends Redis implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(RedisService.name);

  constructor() {
    super(process.env['REDIS_URL'] ?? 'redis://localhost:6379', REDIS_OPTIONS);

    // Handler explícito: sin esto Node lanza "Unhandled error event" y crashea.
    // El retryStrategy ya gestiona la reconexión — aquí solo logueamos.
    this.on('error', (err: Error) => {
      this.logger.warn(`Redis error: ${err.message}`);
    });

    this.on('reconnecting', (delay: number) => {
      this.logger.log(`Redis reconectando en ${delay}ms...`);
    });

    this.on('connect', () => {
      this.logger.log('Redis conectado');
    });
  }

  async onModuleInit(): Promise<void> {
    await this.connect();
  }

  async onModuleDestroy(): Promise<void> {
    await this.quit();
  }
}
EOF

ok "src/redis/redis.service.ts corregido"
echo ""
echo "Cambios aplicados:"
echo "  + retryStrategy    → backoff exponencial hasta 30s, máx 20 reintentos"
echo "  + reconnectOnError → reconecta en ECONNRESET / ETIMEDOUT / ECONNREFUSED"
echo "  + on('error')      → handler explícito, el proceso ya no crashea"
echo "  + keepAlive        → TCP keepalive cada 10s"
echo "  + connectTimeout   → falla rápido si Redis no responde en 10s"
echo ""