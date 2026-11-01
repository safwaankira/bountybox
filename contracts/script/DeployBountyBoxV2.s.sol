// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BountyBoxV2} from "../BountyBoxV2.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @notice Deploys BountyBoxV2 on Arc (mainnet 5042 or testnet 5042002) from the wallet you pass with
/// `--account <keystore name>`. No private key is read from the environment or the command line.
///
/// Environment variables:
///   AI_JUDGE    required. The judge wallet. IMMUTABLE: it can never be changed, so double check it and make
///               sure you control the key (or Circle wallet) behind it.
///   GUARDIAN    required. An independent address that can permanently retire the judge (a kill switch that
///               cannot move funds). IMMUTABLE. Use a different key from the judge, ideally a multisig or a
///               hardware wallet you control. Must differ from AI_JUDGE and from USDC.
///   MAX_AI_POT  optional, USDC base units (6 decimals). Cap on the pot of every AI-judged bounty. IMMUTABLE.
///               Defaults to 100 USDC (100000000).
///
/// Run without `--broadcast` first: that is a simulation that prints the gas estimate and spends nothing.
/// See DEPLOY_MAINNET.md for the exact commands.
contract DeployBountyBoxV2 is Script {
    /// @dev Arc's USDC ERC-20 predeploy; the same address on Arc Mainnet and Arc Testnet.
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant ARC_MAINNET = 5042;
    uint256 internal constant ARC_TESTNET = 5042002;
    uint256 internal constant DEFAULT_MAX_AI_POT = 100e6; // 100 USDC
    uint256 internal constant MIN_AMOUNT = 10_000; // mirrors BountyBoxV2.MIN_AMOUNT (0.01 USDC)

    function run() external returns (BountyBoxV2 box) {
        return deploy(vm.envAddress("AI_JUDGE"), vm.envAddress("GUARDIAN"), vm.envOr("MAX_AI_POT", DEFAULT_MAX_AI_POT));
    }

    /// @dev Split from run() so tests can pass the arguments directly instead of through the process environment.
    function deploy(address judge, address guardian, uint256 maxAIPot) public returns (BountyBoxV2 box) {
        require(block.chainid == ARC_MAINNET || block.chainid == ARC_TESTNET, "DeployBountyBoxV2: not an Arc chain");
        require(ARC_USDC.code.length > 0, "DeployBountyBoxV2: no contract at the USDC address");
        require(IDecimals(ARC_USDC).decimals() == 6, "DeployBountyBoxV2: USDC is not 6 decimals");
        require(judge != address(0) && judge != ARC_USDC, "DeployBountyBoxV2: invalid AI_JUDGE");
        require(guardian != address(0) && guardian != ARC_USDC && guardian != judge, "DeployBountyBoxV2: invalid GUARDIAN");
        require(maxAIPot >= MIN_AMOUNT, "DeployBountyBoxV2: MAX_AI_POT below the 0.01 USDC minimum");

        console.log("Chain id:      ", block.chainid);
        console.log("USDC:          ", ARC_USDC);
        console.log("AI judge:      ", judge);
        console.log("Guardian:      ", guardian);
        console.log("Max AI pot (USDC base units):", maxAIPot);

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        box = new BountyBoxV2(ARC_USDC, judge, guardian, maxAIPot);
        vm.stopBroadcast();

        console.log("Deployer:      ", sender);
        console.log("BountyBoxV2:   ", address(box));
        console.log("Constructor args (USDC, judge, guardian, maxAIPot):");
        console.log(address(box.usdc()), box.aiJudge(), box.guardian());
        console.log(box.maxAIPot());
    }
}
