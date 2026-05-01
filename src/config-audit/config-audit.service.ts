import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { Prisma } from '@prisma/client';

export interface ConfigAuditParams {
  organizationId?: string;
  userId?:         string;
  configType:      string;
  configKey?:      string;
  action:          string;
  previousValue?:  string;
  newValue?:       string;
  diff?:           Record<string, unknown>;
  reason?:         string;
  ipAddress?:      string;
}

@Injectable()
export class ConfigAuditService {
  private readonly logger = new Logger(ConfigAuditService.name);

  constructor(private readonly prisma: PrismaService) {}

  log(params: ConfigAuditParams): void {
    void this.prisma.configAuditLog
      .create({
        data: {
          organizationId: params.organizationId,
          userId:         params.userId,
          configType:     params.configType,
          configKey:      params.configKey,
          action:         params.action,
          previousValue:  params.previousValue,
          newValue:       params.newValue,
          diff:           params.diff
            ? (params.diff as Prisma.InputJsonValue)
            : Prisma.JsonNull,
          reason:         params.reason,
          ipAddress:      params.ipAddress,
        },
      })
      .catch((err) => this.logger.error('ConfigAuditLog write failed:', err));
  }

  async getByOrg(
    organizationId: string,
    filters: { configType?: string; from?: Date; to?: Date; userId?: string },
    take = 50,
    skip = 0,
  ) {
    const where: Prisma.ConfigAuditLogWhereInput = { organizationId };

    if (filters.configType) where.configType = filters.configType;
    if (filters.userId)     where.userId     = filters.userId;
    if (filters.from || filters.to) {
      where.createdAt = {};
      if (filters.from) where.createdAt.gte = filters.from;
      if (filters.to)   where.createdAt.lte = filters.to;
    }

    const [logs, total] = await Promise.all([
      this.prisma.configAuditLog.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        take,
        skip,
      }),
      this.prisma.configAuditLog.count({ where }),
    ]);

    return { success: true, data: { logs, total, take, skip } };
  }
}