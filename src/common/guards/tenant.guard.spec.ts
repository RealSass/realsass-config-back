import { ForbiddenException, UnauthorizedException } from '@nestjs/common';
import { ExecutionContext } from '@nestjs/common';
import { TenantGuard } from './tenant.guard';
import { OrganizationsClientService } from '../../organizations-client/organizations-client.service';

const ACCESS_OK = {
  canAccess: true,
  userId: 'user-1',
  organizationId: 'org-1',
  role: 'OWNER' as const,
  permissions: {
    canViewListings: true,
    canCreateListings: true,
    canEditListings: true,
    canDeleteListings: true,
    canViewStats: true,
    canManageLeads: true,
    canManageCollaborators: true,
  },
};

function buildContext(req: Record<string, unknown>): ExecutionContext {
  return {
    switchToHttp: () => ({ getRequest: () => req }),
  } as unknown as ExecutionContext;
}

describe('TenantGuard', () => {
  let orgsClient: { getAccess: jest.Mock };
  let guard: TenantGuard;

  beforeEach(() => {
    orgsClient = { getAccess: jest.fn() };
    guard = new TenantGuard(orgsClient as unknown as OrganizationsClientService);
  });

  it('rechaza si falta x-organization-id', async () => {
    const req = { headers: { authorization: 'Bearer token' }, user: { uid: 'uid-1' } };
    await expect(guard.canActivate(buildContext(req))).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('rechaza si falta el token Bearer', async () => {
    const req = { headers: { 'x-organization-id': 'org-1' }, user: { uid: 'uid-1' } };
    await expect(guard.canActivate(buildContext(req))).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('rechaza si OrganizationsClientService dice canAccess=false', async () => {
    orgsClient.getAccess.mockResolvedValue({ canAccess: false, reason: 'No tenés acceso' });
    const req: any = {
      headers: { authorization: 'Bearer token', 'x-organization-id': 'org-1' },
      user: { uid: 'uid-1' },
    };
    await expect(guard.canActivate(buildContext(req))).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('inyecta req.tenant y retorna true si el acceso es válido', async () => {
    orgsClient.getAccess.mockResolvedValue(ACCESS_OK);
    const req: any = {
      headers: { authorization: 'Bearer token', 'x-organization-id': 'org-1' },
      user: { uid: 'uid-1' },
    };

    const result = await guard.canActivate(buildContext(req));

    expect(result).toBe(true);
    expect(req.tenant).toEqual({
      userId: 'user-1',
      organizationId: 'org-1',
      role: 'OWNER',
      permissions: ACCESS_OK.permissions,
    });
    expect(orgsClient.getAccess).toHaveBeenCalledWith('token', 'uid-1', 'org-1');
  });
});
