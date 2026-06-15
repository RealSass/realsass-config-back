import {
  Controller, Get, Patch, Param, Body,
  UseGuards, Query, Headers, NotFoundException,
} from '@nestjs/common';
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

  // ── Ruta autenticada: lista flags del tenant actual (vía FirebaseAuthGuard + TenantGuard)
  @Get()
  @UseGuards(TenantGuard, RolesGuard)
  list(@Tenant() tenant: TenantContext) {
    return this.svc.list(tenant.organizationId);
  }

  // ── Ruta pública por orgId en path (usada por frontends con API key)
  @Public()
  @Get(':orgId')
  @UseGuards(ApiKeyGuard)
  getForOrg(
    @Param('orgId') orgId: string,
    @Query('role')  role?: string,
    @Query('plan')  plan?: string,
  ) {
    return this.svc.getForOrg(orgId, role, plan);
  }

  // ── Ruta pública por orgId en header x-organization-id (para llamadas server-side)
  // Útil cuando el frontend no puede poner orgId en el path
  @Public()
  @Get('public/by-org')
  @UseGuards(ApiKeyGuard)
  getForOrgByHeader(
    @Headers('x-organization-id') orgId: string,
    @Query('role') role?: string,
    @Query('plan') plan?: string,
  ) {
    if (!orgId) throw new NotFoundException('x-organization-id header requerido');
    return this.svc.getForOrg(orgId, role, plan);
  }

  // ── Mutaciones (solo OWNER autenticado)
  @Patch(':id')
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER')
  update(
    @Tenant() tenant: TenantContext,
    @Param('id') id: string,
    @Body() dto: UpdateFlagDto,
  ) {
    return this.svc.update(tenant.organizationId, id, dto);
  }
}
