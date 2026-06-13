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
  @Roles('OWNER', 'COLLABORATOR')
  @HttpCode(HttpStatus.CREATED)
  create(@Tenant() tenant: TenantContext, @Body() dto: CreateThemeDto) {
    return this.svc.create(tenant.organizationId, tenant.userId, dto);
  }

  @Patch('themes/:id/activate')
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER', 'COLLABORATOR')
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
