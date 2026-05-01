#!/usr/bin/env bash
# =============================================================================
# CONFIG SERVICE — Setup completo listo para producción
# Stack: NestJS 11 · TypeScript · Prisma 7 · PostgreSQL · Redis · BullMQ · pnpm
#
# PRE-REQUISITOS (hacer ANTES de correr este script):
#   1. Copiar el schema.prisma adjunto a prisma/schema.prisma
#   2. Correr: pnpm prisma migrate dev --name config_module_v1
#   3. Asegurarse de tener .env con todas las variables documentadas abajo
#
# QUÉ HACE ESTE SCRIPT:
#   - Instala todas las dependencias de producción y dev
#   - Crea la estructura completa de src/ con todos los módulos
#   - Reemplaza main.ts y app.module.ts con la versión de producción
#   - Crea el seed de Prisma con temas y plantillas del sistema
#   - Actualiza package.json con el script de seed
#
# VARIABLES DE ENTORNO REQUERIDAS (.env):
#   DATABASE_URL=postgresql://...
#   REDIS_URL=redis://...
#   CONFIG_MASTER_KEY=          # openssl rand -hex 32
#   FIREBASE_PROJECT_ID=
#   FIREBASE_CLIENT_EMAIL=
#   FIREBASE_PRIVATE_KEY=
#   PORT=3001
#   ALLOWED_ORIGINS=http://localhost:3000
#   CONFIG_CACHE_TTL_THEME=300
#   CONFIG_CACHE_TTL_FLAGS=60
#   CONFIG_CACHE_TTL_TEMPLATES=120
#   CONFIG_CACHE_TTL_QUOTAS=10
#   WEBHOOK_DELIVERY_TIMEOUT=5000
#   WEBHOOK_MAX_RETRIES=3
# =============================================================================

set -e
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${BLUE}[→]${NC} $1"; }
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ─── Guardia: verificar que el schema ya fue migrado ──────────────────────────
if [ ! -f "prisma/schema.prisma" ]; then
  err "prisma/schema.prisma no encontrado. Copiá el schema adjunto primero."
fi

# ─── 0. Dependencias ──────────────────────────────────────────────────────────
log "Instalando dependencias de producción..."
pnpm add \
  @nestjs/common@^11.0.1 \
  @nestjs/core@^11.0.1 \
  @nestjs/platform-express@^11.0.1 \
  @nestjs/config@^4.0.3 \
  @nestjs/event-emitter@^3.1.0 \
  @nestjs/bullmq@^11.0.2 \
  @nestjs/throttler@^6.5.0 \
  @prisma/adapter-pg@^7.4.2 \
  @prisma/client@^7.4.2 \
  bullmq@^5.56.0 \
  ioredis@^5.6.1 \
  class-validator@^0.15.1 \
  class-transformer@^0.5.1 \
  helmet@^8.1.0 \
  dotenv@^17.3.1 \
  firebase-admin@^13.7.0 \
  pg@^8.19.0 \
  reflect-metadata@^0.2.2 \
  rxjs@^7.8.1 \
  uuid@^11.1.0

pnpm add -D \
  prisma@^7.4.2 \
  @types/uuid@^11.0.0 \
  @types/node@^22.10.7

ok "Dependencias instaladas"

# ─── 1. Estructura de directorios ─────────────────────────────────────────────
log "Creando estructura de directorios..."
mkdir -p \
  src/prisma \
  src/redis \
  src/firebase \
  src/common/guards \
  src/common/decorators \
  src/common/types \
  src/common/exceptions \
  src/audit \
  src/config-themes/dto \
  src/config-flags/dto \
  src/config-secrets/dto \
  src/config-templates/dto \
  src/config-quotas/dto \
  src/config-webhooks/dto \
  src/config-audit \
  src/config-cache \
  src/webhook-delivery \
  prisma
ok "Directorios creados"

# ─── 2. prisma.config.ts ──────────────────────────────────────────────────────
log "Creando prisma.config.ts..."
cat > prisma.config.ts << 'EOF'
import 'dotenv/config';
import { defineConfig } from 'prisma/config';

export default defineConfig({
  schema: 'prisma/schema.prisma',
  migrations: { path: 'prisma/migrations' },
  datasource: { url: process.env['DATABASE_URL'] },
});
EOF
ok "prisma.config.ts listo"

# ─── 3. PrismaModule ──────────────────────────────────────────────────────────
log "Creando PrismaModule..."
cat > src/prisma/prisma.service.ts << 'EOF'
import { Injectable, OnModuleInit, OnModuleDestroy } from '@nestjs/common';
import { PrismaPg } from '@prisma/adapter-pg';
import { PrismaClient } from '@prisma/client';
import * as pg from 'pg';

@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  constructor() {
    const pool = new pg.Pool({ connectionString: process.env['DATABASE_URL'] });
    const adapter = new PrismaPg(pool);
    super({ adapter });
  }

  async onModuleInit(): Promise<void> {
    await this.$connect();
  }

  async onModuleDestroy(): Promise<void> {
    await this.$disconnect();
  }
}
EOF

cat > src/prisma/prisma.module.ts << 'EOF'
import { Global, Module } from '@nestjs/common';
import { PrismaService } from './prisma.service';

@Global()
@Module({ providers: [PrismaService], exports: [PrismaService] })
export class PrismaModule {}
EOF
ok "PrismaModule listo"

# ─── 4. RedisModule ───────────────────────────────────────────────────────────
log "Creando RedisModule..."
cat > src/redis/redis.service.ts << 'EOF'
import { Injectable, OnModuleDestroy, OnModuleInit, Logger } from '@nestjs/common';
import Redis from 'ioredis';

@Injectable()
export class RedisService extends Redis implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(RedisService.name);

  constructor() {
    super(process.env['REDIS_URL'] ?? 'redis://localhost:6379', {
      maxRetriesPerRequest: 3,
      lazyConnect: true,
    });
  }

  async onModuleInit(): Promise<void> {
    await this.connect();
    this.logger.log('Redis conectado');
  }

  async onModuleDestroy(): Promise<void> {
    await this.quit();
  }
}
EOF

cat > src/redis/redis.module.ts << 'EOF'
import { Global, Module } from '@nestjs/common';
import { RedisService } from './redis.service';

@Global()
@Module({ providers: [RedisService], exports: [RedisService] })
export class RedisModule {}
EOF
ok "RedisModule listo"

# ─── 5. FirebaseModule ────────────────────────────────────────────────────────
log "Creando FirebaseModule..."
cat > src/firebase/firebase.module.ts << 'EOF'
import { Global, Module, OnModuleInit, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import * as admin from 'firebase-admin';

@Global()
@Module({})
export class FirebaseModule implements OnModuleInit {
  private readonly logger = new Logger(FirebaseModule.name);
  constructor(private readonly config: ConfigService) {}

  onModuleInit(): void {
    if (admin.apps.length > 0) return;
    const projectId   = this.config.get<string>('FIREBASE_PROJECT_ID');
    const clientEmail = this.config.get<string>('FIREBASE_CLIENT_EMAIL');
    const privateKey  = this.config.get<string>('FIREBASE_PRIVATE_KEY')?.replace(/\\n/g, '\n');
    if (!projectId) {
      this.logger.warn('FIREBASE_PROJECT_ID no configurado — auth deshabilitado');
      return;
    }
    admin.initializeApp({ credential: admin.credential.cert({ projectId, clientEmail, privateKey }) });
    this.logger.log(`Firebase Admin inicializado: ${projectId}`);
  }
}
EOF
ok "FirebaseModule listo"

# ─── 6. Common: types ─────────────────────────────────────────────────────────
log "Creando tipos compartidos..."
cat > src/common/types/tenant-context.ts << 'EOF'
import type { MembershipRole } from '@prisma/client';

export interface ProductPermissions {
  canRead:  boolean;
  canWrite: boolean;
}

export interface TenantProductPermissions {
  payments?: ProductPermissions;
  chat?:     ProductPermissions;
  ads?:      ProductPermissions;
  [key: string]: ProductPermissions | undefined;
}

export interface TenantContext {
  userId:             string;
  organizationId:     string;
  role:               MembershipRole;
  productPermissions: TenantProductPermissions;
  apiKeyScopes?:      string[];
}
EOF
ok "Tipos creados"

# ─── 7. Common: decorators ────────────────────────────────────────────────────
log "Creando decorators..."
cat > src/common/decorators/current-user.decorator.ts << 'EOF'
import { createParamDecorator, ExecutionContext } from '@nestjs/common';

export interface CurrentUserPayload {
  uid:         string;
  email:       string;
  displayName: string | null;
  avatarUrl:   string | null;
}

export const CurrentUser = createParamDecorator(
  (_: unknown, ctx: ExecutionContext): CurrentUserPayload =>
    ctx.switchToHttp().getRequest().user,
);
EOF

cat > src/common/decorators/tenant.decorator.ts << 'EOF'
import { createParamDecorator, ExecutionContext } from '@nestjs/common';
import type { TenantContext } from '../types/tenant-context';

export const Tenant = createParamDecorator(
  (_: unknown, ctx: ExecutionContext): TenantContext =>
    ctx.switchToHttp().getRequest().tenant,
);
EOF

cat > src/common/decorators/roles.decorator.ts << 'EOF'
import { SetMetadata } from '@nestjs/common';
import type { MembershipRole } from '@prisma/client';

export const ROLES_KEY = 'roles';
export const Roles = (...roles: MembershipRole[]) => SetMetadata(ROLES_KEY, roles);
EOF

cat > src/common/decorators/public.decorator.ts << 'EOF'
import { SetMetadata } from '@nestjs/common';
export const IS_PUBLIC_KEY = 'isPublic';
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);
EOF
ok "Decorators creados"

