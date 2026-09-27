// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal ERC20 surface used by the distributor.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Minimal StakingPool surface used by the distributor.
interface IStakingPool {
    function notifyRewardAmount(uint256 reward) external;
}

/// @title RewardsDistributor
/// @notice Drips a fixed weekly amount of `token` into `pool` and notifies the pool.
/// @dev There is no owner and no withdraw function. Tokens sent to this contract
///      can only ever leave through `drip()`, which sends them to `pool`. Tokens
///      other than `token` sent here are unrecoverable.
contract RewardsDistributor {
    IERC20 public immutable token;
    IStakingPool public immutable pool;
    uint256 public immutable weeklyAmount;

    /// @notice Earliest timestamp at which the next `drip()` is allowed.
    ///         Starts at 0, so the first drip is allowed immediately after deployment.
    uint256 public nextDrip;

    uint256 private constant DRIP_INTERVAL = 7 days;

    event Dripped(uint256 amount, uint256 nextDrip);

    error ZeroAddress();
    error ZeroWeeklyAmount();
    error DripNotReady(uint256 nextDrip);
    error NothingToDrip();
    error TransferFailed();

    constructor(address token_, address pool_, uint256 weeklyAmount_) {
        if (token_ == address(0) || pool_ == address(0)) revert ZeroAddress();
        if (weeklyAmount_ == 0) revert ZeroWeeklyAmount();
        token = IERC20(token_);
        pool = IStakingPool(pool_);
        weeklyAmount = weeklyAmount_;
    }

    /// @notice Permissionless. Transfers min(weeklyAmount, balance) to the pool and
    ///         notifies it. Allowed once `block.timestamp >= nextDrip`. Missed weeks are
    ///         not caught up: the next window always starts from the time of this call.
    function drip() external {
        if (block.timestamp < nextDrip) revert DripNotReady(nextDrip);

        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NothingToDrip();

        uint256 amount = balance < weeklyAmount ? balance : weeklyAmount;

        // Effects before interactions.
        uint256 next = block.timestamp + DRIP_INTERVAL;
        nextDrip = next;
        emit Dripped(amount, next);

        if (!token.transfer(address(pool), amount)) revert TransferFailed();
        pool.notifyRewardAmount(amount);
    }
}
