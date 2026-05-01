import {
  Injectable, NotFoundException, ConflictException, ForbiddenException, Logger,
} from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { CryptoService } from './crypto.service';
import { ConfigAuditService } from '../config-audit/config-audit.service';
import { CreateSecretDto } from './dto/create-secret.dto';

@Injectable()
export class ConfigSecretsService {
  private readonly logger = new Logger(ConfigSecretsService.name);

  constructor(
    private readonly prisma:  PrismaService,
    private readonly crypto:  CryptoService,
    private readonly audit:   ConfigAuditService,
  ) {}

  async create(organizationId: string, userId: string, dto: CreateSecretDto, ip?: string) {
    const exists = await this.prisma.secretConfig.findUnique({
      where: { organizationId_key: { organizationId, key: dto.key } },
    });
    if (exists) throw new ConflictException(`Ya existe un secreto con la clave "${dto.key}"`);

    const { encrypted, iv, tag, prefix } = this.crypto.encrypt(dto.value);

    const secret = await this.prisma.secretConfig.create({
      data: {
        organizationId,
        key:            dto.key,
        valueEncrypted: encrypted,
        valueIv:        iv,
        valueTag:       tag,
        keyPrefix:      prefix,
        description:    dto.description,
        systemTarget:   dto.systemTarget ?? 'all',
        expiresAt:      dto.expiresAt ? new Date(dto.expiresAt) : undefined,
      },
    });

    this.audit.log({
      organizationId, userId, ipAddress: ip,
      configType: 'secret', configKey: dto.key, action: 'create',
      newValue:   '[CIFRADO]',
    });

    return {
      success: true,
      data: {
        id:           secret.id,
        key:          secret.key,
        keyPrefix:    secret.keyPrefix,
        description:  secret.description,
        systemTarget: secret.systemTarget,
        isActive:     secret.isActive,
        expiresAt:    secret.expiresAt,
        createdAt:    secret.createdAt,
      },
    };
  }

  async list(organizationId: string) {
    const secrets = await this.prisma.secretConfig.findMany({
      where:   { organizationId },
      select:  {
        id: true, key: true, keyPrefix: true, description: true,
        systemTarget: true, isActive: true, rotatedAt: true,
        expiresAt: true, createdAt: true,
      },
      orderBy: { key: 'asc' },
    });
    return { success: true, data: secrets };
  }

  async rotate(organizationId: string, userId: string, id: string, newValue: string, ip?: string) {
    const secret = await this.prisma.secretConfig.findFirst({
      where: { id, organizationId },
    });
    if (!secret) throw new NotFoundException('Secreto no encontrado');

    const { encrypted, iv, tag, prefix } = this.crypto.encrypt(newValue);

    const updated = await this.prisma.secretConfig.update({
      where: { id },
      data: {
        valueEncrypted: encrypted,
        valueIv:        iv,
        valueTag:       tag,
        keyPrefix:      prefix,
        rotatedAt:      new Date(),
      },
    });

    this.audit.log({
      organizationId, userId, ipAddress: ip,
      configType: 'secret', configKey: secret.key, action: 'rotate',
      previousValue: '[CIFRADO-PREV]', newValue: '[CIFRADO-NEW]',
    });

    return { success: true, message: 'Secreto rotado exitosamente', data: { rotatedAt: updated.rotatedAt } };
  }

  async revoke(organizationId: string, userId: string, id: string, ip?: string) {
    const secret = await this.prisma.secretConfig.findFirst({
      where: { id, organizationId },
    });
    if (!secret) throw new NotFoundException('Secreto no encontrado');

    await this.prisma.secretConfig.update({ where: { id }, data: { isActive: false } });

    this.audit.log({
      organizationId, userId, ipAddress: ip,
      configType: 'secret', configKey: secret.key, action: 'delete',
    });

    return { success: true, message: 'Secreto revocado' };
  }

  async resolve(organizationId: string, key: string): Promise<{ value: string }> {
    const secret = await this.prisma.secretConfig.findUnique({
      where: { organizationId_key: { organizationId, key } },
    });
    if (!secret || !secret.isActive) throw new NotFoundException('Secreto no encontrado o inactivo');
    if (secret.expiresAt && secret.expiresAt < new Date()) {
      throw new ForbiddenException('Secreto expirado');
    }

    const value = this.crypto.decrypt(secret.valueEncrypted, secret.valueIv, secret.valueTag);
    // audit de lectura — sin loguear el valor
    this.audit.log({
      organizationId,
      configType: 'secret', configKey: key, action: 'read',
    });
    return { value };
  }
}
