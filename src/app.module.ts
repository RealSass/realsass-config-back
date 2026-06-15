import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { EventEmitterModule } from '@nestjs/event-emitter';
import { BullModule } from '@nestjs/bullmq';

import { FirebaseModule }        from './firebase/firebase.module';
import { PrismaModule }          from './prisma/prisma.module';
import { RedisModule }           from './redis/redis.module';
import { ConfigCacheModule }     from './config-cache/config-cache.module';
import { ConfigAuditModule }     from './config-audit/config-audit.module';
import { ConfigThemesModule }    from './config-themes/config-themes.module';
import { ConfigFlagsModule }     from './config-flags/config-flags.module';
import { ConfigSecretsModule }   from './config-secrets/config-secrets.module';
import { ConfigTemplatesModule } from './config-templates/config-templates.module';
import { ConfigQuotasModule }    from './config-quotas/config-quotas.module';
import { ConfigWebhooksModule }  from './config-webhooks/config-webhooks.module';
import { FirebaseAuthGuard }     from './common/guards/firebase-auth.guard';
import { OrganizationsClientModule } from './organizations-client/organizations-client.module';

// BULL_ENABLED=true  → BullMQ activo, Redis con conexión persistente, worker arranca
// BULL_ENABLED=false (o ausente) → sin worker, Redis solo para cache, puede dormir
const BULL_ENABLED = process.env['BULL_ENABLED'] === 'true';

const bullImports = BULL_ENABLED
  ? [
      BullModule.forRoot({
        connection: { url: process.env['REDIS_URL'] ?? 'redis://localhost:6379' },
      }),
    ]
  : [];

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    ThrottlerModule.forRoot([
      { name: 'short', ttl: 1000,  limit: 15  },
      { name: 'long',  ttl: 60000, limit: 100 },
    ]),
    EventEmitterModule.forRoot({ wildcard: false }),
    ...bullImports,
    FirebaseModule,
    PrismaModule,
    OrganizationsClientModule,
    RedisModule,
    ConfigCacheModule,
    ConfigAuditModule,
    ConfigThemesModule,
    ConfigFlagsModule,
    ConfigSecretsModule,
    ConfigTemplatesModule,
    ConfigQuotasModule,
    ConfigWebhooksModule,
  ],
  providers: [
    { provide: APP_GUARD, useClass: FirebaseAuthGuard },
    { provide: APP_GUARD, useClass: ThrottlerGuard },
  ],
})
export class AppModule {}
