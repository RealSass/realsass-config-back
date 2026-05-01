import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { ConfigCacheService } from '../config-cache/config-cache.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { QuotaExceededException } from '../common/exceptions/quota-exceeded.exception';
import { EventEmitter2 } from '@nestjs/event-emitter';

const QUOTA_TTL = Number(process.env['CONFIG_CACHE_TTL_QUOTAS'] ?? 10);

export const DEFAULT_QUOTAS: Record<string, Record<string, number>> = {
  free:       { members: 3,  api_keys: 2,  monthly_api_calls: 1000,  storage_mb: 100,  chat_messages: 100,   ad_campaigns: 1  },
  pro:        { members: 20, api_keys: 10, monthly_api_calls: 50000, storage_mb: 5000, chat_messages: 10000, ad_campaigns: 10 },
  enterprise: { members: -1, api_keys: -1, monthly_api_calls: -1,    storage_mb: -1,   chat_messages: -1,    ad_campaigns: -1 },
};

@Injectable()
export class ConfigQuotasService {
  constructor(
    private readonly prisma:  PrismaService,
    private readonly cache:   ConfigCacheService,
    private readonly audit:   ConfigAuditService,
    private readonly emitter: EventEmitter2,
  ) {}

  async getForOrg(organizationId: string) {
    const quotas = await this.prisma.quotaConfig.findMany({
      where: { organizationId }, orderBy: { resource: 'asc' },
    });
    return { success: true, data: quotas };
  }

  async check(organizationId: string, resource: string) {
    const cacheKey = `${resource}`;
    const cached   = await this.cache.get<any>(organizationId, 'quotas', cacheKey);
    if (cached) {
      if (!cached.allowed) throw new QuotaExceededException(resource, cached.limit, cached.current);
      return cached;
    }

    const quota = await this.prisma.quotaConfig.findUnique({
      where: { organizationId_resource: { organizationId, resource } },
    });

    if (!quota) return { allowed: true, remaining: -1, limit: -1, current: 0 };

    const allowed   = quota.limit === -1 || quota.currentUsage < quota.limit;
    const remaining = quota.limit === -1 ? -1 : quota.limit - quota.currentUsage;
    const result    = { allowed, remaining, limit: quota.limit, current: quota.currentUsage };

    await this.cache.set(organizationId, 'quotas', cacheKey, result, QUOTA_TTL);

    if (!allowed) {
      this.emitter.emit('quota.exceeded', { organizationId, resource, limit: quota.limit });
      throw new QuotaExceededException(resource, quota.limit, quota.currentUsage);
    }

    return { success: true, data: result };
  }

  async increment(organizationId: string, resource: string, delta = 1) {
    await this.prisma.quotaConfig.upsert({
      where:  { organizationId_resource: { organizationId, resource } },
      update: { currentUsage: { increment: delta } },
      create: {
        organizationId, resource,
        limit:        DEFAULT_QUOTAS['free']?.[resource] ?? -1,
        currentUsage: delta,
      },
    });
    await this.cache.del(organizationId, 'quotas', resource);
  }

  async decrement(organizationId: string, resource: string, delta = 1) {
    await this.prisma.quotaConfig.updateMany({
      where: { organizationId, resource, currentUsage: { gt: 0 } },
      data:  { currentUsage: { decrement: delta } },
    });
    await this.cache.del(organizationId, 'quotas', resource);
  }

  async updateLimit(organizationId: string, userId: string, resource: string, limit: number) {
    const prev = await this.prisma.quotaConfig.findUnique({
      where: { organizationId_resource: { organizationId, resource } },
    });

    const updated = await this.prisma.quotaConfig.upsert({
      where:  { organizationId_resource: { organizationId, resource } },
      update: { limit },
      create: { organizationId, resource, limit, currentUsage: 0 },
    });

    this.audit.log({
      organizationId, userId, configType: 'quota', configKey: resource, action: 'update',
      diff: { before: prev?.limit, after: limit },
    });
    await this.cache.del(organizationId, 'quotas', resource);
    return { success: true, data: updated };
  }
}
