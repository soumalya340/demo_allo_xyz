import { BadRequestException } from '@nestjs/common';
import {
  formatEther,
  getAddress,
  isAddress,
  parseEther,
  type Address,
} from 'viem';

/// Query-string parsing. Every amount is a human decimal ("0.5" BNB, "1000" tokens);
/// both BNB and the pool tokens have 18 decimals.

export function requireString(name: string, v: unknown): string {
  if (typeof v !== 'string' || v.trim() === '') {
    throw new BadRequestException(`${name} is required`);
  }
  return v.trim();
}

export function optionalString(v: unknown): string {
  return typeof v === 'string' ? v.trim() : '';
}

export function requireAddress(name: string, v: unknown): Address {
  const s = requireString(name, v);
  if (!isAddress(s, { strict: false })) {
    throw new BadRequestException(`${name} is not a valid address`);
  }
  return getAddress(s);
}

export function optionalAddress(name: string, v: unknown): Address | undefined {
  return v === undefined || v === '' ? undefined : requireAddress(name, v);
}

/// "1.5" -> 1.5e18. Must be > 0.
export function requireAmount(name: string, v: unknown): bigint {
  const s = requireString(name, v);
  if (!/^\d+(\.\d{1,18})?$/.test(s)) {
    throw new BadRequestException(
      `${name} must be a positive decimal number with at most 18 decimals`,
    );
  }
  const wei = parseEther(s);
  if (wei === 0n) throw new BadRequestException(`${name} must be > 0`);
  return wei;
}

export function optionalAmount(name: string, v: unknown): bigint | undefined {
  return v === undefined || v === '' ? undefined : requireAmount(name, v);
}

/// Basis points: integer in [0, max], `fallback` when omitted.
export function bps(
  name: string,
  v: unknown,
  max: number,
  fallback?: number,
): bigint {
  if ((v === undefined || v === '') && fallback !== undefined)
    return BigInt(fallback);
  const s = requireString(name, v);
  if (!/^\d+$/.test(s) || Number(s) > max) {
    throw new BadRequestException(
      `${name} must be an integer from 0 to ${max}`,
    );
  }
  return BigInt(s);
}

/// bigints don't survive JSON, so every amount goes out as both the raw 18-decimal integer
/// and the human-readable decimal.
export function amount(wei: bigint) {
  return { raw: wei.toString(), formatted: formatEther(wei) };
}
