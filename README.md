# DEX Aggregator (Uniswap V2 + V3)

**BLOCKCHAIN2 course — Project 1**

A DEX aggregator contract for Uniswap V2 and V3 on Sepolia. Compares quotes across all four V3 fee tiers (0.01%, 0.05%, 0.30%, 1.00%) and V2 constant-product pools, then routes each swap to the best venue.

The protocol is deployed behind an ERC-1967 UUPS proxy. A first upgrade (V1 → V2) extends single-hop routing with multi-hop paths through a configurable list of intermediate tokens.

For the mathematical analysis — AMM invariants, monotonicity / boundedness / concavity proofs, single-hop optimality theorem, multi-hop dominance characterization — see [`docs/litepaper.pdf`](docs/litepaper.pdf).

---

## Architecture

```
                     ┌──────────────────────────┐
                     │      ERC1967 Proxy        │  ← single stable address
                     │  (upgradeable via UUPS)   │
                     └────────────┬──────────────┘
                                  │  DELEGATECALL
                 ┌────────────────┼────────────────────┐
                 ▼                                     ▼
   ┌───────────────────────┐             ┌────────────────────────┐
   │   DexAggregatorV1     │  ─upgrade→  │    DexAggregatorV2     │
   │  (single-hop V2/V3)   │             │  + multi-hop routing   │
   └───────────┬───────────┘             └──────────┬─────────────┘
               │                                    │
               ▼                                    ▼
   ┌────────────────────────────────────────────────────────────┐
   │   Uniswap V2 Router / Factory / Pair                       │
   │   Uniswap V3 Router / Factory / QuoterV2                   │
   └────────────────────────────────────────────────────────────┘
```

### Contracts

| Contract | Purpose |
|----------|---------|
| `DexAggregatorV1.sol` | Core: quoting + swap across V2 and V3 (single-hop) |
| `DexAggregatorV2.sol` | Upgrade: adds multi-hop through intermediate tokens |
| `DexAggregatorLib.sol` | AMM math (constant-product formula), V3 path encoding |
| `TestToken.sol` | Mintable ERC20 for testing on Sepolia |

### Security
- **AccessControl** — `DEFAULT_ADMIN_ROLE` + `OPERATOR_ROLE`
- **ReentrancyGuard** on all state-modifying functions
- **Pausable** — circuit breaker for swap functions
- **Deadline check** — revert if `block.timestamp > deadline`
- **Slippage protection** — `amountOutMin` enforced
- **SafeERC20** + `forceApprove` for non-standard ERC20s (USDT et al.)
- **ERC-7201 namespaced storage** — collision-safe upgrade layout

---

## Sepolia Deployment

Chain id `11155111`. All contracts verified on Sourcify (exact match of creation + runtime bytecode).

| Contract | Address |
|----------|---------|
| ERC1967 Proxy (stable entry point) | `0x7b43d70CBe2658A09376eB3a8126D426dBb69501` |
| DexAggregatorV1 implementation | `0x860AC17e59d2875FE24541AFAf6A8849409befdB` |
| DexAggregatorV2 implementation (current) | `0x3c9544C5666FCb678eE381390a261bb8E47A6F82` |
| TestTokenA (TKA) | `0x3F8d55D01a59e8327a4eEaf643cd8CAF0ed42993` |
| TestTokenB (TKB) | `0x86C8107D697F99ef61019d62c985b60F11b6c58e` |
| Deployer / Admin | `0x11d7b17BDcaB85626660EBb0AE75a3B4827F0233` |

### Sepolia Uniswap integrations

| Venue | Address |
|-------|---------|
| V2 Router | `0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3` |
| V2 Factory | `0xF62c03E08ada871A0bEb309762E260a7a6a880E6` |
| V3 Router (SwapRouter) | `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E` |
| V3 Factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |
| V3 QuoterV2 | `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3` |
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |

---

## Build & Test

```sh
# install
git clone <this-repo> && cd dex-aggregator
# OZ is vendored under lib/ (cloned directly, not a submodule).

# build
forge build

# run all unit + library + fuzz tests (local, no RPC)
forge test

# run fork tests against real Sepolia state
SEPOLIA_RPC_URL=https://... forge test --match-contract DexAggregatorForkTest -vv
```

Test counts:
- 18 unit tests (`test/DexAggregator.t.sol`)
- 8 library tests (same file, with `LibRevertHelper` for external-call reverts)
- 4 fuzz tests (`test/DexAggregatorFuzz.t.sol`)
- 8 fork tests (`test/DexAggregatorFork.t.sol`)
- **Total: 38 / 38 passing**

---

## Deploy

Set `.env` (see `.env.example`):

```
PRIVATE_KEY=0x...
SEPOLIA_RPC_URL=https://...
PROXY_ADDRESS=0x...   # filled after first deploy, consumed by Upgrade.s.sol
```

```sh
# V1 deploy (implementation + ERC1967 proxy, initialized via delegatecall)
source .env
forge script script/Deploy.s.sol:DeployScript --rpc-url "$SEPOLIA_RPC_URL" --broadcast

# Set PROXY_ADDRESS in .env from the logged proxy address

# V2 upgrade (new impl + upgradeToAndCall with initializeV2([WETH]))
forge script script/Upgrade.s.sol:UpgradeScript --rpc-url "$SEPOLIA_RPC_URL" --broadcast

# Verification (no Etherscan API key needed)
forge verify-contract <ADDR> <PATH>:<NAME> --chain sepolia --verifier sourcify
```

