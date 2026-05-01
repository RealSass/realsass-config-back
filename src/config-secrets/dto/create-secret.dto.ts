import { IsString, IsOptional, MaxLength, IsIn, IsDateString } from 'class-validator';

export class CreateSecretDto {
  @IsString() @MaxLength(100)
  key: string;

  @IsString()
  value: string;

  @IsString() @IsOptional() @MaxLength(300)
  description?: string;

  @IsIn(['chat', 'payments', 'ads', 'all']) @IsOptional()
  systemTarget?: string;

  @IsDateString() @IsOptional()
  expiresAt?: string;
}
