// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "./base/Base01_DeployMockOraclesAndAssets.t.sol";
import "./base/Base02_DeployMockUniswapV4PoolManager.t.sol";
import "@yolo/contracts/core/YoloProtocolHook.sol";
import "@yolo/contracts/core/YoloOracle.sol";

contract Test01_DeployYoloProtocolHookAndOracle is
    Test,
    Base01_DeployMockOraclesAndAssets,
    Base02_DeployMockUniswapV4PoolManager
{
    YoloProtocolHook public yoloProtocolHook;
    YoloOracle public yoloOracle;

    address public treasury = address(0xdead);
    address public weth;
    address public usdc;
    uint256 public hookSwapFee = 250; // 0.25%

    function setUp() public override(Base01_DeployMockOraclesAndAssets, Base02_DeployMockUniswapV4PoolManager) {
        Base01_DeployMockOraclesAndAssets.setUp();
        Base02_DeployMockUniswapV4PoolManager.setUp();

        weth = deployedAssets["WETH"];
        usdc = deployedAssets["USDC"];

        address[] memory assets = new address[](getAssetsLength());
        address[] memory oracles = new address[](getAssetsLength());

        for (uint256 i = 0; i < getAssetsLength(); i++) {
            string memory symbol = getAssetSymbol(i);
            assets[i] = deployedAssets[symbol];

            string memory description = string(abi.encodePacked(symbol, " / USD"));
            address oracleAddress = deployedOracles[description];
            require(oracleAddress != address(0), string(abi.encodePacked("Oracle not found for ", symbol)));
            oracles[i] = oracleAddress;

            emit log_named_address(string(abi.encodePacked("Linked Oracle for Asset: ", symbol)), oracleAddress);
        }

        yoloOracle = new YoloOracle(assets, oracles);

        // Validate UniswapV4 Address Format
        address hookAddress = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
        );
        deployCodeTo(
            "YoloProtocolHook.sol",
            abi.encode(address(yoloOracle), treasury, weth, manager, hookSwapFee, usdc),
            hookAddress
        );

        yoloProtocolHook = YoloProtocolHook(hookAddress);

        emit log_named_address("YoloProtocolHook Deployed At", address(yoloProtocolHook));
        emit log_named_address("YoloOracle Deployed At", address(yoloOracle));

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            address oracle = yoloOracle.getSourceOfAsset(asset);
            assertEq(oracle, oracles[i], "Asset not properly linked to Oracle");
            emit log_named_address("Oracle Linked for Asset", asset);
            emit log_named_address("Oracle Address", oracle);
        }
    }

    function test_01_DeploymentAndInitialization() public {
        assertTrue(address(yoloOracle) != address(0), "YoloOracle not deployed");
        assertTrue(address(yoloProtocolHook) != address(0), "YoloProtocolHook not deployed");
        assertEq(yoloProtocolHook.treasury(), treasury, "Treasury address mismatch");
        assertEq(yoloProtocolHook.hookSwapFee(), hookSwapFee, "Hook swap fee mismatch");
        assertTrue(yoloProtocolHook.isWhiteListedCollateral(weth), "WETH not whitelisted");
    }

    function test_02_OracleInitialization() public {
        address[] memory assets = new address[](getAssetsLength());

        for (uint256 i = 0; i < getAssetsLength(); i++) {
            string memory symbol = getAssetSymbol(i);
            assets[i] = deployedAssets[symbol];
            address oracle = yoloOracle.getSourceOfAsset(assets[i]);
            assertTrue(oracle != address(0), string(abi.encodePacked("Oracle not found for ", symbol)));
        }
    }

    function test_03_OraclePriceFetch() public {
        address dai = deployedAssets["DAI"];
        uint256 price = yoloOracle.getAssetPrice(dai);
        assertEq(price, 1e8, "DAI price incorrect");
    }

    function test_04_AssetRegistration() public {
        address dai = deployedAssets["DAI"];
        assertTrue(yoloOracle.getSourceOfAsset(dai) != address(0), "DAI not registered in Oracle");
    }

    function test_05_WhitelistedCollateral() public {
        assertTrue(yoloProtocolHook.isWhiteListedCollateral(weth), "WETH not whitelisted");
    }
}
