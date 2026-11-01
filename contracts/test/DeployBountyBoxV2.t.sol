// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BountyBoxV2} from "../BountyBoxV2.sol";
import {DeployBountyBoxV2} from "../script/DeployBountyBoxV2.s.sol";
import {MockUSDC} from "./BountyBox.t.sol";

/// @dev Dry-runs the v2 deploy script against a local chain with a stand-in token at Arc's USDC address.
contract DeployBountyBoxV2Test is Test {
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant JUDGE = address(0xA11CE);
    address internal constant GUARDIAN = address(0x6A12D);
    uint256 internal constant CAP = 100e6;

    function _etchUsdc() internal {
        vm.etch(ARC_USDC, address(new MockUSDC()).code);
    }

    function test_DeploysWithJudgeGuardianAndCapOnTestnet() public {
        vm.chainId(5042002);
        _etchUsdc();
        BountyBoxV2 box = new DeployBountyBoxV2().deploy(JUDGE, GUARDIAN, CAP);
        assertEq(address(box.usdc()), ARC_USDC);
        assertEq(box.aiJudge(), JUDGE);
        assertEq(box.guardian(), GUARDIAN);
        assertEq(box.maxAIPot(), CAP);
        assertEq(box.bountyCount(), 0);
        assertFalse(box.judgeRetired());
    }

    function test_DeploysOnMainnetChainId() public {
        vm.chainId(5042);
        _etchUsdc();
        BountyBoxV2 box = new DeployBountyBoxV2().deploy(JUDGE, GUARDIAN, 5e6);
        assertEq(box.aiJudge(), JUDGE);
        assertEq(box.maxAIPot(), 5e6);
    }

    function test_RunReadsEnvAndDefaultsCapTo100Usdc() public {
        vm.chainId(5042002);
        _etchUsdc();
        // Distinct variable names are not needed: this is the only test that touches the process environment.
        vm.setEnv("AI_JUDGE", vm.toString(JUDGE));
        vm.setEnv("GUARDIAN", vm.toString(GUARDIAN));
        BountyBoxV2 box = new DeployBountyBoxV2().run();
        assertEq(box.aiJudge(), JUDGE);
        assertEq(box.guardian(), GUARDIAN);
        assertEq(box.maxAIPot(), 100e6, "MAX_AI_POT defaults to 100 USDC");
    }

    function test_RevertsOnOtherChain() public {
        vm.chainId(1);
        _etchUsdc();
        DeployBountyBoxV2 script = new DeployBountyBoxV2();
        vm.expectRevert("DeployBountyBoxV2: not an Arc chain");
        script.deploy(JUDGE, GUARDIAN, CAP);
    }

    function test_RevertsWhenJudgeIsZeroOrTheToken() public {
        vm.chainId(5042002);
        _etchUsdc();
        DeployBountyBoxV2 script = new DeployBountyBoxV2();
        vm.expectRevert("DeployBountyBoxV2: invalid AI_JUDGE");
        script.deploy(address(0), GUARDIAN, CAP);
        vm.expectRevert("DeployBountyBoxV2: invalid AI_JUDGE");
        script.deploy(ARC_USDC, GUARDIAN, CAP);
    }

    function test_RevertsWhenGuardianIsInvalid() public {
        vm.chainId(5042002);
        _etchUsdc();
        DeployBountyBoxV2 script = new DeployBountyBoxV2();
        vm.expectRevert("DeployBountyBoxV2: invalid GUARDIAN");
        script.deploy(JUDGE, address(0), CAP);
        vm.expectRevert("DeployBountyBoxV2: invalid GUARDIAN");
        script.deploy(JUDGE, ARC_USDC, CAP);
        vm.expectRevert("DeployBountyBoxV2: invalid GUARDIAN");
        script.deploy(JUDGE, JUDGE, CAP);
    }

    function test_RevertsWhenCapBelowMinimum() public {
        vm.chainId(5042002);
        _etchUsdc();
        DeployBountyBoxV2 script = new DeployBountyBoxV2();
        vm.expectRevert("DeployBountyBoxV2: MAX_AI_POT below the 0.01 USDC minimum");
        script.deploy(JUDGE, GUARDIAN, 9_999);
    }

    function test_RevertsWhenNoUsdcAtAddress() public {
        vm.chainId(5042002);
        DeployBountyBoxV2 script = new DeployBountyBoxV2();
        vm.expectRevert("DeployBountyBoxV2: no contract at the USDC address");
        script.deploy(JUDGE, GUARDIAN, CAP);
    }
}
