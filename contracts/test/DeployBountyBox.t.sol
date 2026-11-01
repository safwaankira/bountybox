// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BountyBox} from "../BountyBox.sol";
import {DeployBountyBox} from "../script/DeployBountyBox.s.sol";
import {MockUSDC} from "./BountyBox.t.sol";

/// @dev Dry-runs the deploy script against a local chain with a stand-in token at Arc's USDC address.
contract DeployBountyBoxTest is Test {
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function _etchUsdc() internal {
        vm.etch(ARC_USDC, address(new MockUSDC()).code);
    }

    function test_DeploysOnMainnetChainId() public {
        vm.chainId(5042);
        _etchUsdc();
        BountyBox box = new DeployBountyBox().run();
        assertEq(address(box.usdc()), ARC_USDC);
        assertEq(box.bountyCount(), 0);
        assertEq(box.GRACE_PERIOD(), 7 days);
        assertEq(box.MAX_DURATION(), 90 days);
    }

    function test_DeploysOnTestnetChainId() public {
        vm.chainId(5042002);
        _etchUsdc();
        BountyBox box = new DeployBountyBox().run();
        assertEq(address(box.usdc()), ARC_USDC);
    }

    function test_RevertsOnOtherChain() public {
        vm.chainId(1);
        _etchUsdc();
        DeployBountyBox script = new DeployBountyBox();
        vm.expectRevert("DeployBountyBox: not an Arc chain");
        script.run();
    }

    function test_RevertsWhenNoUsdcAtAddress() public {
        vm.chainId(5042);
        DeployBountyBox script = new DeployBountyBox();
        vm.expectRevert("DeployBountyBox: no contract at the USDC address");
        script.run();
    }
}