# ─── 8. Common: guards ────────────────────────────────────────────────────────
log "Creando guards..."
cat > src/common/guards/firebase-auth.guard.ts << 'EOF'
import {
  CanActivate, ExecutionContext, Injectable, UnauthorizedException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import * as admin from 'firebase-admin';
import { IS_PUBLIC_KEY } from '../decorators/public.decorator';

@Injectable()
export class FirebaseAuthGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      ctx.getHandler(), ctx.getClass(),
    ]);
    if (isPublic) return true;

    const req   = ctx.switchToHttp().getRequest();
    const token = this.extractToken(req);
    if (!token) throw new UnauthorizedException('Token de autenticación requerido');

    try {
      const decoded = await admin.app().auth().verifyIdToken(token);
      req.user = {
        uid:         decoded.uid,
        email:       decoded.email ?? '',
        displayName: decoded.name ?? null,
        avatarUrl:   decoded.picture ?? null,
      };
      return true;
    } catch {
      throw new UnauthorizedException('Token inválido o expirado');
    }
  }

  private extractToken(req: any): string | undefined {
    const [type, token] = req.headers.authorization?.split(' ') ?? [];
    return type === 'Bearer' ? token : undefined;
  }
}
EOF

cat > src/common/guards/tenant.guard.ts << 'EOF'
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
EOF

cat > src/common/guards/roles.guard.ts << 'EOF'
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
EOF

cat > src/common/guards/api-key.guard.ts << 'EOF'
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
EOF

cat > src/common/guards/step-up.guard.ts << 'EOF'
import { CanActivate, ExecutionContext, ForbiddenException, Injectable } from '@nestjs/common';
import * as admin from 'firebase-admin';

@Injectable()
export class StepUpGuard implements CanActivate {
  private readonly WINDOW_MS = 5 * 60 * 1000;

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const req   = ctx.switchToHttp().getRequest();
    const token = req.headers.authorization?.split(' ')[1];
    if (!token) throw new ForbiddenException('Token requerido para esta acción');

    const decoded  = await admin.app().auth().verifyIdToken(token);
    const authTime = decoded.auth_time * 1000;

    if (Date.now() - authTime > this.WINDOW_MS) {
      throw new ForbiddenException('Re-autenticación requerida (ventana de 5 minutos)');
    }
    return true;
  }
}
EOF
ok "Guards creados"

# ─── 9. Common: exceptions ────────────────────────────────────────────────────
log "Creando exceptions..."
cat > src/common/exceptions/quota-exceeded.exception.ts << 'EOF'
import { HttpException, HttpStatus } from '@nestjs/common';

export class QuotaExceededException extends HttpException {
  constructor(resource: string, limit: number, current: number) {
    super(
      {
        statusCode: HttpStatus.TOO_MANY_REQUESTS,
        error:      'Quota Exceeded',
        message:    `Límite de ${resource} alcanzado: ${current}/${limit}`,
        resource,
        limit,
        current,
      },
      HttpStatus.TOO_MANY_REQUESTS,
    );
  }
}
EOF
ok "Exceptions creadas"

# ─── 10. ConfigCacheService ───────────────────────────────────────────────────
log "Creando ConfigCacheService..."
cat > src/config-cache/config-cache.service.ts << 'EOF'
import { Injectable } from '@nestjs/common';
import { RedisService } from '../redis/redis.service';

const NEVER_CACHE = Symbol('NEVER');

@Injectable()
export class ConfigCacheService {
  constructor(private readonly redis: RedisService) {}

  private key(orgId: string, tipo: string, k: string): string {
    return `config:${orgId}:${tipo}:${k}`;
  }

  async get<T>(orgId: string, tipo: string, k: string): Promise<T | null> {
    const raw = await this.redis.get(this.key(orgId, tipo, k));
    return raw ? (JSON.parse(raw) as T) : null;
  }

  async set(orgId: string, tipo: string, k: string, value: unknown, ttl: number): Promise<void> {
    await this.redis.set(this.key(orgId, tipo, k), JSON.stringify(value), 'EX', ttl);
  }

  async del(orgId: string, tipo: string, k?: string): Promise<void> {
    if (k) {
      await this.redis.del(this.key(orgId, tipo, k));
    } else {
      const pattern = `config:${orgId}:${tipo}:*`;
      const keys    = await this.redis.keys(pattern);
      if (keys.length) await this.redis.del(...keys);
    }
  }
}
EOF

cat > src/config-cache/config-cache.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { ConfigCacheService } from './config-cache.service';

@Module({ providers: [ConfigCacheService], exports: [ConfigCacheService] })
export class ConfigCacheModule {}
EOF
ok "ConfigCacheService listo"

# ─── 11. AuditModule (config-audit) ──────────────────────────────────────────
log "Creando ConfigAuditService..."
cat > src/config-audit/config-audit.service.ts << 'EOF'
import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';

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
      .create({ data: { ...params, diff: params.diff ?? undefined } })
      .catch((err) => this.logger.error('ConfigAuditLog write failed:', err));
  }

  async getByOrg(
    organizationId: string,
    filters: { configType?: string; from?: Date; to?: Date; userId?: string },
    take = 50,
    skip = 0,
  ) {
    const where: any = { organizationId };
    if (filters.configType) where.configType = filters.configType;
    if (filters.userId)     where.userId     = filters.userId;
    if (filters.from || filters.to) {
      where.createdAt = {};
      if (filters.from) where.createdAt.gte = filters.from;
      if (filters.to)   where.createdAt.lte = filters.to;
    }

    const [logs, total] = await Promise.all([
      this.prisma.configAuditLog.findMany({ where, orderBy: { createdAt: 'desc' }, take, skip }),
      this.prisma.configAuditLog.count({ where }),
    ]);

    return { success: true, data: { logs, total, take, skip } };
  }
}
EOF

cat > src/config-audit/config-audit.controller.ts << 'EOF'
import {
  Controller, Get, Query, ParseIntPipe, DefaultValuePipe, UseGuards,
} from '@nestjs/common';
import { ConfigAuditService } from './config-audit.service';
import { Tenant } from '../common/decorators/tenant.decorator';
import type { TenantContext } from '../common/types/tenant-context';
import { Roles } from '../common/decorators/roles.decorator';
import { TenantGuard } from '../common/guards/tenant.guard';
import { RolesGuard } from '../common/guards/roles.guard';

@Controller('config/audit')
@UseGuards(TenantGuard, RolesGuard)
@Roles('OWNER', 'ADMIN')
export class ConfigAuditController {
  constructor(private readonly svc: ConfigAuditService) {}

  @Get()
  get(
    @Tenant() tenant: TenantContext,
    @Query('configType') configType?: string,
    @Query('from')       from?: string,
    @Query('to')         to?: string,
    @Query('userId')     userId?: string,
    @Query('take', new DefaultValuePipe(50), ParseIntPipe) take?: number,
    @Query('skip', new DefaultValuePipe(0),  ParseIntPipe) skip?: number,
  ) {
    return this.svc.getByOrg(
      tenant.organizationId,
      {
        configType,
        from: from ? new Date(from) : undefined,
        to:   to   ? new Date(to)   : undefined,
        userId,
      },
      take,
      skip,
    );
  }
}
EOF

cat > src/config-audit/config-audit.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { ConfigAuditService } from './config-audit.service';
import { ConfigAuditController } from './config-audit.controller';

@Module({
  controllers: [ConfigAuditController],
  providers:   [ConfigAuditService],
  exports:     [ConfigAuditService],
})
export class ConfigAuditModule {}
EOF
ok "ConfigAuditModule listo"

# ─── 12. CryptoService ────────────────────────────────────────────────────────
log "Creando CryptoService..."
cat > src/config-secrets/crypto.service.ts << 'EOF'
import { Injectable } from '@nestjs/common';
import * as crypto from 'crypto';

const ALGORITHM = 'aes-256-gcm';
const KEY_LEN   = 32;

export interface EncryptedPayload {
  encrypted: string;
  iv:        string;
  tag:       string;
  prefix:    string;
}

@Injectable()
export class CryptoService {
  private masterKey(): Buffer {
    const hex = process.env['CONFIG_MASTER_KEY'];
    if (!hex || hex.length !== 64) {
      throw new Error('CONFIG_MASTER_KEY debe ser 32 bytes en hex (64 chars)');
    }
    return Buffer.from(hex, 'hex');
  }

  encrypt(plaintext: string): EncryptedPayload {
    const key  = this.masterKey();
    const iv   = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv(ALGORITHM, key, iv);
    const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();

    return {
      encrypted: encrypted.toString('base64'),
      iv:        iv.toString('base64'),
      tag:       tag.toString('base64'),
      prefix:    plaintext.substring(0, 4),
    };
  }

