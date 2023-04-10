// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title Buddieverse Staking Smart Contract
 *
 *
 * @notice This contract uses a simple principle to alow users to stake ERC721 Tokens and earn ERC20 Reward Tokens distributed by the owner of the contract.
 * Each time a user stakes or withdraws a new Token Id, the contract will store the time of the transaction and the amount of ERC20 Reward Tokens that the user has earned up to that point
 * (based on the amount of time that has passed since the last transaction, the amount of Tokens staked and the amount of ERC20 Reward Tokens distributed per hour so that the amount of ERC20
 * Reward Tokens earned by the user is always distributed accounting for how many ERC721 Tokens he has staked at that particular moment.
 * The user can claim the ERC20 Reward Tokens at any time by calling the claimRewards function.
 *
 * @dev The contract is built to be compatible with most ERC721 and ERC20 tokens.
 */
contract BudStaking is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /**
     * @dev The ERC20 Reward Token that will be distributed to stakers.
     */
    IERC20 public immutable rewardsToken;

    /**
     * @dev The ERC721 Collection that will be staked.
     */
    IERC721 public immutable nftCollection;

    uint256 constant SECONDS_IN_HOUR = 3600;

    uint256 constant MAX_STAKING_REWARDS = 3000000;

    /**
     * @dev Struct that holds the staking details for each user.
     */
    struct Staker {
        /**
         * @dev The array of Token Ids staked by the user.
         */
        uint256[] stakedTokenIds;
        /**
         * @dev The rate of rewards for each tokens.
         */
        uint256[] rewardRates;
        /**
         * @dev The time of the last update of the rewards.
         */
        uint256 timeOfLastUpdate;
        /**
         * @dev The amount of ERC20 Reward Tokens that have not been claimed by the user.
         */
        uint256 unclaimedRewards;
    }

    /**
     * @dev The amount of ERC20 Reward Tokens accrued per hour.
     */
    uint256 private rewardsPerHour = 100000;

    /**
     * @dev The amount of rewards already claimed
     */
    uint256 private alreadyClaimedRewards = 0;

    /**
     * @dev Mapping of stakers to their staking info.
     */
    mapping(address => Staker) public stakers;

    /**
     * @dev Mapping of Token Id to staker address.
     */
    mapping(uint256 => address) public stakerAddress;

    /**
     * @dev Array of stakers addresses.
     */
    address[] public stakersArray;

    /**
     * @dev Mapping of stakers addresses to their index in the stakersArray.
     */
    mapping(address => uint256) public stakerToArrayIndex;

    /**
     * @notice Mapping of Token Id to it's index in the staker's stakedTokenIds array.
     */
    mapping(uint256 => uint256) public tokenIdToArrayIndex;

    /**
     * @notice Constructor function that initializes the ERC20 and ERC721 interfaces.
     * @param _nftCollection - The address of the ERC721 Collection.
     * @param _rewardsToken - The address of the ERC20 Reward Token.
     */
    constructor(IERC721 _nftCollection, IERC20 _rewardsToken) {
        nftCollection = _nftCollection;
        rewardsToken = _rewardsToken;
    }

    /**
     * @notice Function used to stake ERC721 Tokens.
     * @param _tokenIds - The array of Token Ids to stake.
     * @dev Each Token Id must be approved for transfer by the user before calling this function.
     */
    function stake(uint256[] calldata _tokenIds) external whenNotPaused {
        require(getTotalStakedRewards() < MAX_STAKING_REWARDS, "Maximum staked rewards overflow");

        Staker storage staker = stakers[msg.sender];

        if (staker.stakedTokenIds.length > 0) {
            updateRewards(msg.sender);
        } else {
            stakersArray.push(msg.sender);
            stakerToArrayIndex[msg.sender] = stakersArray.length - 1;
            staker.timeOfLastUpdate = block.timestamp;
        }

        uint256 len = _tokenIds.length;
        for (uint256 i; i < len; ++i) {
            require(nftCollection.ownerOf(_tokenIds[i]) == msg.sender, "Can't stake tokens you don't own!");

            nftCollection.transferFrom(msg.sender, address(this), _tokenIds[i]);

            uint256 rewardRate = calculateRewardRate();
            staker.rewardRates.push(rewardRate);
            staker.stakedTokenIds.push(_tokenIds[i]);

            tokenIdToArrayIndex[_tokenIds[i]] = staker.stakedTokenIds.length - 1;
            stakerAddress[_tokenIds[i]] = msg.sender;
        }
    }

    /**
     * @notice Function used to withdraw ERC721 Tokens.
     * @param _tokenIds - The array of Token Ids to withdraw.
     */
    function withdraw(uint256[] calldata _tokenIds) external nonReentrant {
        Staker storage staker = stakers[msg.sender];
        require(staker.stakedTokenIds.length > 0, "You have no tokens staked");
        updateRewards(msg.sender);

        uint256 lenToWithdraw = _tokenIds.length;
        for (uint256 i; i < lenToWithdraw; ++i) {
            require(stakerAddress[_tokenIds[i]] == msg.sender);

            uint256 index = tokenIdToArrayIndex[_tokenIds[i]];
            uint256 lastTokenIndex = staker.stakedTokenIds.length - 1;
            if (index != lastTokenIndex) {
                staker.stakedTokenIds[index] = staker.stakedTokenIds[lastTokenIndex];
                tokenIdToArrayIndex[staker.stakedTokenIds[index]] = index;
            }
            staker.stakedTokenIds.pop();

            delete stakerAddress[_tokenIds[i]];

            nftCollection.transferFrom(address(this), msg.sender, _tokenIds[i]);
        }

        if (staker.stakedTokenIds.length == 0) {
            uint256 index = stakerToArrayIndex[msg.sender];
            uint256 lastStakerIndex = stakersArray.length - 1;
            if (index != lastStakerIndex) {
                stakersArray[index] = stakersArray[lastStakerIndex];
                stakerToArrayIndex[stakersArray[index]] = index;
            }
            stakersArray.pop();
        }
    }

    /**
     * @notice Function used to claim the accrued ERC20 Reward Tokens.
     */
    function claimRewards() external {
        Staker storage staker = stakers[msg.sender];

        uint256 rewards = availableRewards(msg.sender);
        require(rewards > 0, "You have no rewards to claim");

        rewardsToken.safeTransfer(msg.sender, rewards);

        staker.timeOfLastUpdate = block.timestamp;
        staker.unclaimedRewards = 0;
    }

    /**
     * @notice Function used to set the amount of ERC20 Reward Tokens accrued per hour.
     * @param _newValue - The new value of the rewardsPerHour variable.
     * @dev Because the rewards are calculated passively, the owner has to first update the rewards
     * to all the stakers, witch could result in very heavy load and expensive transactions or
     * even reverting due to reaching the gas limit per block.
     */
    function setRewardsPerHour(uint256 _newValue) public onlyOwner {
        address[] memory _stakers = stakersArray;

        uint256 len = _stakers.length;
        for (uint256 i; i < len; ++i) {
            updateRewards(_stakers[i]);
        }

        rewardsPerHour = _newValue;
    }

    /**
     * @notice Function used to get the info for a user: the Token Ids staked and the available rewards.
     * @param _user - The address of the user.
     * @return _stakedTokenIds - The array of Token Ids staked by the user.
     * @return _availableRewards - The available rewards for the user.
     */
    function userStakeInfo(address _user)
        public
        view
        returns (uint256[] memory _stakedTokenIds, uint256 _availableRewards)
    {
        return (stakers[_user].stakedTokenIds, availableRewards(_user));
    }

    /**
     * @notice Function used to get the available rewards for a user.
     * @param _user - The address of the user.
     * @return _rewards - The available rewards for the user.
     * @dev This includes both the rewards stored but not claimed and the rewards accumulated since the last update.
     */
    function availableRewards(address _user) internal view returns (uint256 _rewards) {
        _rewards = getRewards(_user);

        uint256 totalRewards = getTotalStakedRewards();
        if (totalRewards >= MAX_STAKING_REWARDS) {
            uint256 totalRewardRates = 0;
            for (uint256 i; i < stakersArray.length; ++i) {
                address user = stakersArray[i];
                totalRewardRates += getStakerRewardRates(user);
            }

            uint256 stakerRewardRates = getStakerRewardRates(_user);

            uint256 overflow = totalRewards - MAX_STAKING_REWARDS;
            _rewards -= (overflow * stakerRewardRates) / totalRewardRates;
        }
    }

    function getRewards(address _user) internal view returns (uint256 _rewards) {
        Staker memory staker = stakers[_user];

        if (staker.stakedTokenIds.length == 0) {
            return staker.unclaimedRewards;
        }

        _rewards = staker.unclaimedRewards + calculateRewards(_user);
    }

    function getStakerRewardRates(address _user) internal view returns (uint256 _rewardRates) {
        Staker memory staker = stakers[_user];

        if (staker.stakedTokenIds.length == 0) {
            return 0;
        }

        _rewardRates = 0;
        for (uint256 i; i < staker.stakedTokenIds.length; ++i) {
            _rewardRates += staker.rewardRates[i];
        }
    }

    /**
     * @notice Function used to calculate the total staked rewards.
     */
    function getTotalStakedRewards() internal view returns (uint256) {
        uint256 rewards = 0;
        for (uint256 i; i < stakersArray.length; ++i) {
            address staker = stakersArray[i];
            rewards += getRewards(staker);
        }
        return alreadyClaimedRewards + rewards;
    }

    /**
     * @notice Function used to calculate the current reward rate.
     * @return _rewards - The rewards for the user.
     */
    function calculateRewardRate() internal view returns (uint256) {
        uint256 totalRewards = getTotalStakedRewards();

        if (totalRewards >= MAX_STAKING_REWARDS) {
            return 0;
        } else if (totalRewards >= 2400000) {
            return rewardsPerHour / 8;
        } else if (totalRewards >= 1800000) {
            return rewardsPerHour / 4;
        } else if (totalRewards >= 1000000) {
            return rewardsPerHour / 2;
        }

        return rewardsPerHour;
    }

    /**
     * @notice Function used to calculate the rewards for a user.
     * @return _rewards - The rewards for the user.
     */
    function calculateRewards(address _staker) internal view returns (uint256) {
        Staker memory staker = stakers[_staker];
        uint256 rewards = 0;
        for (uint256 i; i < staker.stakedTokenIds.length; ++i) {
            uint256 rewardRate = staker.rewardRates[i];
            rewards += (block.timestamp - staker.timeOfLastUpdate) * rewardRate / SECONDS_IN_HOUR;
        }
        return rewards;
    }

    /**
     * @notice Function used to update the rewards for a user.
     * @param _staker - The address of the user.
     */
    function updateRewards(address _staker) internal {
        Staker storage staker = stakers[_staker];

        staker.unclaimedRewards += calculateRewards(_staker);
        staker.timeOfLastUpdate = block.timestamp;
    }

    /**
     * @dev Pause staking.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Resume staking.
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
