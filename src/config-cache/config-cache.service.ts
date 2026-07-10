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
