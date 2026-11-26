#!/usr/bin/env bash
# Deploys tUSDT and UpDownVault to BSC testnet (chain 97) from the deployer keystore.
# Run from the repository root:  ./script/deploy-testnet.sh
# It asks for the deployer keystore's password. Only public addresses are in this file.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=https://bsc-testnet-dataseed.bnbchain.org
KEYSTORE="$HOME/.foundry/keystores/crisp-updown-testnet/deployer/551a7f1e-a4c8-4d12-a8c0-2f57158928d3"

DEPLOYER=0x599db79A2f192A14bfef857462025014305AB33c
export VAULT_ADMIN=$DEPLOYER
export VAULT_GUARDIAN=$DEPLOYER
export VAULT_FEE_RECIPIENT=$DEPLOYER
export VAULT_OPERATOR=0xD97d8C0451FCC2ef4078cdE3628fCd3Aa12220bF
export VAULT_ORACLE=0x9596702B27dD4b8F126c21383e298363410e9487

echo "Deployer balance: $(cast balance "$DEPLOYER" --ether --rpc-url "$RPC") tBNB"

forge script script/DeployUpDownVault.s.sol \
  --rpc-url "$RPC" \
  --keystore "$KEYSTORE" \
  --sender "$DEPLOYER" \
  --broadcast --slow
# Foundry 1.0's Sourcify step fails against Sourcify's current API; publish source afterwards through Sourcify's
# v2 API with the compiler input from `forge verify-contract --show-standard-json-input` (see README, Deployments).
