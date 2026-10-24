#!/usr/bin/env bash
# Deploys PoolFactory and prints the deployer's real on-chain balance before and after.
#
#   ./script/deploy.sh bsc_testnet          # or: bsc, local
#
# Extra arguments go straight to forge, e.g. ./script/deploy.sh bsc_testnet --verify
set -euo pipefail

cd "$(dirname "$0")/.."
NETWORK="${1:?usage: script/deploy.sh <bsc|bsc_testnet|local> [forge args...]}"
shift

set -a; source .env; set +a
KEY="${PRIVATE_KEY#0x}"
DEPLOYER=$(cast wallet address --private-key "0x$KEY")

balance() { cast balance "$DEPLOYER" --rpc-url "$NETWORK"; }

BEFORE=$(balance)
echo "deployer:       $DEPLOYER"
echo "balance before: $(cast from-wei "$BEFORE") BNB"

# BNB Chain: pin 0.1 gwei (forge's own estimate is 1 wei there). Anvil prices its own gas.
GAS_FLAGS=()
[[ "$NETWORK" == bsc* ]] && GAS_FLAGS=(--legacy --with-gas-price 0.1gwei)

forge script script/DeployFactory.s.sol --rpc-url "$NETWORK" --broadcast ${GAS_FLAGS[@]+"${GAS_FLAGS[@]}"} "$@"

AFTER=$(balance)
echo "balance before: $(cast from-wei "$BEFORE") BNB"
echo "balance after:  $(cast from-wei "$AFTER") BNB"
echo "spent:          $(cast from-wei "$(echo "$BEFORE - $AFTER" | bc)") BNB"
