#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${1:-.}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${YELLOW}[i]${NC} $1"; }
ok()  { echo -e "${GREEN}[✓]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

cd "$APP_DIR"
FILE="src/config-cache/config-cache.service.ts"
[ -f "$FILE" ] || err "No se encontró $FILE. Corré esto desde la raíz de real-config-back."

log "Reescribiendo $FILE con guard de REDIS_ENABLED..."

cat > "$FILE" << 'EOF'
import { Injectable, Logger } from '@nestjs/common';
import { RedisService } from '../redis/redis.service';

// REDIS_ENABLED=false (o ausente) → cache en modo no-op, siempre cache-miss,
// las lecturas van directo a Postgres vía Prisma. Útil en fase de prueba
// para que Redis nunca reciba un solo comando y no mantenga conexión abierta.
// REDIS_ENABLED=true → comportamiento normal de cache (como hoy).
const REDIS_ENABLED = process.env['REDIS_ENABLED'] === 'true';

@Injectable()
export class ConfigCacheService {
  private readonly logger = new Logger(ConfigCacheService.name);
  private warned = false;

  constructor(private readonly redis: RedisService) {
    if (!REDIS_ENABLED) {
      this.logger.warn(
        'Redis deshabilitado (REDIS_ENABLED != true) — cache en modo no-op, siempre se lee de Postgres',
      );
    }
  }

  private key(orgId: string, tipo: string, k: string): string {
    return `config:${orgId}:${tipo}:${k}`;
  }

  async get<T>(orgId: string, tipo: string, k: string): Promise<T | null> {
    if (!REDIS_ENABLED) return null;

    const raw = await this.redis.get(this.key(orgId, tipo, k));
    return raw ? (JSON.parse(raw) as T) : null;
  }

  async set(orgId: string, tipo: string, k: string, value: unknown, ttl: number): Promise<void> {
    if (!REDIS_ENABLED) return;

    await this.redis.set(this.key(orgId, tipo, k), JSON.stringify(value), 'EX', ttl);
  }

  async del(orgId: string, tipo: string, k?: string): Promise<void> {
    if (!REDIS_ENABLED) return;

    if (k) {
      await this.redis.del(this.key(orgId, tipo, k));
    } else {
      const pattern = `config:${orgId}:${tipo}:*`;
      const keys = await this.redis.keys(pattern);
      if (keys.length) await this.redis.del(...keys);
    }
  }
}
EOF
ok "$FILE reescrito con guard de REDIS_ENABLED"

# ─── Documentar la var en el .env.example si existe ────────────────────────
if [ -f ".env.example" ]; then
  if ! grep -q "^REDIS_ENABLED=" .env.example; then
    log "Agregando REDIS_ENABLED a .env.example..."
    cat >> .env.example << 'EOF'

# ─── Redis (cache de config) ───────────────────────────────────────────────
# REDIS_ENABLED=true  → cache activo (comportamiento normal, requiere Redis).
# REDIS_ENABLED=false (o ausente) → cache en modo no-op, útil en fase de
# prueba para no mantener una conexión persistente a Redis.
REDIS_ENABLED=false
EOF
    ok ".env.example actualizado"
  else
    ok ".env.example ya tenía REDIS_ENABLED"
  fi
else
  echo -e "${YELLOW}[!]${NC} No hay .env.example — agregá REDIS_ENABLED manualmente a tu documentación de vars."
fi

# ─── Validar build ──────────────────────────────────────────────────────────
log "Corriendo build para validar..."
pnpm run build

echo ""
echo -e "${GREEN}✅ ConfigCacheService ahora respeta REDIS_ENABLED${NC}"