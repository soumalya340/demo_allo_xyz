pragma solidity =0.5.16;

// Pulls the real PancakeSwap V2 core from deps/ into the build (it needs solc 0.5.16),
// so tests can deploy it with deployCode("PancakeFactory.sol:PancakeFactory", ...).
import "../../deps/pancake-swap-core/contracts/PancakeFactory.sol";
