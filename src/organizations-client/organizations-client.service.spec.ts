import { ServiceUnavailableException, UnauthorizedException } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { OrganizationsClientService } from './organizations-client.service';
import { RedisService } from '../redis/redis.service';

describe('OrganizationsClientService', () => {
  let service: OrganizationsClientService;
  let redis: { get: jest.Mock; set: jest.Mock };
  let fetchMock: jest.Mock;

  const ACCESS_OK = {
    canAccess: true,
    userId: 'user-1',
    organizationId: 'org-1',
    role: 'OWNER',
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

  beforeEach(async () => {
    redis = { get: jest.fn(), set: jest.fn() };
    fetchMock = jest.fn();
    (global as unknown as { fetch: jest.Mock }).fetch = fetchMock;

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        OrganizationsClientService,
        { provide: RedisService, useValue: redis },
      ],
    }).compile();

    service = module.get(OrganizationsClientService);
  });

  it('devuelve el resultado cacheado sin llamar a fetch', async () => {
    redis.get.mockResolvedValue(JSON.stringify(ACCESS_OK));

    const result = await service.getAccess('token', 'uid-1', 'org-1');

    expect(result).toEqual(ACCESS_OK);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('consulta real-back, cachea y retorna el resultado si canAccess=true', async () => {
    redis.get.mockResolvedValue(null);
    fetchMock.mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ACCESS_OK,
    });

    const result = await service.getAccess('token', 'uid-1', 'org-1');

    expect(result).toEqual(ACCESS_OK);
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('/auth/organization-access'),
      expect.objectContaining({
        headers: expect.objectContaining({
          Authorization: 'Bearer token',
          'x-organization-id': 'org-1',
        }),
      }),
    );
    expect(redis.set).toHaveBeenCalledWith(
      'org-access:uid-1:org-1',
      JSON.stringify(ACCESS_OK),
      'EX',
      expect.any(Number),
    );
  });

  it('no cachea resultados con canAccess=false', async () => {
    redis.get.mockResolvedValue(null);
    const denied = { canAccess: false, reason: 'No tenés acceso a esta organización' };
    fetchMock.mockResolvedValue({ ok: true, status: 200, json: async () => denied });

    const result = await service.getAccess('token', 'uid-1', 'org-1');

    expect(result).toEqual(denied);
    expect(redis.set).not.toHaveBeenCalled();
  });

  it('lanza UnauthorizedException si real-back responde 401', async () => {
    redis.get.mockResolvedValue(null);
    fetchMock.mockResolvedValue({ ok: false, status: 401, json: async () => ({}) });

    await expect(service.getAccess('token', 'uid-1', 'org-1')).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('lanza ServiceUnavailableException si real-back no responde', async () => {
    redis.get.mockResolvedValue(null);
    fetchMock.mockRejectedValue(new Error('network error'));

    await expect(service.getAccess('token', 'uid-1', 'org-1')).rejects.toBeInstanceOf(ServiceUnavailableException);
  });
});
