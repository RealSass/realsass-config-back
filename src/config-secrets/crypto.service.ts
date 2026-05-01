import { Injectable } from '@nestjs/common';
import * as crypto from 'crypto';

const ALGORITHM = 'aes-256-gcm';
const KEY_LEN   = 32;

export interface EncryptedPayload {
  encrypted: string;
  iv:        string;
  tag:       string;
  prefix:    string;
}

@Injectable()
export class CryptoService {
  private masterKey(): Buffer {
    const hex = process.env['CONFIG_MASTER_KEY'];
    if (!hex || hex.length !== 64) {
      throw new Error('CONFIG_MASTER_KEY debe ser 32 bytes en hex (64 chars)');
    }
    return Buffer.from(hex, 'hex');
  }

  encrypt(plaintext: string): EncryptedPayload {
    const key  = this.masterKey();
    const iv   = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv(ALGORITHM, key, iv);
    const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();

    return {
      encrypted: encrypted.toString('base64'),
      iv:        iv.toString('base64'),
      tag:       tag.toString('base64'),
      prefix:    plaintext.substring(0, 4),
    };
  }

  decrypt(encryptedB64: string, ivB64: string, tagB64: string): string {
    const key       = this.masterKey();
    const iv        = Buffer.from(ivB64, 'base64');
    const tag       = Buffer.from(tagB64, 'base64');
    const encrypted = Buffer.from(encryptedB64, 'base64');
    const decipher  = crypto.createDecipheriv(ALGORITHM, key, iv);
    decipher.setAuthTag(tag);
    return decipher.update(encrypted) + decipher.final('utf8');
  }
}
