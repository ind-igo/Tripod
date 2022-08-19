// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

// Import necessary libraries and interfaces:
// NoHedgetripod to inherit from
import "../Hedges/NoHedgeTripod.sol";
import "forge-std/console.sol";
import { IBalancerVault } from "../interfaces/Balancer/IBalancerVault.sol";
import { IBalancerPool } from "../interfaces/Balancer/IBalancerPool.sol";
import { IAsset } from "../interfaces/Balancer/IAsset.sol";
import {IConvexDeposit} from "../interfaces/Convex/IConvexDeposit.sol";
import {IConvexRewards} from "../interfaces/Convex/IConvexRewards.sol";
import {ICurveFi} from "../interfaces/Curve/IcurveFi.sol";
import {ITradeFactory} from "../interfaces/ySwaps/ITradeFactory.sol";
// Safe casting and math
import {SafeCast} from "../libraries/SafeCast.sol";

interface IFeedRegistry {
    function getFeed(address, address) external view returns (address);
    function latestRoundData(address, address) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

contract BalancerTripod is NoHedgeTripod {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    
    // Used for cloning, will automatically be set to false for other clones
    bool public isOriginal = true;

    //Used for swaps. We swap to usdc due to higher liquidity
    address internal constant usdcAddress =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    //address of the trade factory to be used for extra rewards
    address public tradeFactory;

    //Curve 3 Pool for easy quoting of stable coin swaps
    ICurveFi internal constant curvePool =
        ICurveFi(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);
    //Index mapping provider token to its crv index 
    mapping (address => int128) internal curveIndex;

    //Array of the provider tokens to use during lp functions
    address[3] internal tokens;

    /***
        Balancer specific variables
    ***/
    //Struct for each bb pool that makes up the main pool
    struct PoolInfo {
        address token;
        address bbPool;
        bytes32 poolId;
    }
    //Array of all 3 provider tokens structs
    PoolInfo[3] internal poolInfo;
    //Mapping of provider token to PoolInfo struct
    mapping(address => PoolInfo) internal poolInfoMapping;
    
    //The main Balancer vault
    IBalancerVault internal constant balancerVault = 
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    //Pools we use for swapping rewards
    bytes32 internal constant balEthPoolId = 
        bytes32(0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014);
    bytes32 internal constant auraEthPoolId = 
        bytes32(0xc29562b045d80fd77c69bec09541f5c16fe20d9d000200000000000000000251);
    bytes32 internal constant ethUsdcPoolId =
        bytes32(0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019);
    //The main Balancer Pool Id
    bytes32 internal poolId;

    /***
        Aura specific variables for staking
    ***/
    //Main contracts for staking and rewwards
    IConvexDeposit public constant depositContract = 
        IConvexDeposit(0x7818A1DA7BD1E64c199029E86Ba244a9798eEE10);
    //Specific for each LP token
    IConvexRewards public rewardsContract; 
    // this is unique to each pool
    uint256 public pid; 
    //If we chould claim extras on harvests. Usually true
    bool public harvestExtras; 

    //Base Reward Tokens
    address internal constant auraToken = 
        0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;
    address internal constant balToken =
        0xba100000625a3754423978a60c9317c58a424e3D;

    /*
     * @notice
     *  Constructor, only called during original deploy
     * @param _providerA, provider strategy of tokenA
     * @param _providerB, provider strategy of tokenB
     * @param _providerC, provider strrategy of tokenC
     * @param _referenceToken, token to use as reference, for pricing oracles and paying hedging costs (if any)
     * @param _pool, pool to LP
     * @param _rewardsContract The Convex rewards contract specific to this LP token
     */
    constructor(
        address _providerA,
        address _providerB,
        address _providerC,
        address _referenceToken,
        address _pool,
        address _rewardsContract
    ) NoHedgeTripod(_providerA, _providerB, _providerC, _referenceToken, _pool) {
        _initializeBalancerTripod(_rewardsContract);
    }

    /*
     * @notice
     *  Constructor equivalent for clones, initializing the tripod and the specifics of the strat
     * @param _providerA, provider strategy of tokenA
     * @param _providerB, provider strategy of tokenB
	 * @param _providerC, provider strrategy of tokenC
     * @param _referenceToken, token to use as reference, for pricing oracles and paying hedging costs (if any)
     * @param _pool, pool to LP
     * @param _rewardsContract The Convex rewards contract specific to this LP token
     */
    function initialize(
        address _providerA,
        address _providerB,
        address _providerC,
        address _referenceToken,
        address _pool,
        address _rewardsContract
    ) external {
        _initialize(_providerA, _providerB, _providerC, _referenceToken, _pool);
        _initializeBalancerTripod(_rewardsContract);
    }

    /*
     * @notice
     *  Initialize CurveTripod specifics
     * @param _rewardsContract, The Convex rewards contract specific to this LP token
     */
    function _initializeBalancerTripod(address _rewardsContract) internal {
        rewardsContract = IConvexRewards(_rewardsContract);
        //Update the PID for the rewards pool
        pid = rewardsContract.pid();
        //Default to always claim extras
        harvestExtras = true;

        //Main balancer PoolId
        poolId = IBalancerPool(pool).getPoolId();

        // The reward tokens are the tokens provided to the pool
        //This will update them based on current rewards on convex
        _updateRewardTokens();

        //Set array of pool Infos's for each token
        poolInfo[0] = getBalancerPoolInfo(tokenA);
        poolInfo[1] = getBalancerPoolInfo(tokenB);
        poolInfo[2] = getBalancerPoolInfo(tokenC);

        //Set mapping of curve index's
        curveIndex[tokenA] = _getCRVPoolIndex(tokenA);
        curveIndex[tokenB] = _getCRVPoolIndex(tokenB);
        curveIndex[tokenC] = _getCRVPoolIndex(tokenC);

        maxApprove(tokenA, address(balancerVault));
        maxApprove(tokenB, address(balancerVault));
        maxApprove(tokenC, address(balancerVault));
        maxApprove(pool, address(depositContract));
    }

    event Cloned(address indexed clone);

    /*
     * @notice
     *  Cloning function to migrate/ deploy to other pools
     * @param _providerA, provider strategy of tokenA
     * @param _providerB, provider strategy of tokenB
     * @param _providerC, provider strrategy of tokenC
     * @param _referenceToken, token to use as reference, for pricing oracles and paying hedging costs (if any)
     * @param _pool, pool to LP
     * @param _rewardsContract The Convex rewards contract specific to this LP token
     * @return newTripod, address of newly deployed tripod
     */
    function cloneBalancerTripod(
        address _providerA,
        address _providerB,
        address _providerC,
        address _referenceToken,
        address _pool,
        address _rewardsContract
    ) external returns (address newTripod) {
        require(isOriginal, "!original");
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newTripod := create(0, clone_code, 0x37)
        }

        BalancerTripod(newTripod).initialize(
            _providerA,
            _providerB,
            _providerC,
            _referenceToken,
            _pool,
            _rewardsContract
        );

        emit Cloned(newTripod);
    }

