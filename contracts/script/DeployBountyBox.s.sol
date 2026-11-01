// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BountyBox} from "../BountyBox.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @notice Deploys BountyBox on Arc (mainnet 5042 or testnet 5042002) from the wallet you pass with
/// `--account <keystore name>`. No private key is read from the environment or the command line.
///
/// Run without `--broadcast` first: that is a simulation that prints the gas estimate and spends nothing.
/// Add `--broadcast` only after you have checked the chain, the sender and the USDC address in the output.
/// See DEPLOY_MAINNET.md for the exact commands.
contract DeployBountyBox is Script {
    /// @dev Arc's USDC ERC-20 predeploy; the same address on Arc Mainnet and Arc Testnet.
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant ARC_MAINNET = 5042;
    uint256 internal constant ARC_TESTNET = 5042002;

    function run() external returns (BountyBox box) {
        require(block.chainid == ARC_MAINNET || block.chainid == ARC_TESTNET, "DeployBountyBox: not an Arc chain");
        require(ARC_USDC.code.length > 0, "DeployBountyBox: no contract at the USDC address");
        require(IDecimals(ARC_USDC).decimals() == 6, "DeployBountyBox: USDC is not 6 decimals");

        console.log("Chain id:      ", block.chainid);
        console.log("USDC:          ", ARC_USDC);

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        box = new BountyBox(ARC_USDC);
        vm.stopBroadcast();

        console.log("Deployer:      ", sender);
        console.log("BountyBox:     ", address(box));
        console.log("Constructor arg (USDC):", address(box.usdc()));
    }
}
