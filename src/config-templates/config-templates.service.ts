import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { ConfigCacheService } from '../config-cache/config-cache.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { CreateTemplateDto } from './dto/create-template.dto';

const TMPL_TTL = Number(process.env['CONFIG_CACHE_TTL_TEMPLATES'] ?? 120);

@Injectable()
export class ConfigTemplatesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly cache:  ConfigCacheService,
    private readonly audit:  ConfigAuditService,
  ) {}

  async resolve(organizationId: string, key: string): Promise<any> {
    const cached = await this.cache.get<any>(organizationId, 'templates', key);
    if (cached) return cached;

    let tmpl = await this.prisma.contentTemplate.findUnique({
      where: { organizationId_key: { organizationId, key } },
    });

    if (!tmpl) {
      tmpl = await this.prisma.contentTemplate.findFirst({
        where: { key, isSystemDefault: true, organizationId: null },
      });
    }

    if (!tmpl) throw new NotFoundException(`Plantilla "${key}" no encontrada`);

    await this.cache.set(organizationId, 'templates', key, tmpl, TMPL_TTL);
    return tmpl;
  }

  renderTemplate(content: string, variables: Record<string, string>): string {
    return content.replace(/\{\{(\w+)\}\}/g, (_, k) => variables[k] ?? `{{${k}}}`);
  }

  async renderByKey(organizationId: string, key: string, vars: Record<string, string>) {
    const tmpl    = await this.resolve(organizationId, key);
    const rendered = this.renderTemplate(tmpl.content, vars);
    return { success: true, data: { ...tmpl, rendered } };
  }

  async list(organizationId: string) {
    const templates = await this.prisma.contentTemplate.findMany({
      where:   { OR: [{ organizationId }, { isSystemDefault: true, organizationId: null }] },
      orderBy: { key: 'asc' },
    });
    return { success: true, data: templates };
  }

  async create(organizationId: string, userId: string, dto: CreateTemplateDto) {
    const tmpl = await this.prisma.contentTemplate.create({
      data: {
        organizationId,
        key:          dto.key,
        name:         dto.name,
        content:      dto.content,
        category:     dto.category ?? 'email',
        systemTarget: dto.systemTarget ?? 'all',
        variables:    dto.variables ?? [],
      },
    });
    this.audit.log({ organizationId, userId, configType: 'template', configKey: dto.key, action: 'create' });
    await this.cache.del(organizationId, 'templates', dto.key);
    return { success: true, data: tmpl };
  }

  async update(organizationId: string, userId: string, key: string, dto: Partial<CreateTemplateDto>) {
    const tmpl = await this.prisma.contentTemplate.findUnique({
      where: { organizationId_key: { organizationId, key } },
    });
    if (!tmpl) throw new NotFoundException(`Plantilla "${key}" no encontrada`);

    const updated = await this.prisma.contentTemplate.update({
      where: { id: tmpl.id },
      data:  {
        ...(dto.name         && { name:         dto.name }),
        ...(dto.content      && { content:      dto.content }),
        ...(dto.category     && { category:     dto.category }),
        ...(dto.systemTarget && { systemTarget: dto.systemTarget }),
        ...(dto.variables    && { variables:    dto.variables }),
      },
    });

    this.audit.log({ organizationId, userId, configType: 'template', configKey: key, action: 'update' });
    await this.cache.del(organizationId, 'templates', key);
    return { success: true, data: updated };
  }
}
