import { BadRequestException } from '@nestjs/common';
import {
  formatUnits,
  getAddress,
  isAddress,
  maxUint256,
  parseUnits,
  zeroAddress,
  type Address,
} from 'viem';

/// Query-string parsing. Every amount is a human decimal ("0.5" BNB, "1000" coins). Coins have
/// 18 decimals; quote amounts use the quote token's own decimals.

export function requireString(name: string, v: unknown): string {
  if (typeof v !== 'string' || v.trim() === '') {
    throw new BadRequestException(`${name} is required`);
  }
  return v.trim();
}

export function optionalString(v: unknown): string {
  return typeof v === 'string' ? v.trim() : '';
}

const isMissing = (v: unknown) => v === undefined || v === '';

export function requireAddress(name: string, v: unknown): Address {
  const s = requireString(name, v);
  if (!isAddress(s, { strict: false })) {
    throw new BadRequestException(`${name} is not a valid address`);
  }
  return getAddress(s);
}

export function optionalAddress(name: string, v: unknown): Address | undefined {
  return isMissing(v) ? undefined : requireAddress(name, v);
}

/// A quote token: omitted, "native", "bnb" or the zero address all mean native BNB.
export function quoteTokenAddress(name: string, v: unknown): Address {
  if (isMissing(v)) return zeroAddress;
  const s = requireString(name, v).toLowerCase();
  return s === 'native' || s === 'bnb' ? zeroAddress : requireAddress(name, v);
}

/// "1.5" -> 1.5 * 10^decimals. Must be > 0 unless `allowZero`.
export function requireAmount(
  name: string,
  v: unknown,
  decimals = 18,
  { allowZero = false } = {},
): bigint {
  const s = requireString(name, v);
  const fraction = decimals > 0 ? `(\\.\\d{1,${decimals}})?` : '';
  if (!new RegExp(`^\\d+${fraction}$`).test(s)) {
    throw new BadRequestException(
      `${name} must be a non-negative decimal number with at most ${decimals} decimals`,
    );
  }
  const raw = parseUnits(s, decimals);
  if (raw === 0n && !allowZero) {
    throw new BadRequestException(`${name} must be > 0`);
  }
  return raw;
}

export function optionalAmount(
  name: string,
  v: unknown,
  decimals = 18,
): bigint | undefined {
  return isMissing(v) ? undefined : requireAmount(name, v, decimals);
}

/// Like requireAmount, but also takes "max" (2^256 - 1) and 0, for ERC20 approvals.
export function allowanceAmount(name: string, v: unknown): bigint {
  return requireString(name, v).toLowerCase() === 'max'
    ? maxUint256
    : requireAmount(name, v, 18, { allowZero: true });
}

/// Non-negative integer, `fallback` when omitted.
export function optionalInt(
  name: string,
  v: unknown,
  fallback: number,
): number {
  if (isMissing(v)) return fallback;
  const s = requireString(name, v);
  if (!/^\d+$/.test(s)) {
    throw new BadRequestException(`${name} must be a non-negative integer`);
  }
  return Number(s);
}

/// Basis points: integer in [0, max], `fallback` when omitted.
export function bps(
  name: string,
  v: unknown,
  max: number,
  fallback?: number,
): bigint {
  if (isMissing(v) && fallback !== undefined) return BigInt(fallback);
  const s = requireString(name, v);
  if (!/^\d+$/.test(s) || Number(s) > max) {
    throw new BadRequestException(
      `${name} must be an integer from 0 to ${max}`,
    );
  }
  return BigInt(s);
}

/// bigints don't survive JSON, so every amount goes out as both the raw integer and the
/// human-readable decimal.
export function amount(raw: bigint, decimals = 18) {
  return { raw: raw.toString(), formatted: formatUnits(raw, decimals) };
}
