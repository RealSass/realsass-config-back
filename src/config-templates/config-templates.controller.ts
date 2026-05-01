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
