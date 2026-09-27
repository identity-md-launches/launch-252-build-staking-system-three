// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakeToken} from "../src/StakeToken.sol";
import {StakingPool} from "../src/StakingPool.sol";
import {RewardsDistributor} from "../src/RewardsDistributor.sol";

/// @dev Minimal cheatcode surface; the tree has no forge-std.
interface Vm {
    function warp(uint256 newTimestamp) external;
    function prank(address msgSender) external;
    function expectRevert(bytes calldata revertData) external;
    function expectRevert(bytes4 revertData) external;
    function computeCreateAddress(address deployer, uint256 nonce) external pure returns (address);
    function getNonce(address account) external view returns (uint64);
}

address constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
uint256 constant WEEK = 7 days;
uint256 constant WEEKLY = 10_000 ether;
uint256 constant FUNDING = 100_000 ether;

/// @dev Deploys the real system: token, then the pool pointed at the distributor's
///      predicted CREATE address, then the distributor. StakeToken is both the
///      staking and the reward token.
abstract contract SystemBase {
    Vm internal constant vm = Vm(HEVM_ADDRESS);

    address internal constant TREASURY = address(0x7EA5);

    StakeToken internal stk;
    StakingPool internal pool;
    RewardsDistributor internal distributor;

    function _deploySystem() internal {
        stk = new StakeToken(TREASURY);
        address predicted = vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        pool = new StakingPool(address(stk), address(stk), predicted);
        distributor = new RewardsDistributor(address(stk), address(pool), WEEKLY);
        require(address(distributor) == predicted, "distributor not at predicted address");
        require(pool.rewardsDistributor() == address(distributor), "pool not wired to distributor");
        require(address(distributor.pool()) == address(pool), "distributor not wired to pool");

        vm.prank(TREASURY);
        stk.transfer(address(distributor), FUNDING);
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(TREASURY);
        stk.transfer(who, amount);
        vm.prank(who);
        stk.approve(address(pool), type(uint256).max);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        pool.stake(amount);
    }
}

