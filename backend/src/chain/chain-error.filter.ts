import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpStatus,
} from '@nestjs/common';
import type { Response } from 'express';
import {
  BaseError,
  ContractFunctionRevertedError,
  decodeErrorResult,
  InsufficientFundsError,
  type Hex,
} from 'viem';
import { bondingCurvePoolAbi, poolFactoryAbi } from './abis.js';

const abi = [...poolFactoryAbi, ...bondingCurvePoolAbi];

/// viem errors -> HTTP. A contract revert is the caller's problem (400, with the Solidity
/// error name and args); anything else means the RPC failed us (502).
@Catch(BaseError)
export class ChainErrorFilter implements ExceptionFilter {
  catch(err: BaseError, host: ArgumentsHost) {
    const res = host.switchToHttp().getResponse<Response>();
    const revert = decodeRevert(err);
    if (revert) {
      res.status(HttpStatus.BAD_REQUEST).json({
        statusCode: HttpStatus.BAD_REQUEST,
        message: `Transaction would revert: ${revert.name}`,
        error: revert.name,
        args: revert.args,
      });
      return;
    }
    if (err.walk((e) => e instanceof InsufficientFundsError)) {
      res.status(HttpStatus.BAD_REQUEST).json({
        statusCode: HttpStatus.BAD_REQUEST,
        message: '`from` does not have enough BNB for value + gas',
      });
      return;
    }
    res.status(HttpStatus.BAD_GATEWAY).json({
      statusCode: HttpStatus.BAD_GATEWAY,
      message: err.shortMessage,
    });
  }
}

function decodeRevert(
  err: BaseError,
): { name: string; args: string[] } | undefined {
  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError);
  if (reverted instanceof ContractFunctionRevertedError && reverted.data) {
    return {
      name: reverted.data.errorName,
      args: (reverted.data.args ?? []).map(String),
    };
  }

  // Raw eth_call / eth_estimateGas reverts carry the error bytes somewhere down the cause chain.
  let data: Hex | undefined;
  err.walk((e) => {
    const d = (e as { data?: unknown }).data;
    const hex = typeof d === 'object' && d ? (d as { data?: unknown }).data : d;
    if (typeof hex === 'string' && /^0x[0-9a-fA-F]{8,}$/.test(hex)) {
      data = hex as Hex;
      return true;
    }
    return false;
  });
  if (!data) {
    return reverted ? { name: 'unknown', args: [] } : undefined;
  }
  try {
    const decoded = decodeErrorResult({ abi, data });
    return {
      name: decoded.errorName,
      args: (decoded.args ?? []).map(String),
    };
  } catch {
    return { name: data.slice(0, 10), args: [] };
  }
}