    /*
     * @notice
     *  Function returning the name of the tripod in the format "NoHedgeBalancerTripod(CurveTokenSymbol)"
     * @return name of the strategy
     */
    function name() external view override returns (string memory) {
        string memory symbol = string(
            abi.encodePacked(
                IERC20Extended(pool).symbol()
            )
        );

        return string(abi.encodePacked("NoHedgeBalancerTripod(", symbol, ")"));
    }

    /*
    * @notice
    *   internal function called during initilization and by gov to update the rewardTokens array
    *   Auto adds Bal and Aura tokens, then checks the rewards contract to see if there are any "extra rewards"
    *   available for this pool
    *   Will max approve bal and aura to the balancer vault and any extras to the trade factory
    */
    function _updateRewardTokens() internal {
        delete rewardTokens; //empty the rewardsTokens and rebuild

        //We know we will be getting bal and Aura at least
        rewardTokens.push(balToken);
        _checkAllowance(address(balancerVault), IERC20(balToken), type(uint256).max);

        rewardTokens.push(auraToken);
        _checkAllowance(address(balancerVault), IERC20(auraToken), type(uint256).max);

        for (uint256 i; i < rewardsContract.extraRewardsLength(); i++) {
            address virtualRewardsPool = rewardsContract.extraRewards(i);
            address _rewardsToken =
                IConvexRewards(virtualRewardsPool).rewardToken();

            rewardTokens.push(_rewardsToken);
            //We will use the trade factory for any extra rewards
            if(tradeFactory != address(0)) {
                _checkAllowance(tradeFactory, IERC20(_rewardsToken), type(uint256).max);
                ITradeFactory(tradeFactory).enable(_rewardsToken, usdcAddress);
            }
        }
    }

