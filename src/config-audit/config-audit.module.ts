import { Module } from '@nestjs/common';
import { ConfigAuditService } from './config-audit.service';
import { ConfigAuditController } from './config-audit.controller';

@Module({
  controllers: [ConfigAuditController],
  providers:   [ConfigAuditService],
  exports:     [ConfigAuditService],
})
export class ConfigAuditModule {}
