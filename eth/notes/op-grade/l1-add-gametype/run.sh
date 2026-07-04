#!/usr/bin/env bash
#
# L1 demo (OFFICIAL OPCM path): add a dispute game type via op-deployer's
# `manage add-game-type-v2`, which is an alias for the OPCM V2 *upgrade* flow.
#
#   add-game-type-v2  ==  op-deployer upgrade (default upgrader)
#       -> produces the opcm.upgrade(UpgradeInputV2) calldata (selector 0x8a847e2e)
#       -> { to: <prank = l1ProxyAdminOwner>, data: <upgrade calldata> }
#
# OPCM.upgrade atomically (re-)deploys + registers the dispute game impls for the
# requested game types in ONE transaction. In production the calldata is executed by
# the ProxyAdminOwner Safe via DELEGATECALL. Here OWNER_TYPE=transactor, so we execute
# the SAME calldata via Transactor.DELEGATECALL(opcm, data) with a single owner key.
#
# Flow:
#   1. op-deployer manage add-game-type-v2 --config <config.json> --outfile <out.json>   (docker, official)
#   2. execute out.json[0] via Transactor.DELEGATECALL(opcm, data)
#   3. verify DisputeGameFactory.gameImpls(newType) is now a real OPCM-deployed impl
#
# All keys/addresses are standard LOCAL DEVNET test accounts. Never reuse on a real network.
set -euo pipefail

# ---- configuration (override via env) ---------------------------------------
DEVNET_DIR="${DEVNET_DIR:-/home/po/now/xlayer-toolkit/devnet}"
DOCKER_NETWORK="${DOCKER_NETWORK:-dev-op}"
OP_CONTRACTS_IMAGE="${OP_CONTRACTS_IMAGE:-op-contracts:latest}"
ARTIFACTS_URL="${ARTIFACTS_URL:-file:///app/packages/contracts-bedrock/forge-artifacts}"

L1_RPC_URL="${L1_RPC_URL:-http://localhost:8545}"                 # host-side L1 RPC
L1_RPC_URL_IN_DOCKER="${L1_RPC_URL_IN_DOCKER:-http://l1-geth:8545}"

# The config describing the desired game-type set (UpgradeOPChainInput). Lives in ../config/l1/.
CONFIG="${CONFIG:-$(dirname "$0")/../config/l1/add_game_type_config.json}"

# Owner key (controls the prank / l1ProxyAdminOwner). Export yourself; do NOT commit a real key.
: "${PRIVATE_KEY:?set PRIVATE_KEY to the EOA controlling l1ProxyAdminOwner (anvil/foundry #0)}"

# The new game type id we expect to appear (for verification only).
VERIFY_GAME_TYPE="${VERIFY_GAME_TYPE:-0}"
DISPUTE_GAME_FACTORY="${DISPUTE_GAME_FACTORY:-}"

# L1 dev geth caps gas at 2^24; the Transactor swallows inner reverts so eth_estimateGas
# under-estimates — we MUST pass an explicit gas limit (the geth cap).
GAS_LIMIT="${GAS_LIMIT:-16777216}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

resolve_dgf() {
  if [[ -n "$DISPUTE_GAME_FACTORY" ]]; then return; fi
  local s="$DEVNET_DIR/config-op/state.json"
  if [[ -f "$s" ]]; then
    DISPUTE_GAME_FACTORY="$(jq -r '.opChainDeployments[0].DisputeGameFactoryProxy // .DisputeGameFactoryProxy // empty' "$s" 2>/dev/null || true)"
  fi
  if [[ -z "$DISPUTE_GAME_FACTORY" || "$DISPUTE_GAME_FACTORY" == null ]]; then
    echo "ERROR: set DISPUTE_GAME_FACTORY" >&2; exit 1
  fi
}

OPCM="$(jq -r '.opcm' "$CONFIG")"
PRANK="$(jq -r '.prank' "$CONFIG")"
WORKDIR="$(cd "$(dirname "$CONFIG")" && pwd)"
OUT="$WORKDIR/add_game_type_output.json"

resolve_dgf
log "OPCM      = $OPCM"
log "prank     = $PRANK   (l1ProxyAdminOwner / executor)"
log "DGF       = $DISPUTE_GAME_FACTORY"
log "config    = $CONFIG"

BEFORE="$(cast call "$DISPUTE_GAME_FACTORY" 'gameImpls(uint32)(address)' "$VERIFY_GAME_TYPE" --rpc-url "$L1_RPC_URL")"
log "BEFORE gameImpls($VERIFY_GAME_TYPE) = $BEFORE"

# ---- 1. official op-deployer: generate the opcm.upgrade calldata ------------
log "Running op-deployer manage add-game-type-v2 (official OPCM upgrade) ..."
docker run --rm --network "$DOCKER_NETWORK" -v "$WORKDIR:/work" "$OP_CONTRACTS_IMAGE" \
  /app/op-deployer/bin/op-deployer manage add-game-type-v2 \
    --config "/work/$(basename "$CONFIG")" \
    --l1-rpc-url "$L1_RPC_URL_IN_DOCKER" \
    --override-artifacts-url "$ARTIFACTS_URL" \
    --outfile "/work/$(basename "$OUT")"