  decrypt(encryptedB64: string, ivB64: string, tagB64: string): string {
    const key       = this.masterKey();
    const iv        = Buffer.from(ivB64, 'base64');
    const tag       = Buffer.from(tagB64, 'base64');
    const encrypted = Buffer.from(encryptedB64, 'base64');
    const decipher  = crypto.createDecipheriv(ALGORITHM, key, iv);
    decipher.setAuthTag(tag);
    return decipher.update(encrypted) + decipher.final('utf8');
  }
}
EOF
ok "CryptoService listo"

# ─── 13. ConfigThemes ─────────────────────────────────────────────────────────
log "Creando módulo de temas..."

cat > src/config-themes/dto/create-theme.dto.ts << 'EOF'
import {
  IsString, IsOptional, IsBoolean, MaxLength, IsHexColor,
} from 'class-validator';

export class CreateThemeDto {
  @IsString() @MaxLength(80)
  name: string;

  @IsHexColor() @IsOptional()
  primaryColor?: string;

  @IsHexColor() @IsOptional()
  secondaryColor?: string;

  @IsHexColor() @IsOptional()
  accentColor?: string;

  @IsString() @IsOptional() @MaxLength(80)
  fontFamily?: string;

  @IsString() @IsOptional() @MaxLength(20)
  borderRadius?: string;

  @IsString() @IsOptional()
  logoUrl?: string;

  @IsString() @IsOptional()
  faviconUrl?: string;

  @IsBoolean() @IsOptional()
  darkMode?: boolean;

  @IsString() @IsOptional()
  customCSS?: string;
}
EOF

cat > src/config-themes/config-themes.service.ts << 'EOF'
import {
  Injectable, NotFoundException, ConflictException, ForbiddenException,
} from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { ConfigCacheService } from '../config-cache/config-cache.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { EventEmitter2 } from '@nestjs/event-emitter';
import { CreateThemeDto } from './dto/create-theme.dto';

const THEME_TTL = Number(process.env['CONFIG_CACHE_TTL_THEME'] ?? 300);

@Injectable()
export class ConfigThemesService {
  constructor(
    private readonly prisma:  PrismaService,
    private readonly cache:   ConfigCacheService,
    private readonly audit:   ConfigAuditService,
    private readonly emitter: EventEmitter2,
  ) {}

  async getPublicTheme(orgSlug: string) {
    const cached = await this.cache.get<any>('__public__', 'theme', orgSlug);
    if (cached) return { success: true, data: cached };

    const org = await this.prisma.organization.findUnique({ where: { slug: orgSlug } });
    if (!org) throw new NotFoundException('Organización no encontrada');

    let theme = await this.prisma.themeConfig.findFirst({
      where: { organizationId: org.id, isActive: true },
    });

    if (!theme) {
      theme = await this.prisma.themeConfig.findFirst({
        where: { isSystemDefault: true, name: 'Default' },
      });
    }

    await this.cache.set('__public__', 'theme', orgSlug, theme, THEME_TTL);
    return { success: true, data: theme };
  }

  async list(organizationId: string) {
    const themes = await this.prisma.themeConfig.findMany({
      where:   { OR: [{ organizationId }, { isSystemDefault: true }] },
      orderBy: { createdAt: 'asc' },
    });
    return { success: true, data: themes };
  }

  async create(organizationId: string, userId: string, dto: CreateThemeDto) {
    const exists = await this.prisma.themeConfig.findUnique({
      where: { organizationId_name: { organizationId, name: dto.name } },
    });
    if (exists) throw new ConflictException(`Ya existe un tema llamado "${dto.name}"`);

    const theme = await this.prisma.themeConfig.create({
      data: { organizationId, ...dto },
    });

    this.audit.log({ organizationId, userId, configType: 'theme', configKey: theme.id, action: 'create' });
    await this.cache.del('__public__', 'theme');
    return { success: true, data: theme };
  }

  async activate(organizationId: string, userId: string, id: string) {
    const theme = await this.prisma.themeConfig.findFirst({
      where: { id, OR: [{ organizationId }, { isSystemDefault: true }] },
    });
    if (!theme) throw new NotFoundException('Tema no encontrado');

    await this.prisma.$transaction([
      this.prisma.themeConfig.updateMany({
        where: { organizationId }, data: { isActive: false },
      }),
      this.prisma.themeConfig.update({
        where: { id }, data: { isActive: true },
      }),
    ]);

    this.audit.log({ organizationId, userId, configType: 'theme', configKey: id, action: 'activate' });
    await this.cache.del('__public__', 'theme');
    await this.cache.del(organizationId, 'theme');
    this.emitter.emit('config.theme.changed', { organizationId, themeId: id });

    return { success: true, message: 'Tema activado' };
  }

  async remove(organizationId: string, userId: string, id: string) {
    const theme = await this.prisma.themeConfig.findFirst({
      where: { id, organizationId },
    });
    if (!theme) throw new NotFoundException('Tema no encontrado');
    if (theme.isSystemDefault) throw new ForbiddenException('No se puede eliminar un tema del sistema');
    if (theme.isActive) throw new ForbiddenException('Desactivá el tema antes de eliminarlo');

    await this.prisma.themeConfig.delete({ where: { id } });
    this.audit.log({ organizationId, userId, configType: 'theme', configKey: id, action: 'delete' });
    await this.cache.del('__public__', 'theme');
    return { success: true, message: 'Tema eliminado' };
  }
}
EOF

cat > src/config-themes/config-themes.controller.ts << 'EOF'
import {
  Controller, Get, Post, Patch, Delete,
  Param, Body, UseGuards, HttpCode, HttpStatus,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { ConfigThemesService } from './config-themes.service';
import { CreateThemeDto } from './dto/create-theme.dto';
import { Tenant } from '../common/decorators/tenant.decorator';
import type { TenantContext } from '../common/types/tenant-context';
import { Roles } from '../common/decorators/roles.decorator';
import { TenantGuard } from '../common/guards/tenant.guard';
import { RolesGuard } from '../common/guards/roles.guard';
import { Public } from '../common/decorators/public.decorator';

@Controller('config')
export class ConfigThemesController {
  constructor(private readonly svc: ConfigThemesService) {}

  @Public()
  @Get('theme/:orgSlug')
  @Throttle({ default: { ttl: 60000, limit: 10 } })
  getPublic(@Param('orgSlug') orgSlug: string) {
    return this.svc.getPublicTheme(orgSlug);
  }

  @Get('themes')
  @UseGuards(TenantGuard, RolesGuard)
  list(@Tenant() tenant: TenantContext) {
    return this.svc.list(tenant.organizationId);
  }

  @Post('themes')
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER', 'ADMIN')
  @HttpCode(HttpStatus.CREATED)
  create(@Tenant() tenant: TenantContext, @Body() dto: CreateThemeDto) {
    return this.svc.create(tenant.organizationId, tenant.userId, dto);
  }

  @Patch('themes/:id/activate')
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER', 'ADMIN')
  activate(@Tenant() tenant: TenantContext, @Param('id') id: string) {
    return this.svc.activate(tenant.organizationId, tenant.userId, id);
  }

  @Delete('themes/:id')
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER')
  remove(@Tenant() tenant: TenantContext, @Param('id') id: string) {
    return this.svc.remove(tenant.organizationId, tenant.userId, id);
  }
}
EOF

cat > src/config-themes/config-themes.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { ConfigThemesController } from './config-themes.controller';
import { ConfigThemesService } from './config-themes.service';
import { ConfigCacheModule } from '../config-cache/config-cache.module';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports:     [ConfigCacheModule, ConfigAuditModule],
  controllers: [ConfigThemesController],
  providers:   [ConfigThemesService],
  exports:     [ConfigThemesService],
})
export class ConfigThemesModule {}
EOF
ok "ConfigThemesModule listo"

# ─── 14. ConfigFlags ──────────────────────────────────────────────────────────
log "Creando módulo de feature flags..."

cat > src/config-flags/dto/update-flag.dto.ts << 'EOF'
import { IsBoolean, IsOptional, IsInt, Min, Max, IsObject, IsString, MaxLength } from 'class-validator';

export class UpdateFlagDto {
  @IsBoolean() @IsOptional()
  enabled?: boolean;

  @IsString() @IsOptional() @MaxLength(200)
  description?: string;

  @IsInt() @Min(0) @Max(100) @IsOptional()
  rolloutPercentage?: number;

  @IsObject() @IsOptional()
  conditions?: Record<string, unknown>;
}
EOF

cat > src/config-flags/config-flags.service.ts << 'EOF'
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { ConfigCacheService } from '../config-cache/config-cache.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { EventEmitter2 } from '@nestjs/event-emitter';
import { UpdateFlagDto } from './dto/update-flag.dto';

const FLAG_TTL = Number(process.env['CONFIG_CACHE_TTL_FLAGS'] ?? 60);

@Injectable()
export class ConfigFlagsService {
  constructor(
    private readonly prisma:  PrismaService,
    private readonly cache:   ConfigCacheService,
    private readonly audit:   ConfigAuditService,
    private readonly emitter: EventEmitter2,
  ) {}

