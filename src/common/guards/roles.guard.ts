import {
  CanActivate, ExecutionContext, ForbiddenException, Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { TenantContext, TenantRole } from '../types/tenant-context';
import { ROLES_KEY } from '../decorators/roles.decorator';

// real-back solo conoce dos roles: OWNER (dueño de la organización) y
// COLLABORATOR (con permisos granulares vía TenantContext.permissions).
const HIERARCHY: Record<TenantRole, number> = { OWNER: 2, COLLABORATOR: 1 };

@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(ctx: ExecutionContext): boolean {
    const required = this.reflector.getAllAndOverride<TenantRole[]>(ROLES_KEY, [
      ctx.getHandler(), ctx.getClass(),
    ]);
    if (!required?.length) return true;

    const { tenant } = ctx.switchToHttp().getRequest() as { tenant?: TenantContext };
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
