// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Math for a linear bonding curve with price y = -m*x + b.
///
///   x = tokens still left on the curve (starts at curveSupply, falls to 0 as people buy)
///   b = end price, paid when the curve is empty
///   m = (b - startPrice) / curveSupply
///
/// So the price starts at `startPrice` (x = curveSupply) and climbs linearly to `b` (x = 0).
/// m is never stored: for large supplies it is too small for 18-decimal fixed point, so every
/// formula is written in terms of b, startPrice and curveSupply instead.
///
/// Units: token amounts have 18 decimals; prices are wei per whole token (1e18 units).
library LinearCurveMath {
    uint256 internal constant WAD = 1e18;

    /// @notice End price b such that selling the whole curve raises `threshold` wei.
    /// From threshold = curveSupply * (startPrice + b) / 2. Rounded up so the curve raises at least `threshold`.
    function endPrice(uint256 threshold, uint256 startPrice, uint256 curveSupply) internal pure returns (uint256) {
        return Math.ceilDiv(2 * threshold * WAD, curveSupply) - startPrice;
    }

    /// @notice Spot price when x tokens are left on the curve: b - m*x.
    function priceAt(uint256 b, uint256 startPrice, uint256 curveSupply, uint256 x) internal pure returns (uint256) {
        return b - (b - startPrice) * x / curveSupply;
    }

    /// @notice Wei to buy the tokens between x0 and x1 left on the curve (x0 <= x1), rounded up.
    function buyCost(uint256 b, uint256 startPrice, uint256 curveSupply, uint256 x0, uint256 x1)
        internal
        pure
        returns (uint256)
    {
        return _area(b, startPrice, curveSupply, x0, x1, Math.Rounding.Ceil);
    }

    /// @notice Wei returned for selling tokens back from x0 to x1 left on the curve (x0 <= x1), rounded down.
    function sellRefund(uint256 b, uint256 startPrice, uint256 curveSupply, uint256 x0, uint256 x1)
        internal
        pure
        returns (uint256)
    {
        return _area(b, startPrice, curveSupply, x0, x1, Math.Rounding.Floor);
    }

    /// @notice Most tokens `budget` wei buys when x tokens are left on the curve. Not capped at x.
    /// Buying d tokens costs d*p + m*d^2/2 (p = current price), so solving for d:
    ///   d = 2 * budget / (p + sqrt(p^2 + 2 * m * budget))
    /// This form never divides by the tiny m. Every step rounds toward fewer tokens,
    /// so buyCost(x - d, x) <= budget always holds.
    function tokensForCost(uint256 b, uint256 startPrice, uint256 curveSupply, uint256 x, uint256 budget)
        internal
        pure
        returns (uint256)
    {
        uint256 p = priceAt(b, startPrice, curveSupply, x);
        uint256 twoMBudget = Math.mulDiv(2 * (b - startPrice) * budget, WAD, curveSupply, Math.Rounding.Ceil);
        uint256 root = Math.sqrt(p * p + twoMBudget, Math.Rounding.Ceil);
        return Math.mulDiv(2 * budget, WAD, p + root);
    }

    /// Area under the curve between x0 and x1:
    ///   (x1 - x0) * average price = (x1 - x0) * (b - m (x0 + x1) / 2)
    /// multiplied through by 2 * curveSupply so m's division happens once, at the end.
    function _area(uint256 b, uint256 startPrice, uint256 curveSupply, uint256 x0, uint256 x1, Math.Rounding rounding)
        private
        pure
        returns (uint256)
    {
        uint256 avgPriceTimes2C = 2 * curveSupply * b - (b - startPrice) * (x0 + x1);
        return Math.mulDiv(x1 - x0, avgPriceTimes2C, 2 * curveSupply * WAD, rounding);
    }
}
