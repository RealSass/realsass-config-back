import { Processor, WorkerHost } from '@nestjs/bullmq';
import { Logger } from '@nestjs/common';
import { Job } from 'bullmq';
import { PrismaService } from '../prisma/prisma.service';
import { WEBHOOK_QUEUE } from './webhook-delivery.service';
import * as crypto from 'crypto';

const TIMEOUT = Number(process.env['WEBHOOK_DELIVERY_TIMEOUT'] ?? 5000);

@Processor(WEBHOOK_QUEUE)
export class WebhookDeliveryProcessor extends WorkerHost {
  private readonly logger = new Logger(WebhookDeliveryProcessor.name);

  constructor(private readonly prisma: PrismaService) {
    super();
  }

  async process(job: Job): Promise<void> {
    const { webhookId, event, payload, url, secretHash } = job.data;
    const body      = JSON.stringify({ event, payload, timestamp: new Date().toISOString() });
    const signature = 'sha256=' + crypto.createHmac('sha256', secretHash).update(body).digest('hex');
    const start     = Date.now();

    let statusCode: number | null = null;
    let success                   = false;
    let error: string | null      = null;

    try {
      const controller = new AbortController();
      const timeout    = setTimeout(() => controller.abort(), TIMEOUT);

      const res = await fetch(url, {
        method:  'POST',
        headers: {
          'Content-Type':        'application/json',
          'X-Webhook-Signature': signature,
          'X-Webhook-Event':     event,
        },
        body,
        signal: controller.signal,
      });

      clearTimeout(timeout);
      statusCode = res.status;
      success    = res.ok;

      if (!res.ok) throw new Error(`HTTP ${res.status}`);
    } catch (e: any) {
      error = e.message ?? 'Unknown error';
      this.logger.warn(`Webhook ${webhookId} falló (intento ${job.attemptsMade + 1}): ${error}`);
      throw e;
    } finally {
      const duration = Date.now() - start;
      await this.prisma.webhookDeliveryLog.create({
        data: {
          webhookId,
          event,
          statusCode,
          success,
          duration,
          attempt: job.attemptsMade + 1,
          error,
        },
      });

      await this.prisma.webhookEndpoint.update({
        where: { id: webhookId },
        data: {
          lastTriggeredAt: new Date(),
          failureCount:    success ? 0 : { increment: 1 },
        },
      });
    }
  }
}