    /*
     * @notice
     *  Function returning the liquidity amount of the LP position
     *  This is just the non-staked balance
     * @return balance of LP token
     */
    function balanceOfPool() public view override returns (uint256) {
        return IERC20(pool).balanceOf(address(this));
    }

    /*
    * @notice will return the total staked balance
    *   Staked tokens in convex are treated 1 for 1 with lp tokens
    */
    function balanceOfStake() public view override returns (uint256) {
        return rewardsContract.balanceOf(address(this));
    }

    function totalLpBalance() public view override returns (uint256) {
        unchecked {
            return balanceOfPool() + balanceOfStake();
        }
    }

    /*
     * @notice
     *  Function returning the current balance of each token in the LP position
     *  This will assume tokens were deposited equally, the quoteRebalance will adjust after if that is not correct
     * @return _balanceA, balance of tokenA in the LP position
     * @return _balanceB, balance of tokenB in the LP position
     * @return _balanceC, balance of tokenC in the LP position
     */
    function balanceOfTokensInLP()
        public
        view
        override
        returns (uint256 _balanceA, uint256 _balanceB, uint256 _balanceC) 
    {
        uint256 lpBalance = totalLpBalance();
     
        if(lpBalance == 0) return (0, 0, 0);

        //get the virtual price
        uint256 virtualPrice = IBalancerPool(pool).getRate();
 
        unchecked {
            //Calculate vp -> dollars
            uint256 lpDollarValue = lpBalance * virtualPrice / (10 ** IERC20Extended(pool).decimals());
    
            //div by 3
            uint256 third = lpDollarValue * 3_333 / 10_000;

            //Adjust for decimals
            _balanceA = third / (10 ** (18 - IERC20Extended(tokenA).decimals()));
            _balanceB = third / (10 ** (18 - IERC20Extended(tokenB).decimals()));
            _balanceC = third / (10 ** (18 - IERC20Extended(tokenC).decimals()));
        }
    }

    /*
     * @notice
     *  Function returning the amount of rewards earned until now
     * @return uint256 array of amounts of expected rewards earned
     */
    function pendingRewards() public view override returns (uint256[] memory) {
        // Initialize the array to same length as reward tokens
        uint256[] memory _amountPending = new uint256[](rewardTokens.length);

        //Save the earned CrV rewards to 0 where crv will be
        _amountPending[0] = 
            rewardsContract.earned(address(this)) + 
                IERC20(balToken).balanceOf(address(this));

        //Dont qoute any extra rewards since ySwaps will handle them, or Aura since there is no oracle
        return _amountPending;
    }

    /*
     * @notice
     *  Function used internally to collect the accrued rewards mid epoch
     */
    function getReward() internal override {
        rewardsContract.getReward(address(this), harvestExtras);
    }

    /*
     * @notice
     *  Function used internally to open the LP position: 
     *     
     * @return the amounts actually invested for each token
     */
    function createLP() internal override returns (uint256, uint256, uint256) {
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](6);
        IAsset[] memory assets = new IAsset[](7);
        int[] memory limits = new int[](7);

