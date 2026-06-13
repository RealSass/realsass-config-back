import {
  ForbiddenException,
  Injectable,
  Logger,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { RedisService } from '../redis/redis.service';
import type { OrganizationAccessResult } from './types/organization-access.types';

const CACHE_TTL_SECONDS = Number(process.env['CONFIG_CACHE_TTL_ORG_ACCESS'] ?? 30);
const REQUEST_TIMEOUT_MS = 5000;

// real-back tiene setGlobalPrefix('api/v1') — ver src/main.ts de real-back.
// Configurable por si alguna vez cambia (o se llama a una instancia sin prefijo).
const ORGANIZATIONS_SERVICE_PREFIX = process.env['ORGANIZATIONS_SERVICE_PREFIX'] ?? '/api/v1';

/**
 * Cliente HTTP hacia real-back (organizaciones-back).
 *
 * real-back es la única fuente de verdad de usuarios, organizaciones,
 * colaboradores y permisos. Este servicio resuelve `{ role, permissions }`
 * para el par (usuario autenticado, organización activa) consultando
 * GET /auth/organization-access, y cachea el resultado en Redis con TTL
 * corto para no acoplar la latencia de cada request al servicio remoto.
 */
@Injectable()
export class OrganizationsClientService {
  private readonly logger = new Logger(OrganizationsClientService.name);
  private readonly baseUrl: string;

  constructor(private readonly redis: RedisService) {
    this.baseUrl = (process.env['ORGANIZATIONS_SERVICE_URL'] ?? 'http://localhost:3000').replace(/\/+$/, '');
  }

  private cacheKey(firebaseUid: string, organizationId: string): string {
    return `org-access:${firebaseUid}:${organizationId}`;
  }

  /**
   * Resuelve el acceso del usuario autenticado a `organizationId`.
   *
   * @param firebaseToken Token Bearer del usuario (se reenvía a real-back,
   *                       que lo vuelve a validar contra Firebase Admin).
   * @param firebaseUid   UID ya decodificado, usado solo como clave de cache.
   * @param organizationId Organización activa (header x-organization-id).
   *
   * @throws UnauthorizedException si real-back rechaza el token.
   * @throws ServiceUnavailableException si real-back no responde.
   */
  async getAccess(
    firebaseToken: string,
    firebaseUid: string,
    organizationId: string,
  ): Promise<OrganizationAccessResult> {
    const key = this.cacheKey(firebaseUid, organizationId);

    const cached = await this.redis.get(key).catch(() => null);
    if (cached) {
      return JSON.parse(cached) as OrganizationAccessResult;
    }

    const result = await this.fetchFromOrganizationsService(firebaseToken, organizationId);

    // Solo cacheamos resultados positivos: un canAccess=false podría volverse
    // true rápido (ej. acaban de aceptar una invitación) y no queremos que
    // el usuario quede bloqueado por el TTL.
    if (result.canAccess) {
      await this.redis
        .set(key, JSON.stringify(result), 'EX', CACHE_TTL_SECONDS)
        .catch((err: Error) => this.logger.warn(`No se pudo cachear org-access: ${err.message}`));
    }

    return result;
  }

  private async fetchFromOrganizationsService(
    firebaseToken: string,
    organizationId: string,
  ): Promise<OrganizationAccessResult> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

    try {
      const res = await fetch(`${this.baseUrl}${ORGANIZATIONS_SERVICE_PREFIX}/auth/organization-access`, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${firebaseToken}`,
          'x-organization-id': organizationId,
        },
        signal: controller.signal,
      });

      if (res.status === 401) {
        throw new UnauthorizedException('Token inválido o expirado');
      }
      if (res.status === 400) {
        throw new ForbiddenException('Solicitud inválida al resolver acceso a la organización');
      }
      if (!res.ok) {
        throw new ServiceUnavailableException('Servicio de organizaciones no disponible');
      }

      const body = (await res.json()) as { data?: OrganizationAccessResult } & OrganizationAccessResult;
      // organizaciones-back puede envolver la respuesta en { data: ... }; soportamos ambos shapes.
      return body.data ?? body;
    } catch (err) {
      if (err instanceof UnauthorizedException || err instanceof ForbiddenException || err instanceof ServiceUnavailableException) {
        throw err;
      }
      this.logger.error(`Error consultando organizations-service: ${(err as Error).message}`);
      throw new ServiceUnavailableException('Servicio de organizaciones no disponible');
    } finally {
      clearTimeout(timeout);
    }
  }
}
