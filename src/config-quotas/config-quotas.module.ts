import { Module } from '@nestjs/common';
import { ConfigQuotasController } from './config-quotas.controller';
import { ConfigQuotasService } from './config-quotas.service';
import { ConfigCacheModule } from '../config-cache/config-cache.module';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports:     [ConfigCacheModule, ConfigAuditModule],
  controllers: [ConfigQuotasController],
  providers:   [ConfigQuotasService],
  exports:     [ConfigQuotasService],
})
export class ConfigQuotasModule {}