  async getForOrg(organizationId: string, context?: { role?: string; plan?: string }) {
    const cacheKey = `${organizationId}:all`;
    const cached   = await this.cache.get<any[]>(organizationId, 'flags', 'all');
    if (cached && !context) return { success: true, data: cached };

    const flags = await this.prisma.featureFlag.findMany({
      where: { OR: [{ organizationId }, { organizationId: null }] },
      orderBy: { key: 'asc' },
    });

    const evaluated = flags.filter((f) => {
      if (!f.enabled) return false;
      if (f.rolloutPercentage < 100) {
        const hash = Buffer.from(organizationId).reduce((a, b) => a + b, 0);
        if ((hash % 100) >= f.rolloutPercentage) return false;
      }
      if (context && f.conditions && Object.keys(f.conditions as object).length > 0) {
        const cond = f.conditions as Record<string, string>;
        if (cond.role && context.role !== cond.role) return false;
        if (cond.plan && context.plan !== cond.plan) return false;
      }
      return true;
    });

    await this.cache.set(organizationId, 'flags', 'all', evaluated, FLAG_TTL);
    return { success: true, data: evaluated };
  }

  async list(organizationId: string) {
    const flags = await this.prisma.featureFlag.findMany({
      where:   { OR: [{ organizationId }, { organizationId: null }] },
      orderBy: { key: 'asc' },
    });
    return { success: true, data: flags };
  }

  async update(organizationId: string, userId: string, key: string, dto: UpdateFlagDto) {
    const flag = await this.prisma.featureFlag.findFirst({
      where: { key, organizationId },
    });
    if (!flag) throw new NotFoundException(`Flag "${key}" no encontrado`);

    const prev = { ...flag };
    const updated = await this.prisma.featureFlag.update({
      where: { id: flag.id },
      data:  {
        ...(dto.enabled           !== undefined && { enabled:           dto.enabled }),
        ...(dto.description       !== undefined && { description:       dto.description }),
        ...(dto.rolloutPercentage !== undefined && { rolloutPercentage: dto.rolloutPercentage }),
        ...(dto.conditions        !== undefined && { conditions:        dto.conditions as any }),
      },
    });

    this.audit.log({
      organizationId, userId,
      configType: 'flag', configKey: key, action: 'update',
      diff: { before: prev, after: updated },
    });
    await this.cache.del(organizationId, 'flags');
    this.emitter.emit('config.flag.changed', { organizationId, key, enabled: updated.enabled });

    return { success: true, data: updated };
  }
}
EOF

cat > src/config-flags/config-flags.controller.ts << 'EOF'
import { Controller, Get, Patch, Param, Body, UseGuards, Query } from '@nestjs/common';
import { ConfigFlagsService } from './config-flags.service';
import { UpdateFlagDto } from './dto/update-flag.dto';
import { Tenant } from '../common/decorators/tenant.decorator';
import type { TenantContext } from '../common/types/tenant-context';
import { Roles } from '../common/decorators/roles.decorator';
import { TenantGuard } from '../common/guards/tenant.guard';
import { RolesGuard } from '../common/guards/roles.guard';
import { ApiKeyGuard } from '../common/guards/api-key.guard';
import { Public } from '../common/decorators/public.decorator';

@Controller('config/flags')
export class ConfigFlagsController {
  constructor(private readonly svc: ConfigFlagsService) {}

  @Get()
  @UseGuards(TenantGuard, RolesGuard)
  list(@Tenant() tenant: TenantContext) {
    return this.svc.list(tenant.organizationId);
  }

  @Public()
  @Get(':orgId')
  @UseGuards(ApiKeyGuard)
  getForOrg(
    @Param('orgId') orgId: string,
    @Query('role')  role?: string,
    @Query('plan')  plan?: string,
  ) {
    return this.svc.getForOrg(orgId, { role, plan });
  }

  @Patch(':key')
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER', 'ADMIN')
  update(
    @Tenant() tenant: TenantContext,
    @Param('key') key: string,
    @Body() dto: UpdateFlagDto,
  ) {
    return this.svc.update(tenant.organizationId, tenant.userId, key, dto);
  }
}
EOF

cat > src/config-flags/config-flags.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { ConfigFlagsController } from './config-flags.controller';
import { ConfigFlagsService } from './config-flags.service';
import { ConfigCacheModule } from '../config-cache/config-cache.module';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports:     [ConfigCacheModule, ConfigAuditModule],
  controllers: [ConfigFlagsController],
  providers:   [ConfigFlagsService],
  exports:     [ConfigFlagsService],
})
export class ConfigFlagsModule {}
EOF
ok "ConfigFlagsModule listo"

# ─── 15. ConfigSecrets ────────────────────────────────────────────────────────
log "Creando módulo de secretos..."

cat > src/config-secrets/dto/create-secret.dto.ts << 'EOF'
import { IsString, IsOptional, MaxLength, IsIn, IsDateString } from 'class-validator';

export class CreateSecretDto {
  @IsString() @MaxLength(100)
  key: string;

  @IsString()
  value: string;

  @IsString() @IsOptional() @MaxLength(300)
  description?: string;

  @IsIn(['chat', 'payments', 'ads', 'all']) @IsOptional()
  systemTarget?: string;

  @IsDateString() @IsOptional()
  expiresAt?: string;
}
EOF

cat > src/config-secrets/config-secrets.service.ts << 'EOF'
import {
  Injectable, NotFoundException, ConflictException, ForbiddenException, Logger,
} from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { CryptoService } from './crypto.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { CreateSecretDto } from './dto/create-secret.dto';

@Injectable()
export class ConfigSecretsService {
  private readonly logger = new Logger(ConfigSecretsService.name);

  constructor(
    private readonly prisma:  PrismaService,
    private readonly crypto:  CryptoService,
    private readonly audit:   ConfigAuditService,
  ) {}

  async create(organizationId: string, userId: string, dto: CreateSecretDto, ip?: string) {
    const exists = await this.prisma.secretConfig.findUnique({
      where: { organizationId_key: { organizationId, key: dto.key } },
    });
    if (exists) throw new ConflictException(`Ya existe un secreto con la clave "${dto.key}"`);

    const { encrypted, iv, tag, prefix } = this.crypto.encrypt(dto.value);

    const secret = await this.prisma.secretConfig.create({
      data: {
        organizationId,
        key:            dto.key,
        valueEncrypted: encrypted,
        valueIv:        iv,
        valueTag:       tag,
        keyPrefix:      prefix,
        description:    dto.description,
        systemTarget:   dto.systemTarget ?? 'all',
        expiresAt:      dto.expiresAt ? new Date(dto.expiresAt) : undefined,
      },
    });

    this.audit.log({
      organizationId, userId, ipAddress: ip,
      configType: 'secret', configKey: dto.key, action: 'create',
      newValue:   '[CIFRADO]',
    });

    return {
      success: true,
      data: {
        id:           secret.id,
        key:          secret.key,
        keyPrefix:    secret.keyPrefix,
        description:  secret.description,
        systemTarget: secret.systemTarget,
        isActive:     secret.isActive,
        expiresAt:    secret.expiresAt,
        createdAt:    secret.createdAt,
      },
    };
  }

  async list(organizationId: string) {
    const secrets = await this.prisma.secretConfig.findMany({
      where:   { organizationId },
      select:  {
        id: true, key: true, keyPrefix: true, description: true,
        systemTarget: true, isActive: true, rotatedAt: true,
        expiresAt: true, createdAt: true,
      },
      orderBy: { key: 'asc' },
    });
    return { success: true, data: secrets };
  }

  async rotate(organizationId: string, userId: string, id: string, newValue: string, ip?: string) {
    const secret = await this.prisma.secretConfig.findFirst({
      where: { id, organizationId },
    });
    if (!secret) throw new NotFoundException('Secreto no encontrado');

    const { encrypted, iv, tag, prefix } = this.crypto.encrypt(newValue);

    const updated = await this.prisma.secretConfig.update({
      where: { id },
      data: {
        valueEncrypted: encrypted,
        valueIv:        iv,
        valueTag:       tag,
        keyPrefix:      prefix,
        rotatedAt:      new Date(),
      },
    });

    this.audit.log({
      organizationId, userId, ipAddress: ip,
      configType: 'secret', configKey: secret.key, action: 'rotate',
      previousValue: '[CIFRADO-PREV]', newValue: '[CIFRADO-NEW]',
    });

    return { success: true, message: 'Secreto rotado exitosamente', data: { rotatedAt: updated.rotatedAt } };
  }

  async revoke(organizationId: string, userId: string, id: string, ip?: string) {
    const secret = await this.prisma.secretConfig.findFirst({
      where: { id, organizationId },
    });
    if (!secret) throw new NotFoundException('Secreto no encontrado');

    await this.prisma.secretConfig.update({ where: { id }, data: { isActive: false } });

    this.audit.log({
      organizationId, userId, ipAddress: ip,
      configType: 'secret', configKey: secret.key, action: 'delete',
    });

    return { success: true, message: 'Secreto revocado' };
  }

  async resolve(organizationId: string, key: string): Promise<{ value: string }> {
    const secret = await this.prisma.secretConfig.findUnique({
      where: { organizationId_key: { organizationId, key } },
    });
    if (!secret || !secret.isActive) throw new NotFoundException('Secreto no encontrado o inactivo');
    if (secret.expiresAt && secret.expiresAt < new Date()) {
      throw new ForbiddenException('Secreto expirado');
    }

    const value = this.crypto.decrypt(secret.valueEncrypted, secret.valueIv, secret.valueTag);
    // audit de lectura — sin loguear el valor
    this.audit.log({
      organizationId,
      configType: 'secret', configKey: key, action: 'read',
    });
    return { value };
  }
}
EOF

