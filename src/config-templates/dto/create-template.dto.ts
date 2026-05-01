import {
  IsString, IsOptional, IsBoolean, MaxLength, IsArray, IsIn,
} from 'class-validator';

export class CreateTemplateDto {
  @IsString() @MaxLength(100)
  key: string;

  @IsString() @MaxLength(100)
  name: string;

  @IsString()
  content: string;

  @IsIn(['email', 'chat', 'notification', 'ui']) @IsOptional()
  category?: string;

  @IsIn(['chat', 'payments', 'ads', 'all']) @IsOptional()
  systemTarget?: string;

  @IsArray() @IsOptional()
  variables?: string[];
}
