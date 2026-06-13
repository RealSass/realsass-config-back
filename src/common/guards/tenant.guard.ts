import {
  CanActivate, ExecutionContext, ForbiddenException, Injectable, UnauthorizedException,
} from '@nestjs/common';
import { OrganizationsClientService } from '../../organizations-client/organizations-client.service';
import type { TenantContext } from '../types/tenant-context';

/**
 * Resuelve el TenantContext consultando a real-back (organizaciones-back)
 * vía OrganizationsClientService — Opción B del ADR de integración.
 *
 * Reemplaza la versión anterior que consultaba tablas locales
 * `users`/`memberships` (duplicado del template del ecosistema, eliminadas
 * en la migración 20260612120000_decouple_identity_from_real_back).
 */
@Injectable()
export class TenantGuard implements CanActivate {
  constructor(private readonly orgsClient: OrganizationsClientService) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const req            = ctx.switchToHttp().getRequest();
    const user           = req.user as { uid: string } | undefined;
    const organizationId = req.headers['x-organization-id'] as string | undefined;
    const token          = this.extractToken(req);

    if (!organizationId) throw new ForbiddenException('Header x-organization-id requerido');
    if (!user?.uid) throw new UnauthorizedException('Usuario no autenticado');
    if (!token) throw new UnauthorizedException('Token de autenticación requerido');

    const access = await this.orgsClient.getAccess(token, user.uid, organizationId);

    if (!access.canAccess || !access.role || !access.permissions || !access.userId) {
      throw new ForbiddenException(access.reason ?? 'No tenés acceso a esta organización');
    }

    const tenantCtx: TenantContext = {
      userId:         access.userId,
      organizationId,
      role:           access.role,
      permissions:    access.permissions,
    };
    req.tenant = tenantCtx;
    return true;
  }

  private extractToken(req: { headers: Record<string, string | undefined> }): string | undefined {
    const [type, token] = req.headers.authorization?.split(' ') ?? [];
    return type === 'Bearer' ? token : undefined;
  }
}
