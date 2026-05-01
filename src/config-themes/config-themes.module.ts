import { Module } from '@nestjs/common';
import { ConfigThemesController } from './config-themes.controller';
import { ConfigThemesService } from './config-themes.service';
import { ConfigCacheModule } from '../config-cache/config-cache.module';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports:     [ConfigCacheModule, ConfigAuditModule],
  controllers: [ConfigThemesController],
  providers:   [ConfigThemesService],
  exports:     [ConfigThemesService],
})
export class ConfigThemesModule {}
