# Staking system integration

Components (unchanged from the accepted branches):

- `src/StakeToken.sol`: fixed-supply ERC-20, 1,000,000 STK minted to `holder`.
- `src/StakingPool.sol`: 7-day Synthetix-style rewards pool.
- `src/RewardsDistributor.sol`: permissionless weekly `drip()` into the pool.

Integration tests: `test/StakingIntegration.t.sol`. There are no mocks; every test deploys the
real three contracts, and STK is both the stake and the reward token.

## Deployment wiring (tests only, nothing deployed)

1. `stk = new StakeToken(treasury)`
2. `predicted = vm.computeCreateAddress(this, vm.getNonce(this) + 1)`
3. `pool = new StakingPool(stk, stk, predicted)`: the pool stores the distributor address and
   does not check its code, so a not-yet-deployed address is accepted.
4. `distributor = new RewardsDistributor(stk, pool, 10_000e18)`. The test requires
   `address(distributor) == predicted` and checks both back-references.
5. The treasury sends 100,000 STK to the distributor.

## Interface check and writer guesses

| Point | What each writer assumed | Resolution |
|---|---|---|
| `nextDrip()` view | Distributor: public storage var, first value `0`, so the first drip can happen right away; after that it is `block.timestamp + 7 days` | Matches the spec getter. Tested. |
| `totalStaked()`, `balanceOf(address)` | Pool: public storage vars | The generated getters match the spec. |
| `IStakingPool` in the distributor | Only `notifyRewardAmount(uint256)` | Same signature as the pool's function. |
| `IERC20` | Distributor declares `balanceOf`/`transfer`; pool also declares `transferFrom` | Both are subsets of StakeToken's ABI. Both files name the interface `IERC20`, but the tests import only the contracts they need, so the names don't clash. |
| Order of transfer and notify | Pool expects rewards "already transferred"; distributor transfers first, then calls `notify` | Compatible: the pool's balance check sees the new tokens. |
| Drip amount | Distributor sends `min(weeklyAmount, balance)` | 100k at 10k/week gives exactly 10 drips, then `NothingToDrip`. Tested. |
| Period length | Pool `DURATION = 7 days`, distributor `DRIP_INTERVAL = 7 days` | Equal. A drip made on time finds no leftover. Late drips are not caught up: emission pauses and nothing is lost. |
| Same token for stake and reward | Pool subtracts `totalStaked` from its balance when `stakeToken == rewardToken` | This is what keeps principal safe. |
| Idle rewards | Pool collects rewards that elapsed with no stakers in `idleRewards` and adds them to the next notify | Covers the "re-emitted next week" requirement. Tested for a full idle week and a partial one. |
| Token return values | Pool uses a low-level call that accepts tokens returning nothing; distributor requires a `bool` | STK returns `true`, so both work. |
| `exit()` with no stake | Pool reverts (`ZeroAmount`) | Kept. The spec says nothing either way. |

No source file was changed. The interfaces matched as written.

## Results

`forge test` (forge 1.8.3, default config, no `foundry.toml`): 14 passed, 0 failed.

- 13 scenario tests, covering: three stakers over three weeks (2,500/7,500 → 1,250/3,750/5,000 →
  2,000/0/8,000); a second drip inside 7 days reverting, including at `nextDrip - 1`; idle
  re-emission; a stake 1 s before a drip plus a withdraw 60 s after earning only its time share;
  stake, drip and withdraw in the same block earning 0; stranger `notify` reverting (also after the
  stranger funds the pool); an unfunded notify backed only by principal reverting; daily claims
  over 21 days; the distributor running dry after 10 weeks.
- Invariants (64 runs × 64 calls, `fail-on-revert`, 0 reverts) via a handler that performs
  stake/withdraw/getReward/exit/warp/drip/stranger-notify:
  - pool balance ≥ totalStaked + Σ earned
  - total claimed ≤ total claimed + Σ earned ≤ total dripped
  - a stranger's notify never succeeds
  - STK is conserved

Assertions use `require`; cheatcodes come from an inline `Vm` interface (`warp`, `prank`,
`expectRevert`, `computeCreateAddress`, `getNonce`).

## Findings and limitations

- **Over-commit in `notifyRewardAmount` (not reachable through the integrated distributor).**
  The solvency check compares the new rate with `balance - totalStaked`. That figure still
  includes rewards that were accrued but not claimed. If the distributor address called
  `notify` without transferring tokens, rewards could be promised twice.
  `test_OverCommittedNotifyStillCannotTouchPrincipal` shows that principal stays safe even then:
  `_takeReward` refuses to pay beyond free balance, so the late claimer's `getReward` (and `exit`)
  reverts, while `withdraw` still returns the full principal. `RewardsDistributor` always
  transfers `amount` before it notifies, so this cannot happen in the integrated system. The
  pool was left unchanged. Making the check exact would mean tracking committed-but-unpaid
  rewards in the pool.
- **Rounding dust.** `rewardRate = total / 7 days` rounds down, so each notify strands less
  than 604,800 wei, which is never re-emitted. The tests allow a 1e9-wei tolerance for this.
- **Anyone can call `drip()`.** It only moves the fixed weekly amount on schedule, and the
  pool's time weighting keeps a caller from timing it for profit (tested).
- **Scope of these results.** They are local Foundry runs only: no deployment, no fork. Fee-on-transfer and
  rebasing tokens are out of scope (the pool documents this). The invariant run is modest
  (4,096 calls) and does not replace a formal review.
