import { Module } from '@nestjs/common';
import { ConfigTemplatesController } from './config-templates.controller';
import { ConfigTemplatesService } from './config-templates.service';
import { ConfigCacheModule } from '../config-cache/config-cache.module';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports:     [ConfigCacheModule, ConfigAuditModule],
  controllers: [ConfigTemplatesController],
  providers:   [ConfigTemplatesService],
  exports:     [ConfigTemplatesService],
})
export class ConfigTemplatesModule {}
