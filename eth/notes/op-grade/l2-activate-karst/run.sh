#!/usr/bin/env bash
#
# L2 demo: simulate the full official Karst upgrade flow.
#
#   generate : run the OFFICIAL bundle generator (GenerateNUTBundle.s.sol, = `just generate-nut-bundle`)
#              and copy the bundle into ../config/, with a provenance diff vs the committed bundle.
#   activate : add l2GenesisKarstTimeOffset to the devnet intent template (idempotent).
#   verify   : confirm kona injected the bundle at the Karst activation block and write
#              ../config/l2-upgrade-artifacts.json (the L2 counterpart of L1's upgrade-artifacts.json).
#
# The NUT bundle is the INPUT/plan (analogous to L1's opcm.upgrade calldata); the artifacts file is the
# post-execution RESULT (activation block, injected tx count, predeploy versions before/after).
#
set -euo pipefail

OPTIMISM_DIR="${OPTIMISM_DIR:-/home/po/now/xlayer-reth/deps/optimism}"
DEVNET_DIR="${DEVNET_DIR:-/home/po/now/xlayer-toolkit/devnet}"
OP_CONTRACTS_IMAGE="${OP_CONTRACTS_IMAGE:-op-contracts:latest}"
CONFIG_DIR="$(cd "$(dirname "$0")/../config" && pwd)"
L2_DIR="$CONFIG_DIR/l2"; mkdir -p "$L2_DIR"
INTENT_BAK="$DEVNET_DIR/config-op/intent.toml.bak"
ROLLUP_JSON="$DEVNET_DIR/config-op/rollup.json"
FORK_LOCK="$OPTIMISM_DIR/op-core/nuts/fork_lock.toml"

L2_RPC_URL="${L2_RPC_URL:-http://localhost:8123}"
KARST_OFFSET="${KARST_OFFSET:-0x3c}"   # 60s after L2 genesis

COMMITTED_BUNDLE="$OPTIMISM_DIR/op-core/nuts/bundles/karst_nut_bundle.json"
CONDITIONAL_DEPLOYER=0x420000000000000000000000000000000000002C
L1_BLOCK=0x4200000000000000000000000000000000000015
GAS_PRICE_ORACLE=0x420000000000000000000000000000000000000F

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# -------- generate: official NUT bundle generation + provenance --------------
# Mirrors op-core/nuts/README.md:
#   PR1: just generate-nut-bundle      -> snapshots/upgrades/current-upgrade-bundle.json
#   PR2: just nut-snapshot-for karst   -> op-core/nuts/bundles/karst_nut_bundle.json + fork_lock.toml
#   verify: just nut-provenance-verify karst  (regenerate AT THE LOCKED COMMIT, byte-compare)
cmd_generate() {
  log "PR1: generate-nut-bundle (GenerateNUTBundle.s.sol) ..."
  docker run --rm -v "$L2_DIR:/work" "$OP_CONTRACTS_IMAGE" bash -c '
    set -e
    cd /app/packages/contracts-bedrock
    forge script scripts/upgrade/GenerateNUTBundle.s.sol:GenerateNUTBundle --sig "run()" >/tmp/gen.log 2>&1
    cp snapshots/upgrades/current-upgrade-bundle.json /work/karst_nut_bundle.generated.json
  '
  cp "$COMMITTED_BUNDLE" "$L2_DIR/karst_nut_bundle.json"
  # capture the [karst] section of the lock file (hash + source commit)
  awk '/^\[karst\]/{p=1} p&&/^\[/&&!/^\[karst\]/{p=0} p' "$FORK_LOCK" > "$L2_DIR/fork_lock.karst.toml" 2>/dev/null || true
  log "generated -> config/l2/karst_nut_bundle.generated.json"
  log "committed -> config/l2/karst_nut_bundle.json (the bundle kona embeds)"
  log "lock      -> config/l2/fork_lock.karst.toml (hash + source commit)"

  local gtx ctx
  gtx="$(jq '.transactions|length' "$L2_DIR/karst_nut_bundle.generated.json")"
  ctx="$(jq '.transactions|length' "$L2_DIR/karst_nut_bundle.json")"
  log "tx count: generated=$gtx committed=$ctx"
  if diff -q <(jq -S . "$L2_DIR/karst_nut_bundle.generated.json") \
             <(jq -S . "$L2_DIR/karst_nut_bundle.json") >/dev/null; then
    log "current-tree regen == committed (no source drift)."
  else
    log "current-tree regen != committed: source drifted since the locked commit ($(grep -oE 'commit = \"[0-9a-f]+' "$L2_DIR/fork_lock.karst.toml" | grep -oE '[0-9a-f]{40}'))."
    log "  -> the OFFICIAL provenance check regenerates AT THAT COMMIT. Run with PROVENANCE=1 to execute it."
  fi

  if [[ "${PROVENANCE:-0}" == "1" ]]; then
    log "verify: just nut-provenance-verify karst (regenerate at locked commit + byte-compare) ..."
    ( cd "$OPTIMISM_DIR" && just nut-provenance-verify karst ) || log "provenance-verify reported a mismatch/failure (see output)."
  fi
  log "PR2 (lock, not auto-run; mutates tracked files): cd \$OPTIMISM_DIR && just nut-snapshot-for karst"
}