        //Need two trades for each provider token to create the LP
        //Each trade goes token -> bb-token -> mainPool
        PoolInfo memory _poolInfo;
        for (uint256 i; i < 3; i ++) {
            _poolInfo = poolInfo[i];
            address token = _poolInfo.token;
            uint256 balance = IERC20(token).balanceOf(address(this));
            //Used to offset the array to the correct index
            uint256 j = i * 2;
            swaps[j] = IBalancerVault.BatchSwapStep(
                _poolInfo.poolId,
                j,
                j + 1,
                balance,
                abi.encode(0)
            );

            swaps[j+1] = IBalancerVault.BatchSwapStep(
                poolId,
                j + 1,
                6,
                0,
                abi.encode(0)
            );

            assets[j] = IAsset(token);
            assets[j+1] = IAsset(_poolInfo.bbPool);
            limits[j] = int(balance);
        }
        //Set the main lp token as the last in the array
        assets[6] = IAsset(pool);
        
        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, 
            swaps, 
            assets, 
            getFundManagement(), 
            limits, 
            block.timestamp
        );

        unchecked {
            return (
                (uint256(limits[0]) - balanceOfA()), 
                (uint256(limits[2]) - balanceOfB()), 
                (uint256(limits[4]) - balanceOfC())
            );
        }
    }

    /*
     * @notice
     *  Function used internally to close the LP position: 
     *      - burns the LP liquidity specified amount, all mins are 0
     * @param amount, amount of liquidity to burn
     */
    function burnLP(
        uint256 _amount
    ) internal override {
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](6);
        IAsset[] memory assets = new IAsset[](7);
        int[] memory limits = new int[](7);
        //Burn a third for each token
        uint256 toBurn = _amount * 3_333 / 10_000;

        //Need seperate swaps for each provider token
        //Each swap goes mainPool -> bb-token -> token
        PoolInfo memory _poolInfo;
        for (uint256 i; i < 3; i ++) {
            _poolInfo = poolInfo[i];
            uint256 j = i * 2;
            swaps[j] = IBalancerVault.BatchSwapStep(
                poolId,
                6,
                j,
                j == 0 ? _amount - (toBurn * 2) : toBurn, //To make sure we burn all of the LP
                abi.encode(0)
            );

            swaps[j+1] = IBalancerVault.BatchSwapStep(
                _poolInfo.poolId,
                j,
                j + 1,
                0,
                abi.encode(0)
            );

            assets[j] = IAsset(_poolInfo.bbPool);
            assets[j+1] = IAsset(_poolInfo.token);
        }
        //Set the lp token as asset 6
        assets[6] = IAsset(pool);
        limits[6] = int(_amount);

        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, 
            swaps, 
            assets, 
            getFundManagement(), 
            limits, 
            block.timestamp
        );
    }

    /*
    * @notice
    *   Internal function to deposit lp tokens into Convex and stake
    */
    function depositLP() internal override {
        uint256 toStake = IERC20(pool).balanceOf(address(this));

        if(toStake == 0) return;

        depositContract.deposit(pid, toStake, true);
    }

    /*
    * @notice
    *   Internal function to unstake tokens from Convex
    *   harvesExtras will determine if we claim rewards, normally should be true
    */
    function withdrawLP(uint256 amount) internal override {

        rewardsContract.withdrawAndUnwrap(
            amount, 
            harvestExtras
        );
    }

    /*
    * @notice
    *   Overwritten main function to sell bal and aura with batchSwap
    */
    function swapRewardTokens() internal override {
        //Sell Aura and Bal tokens to usdc
        sellRewrds();
    }
    /*
     * @notice
     *  Function used internally to swap core tokens during rebalancing. 
     *  Perfroms a batch swap that goes tokenFrom -> bb-tokenFrom -> bb-tokento -> tokenTo
     * @param _tokenFrom, adress of token to swap from
     * @param _tokenTo, address of token to swap to
     * @param _amountIn, amount of _tokenIn to swap for _tokenTo
     * @return swapped amount
     */
    function swap(
        address _tokenFrom,
        address _tokenTo,
        uint256 _amountIn,
        uint256 _minOutAmount
    ) internal override returns (uint256) {
        if(_amountIn <= minAmountToSell) {
            return 0;
        }

        require(_tokenTo == tokenA || _tokenTo == tokenB || _tokenTo == tokenC, "must be valid _to"); 
        require(_tokenFrom == tokenA || _tokenFrom == tokenB || _tokenFrom == tokenC, "must be valid _from");
        uint256 prevBalance = IERC20(_tokenTo).balanceOf(address(this));

        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](3);
        PoolInfo memory _fromPoolInfo = poolInfoMapping[_tokenFrom];
        PoolInfo memory _toPoolInfo = poolInfoMapping[_tokenTo];
        //Sell tokenFrom -> bb-tokenFrom
        swaps[0] = IBalancerVault.BatchSwapStep(
            _fromPoolInfo.poolId,
            0,
            1,
            _amountIn,
            abi.encode(0)
        );
        
        //bb-tokenFrom -> bb-tokenTo
        swaps[1] = IBalancerVault.BatchSwapStep(
            poolId,
            1,
            2,
            0,
            abi.encode(0)
        );

        //bb-tokenTo -> tokenTo
        swaps[2] = IBalancerVault.BatchSwapStep(
            _toPoolInfo.poolId ,
            2,
            3,
            0,
            abi.encode(0)
        );

        //Match the token address with the desired index for this trade
        IAsset[] memory assets = new IAsset[](4);
        assets[0] = IAsset(_tokenFrom);
        assets[1] = IAsset(_fromPoolInfo.bbPool);
        assets[2] = IAsset(_toPoolInfo.bbPool);
        assets[3] = IAsset(_tokenTo);
        
        //Only min we need to set is for the balance going in
        int[] memory limits = new int[](4);
        limits[0] = int(_amountIn);
            
        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, 
            swaps, 
            assets, 
            getFundManagement(), 
            limits, 
            block.timestamp
        );

        uint256 diff = IERC20(_tokenTo).balanceOf(address(this)) - prevBalance;
        require(diff >= _minOutAmount, "!out");
        return diff;
    }

    /*
     * @notice
     *  Function used internally to quote a potential rebalancing swap without actually 
     * executing it. 
     *  Will only quote bal reward token or a core token swap
     *  Uses a chainlink oracle for the balToken and the curve 3Pool for the core swaps
     * We are using the curve pool due to easier get Amount out ability for core coins
     * @param _tokenFrom, adress of token to swap from
     * @param _tokenTo, address of token to swap to
     * @param _amountIn, amount of _tokenIn to swap for _tokenTo
     * @return simulated swapped amount
     */
    function quote(
        address _tokenFrom,
        address _tokenTo,
        uint256 _amountIn
    ) internal view override returns (uint256) {
        if(_amountIn == 0) {
            return 0;
        }

        require(_tokenTo == tokenA || 
                    _tokenTo == tokenB || 
                        _tokenTo == tokenC, 
                            "must be valid token"); 

        if(_tokenFrom == balToken) {
            (, int256 balPrice,,,) = IFeedRegistry(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf).latestRoundData(
                balToken,
                address(0x0000000000000000000000000000000000000348) // USD
            );

            //Get the latest oracle price for bal * amount of bal / (1e8 + (diff of token decimals to bal decimals)) to adjust oracle price that is 1e8
            return uint256(balPrice) * _amountIn / (10 ** (8 + (18 - IERC20Extended(_tokenTo).decimals())));
        } else {

            // Call the quote function in CRV pool
            return curvePool.get_dy(
                curveIndex[_tokenFrom], 
                curveIndex[_tokenTo], 
                _amountIn
            );
        }
    }

    /*
    * @notice
    *   function used internally to sell the available Bal and Aura tokens
    * @param _to, the token to sell bal to
    * @param _amountIn, the amount of bal to sell
    * @param _amouontOut, the min amount to get out
    */
    function sellRewrds() internal {
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](4);
        
        uint256 balBalance = IERC20(balToken).balanceOf(address(this));
        uint256 auraBalance = IERC20(auraToken).balanceOf(address(this));
 
        //Cant swap 0
        if(balBalance == 0 || auraBalance == 0) return;

        //Sell bal -> weth
        swaps[0] = IBalancerVault.BatchSwapStep(
            balEthPoolId,
            0,
            2,
            balBalance,
            abi.encode(0)
        );
        
        //Sell WETH -> USDC due to higher liquidity
        swaps[1] = IBalancerVault.BatchSwapStep(
            ethUsdcPoolId,
            2,
            3,
            0,
            abi.encode(0)
        );

        //Sell Aura -> Weth
        swaps[2] = IBalancerVault.BatchSwapStep(
            auraEthPoolId,
            1,
            2,
            auraBalance,
            abi.encode(0)
        );

        //Sell WETH -> USDC due to higher liquidity
        swaps[3] = IBalancerVault.BatchSwapStep(
            ethUsdcPoolId,
            2,
            3,
            0,
            abi.encode(0)
        );

        //Match the token address with the desired index for this trade
        IAsset[] memory assets = new IAsset[](4);
        assets[0] = IAsset(balToken);
        assets[1] = IAsset(auraToken);
        assets[2] = IAsset(referenceToken);
        assets[3] = IAsset(usdcAddress);
        
        //Only min we need to set is for the Weth balance going in
        int[] memory limits = new int[](4);
        limits[0] = int(balBalance);
        limits[1] = int(auraBalance);
            
        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, 
            swaps, 
            assets, 
            getFundManagement(), 
            limits, 
            block.timestamp
        );
    }

    /*
    * @internal
    *   Function used internally to get the info of a bb-pool based on the address of a provider token
    *   Will also set the poolInfoMapping for the injected token
    * @param _token, The address of providers want
    * @return PoolInfo struct for the provider token
    */
    function getBalancerPoolInfo(address _token) internal returns (PoolInfo memory _poolInfo) {
        (IERC20[] memory _tokens, , ) = balancerVault.getPoolTokens(poolId);
        for(uint256 i; i < _tokens.length; i ++) {
            IBalancerPool _pool = IBalancerPool(address(_tokens[i]));
            
            //We cant call getMainToken on the main pool
            if(pool == address(_pool)) continue;
            
            if(_token == _pool.getMainToken()) {
                _poolInfo = PoolInfo(
                    _token,
                    address(_pool),
                    _pool.getPoolId()
                );
                poolInfoMapping[_token] = _poolInfo;
                return _poolInfo;
            }
        }

        //If we get here we do not have the correct pool
        revert("No pool index");
    }

    /*
     * @notice
     *  Function used internally to retrieve the CRV index for a token in a CRV pool
     * @return the token's pool index
     */
    function _getCRVPoolIndex(address _token) internal view returns(int128) {
        uint256 i = 0; 
        int128 poolIndex = 0;
        while (i < 3) {
            if (curvePool.coins(i) == _token) {
                return poolIndex;
            }
            i++;
            poolIndex++;
        }

        //If we get here we do not have the correct pool
        revert("No pool index");
    }

    /*
    * Will swap specifc reward token to USDC
    */
    function swapReward(
        address _from, 
        address /*_to*/, 
        uint256 _amountIn, 
        uint256 _minOut
    ) internal override returns (uint256) {
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](2);
        uint256 balBefore = IERC20(usdcAddress).balanceOf(address(this));

        bytes32 _poolId = _from == balToken ? balEthPoolId : auraEthPoolId;
        //Sell reward -> weth
        swaps[0] = IBalancerVault.BatchSwapStep(
            _poolId,
            0,
            1,
            _amountIn,
            abi.encode(0)
        );
        
        //Sell WETH -> USDC due to higher liquidity
        swaps[1] = IBalancerVault.BatchSwapStep(
            ethUsdcPoolId,
            1,
            2,
            0,
            abi.encode(0)
        );

        //Match the token address with the desired index for this trade
        IAsset[] memory assets = new IAsset[](3);
        assets[0] = IAsset(_from);
        assets[1] = IAsset(referenceToken);
        assets[2] = IAsset(usdcAddress);

        //Only min we need to set is for the balance going in
        int[] memory limits = new int[](3);
        limits[0] = int(_amountIn);

        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, 
            swaps, 
            assets, 
            getFundManagement(), 
            limits, 
            block.timestamp
        );

        uint256 diff = IERC20(usdcAddress).balanceOf(address(this)) - balBefore;
        require(diff >= _minOut, "!minOut");
        return diff;
    }

    /*
     * @notice
     *  Function used by governance to swap tokens manually if needed, can be used when closing 
     * the LP position manually and need some re-balancing before sending funds back to the 
     * providers
     * @param tokenFrom, address of token we are swapping from
     * @param tokenTo, address of token we are swapping to
     * @param swapInAmount, amount of swapPath[0] to swap for swapPath[1]
     * @param minOutAmount, minimum amount of want out
     * @param core, bool repersenting if this is a swap from LP -> LP token or if one is a none LP token
     * @return swapped amount
     */
    function swapTokenForTokenManually(
        address tokenFrom,
        address tokenTo,
        uint256 swapInAmount,
        uint256 minOutAmount,
        bool core
    ) external override onlyVaultManagers returns (uint256) {
        require(swapInAmount > 0, "cant swap 0");
        require(IERC20(tokenFrom).balanceOf(address(this)) >= swapInAmount, "Not enough tokens");
        
        if(core) {
            return swap(
                tokenFrom,
                tokenTo,
                swapInAmount,
                minOutAmount
                );
        } else {
            return swapReward(
                tokenFrom,
                tokenTo,
                swapInAmount,
                minOutAmount
                );
        }
    }

    /*
     * @notice
     *  Function used by harvest trigger to assess whether to harvest it as
     * the tripod may have gone out of bounds. If debt ratio is kept in the vaults, the tripod
     * re-centers, if debt ratio is 0, the tripod is simpley closed and funds are sent back
     * to each provider
     * @return bool assessing whether to end the epoch or not
     */
    function shouldEndEpoch() public view override returns (bool) {}

    /*
    * @notice
    *   Function available internally to create an lp during tend
    *   Will only use USDC since that is what is swapped to during tend
    */
    function createUSDCLP() internal {
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](2);
    
        IAsset[] memory assets = new IAsset[](3);
        int[] memory limits = new int[](3);

        uint256 balance = IERC20(usdcAddress).balanceOf(address(this));
        PoolInfo memory _poolInfo = poolInfoMapping[usdcAddress];

        swaps[0] = IBalancerVault.BatchSwapStep(
            _poolInfo.poolId,
            0,
            1,
            balance,
            abi.encode(0)
        );

        swaps[1] = IBalancerVault.BatchSwapStep(
            poolId,
            1,
            2,
            0,
            abi.encode(0)
        );

        assets[0] = IAsset(usdcAddress);
        assets[1] = IAsset(_poolInfo.bbPool);
        assets[2] = IAsset(pool);

        limits[0] = int(balance);
        
        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, 
            swaps, 
            assets, 
            getFundManagement(), 
            limits, 
            block.timestamp
        );
    }

    /*
    * @notice 
    *  To be called inbetween harvests if applicable
    *  This will claim and sell rewards and create an LP with all available funds
    *  This will not adjust invested amounts, since it is all profit and is likely to be
    *       denominated in one token used to swap to i.e. WETH
    */
    function tend() external override onlyKeepers {
        //Claim all outstanding rewards
        getReward();
        //Swap out of all Reward Tokens
        swapRewardTokens();
        //Create LP tokens
        createUSDCLP();
        //Stake LP tokens
        depositLP();
    }

    /*
    * @notice
    *   Trigger to tell Keepers if they should call tend()
    */
    function tendTrigger(uint256 /*callCost*/) external view override returns (bool) {

        uint256 _minRewardToHarvest = minRewardToHarvest;
        if (_minRewardToHarvest == 0) {
            return false;
        }

        if (totalLpBalance() == 0) {
            return false;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        if (rewardsContract.earned(address(this)) + IERC20(balToken).balanceOf(address(this)) >= _minRewardToHarvest) {
            return true;
        }

        return false;
    }

    /*
    * @notice
    *   External function for management to call that updates our rewardTokens array
    *   Should be called if the convex contract adds or removes any extra rewards
    */
    function updateRewardTokens() external onlyVaultManagers {
        _updateRewardTokens();
    }

    /*
    * @notice 
    *   Function available from management to change wether or not we harvest extra rewards
    * @param _harvestExtras, bool of new harvestExtras status
    */
    function setHarvestExtras(bool _harvestExtras) external onlyVaultManagers {
        harvestExtras = _harvestExtras;
    }

    function maxApprove(address _token, address _contract) internal {
        IERC20(_token).safeApprove(_contract, type(uint256).max);
    }

    function getFundManagement() internal view returns (IBalancerVault.FundManagement memory fundManagement) {
        fundManagement = IBalancerVault.FundManagement(
                address(this),
                false,
                payable(address(this)),
                false
            );
    }

    // ---------------------- YSWAPS FUNCTIONS ----------------------
    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        address[] memory _rewardTokens = rewardTokens;
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        //We only need to set trade factory for non aura/bal tokens
        for(uint256 i = 2; i < _rewardTokens.length; i ++) {
            address token = rewardTokens[i];
        
            IERC20(token).safeApprove(_tradeFactory, type(uint256).max);

            tf.enable(token, usdcAddress);
        }
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyVaultManagers {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        address[] memory _rewardTokens = rewardTokens;
        for(uint256 i = 2; i < _rewardTokens.length; i ++) {
        
            IERC20(_rewardTokens[i]).safeApprove(tradeFactory, 0);
        }
        
        tradeFactory = address(0);
    }
}
