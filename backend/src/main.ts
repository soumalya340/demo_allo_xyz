import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module.js';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  // Browser frontends call this directly.
  app.enableCors();
  await app.listen(process.env.PORT ?? 3000);
}
await bootstrap();
