import { NestFactory } from '@nestjs/core';
import { ValidationPipe, Logger } from '@nestjs/common';
import { AppModule } from './app.module';
import helmet from 'helmet';

async function bootstrap() {
  const logger = new Logger('Bootstrap');
  const app    = await NestFactory.create(AppModule);

  app.use(helmet());

  // ── Health-check sin auth (Railway lo usa para detectar si el pod está vivo)
  // Registramos ANTES del prefijo global para que quede en GET /health
  const httpAdapter = app.getHttpAdapter();
  httpAdapter.get('/health', (_req: any, res: any) => {
    res.status(200).json({ status: 'ok', service: 'real-config-back' });
  });

  app.useGlobalPipes(
    new ValidationPipe({
      whitelist:            true,
      forbidNonWhitelisted: true,
      transform:            true,
      disableErrorMessages: process.env['NODE_ENV'] === 'production',
    }),
  );

  app.setGlobalPrefix('api/v1');

  // CORS — acepta lista de orígenes separados por coma desde env
  const rawOrigins = process.env['ALLOWED_ORIGINS'] ?? '';
  const origins = rawOrigins
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean);

  app.enableCors({
    // Si no hay origins configurados en env, rechazar todo origen desconocido
    origin: origins.length > 0 ? origins : false,
    methods:     ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'x-organization-id', 'x-api-key'],
    credentials: true,
  });

  // Railway inyecta PORT dinámicamente; NUNCA hardcodear 3001 en prod
  const port = parseInt(process.env['PORT'] ?? '3001', 10);
  await app.listen(port, '0.0.0.0');
  logger.log(`Config Service corriendo en http://0.0.0.0:${port}/api/v1`);
  logger.log(`Health-check disponible en http://0.0.0.0:${port}/health`);
}

bootstrap();
