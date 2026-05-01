import { CanActivate, ExecutionContext, Injectable, UnauthorizedException } from '@nestjs/common';
import { PrismaService } from '../../prisma/prisma.service';
import { MembershipRole } from '@prisma/client';
import * as bcrypt from 'bcrypt';

const KEY_PREFIX = 'sk_live_';

@Injectable()
export class ApiKeyGuard implements CanActivate {
  constructor(private readonly prisma: PrismaService) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const req    = ctx.switchToHttp().getRequest();
    const rawKey = req.headers['x-api-key'] as string;
    if (!rawKey) return false;

    if (!rawKey.startsWith(KEY_PREFIX)) throw new UnauthorizedException('Formato de API Key inválido');

    const keyPrefix  = rawKey.substring(0, 12);
    const candidates = await this.prisma.apiKey.findMany({
      where: {
        keyPrefix,
        revokedAt: null,
        OR: [{ expiresAt: null }, { expiresAt: { gt: new Date() } }],
      },
      include: { organization: true },
    });

    for (const candidate of candidates) {
      const valid = await bcrypt.compare(rawKey, candidate.keyHash);
      if (valid) {
        void this.prisma.apiKey
          .update({ where: { id: candidate.id }, data: { lastUsedAt: new Date() } })
          .catch(() => null);

        req.tenant = {
          organizationId: candidate.organizationId,
          role:           MembershipRole.MEMBER,
          apiKeyScopes:   candidate.scopes as string[],
          productPermissions: {},
        };
        return true;
      }
    }
    throw new UnauthorizedException('API Key inválida o expirada');
  }
}
