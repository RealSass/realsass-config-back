import { Module } from '@nestjs/common';
import { ConfigCacheService } from './config-cache.service';

@Module({ providers: [ConfigCacheService], exports: [ConfigCacheService] })
export class ConfigCacheModule {}
