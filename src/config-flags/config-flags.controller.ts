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
  @Roles('OWNER', 'COLLABORATOR')
  update(
    @Tenant() tenant: TenantContext,
    @Param('key') key: string,
    @Body() dto: UpdateFlagDto,
  ) {
    return this.svc.update(tenant.organizationId, tenant.userId, key, dto);
  }
}
