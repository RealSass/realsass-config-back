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
