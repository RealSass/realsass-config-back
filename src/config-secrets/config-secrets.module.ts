import { Module } from '@nestjs/common';
import { ConfigSecretsController } from './config-secrets.controller';
import { ConfigSecretsService } from './config-secrets.service';
import { CryptoService } from './crypto.service';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports:     [ConfigAuditModule],
  controllers: [ConfigSecretsController],
  providers:   [ConfigSecretsService, CryptoService],
  exports:     [ConfigSecretsService, CryptoService],
})
export class ConfigSecretsModule {}
