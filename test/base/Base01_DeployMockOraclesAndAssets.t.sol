// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@yolo/test/base/config/Config01_OraclesAndAssets.sol";
import "@yolo/contracts/mocks/MockChainlinkOracle.sol";
import "@yolo/contracts/mocks/MockERC20.sol";
import {MockWETH} from "@yolo/contracts/mocks/MockWETH.sol";

contract Base01_DeployMockOraclesAndAssets is Test, Config01_OraclesAndAssets {
    mapping(string => address) public deployedAssets;
    mapping(string => address) public deployedOracles;
    mapping(address => address) public assetToOracle;

    function setUp() public virtual {
        // Deploy Assets
        for (uint256 i = 0; i < getAssetsLength(); i++) {
            string memory name = getAssetName(i);
            string memory symbol = getAssetSymbol(i);
            uint256 supply = getAssetInitialSupply(i);

            if (keccak256(abi.encodePacked(name)) != keccak256(abi.encodePacked("WETH"))) {
                MockERC20 token = new MockERC20(name, symbol, supply);
                deployedAssets[symbol] = address(token);
            } else {
                MockWETH weth = new MockWETH();
                deployedAssets[symbol] = address(weth);
            }

            emit log_named_address(string(abi.encodePacked("Deployed Asset: ", symbol)), deployedAssets[symbol]);
        }

        // Deploy Oracles
        for (uint256 i = 0; i < getOraclesLength(); i++) {
            string memory description = getOracleDescription(i);
            int256 price = getOracleInitialPrice(i);

            MockChainlinkOracle oracle = new MockChainlinkOracle(price, description);
            deployedOracles[description] = address(oracle);

            // Link the asset to its corresponding oracle
            string memory symbol = _extractSymbolFromDescription(description);
            address asset = deployedAssets[symbol];
            if (asset != address(0)) {
                assetToOracle[asset] = address(oracle);
            }

            emit log_named_address(string(abi.encodePacked("Deployed Oracle: ", description)), address(oracle));
        }
    }

    function _extractSymbolFromDescription(string memory description) internal pure returns (string memory) {
        bytes memory desc = bytes(description);
        uint256 slashIndex = desc.length;

        for (uint256 i = 0; i < desc.length; i++) {
            if (desc[i] == "/") {
                slashIndex = i - 1;
                break;
            }
        }

        bytes memory symbolBytes = new bytes(slashIndex + 1);
        for (uint256 j = 0; j <= slashIndex; j++) {
            symbolBytes[j] = desc[j];
        }

        return string(symbolBytes);
    }

    function test01_Base01_DeployMockOraclesAndAssets() external {}
}
