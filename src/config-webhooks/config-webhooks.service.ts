import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { WebhookDeliveryService } from './webhook-delivery.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { CreateWebhookDto } from './dto/create-webhook.dto';
import * as crypto from 'crypto';
import * as bcrypt from 'bcrypt';

@Injectable()
export class ConfigWebhooksService {
  constructor(
    private readonly prisma:    PrismaService,
    private readonly delivery:  WebhookDeliveryService,
    private readonly audit:     ConfigAuditService,
  ) {}

  async create(organizationId: string, userId: string, dto: CreateWebhookDto) {
    const rawSecret = crypto.randomBytes(32).toString('hex');
    const secretHash = await bcrypt.hash(rawSecret, 10);

    const wh = await this.prisma.webhookEndpoint.create({
      data: {
        organizationId,
        url:          dto.url,
        events:       dto.events,
        secretHash,
        secretPrefix: rawSecret.substring(0, 6),
      },
    });

    this.audit.log({ organizationId, userId, configType: 'webhook', configKey: wh.id, action: 'create' });

    return { success: true, data: { ...wh, secret: rawSecret } };
  }

  async list(organizationId: string) {
    const whs = await this.prisma.webhookEndpoint.findMany({
      where:   { organizationId },
      select:  {
        id: true, url: true, events: true, secretPrefix: true,
        isActive: true, lastTriggeredAt: true, failureCount: true, createdAt: true,
      },
      orderBy: { createdAt: 'desc' },
    });
    return { success: true, data: whs };
  }

  async test(organizationId: string, id: string) {
    const wh = await this.prisma.webhookEndpoint.findFirst({
      where: { id, organizationId },
    });
    if (!wh) throw new NotFoundException('Webhook no encontrado');

    await this.delivery.dispatch(organizationId, 'webhook.test', {
      organizationId,
      message: 'Webhook de prueba — config service',
      timestamp: new Date().toISOString(),
    });

    return { success: true, message: 'Webhook de prueba encolado' };
  }

  async remove(organizationId: string, userId: string, id: string) {
    const wh = await this.prisma.webhookEndpoint.findFirst({
      where: { id, organizationId },
    });
    if (!wh) throw new NotFoundException('Webhook no encontrado');

    await this.prisma.webhookEndpoint.delete({ where: { id } });
    this.audit.log({ organizationId, userId, configType: 'webhook', configKey: id, action: 'delete' });
    return { success: true, message: 'Webhook eliminado' };
  }

  async getLogs(organizationId: string, id: string, take = 50) {
    const wh = await this.prisma.webhookEndpoint.findFirst({
      where: { id, organizationId },
    });
    if (!wh) throw new NotFoundException('Webhook no encontrado');

    const logs = await this.prisma.webhookDeliveryLog.findMany({
      where:   { webhookId: id },
      orderBy: { createdAt: 'desc' },
      take,
    });
    return { success: true, data: logs };
  }
}