DATA="$(jq -r '.[0].data' "$OUT")"
TO="$(jq -r '.[0].to' "$OUT")"
SEL="${DATA:0:10}"
log "generated calldata: to=$TO selector=$SEL (0x8a847e2e == opcm.upgrade)"
[[ "$SEL" == "0x8a847e2e" ]] || log "WARNING: unexpected selector $SEL"

# ---- 2. execute the calldata via Transactor.DELEGATECALL(opcm, data) --------
# DELEGATECALL is MANDATORY: OPCM.upgrade() reverts unless address(this)!=opcm (_onlyDelegateCall),
# and its inner DGF/ProxyAdmin calls must have msg.sender == owner. Mirrors a Safe operation=DelegateCall.
log "Executing via Transactor.DELEGATECALL(opcm, data) with gas-limit $GAS_LIMIT ..."
SEND_OUT="$(cast send "$PRANK" "DELEGATECALL(address,bytes)" "$OPCM" "$DATA" \
  --private-key "$PRIVATE_KEY" --legacy --gas-limit "$GAS_LIMIT" --rpc-url "$L1_RPC_URL" 2>&1 || true)"
printf '%s\n' "$SEND_OUT" | grep -iE '^(status|transactionHash|gasUsed|blockNumber)' || true
TXHASH="$(printf '%s' "$SEND_OUT" | grep -oiE 'transactionHash[^0]*0x[0-9a-f]{64}' | grep -oE '0x[0-9a-f]{64}' | head -1 || true)"
GASUSED="$(printf '%s' "$SEND_OUT" | grep -iE '^gasUsed' | grep -oE '[0-9]+' | head -1 || true)"

# ---- 3. verify --------------------------------------------------------------
AFTER="$(cast call "$DISPUTE_GAME_FACTORY" 'gameImpls(uint32)(address)' "$VERIFY_GAME_TYPE" --rpc-url "$L1_RPC_URL")"
BOND="$(cast call "$DISPUTE_GAME_FACTORY" 'initBonds(uint32)(uint256)' "$VERIFY_GAME_TYPE" --rpc-url "$L1_RPC_URL")"
log "AFTER  gameImpls($VERIFY_GAME_TYPE) = $AFTER"
log "       initBonds($VERIFY_GAME_TYPE) = $BOND"
if [[ "$AFTER" =~ ^0x0+$ ]]; then
  echo "FAIL: game type $VERIFY_GAME_TYPE not registered (gameImpls still zero)." >&2
  echo "      The Transactor swallows inner reverts; if gasUsed was tiny, raise GAS_LIMIT or check the upgrade config." >&2
  exit 1
fi
log "OK: OPCM atomically deployed + registered game type $VERIFY_GAME_TYPE -> $AFTER"
ver="$(cast call "$AFTER" 'version()(string)' --rpc-url "$L1_RPC_URL" 2>/dev/null || echo '?')"
gt="$(cast call "$AFTER" 'gameType()(uint32)' --rpc-url "$L1_RPC_URL" 2>/dev/null || echo '?')"
log "       impl.version()=$ver  impl.gameType()=$gt"

# ---- 4. emit consolidated artifact (intent + calldata + execution) ----------
ARTIFACT="$WORKDIR/upgrade-artifacts.json"
jq -n \
  --arg opcm "$OPCM" --arg prank "$PRANK" --arg dgf "$DISPUTE_GAME_FACTORY" \
  --arg sysconf "$(jq -r '.upgradeInput.systemConfig' "$CONFIG")" \
  --argjson gtype "$VERIFY_GAME_TYPE" \
  --arg impl "$AFTER" --arg implVer "${ver//\"/}" --arg bond "$BOND" \
  --arg sel "$SEL" --arg data "$DATA" --arg to "$TO" \
  --arg txhash "${TXHASH:-}" --arg gas "${GASUSED:-}" --argjson gaslimit "$GAS_LIMIT" \
  --arg intent "../intent.toml" --arg cfg "$(basename "$CONFIG")" --arg out "$(basename "$OUT")" \
  '{
    chain: "l1",
    description: "Add dispute game type atomically via OPCM upgrade (op-deployer manage add-game-type-v2)",
    addresses: { opcm: $opcm, l1ProxyAdminOwner_prank: $prank, disputeGameFactory: $dgf, systemConfig: $sysconf },
    addedGameType: { id: $gtype, deployedImpl: $impl, implVersion: $implVer, initBond: $bond },
    calldata: {
      generatedBy: "op-deployer manage add-game-type-v2",
      function: "opcm.upgrade((address,(bool,uint256,uint32,bytes)[],(string,bytes)[]))",
      selector: $sel, to: $to, data: $data
    },
    execution: { method: "delegatecall", via: "Transactor.DELEGATECALL(opcm,data)",
                 reason: "OPCM._onlyDelegateCall + inner DGF/ProxyAdmin calls need msg.sender==owner",
                 gasLimit: $gaslimit, txHash: $txhash, gasUsed: $gas },
    inputs: { intentToml: $intent, upgradeConfig: $cfg, opDeployerOutput: $out }
  }' > "$ARTIFACT"
log "wrote consolidated artifact -> $ARTIFACT"
log "DONE."
