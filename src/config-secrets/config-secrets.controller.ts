import {
  Controller,
  Get,
  Post,
  Delete,
  Param,
  Body,
  UseGuards,
  HttpCode,
  HttpStatus,
  Req,
} from '@nestjs/common';
import type { Request } from 'express';
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

class RotateSecretDto {
  @IsString()
  value: string;
}

@Controller('config/secrets')
export class ConfigSecretsController {
  constructor(private readonly svc: ConfigSecretsService) {}

  @Post()
  @UseGuards(TenantGuard, RolesGuard)
  @Roles('OWNER')
  @HttpCode(HttpStatus.CREATED)
  create(
    @Tenant() t: TenantContext,
    @Body() dto: CreateSecretDto,
    @Req() req: Request,
  ) {
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
  revoke(
    @Tenant() t: TenantContext,
    @Param('id') id: string,
    @Req() req: Request,
  ) {
    return this.svc.revoke(t.organizationId, t.userId, id, req.ip);
  }

  @Public()
  @Get('resolve/:key')
  @UseGuards(ApiKeyGuard)
  resolve(@Param('key') key: string, @Req() req: Request & { tenant: TenantContext }) {
    return this.svc.resolve(req.tenant.organizationId, key);
  }
}