# -------- activate: set the Karst fork time in the devnet intent -------------
cmd_activate() {
  [[ -f "$INTENT_BAK" ]] || { echo "ERROR: $INTENT_BAK not found" >&2; exit 1; }
  if grep -q 'l2GenesisKarstTimeOffset' "$INTENT_BAK"; then
    log "Karst already present:"; grep -n 'l2GenesisKarstTimeOffset' "$INTENT_BAK"
  else
    sed -i 's/\(\([[:space:]]*\)l2GenesisJovianTimeOffset = .*\)/\1\n\2l2GenesisKarstTimeOffset = "'"$KARST_OFFSET"'"      # Karst fork activation (added for demo)/' "$INTENT_BAK"
    log "Added l2GenesisKarstTimeOffset=\"$KARST_OFFSET\" to $INTENT_BAK"
  fi
  cat <<EOF
Next: in $DEVNET_DIR/.env set SKIP_OP_STACK_BUILD=false and SKIP_KONA_BUILD=false (ensure kona has Karst),
then  cd $DEVNET_DIR && make run ; wait past the activation, then  ./run.sh verify
EOF
}

# -------- verify: confirm execution + emit l2-upgrade-artifacts.json ---------
# first L2 block with timestamp >= karst_time, via binary search over [genesis, latest]
find_activation_block() {
  local kt="$1" lo="$2" hi mid ts
  hi="$(cast block-number --rpc-url "$L2_RPC_URL")"
  while (( lo < hi )); do
    mid=$(( (lo + hi) / 2 ))
    ts="$(cast block "$mid" -f timestamp --rpc-url "$L2_RPC_URL" 2>/dev/null)"
    if (( ts >= kt )); then hi=$mid; else lo=$((mid+1)); fi
  done
  echo "$lo"
}

predeploy_version_at() {  # addr block
  cast call "$1" 'version()(string)' --rpc-url "$L2_RPC_URL" --block "$2" 2>/dev/null | tr -d '"' || echo ""
}

