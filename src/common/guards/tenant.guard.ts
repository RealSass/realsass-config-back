import {
  CanActivate, ExecutionContext, ForbiddenException, Injectable,
} from '@nestjs/common';
import { PrismaService } from '../../prisma/prisma.service';
import type { TenantContext } from '../types/tenant-context';

@Injectable()
export class TenantGuard implements CanActivate {
  constructor(private readonly prisma: PrismaService) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const req            = ctx.switchToHttp().getRequest();
    const user           = req.user;
    const organizationId = req.headers['x-organization-id'] as string;

    if (!organizationId) throw new ForbiddenException('Header x-organization-id requerido');

    const dbUser = await this.prisma.user.findUnique({ where: { firebaseUid: user.uid } });
    if (!dbUser) throw new ForbiddenException('Usuario no encontrado');

    const membership = await this.prisma.membership.findUnique({
      where: { userId_organizationId: { userId: dbUser.id, organizationId } },
    });
    if (!membership) throw new ForbiddenException('No tenés acceso a esta organización');

    const tenantCtx: TenantContext = {
      userId:             dbUser.id,
      organizationId,
      role:               membership.role,
      productPermissions: (membership.productPermissions as any) ?? {},
    };
    req.tenant = tenantCtx;
    return true;
  }
}
