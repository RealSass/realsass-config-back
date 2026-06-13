import { CanActivate, ExecutionContext, Injectable, UnauthorizedException } from '@nestjs/common';
import * as bcrypt from 'bcrypt';
import { PrismaService } from '../../prisma/prisma.service';
import { FULL_PERMISSIONS, type TenantContext } from '../types/tenant-context';

const KEY_PREFIX = 'sk_live_';

/**
 * API Keys propias de config-service (scoped a una organizationId de
 * real-back, sin FK local — esa tabla ya no es source-of-truth de orgs).
 * Otorgan acceso de nivel OWNER dentro del scope declarado.
 */
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
    });

    for (const candidate of candidates) {
      const valid = await bcrypt.compare(rawKey, candidate.keyHash);
      if (valid) {
        void this.prisma.apiKey
          .update({ where: { id: candidate.id }, data: { lastUsedAt: new Date() } })
          .catch(() => null);

        const tenantCtx: TenantContext = {
          userId:         `api-key:${candidate.id}`,
          organizationId: candidate.organizationId,
          role:           'OWNER',
          permissions:    FULL_PERMISSIONS,
          apiKeyScopes:   candidate.scopes as string[],
        };
        req.tenant = tenantCtx;
        return true;
      }
    }
    throw new UnauthorizedException('API Key inválida o expirada');
  }
}
