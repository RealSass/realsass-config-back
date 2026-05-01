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
