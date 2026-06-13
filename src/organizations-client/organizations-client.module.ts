import { Global, Module } from '@nestjs/common';
import { RedisModule } from '../redis/redis.module';
import { OrganizationsClientService } from './organizations-client.service';

/**
 * Global: TenantGuard y ApiKeyGuard lo consumen vía @UseGuards en cada
 * controller (no son APP_GUARD), por lo que necesitan que el provider
 * esté disponible en cualquier módulo sin importarlo explícitamente.
 */
@Global()
@Module({
  imports: [RedisModule],
  providers: [OrganizationsClientService],
  exports: [OrganizationsClientService],
})
export class OrganizationsClientModule {}
