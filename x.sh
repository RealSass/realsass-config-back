#!/usr/bin/env bash
# =============================================================================
# fix-redis-no-keepalive.sh
# Saca keepAlive del RedisService para que Railway pueda dormir Redis.
#
# keepAlive manda pings TCP cada N ms — eso cuenta como actividad y
# Railway nunca duerme la instancia.
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

import { Injectable, OnModuleDestroy, OnModuleInit, Logger } from '@nestjs/common';
import Redis, { type RedisOptions } from 'ioredis';

const REDIS_OPTIONS: RedisOptions = {
  // Backoff exponencial: 200ms, 400ms... tope 30s, máx 20 reintentos.
  retryStrategy: (retries: number) => {
    if (retries > 20) return null;
    return Math.min(retries * 200, 30_000);
  },

  // Reconectar en errores de red típicos del free tier.
  reconnectOnError: (err: Error) => {
    const shouldReconnect =
      err.message.includes('ECONNRESET') ||
      err.message.includes('ETIMEDOUT') ||
      err.message.includes('ECONNREFUSED');
    return shouldReconnect ? 2 : false;
  },

  lazyConnect:          true,
  maxRetriesPerRequest: 3,
  connectTimeout:       10_000,
  enableOfflineQueue:   true,
  // keepAlive DESACTIVADO — los pings TCP evitan que Railway duerma Redis.
};

@Injectable()
export class RedisService extends Redis implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(RedisService.name);

  constructor() {
    super(process.env['REDIS_URL'] ?? 'redis://localhost:6379', REDIS_OPTIONS);

    this.on('error',       (err: Error) => this.logger.warn(`Redis error: ${err.message}`));
    this.on('reconnecting',(delay: number) => this.logger.log(`Redis reconectando en ${delay}ms...`));
    this.on('connect',     () => this.logger.log('Redis conectado'));
  }

  async onModuleInit(): Promise<void> {
    await this.connect();
  }

  async onModuleDestroy(): Promise<void> {
    await this.quit();
  }
}
EOF

ok "keepAlive removido — Railway puede dormir Redis cuando esté idle"
echo ""