---

## Manual testing walkthrough (Sepolia)

The following sequence reproduces the end-to-end swap that was executed during deployment.

### 1. Verify the upgrade landed

```sh
source .env

# should return "2.0.0" (V2 is current implementation)
cast call $PROXY_ADDRESS "version()(string)" --rpc-url $SEPOLIA_RPC_URL

# V1 storage preserved after upgrade — returns Sepolia V2 Router
cast call $PROXY_ADDRESS "getV2Router()(address)" --rpc-url $SEPOLIA_RPC_URL

# V2 storage initialized — returns [WETH]
cast call $PROXY_ADDRESS "getIntermediateTokens()(address[])" --rpc-url $SEPOLIA_RPC_URL

# Confirm EIP-1967 implementation slot points to V2 impl
cast storage $PROXY_ADDRESS \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url $SEPOLIA_RPC_URL
```

### 2. Wrap ETH and approve the aggregator

```sh
# Wrap 0.005 ETH → WETH
cast send 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 "deposit()" \
  --value 0.005ether \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY

# Approve the proxy to pull 0.005 WETH
cast send 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 "approve(address,uint256)" \
  $PROXY_ADDRESS 5000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

### 3. Query the aggregator for the best quote

```sh
cast call $PROXY_ADDRESS \
  "getQuote(address,address,uint256)((uint8,uint256,uint24))" \
  0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 \
  0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984 \
  5000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL
```

Observed result (block 10660062):

```
(2, 142594212628689, 10000)
  │        │           └── V3 fee tier: 10000 (= 1.00%)
  │        └────────────── amountOut: 0.000142594 UNI
  └─────────────────────── DexType: 2 = V3
```

The aggregator picked V3 at 1% because — at that block's reserves — it strictly dominated both V2 and the other V3 tiers.

### 4. Execute the swap through the aggregator

```sh
DEADLINE=$(($(date +%s) + 3600))

cast send $PROXY_ADDRESS \
  "swap(address,address,uint256,uint256,address,uint256)" \
  0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 \
  0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984 \
  5000000000000000 \
  135000000000000 \
  0x11d7b17BDcaB85626660EBb0AE75a3B4827F0233 \
  $DEADLINE \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

Recorded tx: `0xf3f831c866eada2b411722c11a60f6d461eb16256f8b55bc536922316eac3f11` — status `success`.

Post-swap balances at the deployer address:

| Token | Before | After |
|-------|--------|-------|
| WETH  | 5 000 000 000 000 000 | 0 |
| UNI   | 0 | 142 594 212 628 689 |

`amountOut` matches the off-chain quote exactly (the swap executed at the same block state, so there was no price drift).

### 5. Optional — interact with TestTokens

```sh
# Mint 1M TKA to an address (owner-only)
cast send 0x3F8d55D01a59e8327a4eEaf643cd8CAF0ed42993 "mint(address,uint256)" \
  <RECIPIENT> 1000000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY

# Check a TKA balance
cast call 0x3F8d55D01a59e8327a4eEaf643cd8CAF0ed42993 \
  "balanceOf(address)(uint256)" <ADDR> \
  --rpc-url $SEPOLIA_RPC_URL
```

TKA/TKB are not paired in any Sepolia Uniswap pool. They are provided as ready-to-use ERC20s for future liquidity experiments; the aggregator reuses real WETH/UNI pools for its live swap demo.

---

## Session log

| Session | Scope | Artifacts |
|---------|-------|-----------|
| 1 | Foundry skeleton, Uniswap interfaces, library + fuzz tests | `src/interfaces/*`, `src/libraries/DexAggregatorLib.sol`, `test/DexAggregatorFuzz.t.sol` |
| 2 | V1 core logic, mock-based unit tests, V2 multi-hop impl | `src/DexAggregator{V1,V2}.sol`, `test/DexAggregator.t.sol` |
| 3 | Sepolia fork tests + first deployment + Sourcify verification | `test/DexAggregatorFork.t.sol`, `broadcast/Deploy.s.sol/11155111/` |
| 4 | V1→V2 upgrade, TestTokens, real WETH/UNI swap through aggregator | `broadcast/Upgrade.s.sol/11155111/`, README walkthrough |
| 5 | Litepaper, CI, final polish | `docs/litepaper.tex`, `.github/workflows/test.yml` |

---

## Docs

| Document | Description |
|----------|-------------|
| [`docs/litepaper.pdf`](docs/litepaper.pdf) | Mathematical analysis: AMM invariants, monotonicity / boundedness / concavity proofs, single-hop optimality theorem, multi-hop dominance characterization |
| [`docs/litepaper.tex`](docs/litepaper.tex) | LaTeX source for the litepaper |
| [`docs/dex-aggregator-session-log.md`](docs/dex-aggregator-session-log.md) | Complete session log of the development process |
| [`docs/SESSION LOG.pdf`](docs/SESSION%20LOG.pdf) | PDF version of the session log |

---

## License

MIT
