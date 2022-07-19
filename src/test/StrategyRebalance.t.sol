// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import "forge-std/console.sol";

import {ProviderStrategy} from "../ProviderStrategy.sol";
import {CurveTripod} from "../DEXes/CurveTripod.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Extended} from "../interfaces/IERC20Extended.sol";
import {IVault} from "../interfaces/Vault.sol";

contract RebalanceTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testProfitableRebalance(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        depositAllVaultsAndHarvest(_amount);

        uint256 _a = tripod.invested(address(assetFixtures[0].strategy));
        uint256 _b = tripod.invested(address(assetFixtures[1].strategy));
        uint256 _c = tripod.invested(address(assetFixtures[2].strategy));

        skip(1 days);
        deal(cvx, address(tripod), _amount/100);
        deal(crv, address(tripod), _amount/100);

        //Turn off health check to allow for profit
        setProvidersHealthCheck(false);

        vm.prank(keeper);
        tripod.harvest();

        uint256 aProfit = assetFixtures[0].want.balanceOf(address(assetFixtures[0].vault));
        uint256 bProfit = assetFixtures[1].want.balanceOf(address(assetFixtures[1].vault));
        uint256 cProfit = assetFixtures[2].want.balanceOf(address(assetFixtures[2].vault));

        (uint256 aRatio, uint256 bRatio, uint256 cRatio) = tripod.getRatios(
            aProfit + _a,
            bProfit + _b,
            cProfit + _c
        );
        console.log("A ratio ", aRatio, " profit was ", aProfit);
        console.log("B ratio ", bRatio, " profit was ", bProfit);
        console.log("C ratio ", cRatio, " profit was ", cProfit);

        assertRelApproxEq(aRatio, bRatio, DELTA);
        assertRelApproxEq(bRatio, cRatio, DELTA);
    }

    function testRebalanceOnLoss(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        depositAllVaultsAndHarvest(_amount);

        uint256 _a = tripod.invested(address(assetFixtures[0].strategy));
        uint256 _b = tripod.invested(address(assetFixtures[1].strategy));
        uint256 _c = tripod.invested(address(assetFixtures[2].strategy));

        skip(1);

        vm.startPrank(gov);
        tripod.removeLiquidityManually(
            tripod.totalLpBalance() / 10,
            0,
            0,
            0
        );
        vm.stopPrank();

        vm.prank(address(tripod));
        assetFixtures[0].want.transfer(address(0), tripod.balanceOfA());
        
        //Turn off health check to allow for loss
        setProvidersHealthCheck(false);

        vm.prank(keeper);
        tripod.harvest();

        (uint256 aRatio, uint256 bRatio, uint256 cRatio) = tripod.getRatios(
            _a,
            _b,
            _c
        );
        console.log("A ratio ", aRatio);
        console.log("B ratio ", bRatio);
        console.log("C ratio ", cRatio);

        assertRelApproxEq(aRatio, bRatio, DELTA);
        assertRelApproxEq(bRatio, cRatio, DELTA);
    }
    
    function testUnevenRebalance(uint256 _amount) public {
        
    }

    function testQuoteRebalance(uint256 _amount) public {

    }

    function testQuoteUnevenRebalance(uint256 _amount) public  {

    }

}