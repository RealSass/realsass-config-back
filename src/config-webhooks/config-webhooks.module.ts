import { Module } from '@nestjs/common';
import { BullModule } from '@nestjs/bullmq';
import { ConfigWebhooksController } from './config-webhooks.controller';
import { ConfigWebhooksService } from './config-webhooks.service';
import { WebhookDeliveryService, WEBHOOK_QUEUE } from './webhook-delivery.service';
import { WebhookDeliveryProcessor } from './webhook-delivery.processor';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports: [
    BullModule.registerQueue({ name: WEBHOOK_QUEUE }),
    ConfigAuditModule,
  ],
  controllers: [ConfigWebhooksController],
  providers:   [ConfigWebhooksService, WebhookDeliveryService, WebhookDeliveryProcessor],
  exports:     [WebhookDeliveryService],
})
export class ConfigWebhooksModule {}
