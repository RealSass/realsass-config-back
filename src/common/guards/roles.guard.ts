import {
  CanActivate, ExecutionContext, ForbiddenException, Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { MembershipRole } from '@prisma/client';
import { ROLES_KEY } from '../decorators/roles.decorator';

const HIERARCHY: Record<string, number> = { OWNER: 4, ADMIN: 3, MEMBER: 2, VIEWER: 1 };

@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(ctx: ExecutionContext): boolean {
    const required = this.reflector.getAllAndOverride<MembershipRole[]>(ROLES_KEY, [
      ctx.getHandler(), ctx.getClass(),
    ]);
    if (!required?.length) return true;

    const { tenant } = ctx.switchToHttp().getRequest();
    if (!tenant) throw new ForbiddenException('Tenant context requerido');

    const userLevel = HIERARCHY[tenant.role] ?? 0;
    const minLevel  = Math.min(...required.map((r) => HIERARCHY[r] ?? 0));

    if (userLevel < minLevel) {
      throw new ForbiddenException(
        `Rol requerido: ${required.join(' o ')}. Tu rol: ${tenant.role}`,
      );
    }
    return true;
  }
}
