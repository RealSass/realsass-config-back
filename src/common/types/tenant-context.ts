/**
 * TenantContext — ya NO se resuelve contra una tabla local de Membership.
 * Se obtiene de OrganizationsClientService, que consulta a real-back
 * (única fuente de verdad de usuarios/organizaciones/colaboradores).
 */

export type TenantRole = 'OWNER' | 'COLLABORATOR';

export interface CollaboratorPermissions {
  canViewListings: boolean;
  canCreateListings: boolean;
  canEditListings: boolean;
  canDeleteListings: boolean;
  canViewStats: boolean;
  canManageLeads: boolean;
  canManageCollaborators: boolean;
}

export const FULL_PERMISSIONS: CollaboratorPermissions = {
  canViewListings: true,
  canCreateListings: true,
  canEditListings: true,
  canDeleteListings: true,
  canViewStats: true,
  canManageLeads: true,
  canManageCollaborators: true,
};

export interface TenantContext {
  userId: string;
  organizationId: string;
  role: TenantRole;
  permissions: CollaboratorPermissions;
  apiKeyScopes?: string[];
}
