import {
  Injectable, NotFoundException, ConflictException, ForbiddenException,
} from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { ConfigCacheService } from '../config-cache/config-cache.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { EventEmitter2 } from '@nestjs/event-emitter';
import { CreateThemeDto } from './dto/create-theme.dto';

const THEME_TTL = Number(process.env['CONFIG_CACHE_TTL_THEME'] ?? 300);

@Injectable()
export class ConfigThemesService {
  constructor(
    private readonly prisma:  PrismaService,
    private readonly cache:   ConfigCacheService,
    private readonly audit:   ConfigAuditService,
    private readonly emitter: EventEmitter2,
  ) {}

  /**
   * Tema público por organizationId.
   *
   * NOTA DE ARQUITECTURA: el schema de real-config-back está desacoplado de
   * real-back — no existe tabla `organizations` local. La ruta pública
   * GET /config/theme/:orgId recibe el organizationId directamente (UUID),
   * no el slug. El frontend debe usar el organizationId del contexto activo.
   *
   * Si se necesita resolución por slug en el futuro, agregar una llamada
   * a real-back (OrganizationsClientService) para resolver slug → id.
   */
  async getPublicTheme(organizationId: string) {
    const cached = await this.cache.get<any>('__public__', 'theme', organizationId);
    if (cached) return { success: true, data: cached };

    let theme = await this.prisma.themeConfig.findFirst({
      where: { organizationId, isActive: true },
    });

    if (!theme) {
      theme = await this.prisma.themeConfig.findFirst({
        where: { isSystemDefault: true, name: 'Default' },
      });
    }

    await this.cache.set('__public__', 'theme', organizationId, theme, THEME_TTL);
    return { success: true, data: theme };
  }

  async list(organizationId: string) {
    const themes = await this.prisma.themeConfig.findMany({
      where:   { OR: [{ organizationId }, { isSystemDefault: true }] },
      orderBy: { createdAt: 'asc' },
    });
    return { success: true, data: themes };
  }

  async create(organizationId: string, userId: string, dto: CreateThemeDto) {
    const exists = await this.prisma.themeConfig.findUnique({
      where: { organizationId_name: { organizationId, name: dto.name } },
    });
    if (exists) throw new ConflictException(`Ya existe un tema llamado "${dto.name}"`);

    const theme = await this.prisma.themeConfig.create({
      data: { organizationId, ...dto },
    });

    this.audit.log({ organizationId, userId, configType: 'theme', configKey: theme.id, action: 'create' });
    await this.cache.del('__public__', 'theme');
    return { success: true, data: theme };
  }

  async activate(organizationId: string, userId: string, id: string) {
    const theme = await this.prisma.themeConfig.findFirst({
      where: { id, OR: [{ organizationId }, { isSystemDefault: true }] },
    });
    if (!theme) throw new NotFoundException('Tema no encontrado');

    await this.prisma.$transaction([
      this.prisma.themeConfig.updateMany({
        where: { organizationId }, data: { isActive: false },
      }),
      this.prisma.themeConfig.update({
        where: { id }, data: { isActive: true },
      }),
    ]);

    this.audit.log({ organizationId, userId, configType: 'theme', configKey: id, action: 'activate' });
    await this.cache.del('__public__', 'theme');
    await this.cache.del(organizationId, 'theme');
    this.emitter.emit('config.theme.changed', { organizationId, themeId: id });

    return { success: true, message: 'Tema activado' };
  }

  async remove(organizationId: string, userId: string, id: string) {
    const theme = await this.prisma.themeConfig.findFirst({
      where: { id, organizationId },
    });
    if (!theme) throw new NotFoundException('Tema no encontrado');
    if (theme.isSystemDefault) throw new ForbiddenException('No se puede eliminar un tema del sistema');
    if (theme.isActive) throw new ForbiddenException('Desactivá el tema antes de eliminarlo');

    await this.prisma.themeConfig.delete({ where: { id } });
    this.audit.log({ organizationId, userId, configType: 'theme', configKey: id, action: 'delete' });
    await this.cache.del('__public__', 'theme');
    return { success: true, message: 'Tema eliminado' };
  }
}