cat > src/config-secrets/config-secrets.controller.ts << 'EOF'
import {
  Controller, Get, Post, Delete,
  Param, Body, UseGuards, HttpCode, HttpStatus, Req,
} from '@nestjs/common';
import { Request } from 'express';
import { ConfigSecretsService } from './config-secrets.service';
import { CreateSecretDto } from './dto/create-secret.dto';
import { Tenant } from '../common/decorators/tenant.decorator';
import type { TenantContext } from '../common/types/tenant-context';
import { Roles } from '../common/decorators/roles.decorator';
import { TenantGuard } from '../common/guards/tenant.guard';
import { RolesGuard } from '../common/guards/roles.guard';
import { StepUpGuard } from '../common/guards/step-up.guard';
import { ApiKeyGuard } from '../common/guards/api-key.guard';
import { Public } from '../common/decorators/public.decorator';
import { IsString } from 'class-validator';

class RotateSecretDto { @IsString() value: string; }

@Controller('config/secrets')
export class ConfigSecretsController {
  constructor(private readonly svc: ConfigSecretsService) {}

  @Post()
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER')
  @HttpCode(HttpStatus.CREATED)
  create(@Tenant() t: TenantContext, @Body() dto: CreateSecretDto, @Req() req: Request) {
    return this.svc.create(t.organizationId, t.userId, dto, req.ip);
  }

  @Get()
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER')
  list(@Tenant() t: TenantContext) {
    return this.svc.list(t.organizationId);
  }

  @Post(':id/rotate')
  @UseGuards(TenantGuard, RolesGuard, StepUpGuard)
  @Roles('OWNER')
  rotate(
    @Tenant() t: TenantContext,
    @Param('id') id: string,
    @Body() dto: RotateSecretDto,
    @Req() req: Request,
  ) {
    return this.svc.rotate(t.organizationId, t.userId, id, dto.value, req.ip);
  }

  @Delete(':id')
  @UseGuards(TenantGuard, RolesGuard, StepUpGuard)
  @Roles('OWNER')
  revoke(@Tenant() t: TenantContext, @Param('id') id: string, @Req() req: Request) {
    return this.svc.revoke(t.organizationId, t.userId, id, req.ip);
  }

  @Public()
  @Get('resolve/:key')
  @UseGuards(ApiKeyGuard)
  resolve(@Param('key') key: string, @Req() req: any) {
    return this.svc.resolve(req.tenant.organizationId, key);
  }
}
EOF

cat > src/config-secrets/config-secrets.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { ConfigSecretsController } from './config-secrets.controller';
import { ConfigSecretsService } from './config-secrets.service';
import { CryptoService } from './crypto.service';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports:     [ConfigAuditModule],
  controllers: [ConfigSecretsController],
  providers:   [ConfigSecretsService, CryptoService],
  exports:     [ConfigSecretsService, CryptoService],
})
export class ConfigSecretsModule {}
EOF
ok "ConfigSecretsModule listo"

# ─── 16. ConfigTemplates ──────────────────────────────────────────────────────
log "Creando módulo de plantillas..."

cat > src/config-templates/dto/create-template.dto.ts << 'EOF'
import {
  IsString, IsOptional, IsBoolean, MaxLength, IsArray, IsIn,
} from 'class-validator';

export class CreateTemplateDto {
  @IsString() @MaxLength(100)
  key: string;

  @IsString() @MaxLength(100)
  name: string;

  @IsString()
  content: string;

  @IsIn(['email', 'chat', 'notification', 'ui']) @IsOptional()
  category?: string;

  @IsIn(['chat', 'payments', 'ads', 'all']) @IsOptional()
  systemTarget?: string;

  @IsArray() @IsOptional()
  variables?: string[];
}
EOF

cat > src/config-templates/config-templates.service.ts << 'EOF'
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { ConfigCacheService } from '../config-cache/config-cache.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { CreateTemplateDto } from './dto/create-template.dto';

const TMPL_TTL = Number(process.env['CONFIG_CACHE_TTL_TEMPLATES'] ?? 120);

@Injectable()
export class ConfigTemplatesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly cache:  ConfigCacheService,
    private readonly audit:  ConfigAuditService,
  ) {}

  async resolve(organizationId: string, key: string): Promise<any> {
    const cached = await this.cache.get<any>(organizationId, 'templates', key);
    if (cached) return cached;

    let tmpl = await this.prisma.contentTemplate.findUnique({
      where: { organizationId_key: { organizationId, key } },
    });

    if (!tmpl) {
      tmpl = await this.prisma.contentTemplate.findFirst({
        where: { key, isSystemDefault: true, organizationId: null },
      });
    }

    if (!tmpl) throw new NotFoundException(`Plantilla "${key}" no encontrada`);

    await this.cache.set(organizationId, 'templates', key, tmpl, TMPL_TTL);
    return tmpl;
  }

  renderTemplate(content: string, variables: Record<string, string>): string {
    return content.replace(/\{\{(\w+)\}\}/g, (_, k) => variables[k] ?? `{{${k}}}`);
  }

  async renderByKey(organizationId: string, key: string, vars: Record<string, string>) {
    const tmpl    = await this.resolve(organizationId, key);
    const rendered = this.renderTemplate(tmpl.content, vars);
    return { success: true, data: { ...tmpl, rendered } };
  }

  async list(organizationId: string) {
    const templates = await this.prisma.contentTemplate.findMany({
      where:   { OR: [{ organizationId }, { isSystemDefault: true, organizationId: null }] },
      orderBy: { key: 'asc' },
    });
    return { success: true, data: templates };
  }

  async create(organizationId: string, userId: string, dto: CreateTemplateDto) {
    const tmpl = await this.prisma.contentTemplate.create({
      data: {
        organizationId,
        key:          dto.key,
        name:         dto.name,
        content:      dto.content,
        category:     dto.category ?? 'email',
        systemTarget: dto.systemTarget ?? 'all',
        variables:    dto.variables ?? [],
      },
    });
    this.audit.log({ organizationId, userId, configType: 'template', configKey: dto.key, action: 'create' });
    await this.cache.del(organizationId, 'templates', dto.key);
    return { success: true, data: tmpl };
  }

  async update(organizationId: string, userId: string, key: string, dto: Partial<CreateTemplateDto>) {
    const tmpl = await this.prisma.contentTemplate.findUnique({
      where: { organizationId_key: { organizationId, key } },
    });
    if (!tmpl) throw new NotFoundException(`Plantilla "${key}" no encontrada`);

    const updated = await this.prisma.contentTemplate.update({
      where: { id: tmpl.id },
      data:  {
        ...(dto.name         && { name:         dto.name }),
        ...(dto.content      && { content:      dto.content }),
        ...(dto.category     && { category:     dto.category }),
        ...(dto.systemTarget && { systemTarget: dto.systemTarget }),
        ...(dto.variables    && { variables:    dto.variables }),
      },
    });

    this.audit.log({ organizationId, userId, configType: 'template', configKey: key, action: 'update' });
    await this.cache.del(organizationId, 'templates', key);
    return { success: true, data: updated };
  }
}
EOF

cat > src/config-templates/config-templates.controller.ts << 'EOF'
import {
  Controller, Get, Post, Patch, Param, Body, UseGuards, HttpCode, HttpStatus,
} from '@nestjs/common';
import { ConfigTemplatesService } from './config-templates.service';
import { CreateTemplateDto } from './dto/create-template.dto';
import { Tenant } from '../common/decorators/tenant.decorator';
import type { TenantContext } from '../common/types/tenant-context';
import { Roles } from '../common/decorators/roles.decorator';
import { TenantGuard } from '../common/guards/tenant.guard';
import { RolesGuard } from '../common/guards/roles.guard';
import { ApiKeyGuard } from '../common/guards/api-key.guard';
import { Public } from '../common/decorators/public.decorator';

@Controller('config/templates')
export class ConfigTemplatesController {
  constructor(private readonly svc: ConfigTemplatesService) {}

  @Get()
  @UseGuards(TenantGuard, RolesGuard)
  list(@Tenant() t: TenantContext) {
    return this.svc.list(t.organizationId);
  }

  @Public()
  @Get(':key')
  @UseGuards(ApiKeyGuard)
  resolve(@Param('key') key: string, @Tenant() t: TenantContext) {
    return this.svc.resolve(t.organizationId, key);
  }

  @Post()
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER', 'ADMIN')
  @HttpCode(HttpStatus.CREATED)
  create(@Tenant() t: TenantContext, @Body() dto: CreateTemplateDto) {
    return this.svc.create(t.organizationId, t.userId, dto);
  }

  @Patch(':key')
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER', 'ADMIN')
  update(
    @Tenant() t: TenantContext,
    @Param('key') key: string,
    @Body() dto: CreateTemplateDto,
  ) {
    return this.svc.update(t.organizationId, t.userId, key, dto);
  }
}
EOF

cat > src/config-templates/config-templates.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { ConfigTemplatesController } from './config-templates.controller';
import { ConfigTemplatesService } from './config-templates.service';
import { ConfigCacheModule } from '../config-cache/config-cache.module';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports:     [ConfigCacheModule, ConfigAuditModule],
  controllers: [ConfigTemplatesController],
  providers:   [ConfigTemplatesService],
  exports:     [ConfigTemplatesService],
})
export class ConfigTemplatesModule {}
EOF
ok "ConfigTemplatesModule listo"