contract StakingIntegrationTest is SystemBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant MALLORY = address(0xBAD);

    // Per-week truncation of rewardRate loses < DURATION wei, and rewardPerToken
    // truncation loses < 1 wei per staked token unit per update. Generous bound.
    uint256 internal constant TOL = 1e9;

    uint256 internal t0;

    function setUp() public {
        vm.warp(1_700_000_000);
        t0 = block.timestamp;
        _deploySystem();
        _fund(ALICE, 10_000 ether);
        _fund(BOB, 10_000 ether);
        _fund(CAROL, 10_000 ether);
        _fund(MALLORY, 10_000 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _approx(uint256 a, uint256 b, uint256 tol, string memory what) internal pure {
        uint256 d = a > b ? a - b : b - a;
        require(d <= tol, what);
    }

    function _dripped() internal view returns (uint256) {
        return FUNDING - stk.balanceOf(address(distributor));
    }

    /// @dev pool balance >= totalStaked + sum of earned for the given accounts.
    function _checkSolvency() internal view {
        uint256 owed = pool.totalStaked() + pool.earned(ALICE) + pool.earned(BOB) + pool.earned(CAROL)
            + pool.earned(MALLORY);
        require(stk.balanceOf(address(pool)) >= owed, "pool balance < principal + earned");
        require(stk.balanceOf(address(pool)) >= pool.totalStaked(), "pool dipped into principal");
    }

    function _claim(address who) internal returns (uint256 got) {
        uint256 before = stk.balanceOf(who);
        vm.prank(who);
        pool.getReward();
        got = stk.balanceOf(who) - before;
    }

    // ------------------------------------------------------------------ wiring

    function test_Wiring() public view {
        require(pool.stakeToken() == pool.rewardToken(), "stake token must equal reward token");
        require(address(pool.stakeToken()) == address(stk), "pool stake token");
        require(address(distributor.token()) == address(stk), "distributor token");
        require(distributor.weeklyAmount() == WEEKLY, "weekly amount");
        require(distributor.nextDrip() == 0, "first drip allowed immediately");
        require(stk.balanceOf(address(distributor)) == FUNDING, "distributor funded");
    }

    // ------------------------------------------------------------------ happy path

    /// Three stakers over three weeks of drips.
    ///   week 1: Alice 100, Bob 300           -> 2500 / 7500
    ///   week 2: + Carol 400                  -> 1250 / 3750 / 5000
    ///   week 3: Bob exits at the drip        -> 2000 /    0 / 8000
    function test_ThreeStakersThreeWeeks() public {
        _stake(ALICE, 100 ether);
        _stake(BOB, 300 ether);
        distributor.drip();
        require(distributor.nextDrip() == t0 + WEEK, "nextDrip after drip 1");
        _checkSolvency();

        vm.warp(t0 + WEEK / 2);
        _approx(pool.earned(ALICE), 1250 ether, TOL, "alice mid week 1");
        _approx(pool.earned(BOB), 3750 ether, TOL, "bob mid week 1");
        _checkSolvency();

        vm.warp(t0 + WEEK);
        _approx(pool.earned(ALICE), 2500 ether, TOL, "alice week 1");
        _approx(pool.earned(BOB), 7500 ether, TOL, "bob week 1");

        _stake(CAROL, 400 ether);
        distributor.drip();
        _checkSolvency();

        vm.warp(t0 + 2 * WEEK);
        _approx(pool.earned(ALICE), 3750 ether, TOL, "alice week 2");
        _approx(pool.earned(BOB), 11_250 ether, TOL, "bob week 2");
        _approx(pool.earned(CAROL), 5000 ether, TOL, "carol week 2");

        uint256 bobBefore = stk.balanceOf(BOB);
        vm.prank(BOB);
        pool.exit();
        _approx(stk.balanceOf(BOB) - bobBefore, 300 ether + 11_250 ether, TOL, "bob exit pays principal + rewards");
        require(pool.balanceOf(BOB) == 0 && pool.earned(BOB) == 0, "bob fully exited");

        distributor.drip();
        _checkSolvency();

        vm.warp(t0 + 3 * WEEK);
        _approx(pool.earned(ALICE), 5750 ether, TOL, "alice week 3");
        _approx(pool.earned(CAROL), 13_000 ether, TOL, "carol week 3");

        uint256 claimed = 11_250 ether;
        claimed += _claim(ALICE);
        claimed += _claim(CAROL);
        require(claimed <= _dripped(), "claimed exceeds dripped");
        require(_dripped() == 3 * WEEKLY, "three drips");
        _approx(claimed, 30_000 ether, TOL, "all dripped rewards paid");

        // Only rounding dust remains beyond principal.
        require(stk.balanceOf(address(pool)) >= pool.totalStaked(), "principal intact");
        require(stk.balanceOf(address(pool)) - pool.totalStaked() <= TOL, "only dust left");

        vm.prank(ALICE);
        pool.withdraw(100 ether);
        vm.prank(CAROL);
        pool.exit();
        require(pool.totalStaked() == 0, "all principal withdrawn");
        _approx(stk.balanceOf(ALICE), 10_000 ether + 5750 ether, TOL, "alice final balance");
        _approx(stk.balanceOf(CAROL), 10_000 ether + 13_000 ether, TOL, "carol final balance");
    }

    // ------------------------------------------------------------------ drip cadence

    function test_SecondDripWithinSevenDaysReverts() public {
        _stake(ALICE, 100 ether);
        distributor.drip();
        uint256 next = distributor.nextDrip();
        require(next == t0 + WEEK, "nextDrip");

        vm.expectRevert(abi.encodeWithSelector(RewardsDistributor.DripNotReady.selector, next));
        distributor.drip();

        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(RewardsDistributor.DripNotReady.selector, next));
        distributor.drip();

        vm.warp(next);
        distributor.drip();
        require(distributor.nextDrip() == next + WEEK, "window restarts at drip time");
        require(_dripped() == 2 * WEEKLY, "two drips");
    }

    function test_DistributorExhaustsAfterTenWeeks() public {
        _stake(ALICE, 100 ether);
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(t0 + i * WEEK);
            distributor.drip();
            _checkSolvency();
        }
        require(stk.balanceOf(address(distributor)) == 0, "distributor empty");
        vm.warp(t0 + 10 * WEEK);
        vm.expectRevert(RewardsDistributor.NothingToDrip.selector);
        distributor.drip();

        uint256 got = _claim(ALICE);
        _approx(got, FUNDING, TOL, "sole staker earns everything");
        require(got <= _dripped(), "claimed exceeds dripped");
        vm.prank(ALICE);
        pool.withdraw(100 ether);
        require(stk.balanceOf(address(pool)) <= TOL, "only dust left in pool");
    }

    // ------------------------------------------------------------------ idle rewards

    function test_RewardsWithNobodyStakedAreReemitted() public {
        distributor.drip(); // nobody staked for all of week 1
        vm.warp(t0 + WEEK);
        require(pool.earned(ALICE) == 0, "nobody earns");
        require(pool.rewardPerToken() == 0, "rpt unchanged while empty");

        _stake(ALICE, 100 ether);
        _approx(pool.idleRewards(), WEEKLY, TOL, "whole week idle");
        distributor.drip(); // re-emits week 1 + week 2
        require(pool.idleRewards() == 0, "idle consumed");
        _approx(pool.rewardRate() * WEEK, 2 * WEEKLY, TOL, "rate covers idle + new");

        vm.warp(t0 + 2 * WEEK);
        _approx(pool.earned(ALICE), 2 * WEEKLY, TOL, "alice gets re-emitted rewards");
        _checkSolvency();
        _approx(_claim(ALICE), 2 * WEEKLY, TOL, "claim");
    }

    function test_PartialIdleWindowIsReemitted() public {
        distributor.drip();
        vm.warp(t0 + 3 days); // 3/7 of the week elapses with nobody staked
        _stake(ALICE, 100 ether);
        vm.warp(t0 + WEEK);
        _approx(pool.earned(ALICE), WEEKLY * 4 / 7, TOL, "alice earns her 4/7");

        distributor.drip();
        vm.warp(t0 + 2 * WEEK);
        _approx(pool.earned(ALICE), WEEKLY * 4 / 7 + WEEKLY + WEEKLY * 3 / 7, TOL, "idle 3/7 re-emitted");
        _checkSolvency();
    }

    // ------------------------------------------------------------------ attacks

    /// Stake one second before a drip, withdraw one minute after: only the time share.
    function test_Attack_StakeBeforeDripWithdrawAfter() public {
        _stake(ALICE, 1000 ether);
        distributor.drip();

        vm.warp(t0 + WEEK - 1);
        _stake(MALLORY, 1000 ether);
        vm.warp(t0 + WEEK);
        distributor.drip();
        vm.warp(t0 + WEEK + 60);
        uint256 before = stk.balanceOf(MALLORY);
        vm.prank(MALLORY);
        pool.exit();
        uint256 profit = stk.balanceOf(MALLORY) - before - 1000 ether;

        // Half the pool for 1s of week 1 and 60s of week 2.
        uint256 expected = WEEKLY * 1 / WEEK / 2 + WEEKLY * 60 / WEEK / 2;
        _approx(profit, expected, TOL, "mallory earns only her time share");
        require(profit < 1 ether, "sniping yields a tiny amount");

        vm.warp(t0 + 2 * WEEK);
        _approx(pool.earned(ALICE), 2 * WEEKLY - expected, TOL, "alice keeps the rest");
        _checkSolvency();
    }

    /// Stake, drip and withdraw in the same block earns nothing.
    function test_Attack_SameBlockSandwichEarnsZero() public {
        _stake(ALICE, 100 ether);
        _stake(MALLORY, 10_000 ether);
        distributor.drip();
        vm.prank(MALLORY);
        pool.exit();
        require(stk.balanceOf(MALLORY) == 10_000 ether, "no reward in zero time");
    }

    function test_Attack_StrangerNotifyReverts() public {
        _stake(ALICE, 100 ether);

        vm.expectRevert(StakingPool.UnauthorizedDistributor.selector);
        vm.prank(MALLORY);
        pool.notifyRewardAmount(1 ether);

        // Even after actually sending tokens to the pool.
        vm.prank(MALLORY);
        stk.transfer(address(pool), 1000 ether);
        vm.expectRevert(StakingPool.UnauthorizedDistributor.selector);
        vm.prank(MALLORY);
        pool.notifyRewardAmount(1000 ether);

        vm.expectRevert(StakingPool.UnauthorizedDistributor.selector);
        vm.prank(TREASURY);
        pool.notifyRewardAmount(1 ether);

        require(pool.rewardRate() == 0, "no schedule created");
    }

    /// Staked principal of the same token never backs a reward schedule.
    function test_Attack_NotifyCannotScheduleFromPrincipal() public {
        _stake(ALICE, 5000 ether);
        _stake(BOB, 5000 ether);
        require(stk.balanceOf(address(pool)) == 10_000 ether, "only principal in pool");

        // Distributor notifying without transferring: principal alone must not back it.
        vm.expectRevert(StakingPool.InsufficientRewardBalance.selector);
        vm.prank(address(distributor));
        pool.notifyRewardAmount(WEEKLY);

        distributor.drip();
    }

    /// Known limitation (not reachable through RewardsDistributor, which always transfers
    /// before notifying): the pool's notify check counts accrued-but-unclaimed rewards as
    /// free balance, so an unfunded notify from the distributor address after a week can
    /// over-commit rewards. Principal is still protected: the over-committed claim reverts
    /// and every staker can withdraw principal in full.
    function test_OverCommittedNotifyStillCannotTouchPrincipal() public {
        _stake(ALICE, 5000 ether);
        _stake(BOB, 5000 ether);
        distributor.drip();
        vm.warp(t0 + WEEK);

        vm.prank(address(distributor)); // simulate a misbehaving distributor: no transfer
        pool.notifyRewardAmount(WEEKLY);
        vm.warp(t0 + 2 * WEEK);
        _approx(pool.earned(ALICE), WEEKLY, TOL, "alice accrued incl. phantom week");
        _approx(pool.earned(BOB), WEEKLY, TOL, "bob accrued incl. phantom week");

        _claim(ALICE); // consumes all real rewards
        require(stk.balanceOf(address(pool)) >= pool.totalStaked(), "principal intact after claim");

        vm.expectRevert(StakingPool.InsufficientRewardBalance.selector);
        vm.prank(BOB);
        pool.getReward();

        vm.prank(ALICE);
        pool.withdraw(5000 ether);
        vm.prank(BOB);
        pool.withdraw(5000 ether);
        require(pool.totalStaked() == 0, "all principal withdrawn");
    }

    /// No claim ever dips into principal: after every claim, all stakers can withdraw in full.
    function test_ClaimsNeverTouchPrincipal() public {
        _stake(ALICE, 1 ether);
        _stake(BOB, 9_999 ether);
        distributor.drip();
        for (uint256 i = 1; i <= 21; i++) {
            vm.warp(t0 + i * 1 days);
            _claim(ALICE);
            _claim(BOB);
            require(stk.balanceOf(address(pool)) >= pool.totalStaked(), "claim dipped into principal");
            if (i % 7 == 0) distributor.drip();
            _checkSolvency();
        }
        vm.prank(ALICE);
        pool.exit();
        vm.prank(BOB);
        pool.exit();
        require(pool.totalStaked() == 0, "all withdrawn");
        require(stk.balanceOf(ALICE) >= 10_000 ether, "alice principal back");
        require(stk.balanceOf(BOB) >= 10_000 ether, "bob principal back");
    }

    function test_WithdrawMoreThanStakeReverts() public {
        _stake(ALICE, 100 ether);
        vm.expectRevert(StakingPool.InsufficientStake.selector);
        vm.prank(ALICE);
        pool.withdraw(100 ether + 1);
        vm.expectRevert(StakingPool.InsufficientStake.selector);
        vm.prank(MALLORY);
        pool.withdraw(1);
    }
}

