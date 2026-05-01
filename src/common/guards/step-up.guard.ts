import { CanActivate, ExecutionContext, ForbiddenException, Injectable } from '@nestjs/common';
import * as admin from 'firebase-admin';

@Injectable()
export class StepUpGuard implements CanActivate {
  private readonly WINDOW_MS = 5 * 60 * 1000;

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const req   = ctx.switchToHttp().getRequest();
    const token = req.headers.authorization?.split(' ')[1];
    if (!token) throw new ForbiddenException('Token requerido para esta acción');

    const decoded  = await admin.app().auth().verifyIdToken(token);
    const authTime = decoded.auth_time * 1000;

    if (Date.now() - authTime > this.WINDOW_MS) {
      throw new ForbiddenException('Re-autenticación requerida (ventana de 5 minutos)');
    }
    return true;
  }
}