# ─── 17. ConfigQuotas ─────────────────────────────────────────────────────────
log "Creando módulo de quotas..."

cat > src/config-quotas/config-quotas.service.ts << 'EOF'
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { ConfigCacheService } from '../config-cache/config-cache.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { QuotaExceededException } from '../common/exceptions/quota-exceeded.exception';
import { EventEmitter2 } from '@nestjs/event-emitter';

const QUOTA_TTL = Number(process.env['CONFIG_CACHE_TTL_QUOTAS'] ?? 10);

export const DEFAULT_QUOTAS: Record<string, Record<string, number>> = {
  free:       { members: 3,  api_keys: 2,  monthly_api_calls: 1000,  storage_mb: 100,  chat_messages: 100,   ad_campaigns: 1  },
  pro:        { members: 20, api_keys: 10, monthly_api_calls: 50000, storage_mb: 5000, chat_messages: 10000, ad_campaigns: 10 },
  enterprise: { members: -1, api_keys: -1, monthly_api_calls: -1,    storage_mb: -1,   chat_messages: -1,    ad_campaigns: -1 },
};

@Injectable()
export class ConfigQuotasService {
  constructor(
    private readonly prisma:  PrismaService,
    private readonly cache:   ConfigCacheService,
    private readonly audit:   ConfigAuditService,
    private readonly emitter: EventEmitter2,
  ) {}

  async getForOrg(organizationId: string) {
    const quotas = await this.prisma.quotaConfig.findMany({
      where: { organizationId }, orderBy: { resource: 'asc' },
    });
    return { success: true, data: quotas };
  }

  async check(organizationId: string, resource: string) {
    const cacheKey = `${resource}`;
    const cached   = await this.cache.get<any>(organizationId, 'quotas', cacheKey);
    if (cached) {
      if (!cached.allowed) throw new QuotaExceededException(resource, cached.limit, cached.current);
      return cached;
    }

    const quota = await this.prisma.quotaConfig.findUnique({
      where: { organizationId_resource: { organizationId, resource } },
    });

    if (!quota) return { allowed: true, remaining: -1, limit: -1, current: 0 };

    const allowed   = quota.limit === -1 || quota.currentUsage < quota.limit;
    const remaining = quota.limit === -1 ? -1 : quota.limit - quota.currentUsage;
    const result    = { allowed, remaining, limit: quota.limit, current: quota.currentUsage };

    await this.cache.set(organizationId, 'quotas', cacheKey, result, QUOTA_TTL);

    if (!allowed) {
      this.emitter.emit('quota.exceeded', { organizationId, resource, limit: quota.limit });
      throw new QuotaExceededException(resource, quota.limit, quota.currentUsage);
    }

    return { success: true, data: result };
  }

  async increment(organizationId: string, resource: string, delta = 1) {
    await this.prisma.quotaConfig.upsert({
      where:  { organizationId_resource: { organizationId, resource } },
      update: { currentUsage: { increment: delta } },
      create: {
        organizationId, resource,
        limit:        DEFAULT_QUOTAS['free']?.[resource] ?? -1,
        currentUsage: delta,
      },
    });
    await this.cache.del(organizationId, 'quotas', resource);
  }

  async decrement(organizationId: string, resource: string, delta = 1) {
    await this.prisma.quotaConfig.updateMany({
      where: { organizationId, resource, currentUsage: { gt: 0 } },
      data:  { currentUsage: { decrement: delta } },
    });
    await this.cache.del(organizationId, 'quotas', resource);
  }

  async updateLimit(organizationId: string, userId: string, resource: string, limit: number) {
    const prev = await this.prisma.quotaConfig.findUnique({
      where: { organizationId_resource: { organizationId, resource } },
    });

    const updated = await this.prisma.quotaConfig.upsert({
      where:  { organizationId_resource: { organizationId, resource } },
      update: { limit },
      create: { organizationId, resource, limit, currentUsage: 0 },
    });

    this.audit.log({
      organizationId, userId, configType: 'quota', configKey: resource, action: 'update',
      diff: { before: prev?.limit, after: limit },
    });
    await this.cache.del(organizationId, 'quotas', resource);
    return { success: true, data: updated };
  }
}
EOF

cat > src/config-quotas/config-quotas.controller.ts << 'EOF'
import {
  Controller, Get, Patch, Post, Param, Body, UseGuards, ParseIntPipe,
} from '@nestjs/common';
import { ConfigQuotasService } from './config-quotas.service';
import { Tenant } from '../common/decorators/tenant.decorator';
import type { TenantContext } from '../common/types/tenant-context';
import { Roles } from '../common/decorators/roles.decorator';
import { TenantGuard } from '../common/guards/tenant.guard';
import { RolesGuard } from '../common/guards/roles.guard';
import { ApiKeyGuard } from '../common/guards/api-key.guard';
import { Public } from '../common/decorators/public.decorator';
import { IsInt, Min } from 'class-validator';

class UpdateLimitDto { @IsInt() @Min(1) limit: number; }
class CheckDto       { orgId?: string; }

@Controller('config/quotas')
export class ConfigQuotasController {
  constructor(private readonly svc: ConfigQuotasService) {}

  @Get()
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER', 'ADMIN')
  getForOrg(@Tenant() t: TenantContext) {
    return this.svc.getForOrg(t.organizationId);
  }

  @Patch(':resource')
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER')
  updateLimit(
    @Tenant() t: TenantContext,
    @Param('resource') resource: string,
    @Body() dto: UpdateLimitDto,
  ) {
    return this.svc.updateLimit(t.organizationId, t.userId, resource, dto.limit);
  }

  @Public()
  @Post(':resource/check')
  @UseGuards(ApiKeyGuard)
  check(@Param('resource') resource: string, @Tenant() t: TenantContext) {
    return this.svc.check(t.organizationId, resource);
  }

  @Public()
  @Post(':resource/increment')
  @UseGuards(ApiKeyGuard)
  increment(@Param('resource') resource: string, @Tenant() t: TenantContext) {
    return this.svc.increment(t.organizationId, resource);
  }
}
EOF

cat > src/config-quotas/config-quotas.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { ConfigQuotasController } from './config-quotas.controller';
import { ConfigQuotasService } from './config-quotas.service';
import { ConfigCacheModule } from '../config-cache/config-cache.module';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports:     [ConfigCacheModule, ConfigAuditModule],
  controllers: [ConfigQuotasController],
  providers:   [ConfigQuotasService],
  exports:     [ConfigQuotasService],
})
export class ConfigQuotasModule {}
EOF
ok "ConfigQuotasModule listo"

# ─── 18. ConfigWebhooks ───────────────────────────────────────────────────────
log "Creando módulo de webhooks..."

cat > src/config-webhooks/dto/create-webhook.dto.ts << 'EOF'
import { IsUrl, IsArray, IsString, ArrayNotEmpty, MaxLength, IsOptional } from 'class-validator';

export class CreateWebhookDto {
  @IsUrl()
  url: string;

  @IsArray()
  @ArrayNotEmpty()
  @IsString({ each: true })
  events: string[];

  @IsString() @MaxLength(200) @IsOptional()
  description?: string;
}
EOF

cat > src/config-webhooks/webhook-delivery.service.ts << 'EOF'
import { Injectable, Logger } from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { OnEvent } from '@nestjs/event-emitter';
import { PrismaService } from '../prisma/prisma.service';
import * as crypto from 'crypto';

const TIMEOUT = Number(process.env['WEBHOOK_DELIVERY_TIMEOUT'] ?? 5000);

export const WEBHOOK_QUEUE = 'webhook-delivery';

@Injectable()
export class WebhookDeliveryService {
  private readonly logger = new Logger(WebhookDeliveryService.name);

  constructor(
    private readonly prisma: PrismaService,
    @InjectQueue(WEBHOOK_QUEUE) private readonly queue: Queue,
  ) {}

  @OnEvent('config.theme.changed')
  @OnEvent('config.flag.changed')
  @OnEvent('config.secret.rotated')
  @OnEvent('quota.exceeded')
  @OnEvent('member.joined')
  @OnEvent('member.removed')
  async onConfigEvent(payload: { organizationId: string; [key: string]: any }) {
    const eventName = 'config.changed';
    await this.dispatch(payload.organizationId, eventName, payload);
  }

  async dispatch(organizationId: string, event: string, payload: unknown) {
    const webhooks = await this.prisma.webhookEndpoint.findMany({
      where: { organizationId, isActive: true },
    });

    for (const wh of webhooks) {
      const events = wh.events as string[];
      if (!events.includes(event) && !events.includes('*')) continue;

      await this.queue.add(
        'deliver',
        { webhookId: wh.id, event, payload, url: wh.url, secretHash: wh.secretHash },
        {
          attempts: Number(process.env['WEBHOOK_MAX_RETRIES'] ?? 3),
          backoff:  { type: 'exponential', delay: 1000 },
          removeOnComplete: 100,
          removeOnFail:     200,
        },
      );
    }
  }

  signPayload(secret: string, body: string): string {
    return 'sha256=' + crypto.createHmac('sha256', secret).update(body).digest('hex');
  }
}
EOF