cmd_verify() {
  log "L2 RPC = $L2_RPC_URL"
  local KT GEN LATEST ACT BEFORE
  KT="$(jq -r '.karst_time' "$ROLLUP_JSON" 2>/dev/null || true)"
  GEN="$(jq -r '.l2_genesis.number // .genesis.l2.number' "$ROLLUP_JSON" 2>/dev/null || true)"
  LATEST="$(cast block-number --rpc-url "$L2_RPC_URL")"
  [[ -z "$KT" || "$KT" == null ]] && { echo "ERROR: no karst_time in $ROLLUP_JSON (is Karst activated?)" >&2; exit 1; }
  log "karst_time=$KT  genesis_block=$GEN  latest=$LATEST"

  # ConditionalDeployer (0x42..2C) is a genesis proxy (code always present); the REAL Karst signal is its
  # EIP-1967 implementation pointer going 0x0 -> <impl> when the Karst bundle deploys + wires it.
  local EIP1967_IMPL=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
  local IMPL_NOW; IMPL_NOW="$(cast storage "$CONDITIONAL_DEPLOYER" "$EIP1967_IMPL" --rpc-url "$L2_RPC_URL")"
  if [[ "$IMPL_NOW" =~ ^0x0+$ ]]; then echo "FAIL: ConditionalDeployer impl pointer is zero -> Karst bundle not executed yet." >&2; exit 1; fi
  log "ConditionalDeployer impl pointer (latest) = $IMPL_NOW (non-zero => Karst executed)"

  ACT="$(find_activation_block "$KT" "${GEN:-1}")"
  BEFORE=$((ACT - 1))
  local ACT_TS NTX
  ACT_TS="$(cast block "$ACT" -f timestamp --rpc-url "$L2_RPC_URL")"
  NTX="$(cast block "$ACT" --json --rpc-url "$L2_RPC_URL" 2>/dev/null | jq '.transactions|length' 2>/dev/null || echo null)"
  log "Karst activation block = $ACT (ts=$ACT_TS), txCount=$NTX (NUT deposit txs injected by kona)"

  # before/after predeploy versions
  local L1B_BEFORE L1B_AFTER GPO_BEFORE GPO_AFTER
  L1B_BEFORE="$(predeploy_version_at "$L1_BLOCK" "$BEFORE")";  L1B_AFTER="$(predeploy_version_at "$L1_BLOCK" "$LATEST")"
  GPO_BEFORE="$(predeploy_version_at "$GAS_PRICE_ORACLE" "$BEFORE")"; GPO_AFTER="$(predeploy_version_at "$GAS_PRICE_ORACLE" "$LATEST")"
  log "L1Block.version()      before=$L1B_BEFORE  after=$L1B_AFTER"
  log "GasPriceOracle.version() before=$GPO_BEFORE  after=$GPO_AFTER"

  # kona evidence
  local KONA_EVID
  KONA_EVID="$(docker logs op-kona-seq 2>&1 | grep -iE 'karst|Sequencing karst upgrade block' | tail -2 | tr '\n' ';' || true)"

  # bundle facts
  local BUNDLE_HASH BUNDLE_TX
  BUNDLE_HASH="$(grep -A3 '\[karst\]' "$OPTIMISM_DIR/op-core/nuts/fork_lock.toml" 2>/dev/null | grep -oE 'sha256:[0-9a-f]+' | head -1 || echo '')"
  BUNDLE_TX="$(jq '.transactions|length' "$COMMITTED_BUNDLE" 2>/dev/null || echo null)"

  # ConditionalDeployer EIP-1967 impl pointer: 0x0 before Karst, set after (the unambiguous witness)
  local CD_IMPL_BEFORE CD_IMPL_AFTER
  CD_IMPL_BEFORE="$(cast storage "$CONDITIONAL_DEPLOYER" "$EIP1967_IMPL" --block "$BEFORE" --rpc-url "$L2_RPC_URL" 2>/dev/null)"
  CD_IMPL_AFTER="$IMPL_NOW"
  log "ConditionalDeployer impl pointer: before(blk $BEFORE)=$CD_IMPL_BEFORE  after=$CD_IMPL_AFTER"

  local ART="$L2_DIR/l2-upgrade-artifacts.json"
  jq -n \
    --argjson kt "$KT" --arg gen "${GEN:-}" --argjson act "$ACT" --argjson before "$BEFORE" \
    --argjson latest "$LATEST" --argjson actTs "$ACT_TS" --argjson ntx "${NTX:-null}" \
    --arg l1bB "$L1B_BEFORE" --arg l1bA "$L1B_AFTER" --arg gpoB "$GPO_BEFORE" --arg gpoA "$GPO_AFTER" \
    --arg kona "$KONA_EVID" --arg bhash "$BUNDLE_HASH" --argjson btx "${BUNDLE_TX:-null}" \
    --arg cdB "$CD_IMPL_BEFORE" --arg cdA "$CD_IMPL_AFTER" \
    '{
      chain: "l2",
      description: "Activate Karst -> kona injects NUT bundle at fork block -> L2ProxyAdmin.upgradePredeploys -> delegatecall L2CM.upgrade (per l2-upgrades-1-execution spec)",
      bundle: { file: "l2/karst_nut_bundle.json", generated: "l2/karst_nut_bundle.generated.json",
                lock: "l2/fork_lock.karst.toml", sha256: $bhash, txCount: $btx,
                generatedBy: "GenerateNUTBundle.s.sol (just generate-nut-bundle)" },
      activation: { karstTime: $kt, genesisBlock: $gen, activationBlock: $act,
                    activationBlockTs: $actTs, latestBlock: $latest,
                    injectedTxCountInBlock: $ntx, injectedBy: "kona (consensus layer), depositor account" },
      verification: {
        conditionalDeployerImplPointer: { before: $cdB, after: $cdA, note: "0x0 before Karst -> impl set after (proves the bundle deployed+wired it)" },
        predeployVersions: {
          L1Block:        { before: $l1bB, after: $l1bA },
          GasPriceOracle: { before: $gpoB, after: $gpoA }
        },
        konaEvidence: $kona
      },
      executionModel: "no operator tx / no receipt: operator only sets karst_time (via op-deployer/intent); kona executes the bundle deterministically at the activation block. This artifact is an observed-result record, NOT something OP itself produces."
    }' > "$ART"
  log "wrote L2 artifact -> $ART"
  log "DONE."
}

case "${1:-}" in
  generate) cmd_generate ;;
  activate) cmd_activate ;;
  verify)   cmd_verify ;;
  *) echo "usage: $0 {generate|activate|verify}" >&2; exit 2 ;;
esac
