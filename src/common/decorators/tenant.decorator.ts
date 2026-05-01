import { createParamDecorator, ExecutionContext } from '@nestjs/common';
import type { TenantContext } from '../types/tenant-context';

export const Tenant = createParamDecorator(
  (_: unknown, ctx: ExecutionContext): TenantContext =>
    ctx.switchToHttp().getRequest().tenant,
);
