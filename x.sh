#!/usr/bin/env bash
# =============================================================================
# real-config-back — integración con real-back (Opción B)
# Ejecutar desde la RAIZ del repo real-config-back.
# Reemplaza User/Membership/Organization locales por un cliente HTTP hacia
# real-back (GET /auth/organization-access), cacheado en Redis.
# =============================================================================
set -euo pipefail

if [ ! -f "package.json" ] || [ ! -d "src/common/guards" ]; then
  echo "ERROR: corré este script desde la raíz del repo real-config-back." >&2
  exit 1
fi

# =============================================================================
# 2) real-config-back — cliente HTTP a real-back + Redis cache
# =============================================================================

mkdir -p "./src/organizations-client/types"

cat > "./src/organizations-client/types/organization-access.types.ts" << 'EOF'
/**
 * Contrato compartido con real-back (src/users/types/organization-access.types.ts).
 * Si cambia uno, debe actualizarse el otro. Ver nota de ADR en ese archivo.
 */

export type TenantRole = 'OWNER' | 'COLLABORATOR';

export interface CollaboratorPermissions {
  canViewListings: boolean;
  canCreateListings: boolean;
  canEditListings: boolean;
  canDeleteListings: boolean;
  canViewStats: boolean;
  canManageLeads: boolean;
  canManageCollaborators: boolean;
}

export interface OrganizationAccessResult {
  canAccess: boolean;
  userId?: string;
  organizationId?: string;
  role?: TenantRole;
  permissions?: CollaboratorPermissions;
  reason?: string;
}
EOF
echo "  [ok] src/organizations-client/types/organization-access.types.ts"