// ---------------------------------------------------------------------- invariants

/// @dev Drives random stake / withdraw / claim / exit / drip / time sequences
///      against the real system and tracks totals for the invariants.
contract Handler {
    Vm internal constant vm = Vm(HEVM_ADDRESS);

    StakeToken public immutable stk;
    StakingPool public immutable pool;
    RewardsDistributor public immutable distributor;
    address[3] public actors;

    uint256 public totalClaimed;
    uint256 public strangerNotifySucceeded;

    constructor(StakeToken stk_, StakingPool pool_, RewardsDistributor distributor_, address[3] memory actors_) {
        stk = stk_;
        pool = pool_;
        distributor = distributor_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function stake(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 bal = stk.balanceOf(a);
        if (bal == 0) return;
        amount = 1 + amount % bal;
        vm.prank(a);
        pool.stake(amount);
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 staked = pool.balanceOf(a);
        if (staked == 0) return;
        amount = 1 + amount % staked;
        vm.prank(a);
        pool.withdraw(amount);
    }

    function getReward(uint256 seed) external {
        address a = _actor(seed);
        uint256 before = stk.balanceOf(a);
        vm.prank(a);
        pool.getReward();
        totalClaimed += stk.balanceOf(a) - before;
    }

    function exit(uint256 seed) external {
        address a = _actor(seed);
        uint256 staked = pool.balanceOf(a);
        if (staked == 0) return;
        uint256 before = stk.balanceOf(a);
        vm.prank(a);
        pool.exit();
        totalClaimed += stk.balanceOf(a) - before - staked;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + secs % (10 days));
    }

    function drip() external {
        if (block.timestamp < distributor.nextDrip()) vm.warp(distributor.nextDrip());
        if (stk.balanceOf(address(distributor)) == 0) return;
        distributor.drip();
    }

    function strangerNotify(uint256 reward) external {
        vm.prank(address(0xBAD));
        try pool.notifyRewardAmount(reward) {
            strangerNotifySucceeded++;
        } catch {}
    }

    function sumEarned() external view returns (uint256 s) {
        for (uint256 i = 0; i < 3; i++) s += pool.earned(actors[i]);
    }
}

