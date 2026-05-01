import { NestFactory } from '@nestjs/core';
import { ValidationPipe, Logger } from '@nestjs/common';
import { AppModule } from './app.module';
import helmet from 'helmet';

async function bootstrap() {
  const logger = new Logger('Bootstrap');
  const app    = await NestFactory.create(AppModule);

  app.use(helmet());

  app.useGlobalPipes(
    new ValidationPipe({
      whitelist:            true,
      forbidNonWhitelisted: true,
      transform:            true,
      disableErrorMessages: process.env['NODE_ENV'] === 'production',
    }),
  );

  app.setGlobalPrefix('api/v1');

  app.enableCors({
    origin:      process.env['ALLOWED_ORIGINS']?.split(',') ?? ['http://localhost:3000'],
    methods:     ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
    credentials: true,
  });

  const port = process.env['PORT'] ?? 3001;
  await app.listen(port);
  logger.log(`Config Service corriendo en http://localhost:${port}/api/v1`);
}

bootstrap();
