import { SetMetadata } from '@nestjs/common';
import type { TenantRole } from '../types/tenant-context';

export const ROLES_KEY = 'roles';
export const Roles = (...roles: TenantRole[]) => SetMetadata(ROLES_KEY, roles);
