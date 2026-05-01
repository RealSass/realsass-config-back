import { Injectable } from '@nestjs/common';
import { RedisService } from '../redis/redis.service';

const NEVER_CACHE = Symbol('NEVER');

@Injectable()
export class ConfigCacheService {
  constructor(private readonly redis: RedisService) {}

  private key(orgId: string, tipo: string, k: string): string {
    return `config:${orgId}:${tipo}:${k}`;
  }

  async get<T>(orgId: string, tipo: string, k: string): Promise<T | null> {
    const raw = await this.redis.get(this.key(orgId, tipo, k));
    return raw ? (JSON.parse(raw) as T) : null;
  }

  async set(orgId: string, tipo: string, k: string, value: unknown, ttl: number): Promise<void> {
    await this.redis.set(this.key(orgId, tipo, k), JSON.stringify(value), 'EX', ttl);
  }

  async del(orgId: string, tipo: string, k?: string): Promise<void> {
    if (k) {
      await this.redis.del(this.key(orgId, tipo, k));
    } else {
      const pattern = `config:${orgId}:${tipo}:*`;
      const keys    = await this.redis.keys(pattern);
      if (keys.length) await this.redis.del(...keys);
    }
  }
}
