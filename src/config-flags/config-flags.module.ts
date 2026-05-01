import { Module } from '@nestjs/common';
import { ConfigFlagsController } from './config-flags.controller';
import { ConfigFlagsService } from './config-flags.service';
import { ConfigCacheModule } from '../config-cache/config-cache.module';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports:     [ConfigCacheModule, ConfigAuditModule],
  controllers: [ConfigFlagsController],
  providers:   [ConfigFlagsService],
  exports:     [ConfigFlagsService],
})
export class ConfigFlagsModule {}
