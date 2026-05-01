import { IsUrl, IsArray, IsString, ArrayNotEmpty, MaxLength, IsOptional } from 'class-validator';

export class CreateWebhookDto {
  @IsUrl()
  url: string;

  @IsArray()
  @ArrayNotEmpty()
  @IsString({ each: true })
  events: string[];

  @IsString() @MaxLength(200) @IsOptional()
  description?: string;
}
