import {
  IsString, IsOptional, IsBoolean, MaxLength, IsHexColor,
} from 'class-validator';

export class CreateThemeDto {
  @IsString() @MaxLength(80)
  name: string;

  @IsHexColor() @IsOptional()
  primaryColor?: string;

  @IsHexColor() @IsOptional()
  secondaryColor?: string;

  @IsHexColor() @IsOptional()
  accentColor?: string;

  @IsString() @IsOptional() @MaxLength(80)
  fontFamily?: string;

  @IsString() @IsOptional() @MaxLength(20)
  borderRadius?: string;

  @IsString() @IsOptional()
  logoUrl?: string;

  @IsString() @IsOptional()
  faviconUrl?: string;

  @IsBoolean() @IsOptional()
  darkMode?: boolean;

  @IsString() @IsOptional()
  customCSS?: string;
}