contract StakingInvariantTest is SystemBase {
    Handler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        _deploySystem();
        address[3] memory actors = [address(0xA11CE), address(0xB0B), address(0xCA201)];
        for (uint256 i = 0; i < 3; i++) _fund(actors[i], 50_000 ether);
        handler = new Handler(stk, pool, distributor, actors);
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function _dripped() internal view returns (uint256) {
        return FUNDING - stk.balanceOf(address(distributor));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_PoolCoversPrincipalAndEarned() public view {
        require(
            stk.balanceOf(address(pool)) >= pool.totalStaked() + handler.sumEarned(),
            "pool balance < totalStaked + sum(earned)"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ClaimedNeverExceedsDripped() public view {
        require(handler.totalClaimed() <= _dripped(), "claimed > dripped");
        require(handler.totalClaimed() + handler.sumEarned() <= _dripped(), "claimed + owed > dripped");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_StrangerNeverNotifies() public view {
        require(handler.strangerNotifySucceeded() == 0, "stranger notified");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_TokenConservation() public view {
        uint256 held = stk.balanceOf(address(pool)) + stk.balanceOf(address(distributor))
            + stk.balanceOf(address(0xA11CE)) + stk.balanceOf(address(0xB0B)) + stk.balanceOf(address(0xCA201))
            + stk.balanceOf(TREASURY);
        require(held == stk.totalSupply(), "tokens leaked");
    }
}
