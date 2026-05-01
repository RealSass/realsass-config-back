import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { ConfigCacheService } from '../config-cache/config-cache.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { EventEmitter2 } from '@nestjs/event-emitter';
import { UpdateFlagDto } from './dto/update-flag.dto';

const FLAG_TTL = Number(process.env['CONFIG_CACHE_TTL_FLAGS'] ?? 60);

@Injectable()
export class ConfigFlagsService {
  constructor(
    private readonly prisma:  PrismaService,
    private readonly cache:   ConfigCacheService,
    private readonly audit:   ConfigAuditService,
    private readonly emitter: EventEmitter2,
  ) {}

  async getForOrg(organizationId: string, context?: { role?: string; plan?: string }) {
    const cacheKey = `${organizationId}:all`;
    const cached   = await this.cache.get<any[]>(organizationId, 'flags', 'all');
    if (cached && !context) return { success: true, data: cached };

    const flags = await this.prisma.featureFlag.findMany({
      where: { OR: [{ organizationId }, { organizationId: null }] },
      orderBy: { key: 'asc' },
    });

    const evaluated = flags.filter((f) => {
      if (!f.enabled) return false;
      if (f.rolloutPercentage < 100) {
        const hash = Buffer.from(organizationId).reduce((a, b) => a + b, 0);
        if ((hash % 100) >= f.rolloutPercentage) return false;
      }
      if (context && f.conditions && Object.keys(f.conditions as object).length > 0) {
        const cond = f.conditions as Record<string, string>;
        if (cond.role && context.role !== cond.role) return false;
        if (cond.plan && context.plan !== cond.plan) return false;
      }
      return true;
    });

    await this.cache.set(organizationId, 'flags', 'all', evaluated, FLAG_TTL);
    return { success: true, data: evaluated };
  }

  async list(organizationId: string) {
    const flags = await this.prisma.featureFlag.findMany({
      where:   { OR: [{ organizationId }, { organizationId: null }] },
      orderBy: { key: 'asc' },
    });
    return { success: true, data: flags };
  }

  async update(organizationId: string, userId: string, key: string, dto: UpdateFlagDto) {
    const flag = await this.prisma.featureFlag.findFirst({
      where: { key, organizationId },
    });
    if (!flag) throw new NotFoundException(`Flag "${key}" no encontrado`);

    const prev = { ...flag };
    const updated = await this.prisma.featureFlag.update({
      where: { id: flag.id },
      data:  {
        ...(dto.enabled           !== undefined && { enabled:           dto.enabled }),
        ...(dto.description       !== undefined && { description:       dto.description }),
        ...(dto.rolloutPercentage !== undefined && { rolloutPercentage: dto.rolloutPercentage }),
        ...(dto.conditions        !== undefined && { conditions:        dto.conditions as any }),
      },
    });

    this.audit.log({
      organizationId, userId,
      configType: 'flag', configKey: key, action: 'update',
      diff: { before: prev, after: updated },
    });
    await this.cache.del(organizationId, 'flags');
    this.emitter.emit('config.flag.changed', { organizationId, key, enabled: updated.enabled });

    return { success: true, data: updated };
  }
}
