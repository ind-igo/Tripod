// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

import "./interfaces/IERC20Extended.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {TripodMath} from "./libraries/TripodMath.sol";
import {IVault} from "./interfaces/Vault.sol";
import {IProviderStrategy} from "./interfaces/IProviderStrategy.sol";

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

/// @title BaseJoint
/// @notice This is the base contract for a 3 token joint LP strategy to be used with @Yearn vaults
///     The contract takes tokens from 3 seperate Provider strategies each with a different token that corresponds to one of the tokens that
///     makes up the LP of "pool". Each harvest the Tripod will attempt to rebalance each token into an equal relative return percentage wise
///     irrespective of the begining weights, exchange rates or decimal differences. 
///
///     Made by Schlagania https://github.com/Schlagonia/Tripod adapted from the 2 token joint strategy https://github.com/fp-crypto/joint-strategy
///
abstract contract BaseJoint {
    using SafeERC20 for IERC20;
    using Address for address;

    // Constant to use in ratio calculations
    uint256 internal constant RATIO_PRECISION = 1e18;

    /// @notice List of provider strategies
    IProviderStrategy[] public providers;

    // Provider strategy of tokenA
    IProviderStrategy public providerA;
    // Provider strategy of tokenB
    IProviderStrategy public providerB;
    // Provider strategy of tokenC
    IProviderStrategy public providerC;

    /// @notice List of tokens used by joint
    address[] public tokens;

    // Address of tokenA
    address public tokenA;
    // Address of tokenB
    address public tokenB;
    // Address of tokenC
    address public tokenC;

    /// @notice Reference token to use in swaps: WETH, WFTM...
    address public constant referenceToken = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

    // Bool repersenting if one of the tokens is == referencetoken
    bool public usingReference;

    // Array containing reward tokens
    address[] public rewardTokens;

    // Address of the pool to LP
    address public pool;

    // Mapping of the Amounts that actually go into the LP position
    mapping(address => uint256) public invested;
    // Mapping of the weights of each token that was invested to 1e18, .33e18 == 33%
    mapping(address => uint256) public investedWeight;

    // Address of the Keeper for this strategy
    address public keeper;

    // Bool manually set to determine wether we should harvest
    bool public launchHarvest;

    // Boolean values protecting against re-investing into the pool
    bool public dontInvestWant;

    // Thresholds to operate the strat
    uint256 public minAmountToSell;
    uint256 public minRewardToHarvest;
    uint256 public maxPercentageLoss;

    // Tripod version of maxReportDelay
    uint256 public maxEpochTime;

    // Modifiers needed for access control normally inherited from BaseStrategy 
    modifier onlyGovernance() {	
        checkGovernance();	
        _;	
    }	
    modifier onlyVaultManagers() {	
        checkVaultManagers();	
        _;	
    }	
    modifier onlyProviders() {	
        checkProvider();	
        _;	
    }	
    modifier onlyKeepers() {	
        checkKeepers();	
        _;	
    }	
    function checkKeepers() internal view {	
        require(isKeeper() || isGovernance() || isVaultManager(), "auth");	
    }	
    function checkGovernance() internal view {	
        require(isGovernance(), "auth");	
    }	
    function checkVaultManagers() internal view {	
        require(isGovernance() || isVaultManager(), "auth");	
    }	
    function checkProvider() internal view {	
        require(isProvider(), "auth");	
    }

    function isGovernance() internal view returns (bool) {
        IProviderStrategy[] memory provs = providers;
        uint len = providers.length;
        for (uint i; i < len;) {
            
            if (msg.sender != provs[i].vault().governance()) return false;
            unchecked { ++i; }
        }
        return true;
    }

    function isVaultManager() internal view returns (bool) {
        IProviderStrategy[] memory provs = providers;
        uint len = providers.length;
        for (uint i; i < len;) {
            if (msg.sender != provs[i].vault().management()) return false;
            unchecked { ++i; }
        }
        return true;
    }

    function isKeeper() internal view returns (bool) {
        return msg.sender == keeper;
    }

    function isProvider() internal view returns (bool) {
        IProviderStrategy[] memory provs = providers;
        uint len = providers.length;
        for (uint i; i < len;) {
            if(msg.sender == address(provs[i])) return true;
            unchecked { ++i; }
        }
        return false;
    }

    function _initialize(address[] calldata providers_, address pool_) internal virtual;

    
}