cat > "./src/organizations-client/organizations-client.service.ts" << 'EOF'
import {
  ForbiddenException,
  Injectable,
  Logger,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { RedisService } from '../redis/redis.service';
import type { OrganizationAccessResult } from './types/organization-access.types';

const CACHE_TTL_SECONDS = Number(process.env['CONFIG_CACHE_TTL_ORG_ACCESS'] ?? 30);
const REQUEST_TIMEOUT_MS = 5000;

/**
 * Cliente HTTP hacia real-back (organizaciones-back).
 *
 * real-back es la única fuente de verdad de usuarios, organizaciones,
 * colaboradores y permisos. Este servicio resuelve `{ role, permissions }`
 * para el par (usuario autenticado, organización activa) consultando
 * GET /auth/organization-access, y cachea el resultado en Redis con TTL
 * corto para no acoplar la latencia de cada request al servicio remoto.
 */
@Injectable()
export class OrganizationsClientService {
  private readonly logger = new Logger(OrganizationsClientService.name);
  private readonly baseUrl: string;

  constructor(private readonly redis: RedisService) {
    this.baseUrl = (process.env['ORGANIZATIONS_SERVICE_URL'] ?? 'http://localhost:3000').replace(/\/+$/, '');
  }

  private cacheKey(firebaseUid: string, organizationId: string): string {
    return `org-access:${firebaseUid}:${organizationId}`;
  }

  /**
   * Resuelve el acceso del usuario autenticado a `organizationId`.
   *
   * @param firebaseToken Token Bearer del usuario (se reenvía a real-back,
   *                       que lo vuelve a validar contra Firebase Admin).
   * @param firebaseUid   UID ya decodificado, usado solo como clave de cache.
   * @param organizationId Organización activa (header x-organization-id).
   *
   * @throws UnauthorizedException si real-back rechaza el token.
   * @throws ServiceUnavailableException si real-back no responde.
   */
  async getAccess(
    firebaseToken: string,
    firebaseUid: string,
    organizationId: string,
  ): Promise<OrganizationAccessResult> {
    const key = this.cacheKey(firebaseUid, organizationId);

    const cached = await this.redis.get(key).catch(() => null);
    if (cached) {
      return JSON.parse(cached) as OrganizationAccessResult;
    }

    const result = await this.fetchFromOrganizationsService(firebaseToken, organizationId);

    // Solo cacheamos resultados positivos: un canAccess=false podría volverse
    // true rápido (ej. acaban de aceptar una invitación) y no queremos que
    // el usuario quede bloqueado por el TTL.
    if (result.canAccess) {
      await this.redis
        .set(key, JSON.stringify(result), 'EX', CACHE_TTL_SECONDS)
        .catch((err: Error) => this.logger.warn(`No se pudo cachear org-access: ${err.message}`));
    }

    return result;
  }

  private async fetchFromOrganizationsService(
    firebaseToken: string,
    organizationId: string,
  ): Promise<OrganizationAccessResult> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

    try {
      const res = await fetch(`${this.baseUrl}/auth/organization-access`, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${firebaseToken}`,
          'x-organization-id': organizationId,
        },
        signal: controller.signal,
      });

      if (res.status === 401) {
        throw new UnauthorizedException('Token inválido o expirado');
      }
      if (res.status === 400) {
        throw new ForbiddenException('Solicitud inválida al resolver acceso a la organización');
      }
      if (!res.ok) {
        throw new ServiceUnavailableException('Servicio de organizaciones no disponible');
      }

      const body = (await res.json()) as { data?: OrganizationAccessResult } & OrganizationAccessResult;
      // organizaciones-back puede envolver la respuesta en { data: ... }; soportamos ambos shapes.
      return body.data ?? body;
    } catch (err) {
      if (err instanceof UnauthorizedException || err instanceof ForbiddenException || err instanceof ServiceUnavailableException) {
        throw err;
      }
      this.logger.error(`Error consultando organizations-service: ${(err as Error).message}`);
      throw new ServiceUnavailableException('Servicio de organizaciones no disponible');
    } finally {
      clearTimeout(timeout);
    }
  }
}
EOF
echo "  [ok] src/organizations-client/organizations-client.service.ts"

cat > "./src/organizations-client/organizations-client.module.ts" << 'EOF'
import { Global, Module } from '@nestjs/common';
import { RedisModule } from '../redis/redis.module';
import { OrganizationsClientService } from './organizations-client.service';

/**
 * Global: TenantGuard y ApiKeyGuard lo consumen vía @UseGuards en cada
 * controller (no son APP_GUARD), por lo que necesitan que el provider
 * esté disponible en cualquier módulo sin importarlo explícitamente.
 */
@Global()
@Module({
  imports: [RedisModule],
  providers: [OrganizationsClientService],
  exports: [OrganizationsClientService],
})
export class OrganizationsClientModule {}
EOF
echo "  [ok] src/organizations-client/organizations-client.module.ts"

cat > "./src/organizations-client/organizations-client.service.spec.ts" << 'EOF'
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
EOF
echo "  [ok] src/organizations-client/organizations-client.service.spec.ts"

# --- app.module.ts: registrar OrganizationsClientModule ----------------------
perl -0pi -e "s/import \{ FirebaseAuthGuard \}    from '.\/common\/guards\/firebase-auth.guard';/import { FirebaseAuthGuard }    from '.\/common\/guards\/firebase-auth.guard';\nimport { OrganizationsClientModule } from '.\/organizations-client\/organizations-client.module';/" \
  "./src/app.module.ts"

perl -0pi -e "s/(    RedisModule,\n)/\$1    OrganizationsClientModule,\n/" \
  "./src/app.module.ts"
echo "  [ok] OrganizationsClientModule registrado en app.module.ts"

# =============================================================================
# 3) real-config-back — TenantContext, decorators y guards
# =============================================================================

mkdir -p "./src/common/types" "./src/common/decorators" "./src/common/guards"

cat > "./src/common/types/tenant-context.ts" << 'EOF'
/**
 * TenantContext — ya NO se resuelve contra una tabla local de Membership.
 * Se obtiene de OrganizationsClientService, que consulta a real-back
 * (única fuente de verdad de usuarios/organizaciones/colaboradores).
 */

export type TenantRole = 'OWNER' | 'COLLABORATOR';

export interface CollaboratorPermissions {
  canViewListings: boolean;
  canCreateListings: boolean;
  canEditListings: boolean;
  canDeleteListings: boolean;
  canViewStats: boolean;
  canManageLeads: boolean;
  canManageCollaborators: boolean;
}

export const FULL_PERMISSIONS: CollaboratorPermissions = {
  canViewListings: true,
  canCreateListings: true,
  canEditListings: true,
  canDeleteListings: true,
  canViewStats: true,
  canManageLeads: true,
  canManageCollaborators: true,
};

export interface TenantContext {
  userId: string;
  organizationId: string;
  role: TenantRole;
  permissions: CollaboratorPermissions;
  apiKeyScopes?: string[];
}
EOF
echo "  [ok] src/common/types/tenant-context.ts (rewrite)"

cat > "./src/common/decorators/roles.decorator.ts" << 'EOF'
import { SetMetadata } from '@nestjs/common';
import type { TenantRole } from '../types/tenant-context';

export const ROLES_KEY = 'roles';
export const Roles = (...roles: TenantRole[]) => SetMetadata(ROLES_KEY, roles);
EOF
echo "  [ok] src/common/decorators/roles.decorator.ts (rewrite)"

cat > "./src/common/guards/roles.guard.ts" << 'EOF'
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
EOF
echo "  [ok] src/common/guards/roles.guard.ts (rewrite)"

cat > "./src/common/guards/tenant.guard.ts" << 'EOF'
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
EOF
echo "  [ok] src/common/guards/tenant.guard.ts (rewrite)"

cat > "./src/common/guards/tenant.guard.spec.ts" << 'EOF'
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
EOF
echo "  [ok] src/common/guards/tenant.guard.spec.ts"

cat > "./src/common/guards/api-key.guard.ts" << 'EOF'
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
EOF
echo "  [ok] src/common/guards/api-key.guard.ts (rewrite)"

# --- @Roles('OWNER', 'ADMIN') -> @Roles('OWNER', 'COLLABORATOR') ------------
# real-back no tiene rol ADMIN; cualquier colaborador con acceso a la org
# pasa este check. Restricciones más finas deben usar tenant.permissions
# (ej. canManageCollaborators) — ver "Riesgos" en la respuesta.
find "./src" -type f -name '*.controller.ts' -print0 \
  | xargs -0 sed -i "s/@Roles('OWNER', 'ADMIN')/@Roles('OWNER', 'COLLABORATOR')/g"
echo "  [ok] @Roles('OWNER','ADMIN') -> @Roles('OWNER','COLLABORATOR') en controllers"

# =============================================================================
# 4) real-config-back — schema.prisma: eliminar User/Org/Membership/etc.
# =============================================================================

cat > "./prisma/schema.prisma" << 'EOF'
// =============================================================================
// schema.prisma — Config Service
// Stack: NestJS 11 · Prisma 7 · PostgreSQL · pnpm
//
// Identidad/organizaciones/membresías YA NO viven acá: real-back
// (organizaciones-back) es la única fuente de verdad. Este servicio solo
// guarda configuración por `organizationId` (string plano, sin FK local),
// resuelta vía OrganizationsClientService -> GET /auth/organization-access.
//
// Después de actualizar este archivo:
//   pnpm prisma migrate dev --name decouple_identity_from_real_back
//   pnpm prisma generate
// =============================================================================

generator client {
  provider   = "prisma-client-js"
  engineType = "client"
}

datasource db {
  provider = "postgresql"
}

// =============================================================================
// MODELOS DEL CONFIG SERVICE
// =============================================================================

// ─── ApiKey ───────────────────────────────────────────────────────────────────
// API Keys propias del Config Service. organizationId referencia el id de
// Organization en real-back (sin FK local).

model ApiKey {
  id             String    @id @default(uuid())
  organizationId String
  name           String
  keyHash        String    @unique
  keyPrefix      String
  scopes         Json      @default("[]")
  description    String?
  lastUsedAt     DateTime?
  expiresAt      DateTime?
  revokedAt      DateTime?
  createdAt      DateTime  @default(now())

  @@index([organizationId])
  @@index([keyPrefix])
  @@map("api_keys")
}

// ─── ThemeConfig ──────────────────────────────────────────────────────────────
// Temas visuales por organización.
// organizationId null → tema del sistema (seeds), copiable por cualquier org.
// Solo un tema puede estar activo por org a la vez (isActive).

model ThemeConfig {
  id              String  @id @default(uuid())
  organizationId  String?

  name            String
  isActive        Boolean @default(false)
  isSystemDefault Boolean @default(false)

  primaryColor   String  @default("#000000")
  secondaryColor String  @default("#ffffff")
  accentColor    String?
  fontFamily     String  @default("DM Sans")
  borderRadius   String  @default("0.75rem")
  logoUrl        String?
  faviconUrl     String?
  darkMode       Boolean @default(false)
  customCSS      String?

  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@unique([organizationId, name])
  @@index([organizationId])
  @@map("theme_configs")
}

// ─── SecretConfig ─────────────────────────────────────────────────────────────
// Secretos cifrados con AES-256-GCM. El valor nunca se devuelve en claro.

model SecretConfig {
  id             String    @id @default(uuid())
  organizationId String

  key            String
  valueEncrypted String
  valueIv        String
  valueTag       String
  keyPrefix      String

  description  String?
  systemTarget String    @default("all")
  isActive     Boolean   @default(true)
  rotatedAt    DateTime?
  expiresAt    DateTime?

  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@unique([organizationId, key])
  @@index([organizationId])
  @@map("secret_configs")
}

// ─── FeatureFlag ──────────────────────────────────────────────────────────────
// Feature flags por organización o globales del sistema.

model FeatureFlag {
  id             String  @id @default(uuid())
  organizationId String?

  key               String
  enabled           Boolean @default(false)
  description       String?
  systemTarget      String  @default("all")
  rolloutPercentage Int     @default(100)
  conditions        Json    @default("{}")

  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@unique([organizationId, key])
  @@index([organizationId])
  @@map("feature_flags")
}

// ─── ContentTemplate ──────────────────────────────────────────────────────────
// Plantillas de contenido con variables {{nombre}}.

model ContentTemplate {
  id             String  @id @default(uuid())
  organizationId String?

  key             String
  name            String
  content         String
  category        String  @default("email")
  systemTarget    String  @default("all")
  isSystemDefault Boolean @default(false)
  variables       Json    @default("[]")

  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@unique([organizationId, key])
  @@index([organizationId])
  @@map("content_templates")
}

// ─── QuotaConfig ──────────────────────────────────────────────────────────────
// Quotas y límites por organización y recurso. limit = -1 → ilimitado.

model QuotaConfig {
  id             String    @id @default(uuid())
  organizationId String

  resource     String
  limit        Int
  currentUsage Int       @default(0)
  alertAt      Int       @default(80)
  resetAt      DateTime?

  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@unique([organizationId, resource])
  @@index([organizationId])
  @@map("quota_configs")
}

// ─── WebhookEndpoint ──────────────────────────────────────────────────────────
// Webhooks outbound configurados por la organización.

model WebhookEndpoint {
  id             String    @id @default(uuid())
  organizationId String

  url          String
  events       Json      @default("[]")
  secretHash   String
  secretPrefix String
  isActive     Boolean   @default(true)
  description  String?

  lastTriggeredAt DateTime?
  failureCount    Int       @default(0)
  retryPolicy     Json      @default("{\"maxAttempts\":3,\"backoffMs\":1000}")

  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  deliveryLogs WebhookDeliveryLog[]

  @@index([organizationId])
  @@map("webhook_endpoints")
}

// ─── WebhookDeliveryLog ───────────────────────────────────────────────────────

model WebhookDeliveryLog {
  id        String @id @default(uuid())
  webhookId String

  event      String
  statusCode Int?
  success    Boolean
  duration   Int?
  attempt    Int     @default(1)
  error      String?

  createdAt DateTime @default(now())

  webhook WebhookEndpoint @relation(fields: [webhookId], references: [id], onDelete: Cascade)

  @@index([webhookId, createdAt])
  @@map("webhook_delivery_logs")
}

// ─── ConfigAuditLog ───────────────────────────────────────────────────────────
// Audit log específico del módulo de configuración.
// userId es el id de usuario en real-back (sin FK local).

model ConfigAuditLog {
  id             String  @id @default(uuid())
  organizationId String?
  userId         String?

  configType String
  configKey  String?
  action     String

  previousValue String?
  newValue      String?
  diff          Json?
  reason        String?
  ipAddress     String?

  createdAt DateTime @default(now())

  @@index([organizationId, createdAt])
  @@index([configType])
  @@map("config_audit_logs")
}
EOF
echo "  [ok] prisma/schema.prisma (rewrite)"

# --- migración: drop FKs + tablas de identidad duplicadas -------------------
MIGRATION_DIR="./prisma/migrations/20260612120000_decouple_identity_from_real_back"
mkdir -p "$MIGRATION_DIR"

cat > "$MIGRATION_DIR/migration.sql" << 'EOF'
-- =============================================================================
-- decouple_identity_from_real_back
--
-- real-config-back deja de tener su propia copia de users/organizations/
-- memberships/invitations/affiliate_data/audit_logs (calcada del template
-- del ecosistema). real-back pasa a ser la única fuente de verdad; este
-- servicio resuelve identidad/permisos vía HTTP (GET /auth/organization-access).
--
-- IMPORTANTE: ejecutar contra la base de datos propia de real-config-back.
-- Si esta migración corre sobre una base que NUNCA tuvo estas tablas
-- (porque la migración inicial 20260501005631 no llegó a aplicarse),
-- los DROP fallarán — en ese caso, aplicar solo desde la sección
-- "recrear api_keys sin FK" en adelante, o limpiar manualmente.
-- =============================================================================

-- 1) Quitar FKs hacia organizations/users
ALTER TABLE "memberships"        DROP CONSTRAINT IF EXISTS "memberships_userId_fkey";
ALTER TABLE "memberships"        DROP CONSTRAINT IF EXISTS "memberships_organizationId_fkey";
ALTER TABLE "invitations"        DROP CONSTRAINT IF EXISTS "invitations_organizationId_fkey";
ALTER TABLE "invitations"        DROP CONSTRAINT IF EXISTS "invitations_acceptedByUserId_fkey";
ALTER TABLE "api_keys"           DROP CONSTRAINT IF EXISTS "api_keys_organizationId_fkey";
ALTER TABLE "audit_logs"         DROP CONSTRAINT IF EXISTS "audit_logs_organizationId_fkey";
ALTER TABLE "audit_logs"         DROP CONSTRAINT IF EXISTS "audit_logs_userId_fkey";
ALTER TABLE "affiliate_data"     DROP CONSTRAINT IF EXISTS "affiliate_data_userId_fkey";
ALTER TABLE "theme_configs"      DROP CONSTRAINT IF EXISTS "theme_configs_organizationId_fkey";
ALTER TABLE "secret_configs"     DROP CONSTRAINT IF EXISTS "secret_configs_organizationId_fkey";
ALTER TABLE "feature_flags"      DROP CONSTRAINT IF EXISTS "feature_flags_organizationId_fkey";
ALTER TABLE "content_templates"  DROP CONSTRAINT IF EXISTS "content_templates_organizationId_fkey";
ALTER TABLE "quota_configs"      DROP CONSTRAINT IF EXISTS "quota_configs_organizationId_fkey";
ALTER TABLE "webhook_endpoints"  DROP CONSTRAINT IF EXISTS "webhook_endpoints_organizationId_fkey";
ALTER TABLE "config_audit_logs"  DROP CONSTRAINT IF EXISTS "config_audit_logs_organizationId_fkey";

-- 2) Eliminar tablas de identidad duplicadas (y api_keys vieja, se recrea abajo)
DROP TABLE IF EXISTS "memberships";
DROP TABLE IF EXISTS "invitations";
DROP TABLE IF EXISTS "affiliate_data";
DROP TABLE IF EXISTS "audit_logs";
DROP TABLE IF EXISTS "api_keys";
DROP TABLE IF EXISTS "users";
DROP TABLE IF EXISTS "organizations";

-- 3) Eliminar enums de identidad ya no usados
DROP TYPE IF EXISTS "MembershipRole";
DROP TYPE IF EXISTS "InvitationStatus";
DROP TYPE IF EXISTS "ApiKeyScope";

-- 4) Recrear api_keys sin FK a organizations (organizationId referencia
--    Organization.id en real-back, validado vía API, no vía FK local)
CREATE TABLE "api_keys" (
    "id"             TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "name"           TEXT NOT NULL,
    "keyHash"        TEXT NOT NULL,
    "keyPrefix"      TEXT NOT NULL,
    "scopes"         JSONB NOT NULL DEFAULT '[]',
    "description"    TEXT,
    "lastUsedAt"     TIMESTAMP(3),
    "expiresAt"      TIMESTAMP(3),
    "revokedAt"      TIMESTAMP(3),
    "createdAt"      TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "api_keys_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "api_keys_keyHash_key" ON "api_keys"("keyHash");
CREATE INDEX "api_keys_organizationId_idx" ON "api_keys"("organizationId");
CREATE INDEX "api_keys_keyPrefix_idx" ON "api_keys"("keyPrefix");
EOF
echo "  [ok] migración 20260612120000_decouple_identity_from_real_back"

# =============================================================================
# 5) Variables de entorno necesarias (informativo)
# =============================================================================
cat << 'EOF'

==> Variables de entorno nuevas requeridas en real-config-back (.env):

  ORGANIZATIONS_SERVICE_URL=http://localhost:3000   # URL base de real-back
  CONFIG_CACHE_TTL_ORG_ACCESS=30                    # TTL (seg) del cache de acceso

==> Pasos manuales pendientes:

  1. En real-config-back:
       pnpm prisma migrate dev   # o `prisma migrate deploy` en CI/CD
       pnpm prisma generate

  2. Verificar que ningún otro archivo de real-config-back referencie
     los modelos eliminados (User, Organization, Membership, Invitation,
     AffiliateData, AuditLog) — ej. seeds (prisma/seed.ts) y
     config-audit.service.ts si hacían joins con `organization`/`user`.

  3. Revisar los controllers donde @Roles('OWNER','ADMIN') quedó como
     @Roles('OWNER','COLLABORATOR') — son checks "cualquier miembro con
     acceso", no granulares. Si alguno necesita restricción real tipo
     "solo admins", usar tenant.permissions.canManageCollaborators.

EOF