import { Injectable, Logger } from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { OnEvent } from '@nestjs/event-emitter';
import { PrismaService } from '../prisma/prisma.service';
import * as crypto from 'crypto';

const TIMEOUT = Number(process.env['WEBHOOK_DELIVERY_TIMEOUT'] ?? 5000);

export const WEBHOOK_QUEUE = 'webhook-delivery';

@Injectable()
export class WebhookDeliveryService {
  private readonly logger = new Logger(WebhookDeliveryService.name);

  constructor(
    private readonly prisma: PrismaService,
    @InjectQueue(WEBHOOK_QUEUE) private readonly queue: Queue,
  ) {}

  @OnEvent('config.theme.changed')
  @OnEvent('config.flag.changed')
  @OnEvent('config.secret.rotated')
  @OnEvent('quota.exceeded')
  @OnEvent('member.joined')
  @OnEvent('member.removed')
  async onConfigEvent(payload: { organizationId: string; [key: string]: any }) {
    const eventName = 'config.changed';
    await this.dispatch(payload.organizationId, eventName, payload);
  }

  async dispatch(organizationId: string, event: string, payload: unknown) {
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
          attempts: Number(process.env['WEBHOOK_MAX_RETRIES'] ?? 3),
          backoff:  { type: 'exponential', delay: 1000 },
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