cat > src/config-webhooks/webhook-delivery.processor.ts << 'EOF'
import { Processor, WorkerHost } from '@nestjs/bullmq';
import { Logger } from '@nestjs/common';
import { Job } from 'bullmq';
import { PrismaService } from '../prisma/prisma.service';
import { WEBHOOK_QUEUE } from './webhook-delivery.service';
import * as crypto from 'crypto';

const TIMEOUT = Number(process.env['WEBHOOK_DELIVERY_TIMEOUT'] ?? 5000);

@Processor(WEBHOOK_QUEUE)
export class WebhookDeliveryProcessor extends WorkerHost {
  private readonly logger = new Logger(WebhookDeliveryProcessor.name);

  constructor(private readonly prisma: PrismaService) {
    super();
  }

  async process(job: Job): Promise<void> {
    const { webhookId, event, payload, url, secretHash } = job.data;
    const body      = JSON.stringify({ event, payload, timestamp: new Date().toISOString() });
    const signature = 'sha256=' + crypto.createHmac('sha256', secretHash).update(body).digest('hex');
    const start     = Date.now();

    let statusCode: number | null = null;
    let success                   = false;
    let error: string | null      = null;

    try {
      const controller = new AbortController();
      const timeout    = setTimeout(() => controller.abort(), TIMEOUT);

      const res = await fetch(url, {
        method:  'POST',
        headers: {
          'Content-Type':        'application/json',
          'X-Webhook-Signature': signature,
          'X-Webhook-Event':     event,
        },
        body,
        signal: controller.signal,
      });

      clearTimeout(timeout);
      statusCode = res.status;
      success    = res.ok;

      if (!res.ok) throw new Error(`HTTP ${res.status}`);
    } catch (e: any) {
      error = e.message ?? 'Unknown error';
      this.logger.warn(`Webhook ${webhookId} falló (intento ${job.attemptsMade + 1}): ${error}`);
      throw e;
    } finally {
      const duration = Date.now() - start;
      await this.prisma.webhookDeliveryLog.create({
        data: {
          webhookId,
          event,
          statusCode,
          success,
          duration,
          attempt: job.attemptsMade + 1,
          error,
        },
      });

      await this.prisma.webhookEndpoint.update({
        where: { id: webhookId },
        data: {
          lastTriggeredAt: new Date(),
          failureCount:    success ? 0 : { increment: 1 },
        },
      });
    }
  }
}
EOF

cat > src/config-webhooks/config-webhooks.service.ts << 'EOF'
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { WebhookDeliveryService } from './webhook-delivery.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { CreateWebhookDto } from './dto/create-webhook.dto';
import * as crypto from 'crypto';
import * as bcrypt from 'bcrypt';

@Injectable()
export class ConfigWebhooksService {
  constructor(
    private readonly prisma:    PrismaService,
    private readonly delivery:  WebhookDeliveryService,
    private readonly audit:     ConfigAuditService,
  ) {}

  async create(organizationId: string, userId: string, dto: CreateWebhookDto) {
    const rawSecret = crypto.randomBytes(32).toString('hex');
    const secretHash = await bcrypt.hash(rawSecret, 10);

    const wh = await this.prisma.webhookEndpoint.create({
      data: {
        organizationId,
        url:          dto.url,
        events:       dto.events,
        secretHash,
        secretPrefix: rawSecret.substring(0, 6),
      },
    });

    this.audit.log({ organizationId, userId, configType: 'webhook', configKey: wh.id, action: 'create' });

    return { success: true, data: { ...wh, secret: rawSecret } };
  }

  async list(organizationId: string) {
    const whs = await this.prisma.webhookEndpoint.findMany({
      where:   { organizationId },
      select:  {
        id: true, url: true, events: true, secretPrefix: true,
        isActive: true, lastTriggeredAt: true, failureCount: true, createdAt: true,
      },
      orderBy: { createdAt: 'desc' },
    });
    return { success: true, data: whs };
  }

  async test(organizationId: string, id: string) {
    const wh = await this.prisma.webhookEndpoint.findFirst({
      where: { id, organizationId },
    });
    if (!wh) throw new NotFoundException('Webhook no encontrado');

    await this.delivery.dispatch(organizationId, 'webhook.test', {
      organizationId,
      message: 'Webhook de prueba — config service',
      timestamp: new Date().toISOString(),
    });

    return { success: true, message: 'Webhook de prueba encolado' };
  }

  async remove(organizationId: string, userId: string, id: string) {
    const wh = await this.prisma.webhookEndpoint.findFirst({
      where: { id, organizationId },
    });
    if (!wh) throw new NotFoundException('Webhook no encontrado');

    await this.prisma.webhookEndpoint.delete({ where: { id } });
    this.audit.log({ organizationId, userId, configType: 'webhook', configKey: id, action: 'delete' });
    return { success: true, message: 'Webhook eliminado' };
  }

  async getLogs(organizationId: string, id: string, take = 50) {
    const wh = await this.prisma.webhookEndpoint.findFirst({
      where: { id, organizationId },
    });
    if (!wh) throw new NotFoundException('Webhook no encontrado');

    const logs = await this.prisma.webhookDeliveryLog.findMany({
      where:   { webhookId: id },
      orderBy: { createdAt: 'desc' },
      take,
    });
    return { success: true, data: logs };
  }
}
EOF

cat > src/config-webhooks/config-webhooks.controller.ts << 'EOF'
import {
  Controller, Get, Post, Delete, Param, Body, UseGuards, HttpCode, HttpStatus, Query, ParseIntPipe, DefaultValuePipe,
} from '@nestjs/common';
import { ConfigWebhooksService } from './config-webhooks.service';
import { CreateWebhookDto } from './dto/create-webhook.dto';
import { Tenant } from '../common/decorators/tenant.decorator';
import type { TenantContext } from '../common/types/tenant-context';
import { Roles } from '../common/decorators/roles.decorator';
import { TenantGuard } from '../common/guards/tenant.guard';
import { RolesGuard } from '../common/guards/roles.guard';

@Controller('config/webhooks')
@UseGuards(TenantGuard, RolesGuard)
@Roles('OWNER')
export class ConfigWebhooksController {
  constructor(private readonly svc: ConfigWebhooksService) {}

  @Get()
  list(@Tenant() t: TenantContext) {
    return this.svc.list(t.organizationId);
  }

  @Post()
  @HttpCode(HttpStatus.CREATED)
  create(@Tenant() t: TenantContext, @Body() dto: CreateWebhookDto) {
    return this.svc.create(t.organizationId, t.userId, dto);
  }

  @Post(':id/test')
  test(@Tenant() t: TenantContext, @Param('id') id: string) {
    return this.svc.test(t.organizationId, id);
  }

  @Delete(':id')
  remove(@Tenant() t: TenantContext, @Param('id') id: string) {
    return this.svc.remove(t.organizationId, t.userId, id);
  }

  @Get(':id/logs')
  getLogs(
    @Tenant() t: TenantContext,
    @Param('id') id: string,
    @Query('take', new DefaultValuePipe(50), ParseIntPipe) take: number,
  ) {
    return this.svc.getLogs(t.organizationId, id, take);
  }
}
EOF

cat > src/config-webhooks/config-webhooks.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { BullModule } from '@nestjs/bullmq';
import { ConfigWebhooksController } from './config-webhooks.controller';
import { ConfigWebhooksService } from './config-webhooks.service';
import { WebhookDeliveryService, WEBHOOK_QUEUE } from './webhook-delivery.service';
import { WebhookDeliveryProcessor } from './webhook-delivery.processor';
import { ConfigAuditModule } from '../config-audit/config-audit.module';

@Module({
  imports: [
    BullModule.registerQueue({ name: WEBHOOK_QUEUE }),
    ConfigAuditModule,
  ],
  controllers: [ConfigWebhooksController],
  providers:   [ConfigWebhooksService, WebhookDeliveryService, WebhookDeliveryProcessor],
  exports:     [WebhookDeliveryService],
})
export class ConfigWebhooksModule {}
EOF
ok "ConfigWebhooksModule listo"

# ─── 19. main.ts ──────────────────────────────────────────────────────────────
log "Actualizando main.ts..."
cat > src/main.ts << 'EOF'
import { NestFactory } from '@nestjs/core';
import { ValidationPipe, Logger } from '@nestjs/common';
import { AppModule } from './app.module';
import helmet from 'helmet';

async function bootstrap() {
  const logger = new Logger('Bootstrap');
  const app    = await NestFactory.create(AppModule);

  app.use(helmet());

  app.useGlobalPipes(
    new ValidationPipe({
      whitelist:            true,
      forbidNonWhitelisted: true,
      transform:            true,
      disableErrorMessages: process.env['NODE_ENV'] === 'production',
    }),
  );

  app.setGlobalPrefix('api/v1');

  app.enableCors({
    origin:      process.env['ALLOWED_ORIGINS']?.split(',') ?? ['http://localhost:3000'],
    methods:     ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
    credentials: true,
  });

  const port = process.env['PORT'] ?? 3001;
  await app.listen(port);
  logger.log(`Config Service corriendo en http://localhost:${port}/api/v1`);
}

bootstrap();
EOF
ok "main.ts actualizado"

# ─── 20. AppModule ────────────────────────────────────────────────────────────
log "Actualizando AppModule..."
cat > src/app.module.ts << 'EOF'
import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { EventEmitterModule } from '@nestjs/event-emitter';
import { BullModule } from '@nestjs/bullmq';

