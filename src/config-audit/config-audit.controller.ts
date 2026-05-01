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
