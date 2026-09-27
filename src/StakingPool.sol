// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Seven-day staking rewards for ERC20 tokens without transfer fees or rebasing.
contract StakingPool {
    uint256 public constant DURATION = 7 days;

    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken;
    address public immutable rewardsDistributor;

    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;

    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public idleRewards;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _status = 1;

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientStake();
    error UnauthorizedDistributor();
    error InsufficientRewardBalance();
    error TokenTransferFailed();
    error ReentrantCall();

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward);

    constructor(address stakeToken_, address rewardToken_, address rewardsDistributor_) {
        if (stakeToken_ == address(0) || rewardToken_ == address(0) || rewardsDistributor_ == address(0)) {
            revert ZeroAddress();
        }
        stakeToken = IERC20(stakeToken_);
        rewardToken = IERC20(rewardToken_);
        // The distributor may be deployed later at its predicted CREATE address.
        rewardsDistributor = rewardsDistributor_;
    }

    modifier nonReentrant() {
        if (_status != 1) revert ReentrantCall();
        _status = 2;
        _;
        _status = 1;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18 / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / 1e18 + rewards[account];
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _updateReward(msg.sender);
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        emit Staked(msg.sender, amount);
        _callToken(stakeToken, abi.encodeCall(IERC20.transferFrom, (msg.sender, address(this), amount)));
    }

    function withdraw(uint256 amount) external nonReentrant {
        _updateReward(msg.sender);
        _decreaseStake(msg.sender, amount);
        _callToken(stakeToken, abi.encodeCall(IERC20.transfer, (msg.sender, amount)));
    }

    function getReward() external nonReentrant {
        _updateReward(msg.sender);
        _sendReward(msg.sender, _takeReward(msg.sender));
    }

    /// @notice Withdraw the entire stake and claim rewards; an empty stake reverts.
    function exit() external nonReentrant {
        _updateReward(msg.sender);
        uint256 amount = balanceOf[msg.sender];
        uint256 reward = _takeReward(msg.sender);
        _decreaseStake(msg.sender, amount);
        _callToken(stakeToken, abi.encodeCall(IERC20.transfer, (msg.sender, amount)));
        _sendReward(msg.sender, reward);
    }

    /// @notice Schedule rewards already transferred into this pool by the distributor.
    function notifyRewardAmount(uint256 reward) external nonReentrant {
        if (msg.sender != rewardsDistributor) revert UnauthorizedDistributor();
        _updateReward(address(0));

        uint256 leftover = 0;
        if (block.timestamp < periodFinish) {
            leftover = (periodFinish - block.timestamp) * rewardRate;
        }
        uint256 newRate = (reward + idleRewards + leftover) / DURATION;
        // Equivalent to newRate * DURATION <= available, without multiplication overflow.
        if (newRate > _availableRewards() / DURATION) revert InsufficientRewardBalance();

        rewardRate = newRate;
        idleRewards = 0;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + DURATION;
        emit RewardAdded(reward);
    }

    function _updateReward(address account) private {
        uint256 applicableTime = lastTimeRewardApplicable();
        uint256 elapsedRewards = (applicableTime - lastUpdateTime) * rewardRate;
        if (totalStaked == 0) {
            idleRewards += elapsedRewards;
        } else {
            rewardPerTokenStored += elapsedRewards * 1e18 / totalStaked;
        }
        lastUpdateTime = applicableTime;

        if (account != address(0)) {
            rewards[account] += balanceOf[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account]) / 1e18;
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _decreaseStake(address account, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        if (amount > balanceOf[account]) revert InsufficientStake();
        totalStaked -= amount;
        balanceOf[account] -= amount;
        emit Withdrawn(account, amount);
    }

    function _takeReward(address account) private returns (uint256 reward) {
        reward = rewards[account];
        if (reward == 0) return 0;
        // Also protect principal if a distributor overcommits already accrued rewards.
        if (reward > _availableRewards()) revert InsufficientRewardBalance();
        rewards[account] = 0;
    }

    function _sendReward(address account, uint256 reward) private {
        if (reward == 0) return;
        emit RewardPaid(account, reward);
        _callToken(rewardToken, abi.encodeCall(IERC20.transfer, (account, reward)));
    }

    function _availableRewards() private view returns (uint256 available) {
        available = rewardToken.balanceOf(address(this));
        if (address(stakeToken) == address(rewardToken)) {
            if (available < totalStaked) revert InsufficientRewardBalance();
            available -= totalStaked;
        }
    }

    function _callToken(IERC20 token, bytes memory data) private {
        if (address(token).code.length == 0) revert TokenTransferFailed();
        (bool success, bytes memory result) = address(token).call(data);
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) revert TokenTransferFailed();
    }
}
