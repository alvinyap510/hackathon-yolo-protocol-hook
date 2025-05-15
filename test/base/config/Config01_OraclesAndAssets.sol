// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Config01_OraclesAndAssets {
    struct AssetConfig {
        string name;
        string symbol;
        uint256 initialSupply;
    }

    struct OracleConfig {
        string description;
        int256 initialPrice;
    }

    AssetConfig[] internal assetsConfig;
    OracleConfig[] internal oraclesConfig;

    constructor() {
        // Initialize Assets
        assetsConfig.push(AssetConfig("Mock DAI", "DAI", 100_000_000 * 1e18));
        assetsConfig.push(AssetConfig("Mock USDC", "USDC", 100_000_000 * 1e6));
        assetsConfig.push(AssetConfig("Mock USDT", "USDT", 100_000_000 * 1e6));
        assetsConfig.push(AssetConfig("Mock USDe", "USDe", 100_000_000 * 1e18));
        assetsConfig.push(AssetConfig("Mock WBTC", "WBTC", 100_000_000 * 1e8));
        assetsConfig.push(AssetConfig("Mock PT-sUSDe-31JUL2025", "PT-sUSDe-31JUL2025", 10_000_000 * 1e18));
        assetsConfig.push(AssetConfig("Mock wstETH", "wstETH", 10_000_000 * 1e18));

        // Initialize Oracles
        oraclesConfig.push(OracleConfig("DAI / USD", 1 * 1e8));
        oraclesConfig.push(OracleConfig("USDC / USD", 1 * 1e8));
        oraclesConfig.push(OracleConfig("USDT / USD", 1 * 1e8));
        oraclesConfig.push(OracleConfig("USDe / USD", 1 * 1e8));
        oraclesConfig.push(OracleConfig("BTC / USD", 104_000 * 1e8));
        oraclesConfig.push(OracleConfig("PT-sUSDe-31JUL2025 / USD", 2_600 * 1e8));
        oraclesConfig.push(OracleConfig("wstETH / USD", 3_061_441_798_33));
        oraclesConfig.push(OracleConfig("ETH / USD", 2_600 * 1e8));
    }

    function getAssetsLength() public view returns (uint256) {
        return assetsConfig.length;
    }

    function getAssetName(uint256 index) public view returns (string memory) {
        return assetsConfig[index].name;
    }

    function getAssetSymbol(uint256 index) public view returns (string memory) {
        return assetsConfig[index].symbol;
    }

    function getAssetInitialSupply(uint256 index) public view returns (uint256) {
        return assetsConfig[index].initialSupply;
    }

    function getOraclesLength() public view returns (uint256) {
        return oraclesConfig.length;
    }

    function getOracleDescription(uint256 index) public view returns (string memory) {
        return oraclesConfig[index].description;
    }

    function getOracleInitialPrice(uint256 index) public view returns (int256) {
        return oraclesConfig[index].initialPrice;
    }
}
