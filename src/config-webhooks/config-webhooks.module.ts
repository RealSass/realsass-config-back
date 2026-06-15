import { Module } from '@nestjs/common';
import { BullModule } from '@nestjs/bullmq';
import { ConfigWebhooksController }  from './config-webhooks.controller';
import { ConfigWebhooksService }     from './config-webhooks.service';
import { WebhookDeliveryService, WEBHOOK_QUEUE } from './webhook-delivery.service';
import { WebhookDeliveryProcessor }  from './webhook-delivery.processor';
import { ConfigAuditModule }         from '../config-audit/config-audit.module';

const BULL_ENABLED = process.env['BULL_ENABLED'] === 'true';

// Con BULL_ENABLED=false:
//  - No se registra la cola en BullMQ (evita conexión persistente a Redis)
//  - No se registra el processor (no hay worker polling)
//  - WebhookDeliveryService sigue disponible pero despacha en modo no-op
const bullImports  = BULL_ENABLED ? [BullModule.registerQueue({ name: WEBHOOK_QUEUE })] : [];
const bullProviders = BULL_ENABLED ? [WebhookDeliveryProcessor] : [];

@Module({
  imports:     [ConfigAuditModule, ...bullImports],
  controllers: [ConfigWebhooksController],
  providers:   [ConfigWebhooksService, WebhookDeliveryService, ...bullProviders],
  exports:     [WebhookDeliveryService],
})
export class ConfigWebhooksModule {}
