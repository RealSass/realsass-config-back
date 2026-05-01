import { HttpException, HttpStatus } from '@nestjs/common';

export class QuotaExceededException extends HttpException {
  constructor(resource: string, limit: number, current: number) {
    super(
      {
        statusCode: HttpStatus.TOO_MANY_REQUESTS,
        error:      'Quota Exceeded',
        message:    `Límite de ${resource} alcanzado: ${current}/${limit}`,
        resource,
        limit,
        current,
      },
      HttpStatus.TOO_MANY_REQUESTS,
    );
  }
}
