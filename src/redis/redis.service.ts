// src/redis/redis.service.ts
//
// Redis en modo lazy: NO conecta al arrancar el módulo.
// La conexión se establece en el primer comando que se ejecute.
//
// Por qué: una conexión persistente activa mantiene despierto tanto
// a Redis como al backend en Railway, impidiendo el sleep automático
// cuando no hay tráfico. En desarrollo esto desperdicia recursos.
//
// En producción (con tráfico real) el comportamiento es idéntico al
// eager connect — la primera request establece la conexión y se mantiene
// por el pool de ioredis.

import { Injectable, OnModuleDestroy, Logger } from '@nestjs/common';
import Redis, { type RedisOptions } from 'ioredis';

const REDIS_OPTIONS: RedisOptions = {
  // Backoff exponencial: 200ms, 400ms... tope 30s, máx 20 reintentos.
  retryStrategy: (retries: number) => {
    if (retries > 20) return null;
    return Math.min(retries * 200, 30_000);
  },

  reconnectOnError: (err: Error) => {
    const shouldReconnect =
      err.message.includes('ECONNRESET') ||
      err.message.includes('ETIMEDOUT') ||
      err.message.includes('ECONNREFUSED');
    return shouldReconnect ? 2 : false;
  },

  // lazyConnect: true → NO conecta hasta el primer comando
  // El onModuleInit ya NO llama a this.connect()
  lazyConnect:          true,
  maxRetriesPerRequest: 3,
  connectTimeout:       10_000,
  enableOfflineQueue:   true,
};

@Injectable()
export class RedisService extends Redis implements OnModuleDestroy {
  private readonly logger = new Logger(RedisService.name);

  constructor() {
    super(process.env['REDIS_URL'] ?? 'redis://localhost:6379', REDIS_OPTIONS);

    this.on('error',        (err: Error)    => this.logger.warn(`Redis error: ${err.message}`));
    this.on('reconnecting', (delay: number) => this.logger.log(`Redis reconectando en ${delay}ms...`));
    this.on('connect',      ()              => this.logger.log('Redis conectado'));
  }

  // onModuleInit eliminado — sin connect() al arrancar → sin conexión persistente
  // ioredis conecta automáticamente en el primer get/set/del

  async onModuleDestroy(): Promise<void> {
    // quit() solo si hay una conexión activa
    if (this.status === 'ready') {
      await this.quit();
    }
  }
}
