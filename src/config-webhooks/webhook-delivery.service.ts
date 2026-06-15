import { Injectable, Logger, Optional } from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { OnEvent } from '@nestjs/event-emitter';
import { PrismaService } from '../prisma/prisma.service';
import * as crypto from 'crypto';

export const WEBHOOK_QUEUE = 'webhook-delivery';

const BULL_ENABLED = process.env['BULL_ENABLED'] === 'true';

@Injectable()
export class WebhookDeliveryService {
  private readonly logger = new Logger(WebhookDeliveryService.name);

  constructor(
    private readonly prisma: PrismaService,
    // @Optional() permite que NestJS no falle si la cola no está registrada
    // (cuando BULL_ENABLED=false el BullModule no registra la cola y el
    //  token de inyección no existe — sin @Optional() el módulo no arrancaría)
    @Optional() @InjectQueue(WEBHOOK_QUEUE) private readonly queue: Queue | null,
  ) {
    if (!BULL_ENABLED) {
      this.logger.warn('BullMQ deshabilitado (BULL_ENABLED != true) — webhooks en modo no-op');
    }
  }

  @OnEvent('config.theme.changed')
  @OnEvent('config.flag.changed')
  @OnEvent('config.secret.rotated')
  @OnEvent('quota.exceeded')
  @OnEvent('member.joined')
  @OnEvent('member.removed')
  async onConfigEvent(payload: { organizationId: string; [key: string]: any }) {
    await this.dispatch(payload.organizationId, 'config.changed', payload);
  }

  async dispatch(organizationId: string, event: string, payload: unknown) {
    // Sin BullMQ: no-op — los webhooks se entregarán cuando BULL_ENABLED=true en prod
    if (!BULL_ENABLED || !this.queue) {
      this.logger.debug(`[no-op] Webhook omitido (BULL_ENABLED=false): ${event} para org ${organizationId}`);
      return;
    }

    const webhooks = await this.prisma.webhookEndpoint.findMany({
      where: { organizationId, isActive: true },
    });

    for (const wh of webhooks) {
      const events = wh.events as string[];
      if (!events.includes(event) && !events.includes('*')) continue;

      await this.queue.add(
        'deliver',
        { webhookId: wh.id, event, payload, url: wh.url, secretHash: wh.secretHash },
        {
          attempts:         Number(process.env['WEBHOOK_MAX_RETRIES'] ?? 3),
          backoff:          { type: 'exponential', delay: 1000 },
          removeOnComplete: 100,
          removeOnFail:     200,
        },
      );
    }
  }

  signPayload(secret: string, body: string): string {
    return 'sha256=' + crypto.createHmac('sha256', secret).update(body).digest('hex');
  }
}
