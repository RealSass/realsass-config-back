import { IsBoolean, IsOptional, IsInt, Min, Max, IsObject, IsString, MaxLength } from 'class-validator';

export class UpdateFlagDto {
  @IsBoolean() @IsOptional()
  enabled?: boolean;

  @IsString() @IsOptional() @MaxLength(200)
  description?: string;

  @IsInt() @Min(0) @Max(100) @IsOptional()
  rolloutPercentage?: number;

  @IsObject() @IsOptional()
  conditions?: Record<string, unknown>;
}
