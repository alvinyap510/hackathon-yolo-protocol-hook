// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "./Test01_DeployYoloProtocolHookAndOracle.t.sol";
import "./base/config/Config02_AssetAndCollateralInitialization.sol";
import "@yolo/contracts/interfaces/IFlashBorrower.sol";

contract MockFlashBorrower is IFlashBorrower {
    address public immutable yoloProtocolHook;
    bool public repayLoan = true;

    constructor(address _yoloProtocolHook) {
        yoloProtocolHook = _yoloProtocolHook;
    }

    function setRepayLoan(bool _repayLoan) external {
        repayLoan = _repayLoan;
    }

    function onFlashLoan(address initiator, address asset, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
    {
        require(msg.sender == yoloProtocolHook, "MockFlashBorrower: caller is not YoloProtocolHook");
        require(initiator == address(this), "MockFlashBorrower: initiator mismatch");

        if (repayLoan) {
            // Approve the hook to burn tokens from this contract
            IERC20(asset).approve(yoloProtocolHook, amount + fee);
        }
    }

    function onBatchFlashLoan(
        address initiator,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external override {
        require(msg.sender == yoloProtocolHook, "MockFlashBorrower: caller is not YoloProtocolHook");
        require(initiator == address(this), "MockFlashBorrower: initiator mismatch");

        if (repayLoan) {
            // Approve the hook to burn tokens
            for (uint256 i = 0; i < assets.length; i++) {
                IERC20(assets[i]).approve(yoloProtocolHook, amounts[i] + fees[i]);
            }
        }
    }
}

contract Test02_AssetAndCollateralInitializationMintingBorrowingLiquidation is
    Test,
    Test01_DeployYoloProtocolHookAndOracle,
    Config02_AssetAndCollateralInitialization
{
    mapping(string => address) yoloAssetToAddress;

    address public testUser1 = address(0x1);
    address public testUser2 = address(0x2);
    address public liquidator = address(0x3);

    MockFlashBorrower public flashBorrower;

    // For convenience
    address public jpyYAsset;
    address public krwYAsset;
    address public goldYAsset;
    address public nvidiaYAsset;
    address public wbtcAsset;
    address public ptUsdeAsset;

    function setUp() public virtual override(Test01_DeployYoloProtocolHookAndOracle) {
        Test01_DeployYoloProtocolHookAndOracle.setUp();

        // Set up flash borrower
        flashBorrower = new MockFlashBorrower(address(yoloProtocolHook));

        // Step 1: Deploy and Configure All Yolo Assets
        for (uint256 i = 0; i < yoloAssetsArray.length; i++) {
            // Deploy Oracle Config
            OracleConfig memory oracleConfig = yoloAssetsArray[i].oracleConfig;
            MockChainlinkOracle oracle = new MockChainlinkOracle(oracleConfig.initialPrice, oracleConfig.description);

            // Set Hook on YoloOracle
            yoloOracle.setHook(address(yoloProtocolHook));

            // Create New Yolo Assets
            address yoloAsset = yoloProtocolHook.createNewYoloAsset(
                yoloAssetsArray[i].name, yoloAssetsArray[i].symbol, yoloAssetsArray[i].decimals, address(oracle)
            );
            yoloAssetToAddress[yoloAssetsArray[i].symbol] = yoloAsset;

            // Configure Yolo Assets
            yoloProtocolHook.setYoloAssetConfig(
                yoloAsset,
                yoloAssetsArray[i].assetConfiguration.maxMintableCap,
                yoloAssetsArray[i].assetConfiguration.maxFlashLoanableAmount
            );
        }

        // Step 2: Register All Collaterals
        for (uint256 i = 0; i < collateralAssetsArray.length; i++) {
            address asset = deployedAssets[collateralAssetsArray[i].symbol];
            address priceSource = yoloOracle.getSourceOfAsset(asset);

            // setCollateralConfig()
            yoloProtocolHook.setCollateralConfig(asset, collateralAssetsArray[i].supplyCap, priceSource);
        }

        // Set convenience variables
        jpyYAsset = yoloAssetToAddress["JPYY"];
        krwYAsset = yoloAssetToAddress["KRWY"];
        goldYAsset = yoloAssetToAddress["XAUY"];
        nvidiaYAsset = yoloAssetToAddress["NVDIA-Y"];
        wbtcAsset = deployedAssets["WBTC"];
        ptUsdeAsset = deployedAssets["PT-sUSDe-31JUL2025"];

        // Setup users with initial balances
        vm.startPrank(address(this));
        MockERC20(wbtcAsset).transfer(testUser1, 10 * 1e18);
        MockERC20(wbtcAsset).transfer(testUser2, 10 * 1e18);
        MockERC20(wbtcAsset).transfer(liquidator, 10 * 1e18);
        MockERC20(ptUsdeAsset).transfer(testUser1, 100_000 * 1e18);
        MockERC20(ptUsdeAsset).transfer(testUser2, 100_000 * 1e18);
        vm.stopPrank();

        // Setup PairConfigs for all combinations of collaterals and yolo assets
        _setupPairConfigs();
    }

    function _setupPairConfigs() internal {
        address[] memory collateralAssets = new address[](2);
        collateralAssets[0] = wbtcAsset;
        collateralAssets[1] = ptUsdeAsset;

        address[] memory yoloAssets = new address[](4);
        yoloAssets[0] = jpyYAsset;
        yoloAssets[1] = krwYAsset;
        yoloAssets[2] = goldYAsset;
        yoloAssets[3] = nvidiaYAsset;

        for (uint256 i = 0; i < collateralAssets.length; i++) {
            for (uint256 j = 0; j < yoloAssets.length; j++) {
                // Set pair configs with reasonable values
                // interestRate: 5% APR
                // ltv: 80% (for WBTC), 70% (for PT-sUSDe)
                // liquidationPenalty: 5%
                uint256 interestRate = 500; // 5%
                uint256 ltv = i == 0 ? 8000 : 7000; // 80% or 70%
                uint256 liquidationPenalty = 500; // 5%

                yoloProtocolHook.setPairConfig(
                    collateralAssets[i], yoloAssets[j], interestRate, ltv, liquidationPenalty
                );
            }
        }
    }

    // Test pair config setup
    function test_Test02_Case01_PairConfigSetup() public {
        // Check pair config for WBTC-JPYY pair
        (address collateral, address yoloAsset, uint256 interestRate, uint256 ltv, uint256 liquidationPenalty) =
            yoloProtocolHook.pairConfigs(wbtcAsset, jpyYAsset);

        assertEq(collateral, wbtcAsset, "Collateral address mismatch");
        assertEq(yoloAsset, jpyYAsset, "YoloAsset address mismatch");
        assertEq(interestRate, 500, "Interest rate mismatch");
        assertEq(ltv, 8000, "LTV mismatch");
        assertEq(liquidationPenalty, 500, "Liquidation penalty mismatch");
    }

    // Test borrowing (minting) yolo assets
    function test_Test02_Case02_BorrowMintYoloAsset() public {
        uint256 collateralAmount = 1 * 1e18; // 1 WBTC
        uint256 borrowAmount = 1_000_000 * 1e18; // 1 million JPY tokens

        vm.startPrank(testUser1);

        // Approve the collateral
        MockERC20(wbtcAsset).approve(address(yoloProtocolHook), collateralAmount);

        // Borrow/Mint
        yoloProtocolHook.borrow(jpyYAsset, borrowAmount, wbtcAsset, collateralAmount);

        vm.stopPrank();

        // Verify the position
        (
            address borrower,
            address collateral,
            uint256 collateralSupplied,
            address yAsset,
            uint256 yAssetMinted,
            ,
            ,
            uint256 accruedInterest
        ) = yoloProtocolHook.positions(testUser1, wbtcAsset, jpyYAsset);

        assertEq(borrower, testUser1, "Borrower address mismatch");
        assertEq(collateral, wbtcAsset, "Collateral address mismatch");
        assertEq(collateralSupplied, collateralAmount, "Collateral amount mismatch");
        assertEq(yAsset, jpyYAsset, "YoloAsset address mismatch");
        assertEq(yAssetMinted, borrowAmount, "Borrowed amount mismatch");
        assertEq(accruedInterest, 0, "Accrued interest should be 0 initially");

        // Check balances
        uint256 jpyBalance = IERC20(jpyYAsset).balanceOf(testUser1);
        assertEq(jpyBalance, borrowAmount, "JPY token balance mismatch");
    }

    // Test interest accrual and partial repayment
    function test_Test02_Case03_InterestAccrualAndPartialRepayment() public {
        // First borrow
        uint256 collateralAmount = 1 * 1e18; // 1 WBTC
        uint256 borrowAmount = 1_000_000 * 1e18; // 1 million JPY tokens

        vm.startPrank(testUser1);

        // Approve the collateral
        MockERC20(wbtcAsset).approve(address(yoloProtocolHook), collateralAmount);

        // Borrow/Mint
        yoloProtocolHook.borrow(jpyYAsset, borrowAmount, wbtcAsset, collateralAmount);

        // Fast forward 30 days to accrue interest
        vm.warp(block.timestamp + 30 days);

        IERC20(jpyYAsset).approve(address(yoloProtocolHook), 1);
        yoloProtocolHook.repay(wbtcAsset, jpyYAsset, 1, false);
        (,,,,,,, uint256 accruedInterestBeforeRepayment) = yoloProtocolHook.positions(testUser1, wbtcAsset, jpyYAsset);
        assertTrue(accruedInterestBeforeRepayment > 0, "No interest accrued");

        // Repay half of the amount
        uint256 repayAmount = borrowAmount / 2;
        IERC20(jpyYAsset).approve(address(yoloProtocolHook), repayAmount);
        yoloProtocolHook.repay(wbtcAsset, jpyYAsset, repayAmount, false);

        vm.stopPrank();

        // Verify the position after partial repayment
        (,,,, uint256 yAssetMinted,,, uint256 accruedInterest) =
            yoloProtocolHook.positions(testUser1, wbtcAsset, jpyYAsset);

        // Interest should have accrued and some principal should have been repaid
        assertTrue(accruedInterest < accruedInterestBeforeRepayment, "Interest not repaid");
        assertTrue(yAssetMinted < borrowAmount, "No principal repaid");
        assertTrue(yAssetMinted > 0, "All principal repaid");
    }

    // Test full repayment with collateral claim
    function test_Test02_Case04_FullRepaymentWithCollateralClaim() public {
        // First borrow
        uint256 collateralAmount = 1 * 1e18; // 1 WBTC
        uint256 borrowAmount = 1_000_000 * 1e18; // 1 million JPY tokens

        vm.startPrank(testUser1);

        // Approve the collateral
        MockERC20(wbtcAsset).approve(address(yoloProtocolHook), collateralAmount);

        // Borrow/Mint
        yoloProtocolHook.borrow(jpyYAsset, borrowAmount, wbtcAsset, collateralAmount);

        // Fast forward 7 days to accrue some interest
        vm.warp(block.timestamp + 7 days);

        // Get the total debt (principal + interest)
        IERC20(jpyYAsset).approve(address(yoloProtocolHook), 1);
        yoloProtocolHook.repay(wbtcAsset, jpyYAsset, 1, true);
        (,,,, uint256 yAssetMinted,,, uint256 accruedInterest) =
            yoloProtocolHook.positions(testUser1, wbtcAsset, jpyYAsset);

        uint256 totalDebt = yAssetMinted + accruedInterest;

        // Approve enough for full repayment
        // After calculating totalDebt
        vm.startPrank(address(yoloProtocolHook));
        IYoloAsset(jpyYAsset).mint(testUser1, accruedInterest * 2); // Mint extra tokens to cover interest
        vm.startPrank(testUser1);
        IERC20(jpyYAsset).approve(address(yoloProtocolHook), totalDebt);

        // Balance before repayment
        uint256 wbtcBalanceBefore = IERC20(wbtcAsset).balanceOf(testUser1);

        // Full repayment (with 0 amount) and claim collateral
        yoloProtocolHook.repay(wbtcAsset, jpyYAsset, 0, true);

        vm.stopPrank();

        // Verify the position is closed
        (address borrower,, uint256 collateralSupplied,, uint256 remainingDebt,,, uint256 remainingInterest) =
            yoloProtocolHook.positions(testUser1, wbtcAsset, jpyYAsset);

        // Position should be empty (either deleted or zeroed out)
        // assertEq(borrower, address(0), "Position not properly closed");
        assertEq(collateralSupplied, 0, "Collateral not returned");
        assertEq(remainingDebt, 0, "Debt not fully repaid");
        assertEq(remainingInterest, 0, "Interest not fully repaid");

        // Check that collateral was returned
        uint256 wbtcBalanceAfter = IERC20(wbtcAsset).balanceOf(testUser1);
        assertEq(wbtcBalanceAfter, wbtcBalanceBefore + collateralAmount, "Collateral not returned correctly");
    }

    // Test withdrawal of partial collateral
    function test_Test02_Case05_WithdrawPartialCollateral() public {
        // First borrow with excess collateral
        uint256 collateralAmount = 2 * 1e18; // 2 WBTC
        uint256 borrowAmount = 1_000_000 * 1e18; // 1 million JPY tokens - significantly undercollateralized

        vm.startPrank(testUser1);

        // Approve the collateral
        MockERC20(wbtcAsset).approve(address(yoloProtocolHook), collateralAmount);

        // Borrow/Mint
        yoloProtocolHook.borrow(jpyYAsset, borrowAmount, wbtcAsset, collateralAmount);

        // Balance before withdrawal
        uint256 wbtcBalanceBefore = IERC20(wbtcAsset).balanceOf(testUser1);

        // Withdraw 0.5 WBTC
        uint256 withdrawAmount = 0.5 * 1e18;
        yoloProtocolHook.withdraw(wbtcAsset, jpyYAsset, withdrawAmount);

        vm.stopPrank();

        // Verify the position
        (,, uint256 remainingCollateral,,,,,) = yoloProtocolHook.positions(testUser1, wbtcAsset, jpyYAsset);

        assertEq(remainingCollateral, collateralAmount - withdrawAmount, "Collateral not withdrawn correctly");

        // Check balance
        uint256 wbtcBalanceAfter = IERC20(wbtcAsset).balanceOf(testUser1);
        assertEq(wbtcBalanceAfter, wbtcBalanceBefore + withdrawAmount, "Collateral not received");
    }

    // Test attempted withdrawal that would breach LTV
    function test_Test02_Case06_WithdrawBeyondLTVShouldFail() public {
        // First borrow with just enough collateral
        uint256 collateralAmount = 1 * 1e18; // 1 WBTC
        uint256 borrowAmount = 2_000_000 * 1e18;

        vm.startPrank(testUser1);

        // Approve the collateral
        MockERC20(wbtcAsset).approve(address(yoloProtocolHook), collateralAmount);

        // Borrow/Mint
        yoloProtocolHook.borrow(jpyYAsset, borrowAmount, wbtcAsset, collateralAmount);

        // Try to withdraw 0.8 WBTC, which would breach LTV
        uint256 withdrawAmount = 0.99 * 1e18;

        // This should revert
        vm.expectRevert();
        yoloProtocolHook.withdraw(wbtcAsset, jpyYAsset, withdrawAmount);
        vm.stopPrank();
    }

    // Test liquidation when position becomes insolvent
    function test_Test02_Case07_LiquidationWhenInsolvent() public {
        // First borrow with just enough collateral
        uint256 collateralAmount = 1 * 1e18; // 1 WBTC
        uint256 borrowAmount = 12_000_000 * 1e18; // 80M JPY tokens (roughly 80% of collateral value)

        vm.startPrank(testUser1);

        // Approve the collateral
        MockERC20(wbtcAsset).approve(address(yoloProtocolHook), collateralAmount);

        // Borrow/Mint
        yoloProtocolHook.borrow(jpyYAsset, borrowAmount, wbtcAsset, collateralAmount);

        vm.stopPrank();

        // Change WBTC price to make the position undercollateralized
        // Original price: 104,000 * 1e8
        // New price: 90,000 * 1e8 (~13% drop)
        address wbtcOracle = yoloOracle.getSourceOfAsset(wbtcAsset);
        MockChainlinkOracle(wbtcOracle).updateAnswer(90_000 * 1e8);

        // Liquidator prepares
        vm.startPrank(liquidator);

        // Get JPY tokens for liquidation
        MockERC20(wbtcAsset).approve(address(yoloProtocolHook), 2 * 1e18);
        yoloProtocolHook.borrow(jpyYAsset, borrowAmount, wbtcAsset, 2 * 1e18);

        // Approve JPY tokens for liquidation
        IERC20(jpyYAsset).approve(address(yoloProtocolHook), borrowAmount);

        // Liquidate the position
        uint256 wbtcBalanceBefore = IERC20(wbtcAsset).balanceOf(liquidator);

        // Liquidate half of the debt
        uint256 liquidateAmount = borrowAmount / 2;
        yoloProtocolHook.liquidate(testUser1, wbtcAsset, jpyYAsset, liquidateAmount);

        vm.stopPrank();

        // Verify liquidator received collateral
        uint256 wbtcBalanceAfter = IERC20(wbtcAsset).balanceOf(liquidator);
        assertTrue(wbtcBalanceAfter > wbtcBalanceBefore, "Liquidator didn't receive collateral");

        // Verify the position has less collateral
        (,, uint256 remainingCollateral,, uint256 remainingDebt,,,) =
            yoloProtocolHook.positions(testUser1, wbtcAsset, jpyYAsset);

        assertTrue(remainingCollateral < collateralAmount, "Collateral not seized");
        assertTrue(remainingDebt < borrowAmount, "Debt not reduced");
    }

    // // Test single flash loan
    // function test_Test02_Case08_SingleFlashLoan() public {
    //     // Set flash loan fee
    //     yoloProtocolHook.setFlashLoanFee(100); // 1%

    //     // Create initial supply for flashloan
    //     address tokenToFlashloan = jpyYAsset;
    //     uint256 flashloanAmount = 1_000_000 * 1e18;

    //     // Make sure the flash borrower can borrow
    //     vm.startPrank(address(flashBorrower));

    //     // Calculate the flash loan fee
    //     uint256 fee = (flashloanAmount * 100) / 10000; // 1% fee
    //     uint256 totalRepayment = flashloanAmount + fee;

    //     // The flash loan will mint the tokens, then require repayment
    //     // vm.expectEmit(true, true, true, true);
    //     // emit FlashLoanExecuted(address(flashBorrower), tokenToFlashloan, flashloanAmount, fee);
    //     yoloProtocolHook.simpleFlashLoan(tokenToFlashloan, flashloanAmount, "");

    //     vm.stopPrank();

    //     // Verify treasury received the fee
    //     uint256 treasuryBalance = IERC20(tokenToFlashloan).balanceOf(treasury);
    //     assertEq(treasuryBalance, fee, "Treasury didn't receive flash loan fee");
    // }

    // // Test batch flash loan
    // function test_Test02_Case09_BatchFlashLoan() public {
    //     // Set flash loan fee
    //     yoloProtocolHook.setFlashLoanFee(50); // 0.5%

    //     // Create initial supply for flashloan
    //     address[] memory tokensToFlashloan = new address[](2);
    //     tokensToFlashloan[0] = jpyYAsset;
    //     tokensToFlashloan[1] = krwYAsset;

    //     uint256[] memory flashloanAmounts = new uint256[](2);
    //     flashloanAmounts[0] = 1_000_000 * 1e18; // 1M JPY
    //     flashloanAmounts[1] = 5_000_000 * 1e18; // 5M KRW

    //     // Make sure the flash borrower can borrow
    //     vm.startPrank(address(flashBorrower));

    //     // Calculate the flash loan fees
    //     uint256[] memory fees = new uint256[](2);
    //     fees[0] = (flashloanAmounts[0] * 50) / 10000; // 0.5% fee
    //     fees[1] = (flashloanAmounts[1] * 50) / 10000; // 0.5% fee

    //     // Expect the batch flash loan event
    //     // vm.expectEmit(true, true, true, true);
    //     // emit BatchFlashLoanExecuted(address(flashBorrower), tokensToFlashloan, flashloanAmounts, fees);

    //     // Execute the batch flash loan
    //     yoloProtocolHook.flashLoan(tokensToFlashloan, flashloanAmounts, "");

    //     vm.stopPrank();

    //     // Verify treasury received the fees
    //     uint256 treasuryJpyBalance = IERC20(jpyYAsset).balanceOf(treasury);
    //     uint256 treasuryKrwBalance = IERC20(krwYAsset).balanceOf(treasury);
    //     assertEq(treasuryJpyBalance, fees[0], "Treasury didn't receive JPY flash loan fee");
    //     assertEq(treasuryKrwBalance, fees[1], "Treasury didn't receive KRW flash loan fee");
    // }

    // Test failed flash loan repayment
    function test_Test02_Case10_FailedFlashLoanRepayment() public {
        // Set flash loan fee
        yoloProtocolHook.setFlashLoanFee(100); // 1%

        // Configure flash borrower to not repay the loan
        flashBorrower.setRepayLoan(false);

        // Create initial supply for flashloan
        address tokenToFlashloan = jpyYAsset;
        uint256 flashloanAmount = 1_000_000 * 1e18;

        // Make sure the flash borrower can borrow
        vm.startPrank(address(flashBorrower));

        // The flash loan will revert because the borrower doesn't approve repayment
        vm.expectRevert();
        yoloProtocolHook.simpleFlashLoan(tokenToFlashloan, flashloanAmount, "");

        vm.stopPrank();
    }

    // Events needed for tests
    event FlashLoanExecuted(address flashBorrower, address yoloAsset, uint256 amount, uint256 fee);
    event BatchFlashLoanExecuted(
        address indexed flashBorrower, address[] yoloAssets, uint256[] amounts, uint256[] fees
    );
}