import { FirebaseModule }       from './firebase/firebase.module';
import { PrismaModule }         from './prisma/prisma.module';
import { RedisModule }          from './redis/redis.module';
import { ConfigCacheModule }    from './config-cache/config-cache.module';
import { ConfigAuditModule }    from './config-audit/config-audit.module';
import { ConfigThemesModule }   from './config-themes/config-themes.module';
import { ConfigFlagsModule }    from './config-flags/config-flags.module';
import { ConfigSecretsModule }  from './config-secrets/config-secrets.module';
import { ConfigTemplatesModule } from './config-templates/config-templates.module';
import { ConfigQuotasModule }   from './config-quotas/config-quotas.module';
import { ConfigWebhooksModule } from './config-webhooks/config-webhooks.module';
import { FirebaseAuthGuard }    from './common/guards/firebase-auth.guard';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    ThrottlerModule.forRoot([
      { name: 'short', ttl: 1000,  limit: 15  },
      { name: 'long',  ttl: 60000, limit: 100 },
    ]),
    EventEmitterModule.forRoot({ wildcard: false }),
    BullModule.forRoot({
      connection: { url: process.env['REDIS_URL'] ?? 'redis://localhost:6379' },
    }),
    FirebaseModule,
    PrismaModule,
    RedisModule,
    ConfigCacheModule,
    ConfigAuditModule,
    ConfigThemesModule,
    ConfigFlagsModule,
    ConfigSecretsModule,
    ConfigTemplatesModule,
    ConfigQuotasModule,
    ConfigWebhooksModule,
  ],
  providers: [
    { provide: APP_GUARD, useClass: FirebaseAuthGuard },
    { provide: APP_GUARD, useClass: ThrottlerGuard },
  ],
})
export class AppModule {}
EOF
ok "AppModule actualizado"

# ─── 21. Seed de Prisma ───────────────────────────────────────────────────────
log "Creando seed de Prisma..."
mkdir -p prisma

cat > prisma/seed.ts << 'EOF'
import 'dotenv/config';
import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

async function main() {
  console.log('Sembrando datos del sistema...');

  // ── Temas del sistema ──────────────────────────────────────────────────────
  const themes = [
    {
      name: 'Default', isSystemDefault: true, isActive: false,
      primaryColor: '#000000', secondaryColor: '#ffffff', fontFamily: 'DM Sans',
      borderRadius: '0.75rem', darkMode: false,
    },
    {
      name: 'Dark', isSystemDefault: true, isActive: false,
      primaryColor: '#ffffff', secondaryColor: '#0a0a0a', fontFamily: 'DM Sans',
      borderRadius: '0.75rem', darkMode: true,
    },
    {
      name: 'Minimal', isSystemDefault: true, isActive: false,
      primaryColor: '#1a1a1a', secondaryColor: '#fafafa', fontFamily: 'Inter',
      borderRadius: '0.25rem', darkMode: false,
    },
    {
      name: 'Bold', isSystemDefault: true, isActive: false,
      primaryColor: '#4F46E5', secondaryColor: '#EEF2FF', fontFamily: 'Poppins',
      borderRadius: '1rem', darkMode: false,
    },
  ];

  for (const theme of themes) {
    await prisma.themeConfig.upsert({
      where:  { organizationId_name: { organizationId: null as any, name: theme.name } },
      update: theme,
      create: theme,
    });
  }
  console.log(`✓ ${themes.length} temas del sistema`);

  // ── Plantillas del sistema ─────────────────────────────────────────────────
  const templates = [
    {
      key: 'welcome_email', name: 'Email de bienvenida',
      category: 'email', systemTarget: 'all', isSystemDefault: true,
      content: 'Hola {{nombre}}, bienvenido a {{organizacion}}. Tu cuenta está lista.',
      variables: ['nombre', 'organizacion'],
    },
    {
      key: 'invitation_email', name: 'Email de invitación',
      category: 'email', systemTarget: 'all', isSystemDefault: true,
      content: 'Hola {{nombre}}, {{invitador}} te invita a unirte a {{organizacion}}. Aceptá la invitación aquí: {{link}}',
      variables: ['nombre', 'invitador', 'organizacion', 'link'],
    },
    {
      key: 'chat_welcome_message', name: 'Mensaje de bienvenida del chat',
      category: 'chat', systemTarget: 'chat', isSystemDefault: true,
      content: '¡Hola {{nombre}}! Soy el asistente de {{organizacion}}. ¿En qué puedo ayudarte?',
      variables: ['nombre', 'organizacion'],
    },
    {
      key: 'notification_new_member', name: 'Notificación nuevo miembro',
      category: 'notification', systemTarget: 'all', isSystemDefault: true,
      content: '{{nombre}} se unió a {{organizacion}} con el rol {{rol}}.',
      variables: ['nombre', 'organizacion', 'rol'],
    },
  ];

  for (const tmpl of templates) {
    await prisma.contentTemplate.upsert({
      where:  { organizationId_key: { organizationId: null as any, key: tmpl.key } },
      update: tmpl,
      create: tmpl,
    });
  }
  console.log(`✓ ${templates.length} plantillas del sistema`);

  // ── Feature flags globales ─────────────────────────────────────────────────
  const flags = [
    { key: 'chat_enabled',        enabled: false, description: 'Habilita el módulo de chat',               systemTarget: 'chat'     },
    { key: 'payments_enabled',    enabled: false, description: 'Habilita el módulo de pagos',              systemTarget: 'payments' },
    { key: 'ads_enabled',         enabled: false, description: 'Habilita el módulo de publicidad',         systemTarget: 'ads'      },
    { key: 'webhooks_enabled',    enabled: true,  description: 'Habilita webhooks outbound',               systemTarget: 'all'      },
    { key: 'audit_log_enabled',   enabled: true,  description: 'Habilita el log de auditoría',             systemTarget: 'all'      },
    { key: 'quota_enforcement',   enabled: true,  description: 'Enforce de quotas en todos los sistemas',  systemTarget: 'all'      },
  ];

  for (const flag of flags) {
    await prisma.featureFlag.upsert({
      where:  { organizationId_key: { organizationId: null as any, key: flag.key } },
      update: flag,
      create: flag,
    });
  }
  console.log(`✓ ${flags.length} feature flags globales`);

  console.log('Seed completado.');
}

main()
  .catch((e) => { console.error(e); process.exit(1); })
  .finally(() => prisma.$disconnect());
EOF

# Agregar script de seed al package.json
node -e "
const fs   = require('fs');
const pkg  = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.scripts['db:seed'] = 'ts-node --project tsconfig.json prisma/seed.ts';
pkg.prisma = { seed: 'ts-node --project tsconfig.json prisma/seed.ts' };
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2));
console.log('package.json actualizado con script db:seed');
"
ok "Seed creado"

# ─── 22. .env.example ─────────────────────────────────────────────────────────
log "Creando .env.example..."
cat > .env.example << 'EOF'
# Base de datos
DATABASE_URL=postgresql://user:password@localhost:5432/config_service

# Redis
REDIS_URL=redis://localhost:6379

# Cifrado de secretos — OBLIGATORIO — generar con: openssl rand -hex 32
CONFIG_MASTER_KEY=

# Firebase Admin
FIREBASE_PROJECT_ID=
FIREBASE_CLIENT_EMAIL=
FIREBASE_PRIVATE_KEY=

# App
PORT=3001
NODE_ENV=development
ALLOWED_ORIGINS=http://localhost:3000,http://localhost:3001

# Cache TTLs (segundos)
CONFIG_CACHE_TTL_THEME=300
CONFIG_CACHE_TTL_FLAGS=60
CONFIG_CACHE_TTL_TEMPLATES=120
CONFIG_CACHE_TTL_QUOTAS=10

# Webhooks
WEBHOOK_DELIVERY_TIMEOUT=5000
WEBHOOK_MAX_RETRIES=3
EOF
ok ".env.example creado"

# ─── 23. Verificación final ───────────────────────────────────────────────────
log "Generando cliente Prisma..."
pnpm prisma generate

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Config Service — instalación completada${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BLUE}Próximos pasos:${NC}"
echo -e "  1. Completar ${YELLOW}.env${NC} con tus credenciales reales"
echo -e "  2. Verificar que el schema de Prisma fue migrado:"
echo -e "     ${YELLOW}pnpm prisma migrate dev --name config_module_v1${NC}"
echo -e "  3. Correr el seed:"
echo -e "     ${YELLOW}pnpm db:seed${NC}"
echo -e "  4. Levantar en desarrollo:"
echo -e "     ${YELLOW}pnpm start:dev${NC}"
echo ""
echo -e "  ${BLUE}Endpoints disponibles en api/v1/:${NC}"
echo -e "  GET  config/theme/:orgSlug   → público, sin auth"
echo -e "  GET  config/themes           → autenticado"
echo -e "  GET  config/flags            → autenticado"
echo -e "  GET  config/flags/:orgId     → API key"
echo -e "  GET  config/secrets          → OWNER"
echo -e "  GET  config/secrets/resolve/:key → API key"
echo -e "  GET  config/templates        → autenticado"
echo -e "  GET  config/quotas           → OWNER, ADMIN"
echo -e "  POST config/quotas/:r/check  → API key"
echo -e "  GET  config/webhooks         → OWNER"
echo -e "  GET  config/audit            → OWNER, ADMIN"
echo ""