// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*---------- IMPORT LIBRARIES & TYPES ----------*/
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
/*---------- IMPORT INTERFACES ----------*/
import "@yolo/contracts/interfaces/IYoloAsset.sol";
import "@yolo/contracts/interfaces/IYoloOracle.sol";
import "@yolo/contracts/interfaces/IWETH.sol";
import "@yolo/contracts/interfaces/IFlashBorrower.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/*---------- IMPORT CONTRACTS ----------*/
import "@yolo/contracts/core/YoloAsset.sol";
/*---------- IMPORT BASE CONTRACTS ----------*/
import "@openzeppelin/contracts/access/Ownable.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/**
 * @title   YoloProtocolHook
 * @author  0xyolodev.eth
 * @notice  Function as the main entry point for user to mint collateral, repay debt, flash-loaning, as
 *          well as functioning as a UniswapV4 hook to store and manages the all of the swap logics of
 *          Yolo assets.
 * @dev     WARNING: SIMPLIFIED FOR HACKATHON PURPOSE, NOT READY FOR PRODUCTION
 */

// Later will update and inherit BaseHook from uniswapV4
contract YoloProtocolHook is Ownable, BaseHook {
    // ***************** //
    // *** LIBRARIES *** //
    // ***************** //
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // ***************** //
    // *** DATATYPES *** //
    // ***************** //

    struct YoloAssetConfiguration {
        address yoloAssetAddress;
        uint256 maxMintableCap; // 0 == Pause
        uint256 maxFlashLoanableAmount;
    }

    struct CollateralConfiguration {
        address collateralAsset;
        uint256 maxSupplyCap; // 0 == Pause
    }

    struct CollateralToYoloAssetConfiguration {
        address collateral;
        address yoloAsset;
        uint256 interestRate;
        uint256 ltv;
        uint256 liquidationPenalty;
    }

    struct UserPosition {
        address borrower;
        address collateral;
        uint256 collateralSuppliedAmount;
        address yoloAsset;
        uint256 yoloAssetMinted;
        uint256 lastUpdatedTimeStamp;
        uint256 storedInterestRate;
        uint256 accruedInterest;
    }

    struct UserPositionKey {
        address collateral;
        address yoloAsset;
    }

    // ******************************//
    // *** CONSTANT & IMMUTABLES *** //
    // ***************************** //
    uint256 public constant PRECISION_DIVISOR = 10000; // 100%

    // ***************************//
    // *** CONTRACT VARIABLES *** //
    // ************************** //
    IWETH public immutable weth;

    IYoloAsset public anchor;
    IERC20 public usdc; // functions as pair of anchor
    IYoloOracle public yoloOracle;
    address public treasury;

    mapping(address => bool) public isYoloAsset;
    mapping(address => bool) public isWhiteListedCollateral;

    mapping(address => address[]) collateralToSupportedYoloAssets; // List of Yolo assets can be minted with a particular asset
    mapping(address => address[]) yoloAssetsToSupportedCollateral; // List of collaterals can be used to mint a Yolo Asset

    mapping(address => UserPosition[]) userAllPositions;

    /// @dev each (collateral, yoloAsset) combination gets its own rules
    mapping(address => mapping(address => CollateralToYoloAssetConfiguration)) public pairConfigs; // Pair Configs of (collateral => asset)

    /// @dev track per‐user per‐pair positions
    mapping(address => mapping(address => mapping(address => UserPosition))) public positions;

    mapping(address => CollateralConfiguration) public collateralConfigs; // Maps collateral to its configuration

    mapping(address => YoloAssetConfiguration) public yoloAssetConfigs; // Maps Yolo assets to its configuration

    uint256 public flashLoanFee;

    uint256 public hookSwapFee;

    mapping(address => UserPositionKey[]) public userPositionKeys;

    mapping(bytes32 => bool) public isAnchorPool;

    mapping(bytes32 => bool) public isSyntheticPool;

    // ************** //
    // *** EVENTS *** //
    // ************** //
    event UpdateFlashLoanFee(uint256 newFlashLoanFee, uint256 oldFlashLoanFee);
    event FlashLoanExecuted(address flashBorrower, address yoloAsset, uint256 amount, uint256 fee);
    event BatchFlashLoanExecuted(
        address indexed flashBorrower, address[] yoloAssets, uint256[] amounts, uint256[] fees
    );
    event YoloAssetCreated(address indexed asset, string name, string symbol, uint8 decimals, address priceSource);
    event YoloAssetConfigurationUpdated(
        address yoloAsset, uint256 newMaxMintableCap, uint256 newMaxFlashLoanableAmount
    );
    event CollateralConfigurationUpdated(address indexed collateral, uint256 newSupplyCap, address newPriceSource);
    event PairDropped(address collateral, address yoloAsset);
    event PriceSourceUpdated(address indexed asset, address newPriceSource, address oldPriceSource);
    event PairConfigUpdated(
        address indexed collateral,
        address indexed yoloAsset,
        uint256 interestRate,
        uint256 ltv,
        uint256 liquidationPenalty
    );
    event Borrowed(
        address indexed user,
        address indexed collateral,
        uint256 collateralAmount,
        address indexed yoloAsset,
        uint256 borrowAmount
    );

    event PositionFullyRepaid(
        address indexed user,
        address indexed collateral,
        address indexed yoloAsset,
        uint256 totalRepaid,
        uint256 collateralReturned
    );

    event PositionPartiallyRepaid(
        address indexed user,
        address indexed collateral,
        address indexed yoloAsset,
        uint256 totalRepaid,
        uint256 interestPaid,
        uint256 principalPaid,
        uint256 remainingPrincipal,
        uint256 remainingInterest
    );

    event Withdrawn(address indexed user, address indexed collateral, address indexed yoloAsset, uint256 amount);

    event Liquidated(
        address indexed user,
        address indexed collateral,
        address indexed yoloAsset,
        uint256 repayAmount,
        uint256 collateralSeized
    );

    event AnchorLiquidityAdded(bytes32 indexed poolId, address indexed provider, uint256 amountUSDC);

    event HookSwapExecuted(
        bytes32 indexed poolId,
        address indexed sender,
        bool zeroForOne,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        uint256 fee
    );

    // ******************* //
    // *** CONSTRUCTOR *** //
    // ******************* //

    constructor(
        address _yoloOracle,
        address _treasury,
        address _wethAddress,
        address _v4PoolManager,
        uint256 _hookSwapFee,
        address _usdc
    ) Ownable(msg.sender) BaseHook(IPoolManager(_v4PoolManager)) {
        yoloOracle = IYoloOracle(_yoloOracle);
        treasury = _treasury;
        anchor = IYoloAsset(address(new YoloAsset("Yolo USD", "USY", 18)));
        isYoloAsset[address(anchor)] = true;
        yoloAssetConfigs[address(anchor)] = YoloAssetConfiguration(address(anchor), 0, 0);
        weth = IWETH(_wethAddress);
        isWhiteListedCollateral[_wethAddress] = true;
        collateralConfigs[address(weth)] = CollateralConfiguration(address(weth), 0);
        hookSwapFee = _hookSwapFee;
        usdc = IERC20(_usdc);

        //
        // ── SORT & INIT THE ANCHOR POOL FOR USDC⇄USY ─────────────────────────────────
        //
        address tokenA = _usdc;
        address tokenB = address(anchor);
        bool usdcIs0 = tokenA < tokenB;

        Currency c0 = Currency.wrap(usdcIs0 ? tokenA : tokenB);
        Currency c1 = Currency.wrap(usdcIs0 ? tokenB : tokenA);

        PoolKey memory pk =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});
        // initialize at 1:1 => sqrtPriceX96 = 1<<96

        poolManager.initialize(pk, uint160(1) << 96);

        // mark it for our hook
        isAnchorPool[PoolId.unwrap(pk.toId())] = true;
    }

    // ********************** //
    // *** USER FUNCTIONS *** //
    // ********************** //

    /**
     * @notice  Allow users to deposit collateral and mint yolo assets
     * @param   _yoloAsset          The yolo asset to mint
     * @param   _borrowAmount       The amount of yolo asset to mint
     * @param   _collateral         The collateral asset to deposit
     * @param   _collateralAmount   The amount of collateral to deposit
     */
    function borrow(address _yoloAsset, uint256 _borrowAmount, address _collateral, uint256 _collateralAmount)
        external
    {
        // Validate parameters
        require(isYoloAsset[_yoloAsset], "YoloProtocolHook: not a registered YoloAsset");
        require(isWhiteListedCollateral[_collateral], "YoloProtocolHook: collateral not whitelisted");
        require(_borrowAmount > 0 && _collateralAmount > 0, "YoloProtocolHook: amounts must be > 0");

        // Check if this pair is configured
        CollateralToYoloAssetConfiguration storage pairConfig = pairConfigs[_collateral][_yoloAsset];
        require(pairConfig.collateral != address(0), "YoloProtocolHook: pair not configured");

        // Transfer collateral from user to this contract
        IERC20(_collateral).safeTransferFrom(msg.sender, address(this), _collateralAmount);

        // Get the user position
        UserPosition storage position = positions[msg.sender][_collateral][_yoloAsset];

        // Handle new vs existing position
        if (position.borrower == address(0)) {
            // Initialize new position
            position.borrower = msg.sender;
            position.collateral = _collateral;
            position.yoloAsset = _yoloAsset;
            position.lastUpdatedTimeStamp = block.timestamp;
            position.storedInterestRate = pairConfig.interestRate;

            // Add to user's positions array - using key pair approach
            UserPositionKey memory key = UserPositionKey({collateral: _collateral, yoloAsset: _yoloAsset});
            userPositionKeys[msg.sender].push(key);
        } else {
            // Accrue interest on existing position at the current stored rate
            _accrueInterest(position, position.storedInterestRate);
            // Update to new interest rate
            position.storedInterestRate = pairConfig.interestRate;
        }

        // Update position
        position.collateralSuppliedAmount += _collateralAmount;
        position.yoloAssetMinted += _borrowAmount;

        CollateralConfiguration storage colConfig = collateralConfigs[_collateral];
        YoloAssetConfiguration storage assetConfig = yoloAssetConfigs[_yoloAsset];

        // Check if position would be solvent after minting
        require(
            _isSolvent(position, _collateral, _yoloAsset, pairConfig.ltv),
            "YoloProtocolHook: position would not be solvent"
        );

        // Check if yolo asset is paused
        require(assetConfig.maxMintableCap > 0, "YoloProtocolHook: yolo asset is paused");

        // Check if minting would exceed the asset's cap
        require(
            IYoloAsset(_yoloAsset).totalSupply() + _borrowAmount <= assetConfig.maxMintableCap,
            "YoloProtocolHook: would exceed mint cap"
        );

        require(colConfig.maxSupplyCap > 0, "YoloProtocolHook: collateral is paused");

        // Then check the actual cap
        require(
            IERC20(_collateral).balanceOf(address(this)) <= colConfig.maxSupplyCap,
            "YoloProtocolHook: exceeds collateral cap"
        );

        // Mint yolo asset to user
        IYoloAsset(_yoloAsset).mint(msg.sender, _borrowAmount);

        // Emit event
        emit Borrowed(msg.sender, _collateral, _collateralAmount, _yoloAsset, _borrowAmount);
    }

    /**
     * @notice Allows users to repay their borrowed YoloAssets
     * @param _collateral The collateral asset address
     * @param _yoloAsset The yolo asset address being repaid
     * @param _repayAmount The amount to repay (0 for full repayment)
     * @param _claimCollateral Whether to withdraw collateral after full repayment
     */
    function repay(address _collateral, address _yoloAsset, uint256 _repayAmount, bool _claimCollateral) external {
        // Get user position
        UserPosition storage position = positions[msg.sender][_collateral][_yoloAsset];
        require(position.borrower == msg.sender, "YoloProtocolHook: no position found");

        // Accrue interest at the stored rate (don't update rate)
        _accrueInterest(position, position.storedInterestRate);

        // Calculate total debt (principal + interest)
        uint256 totalDebt = position.yoloAssetMinted + position.accruedInterest;
        require(totalDebt > 0, "YoloProtocolHook: no debt to repay");

        // If repayAmount is 0, repay full debt
        uint256 repayAmount = _repayAmount == 0 ? totalDebt : _repayAmount;
        require(repayAmount <= totalDebt, "YoloProtocolHook: repay amount exceeds debt");

        // First pay off interest, then principal
        uint256 interestPayment = 0;
        uint256 principalPayment = 0;

        if (position.accruedInterest > 0) {
            // Determine how much interest to pay
            interestPayment = repayAmount < position.accruedInterest ? repayAmount : position.accruedInterest;

            // Update position's accrued interest
            position.accruedInterest -= interestPayment;

            // Burn interest payment from user
            IYoloAsset(_yoloAsset).burn(msg.sender, interestPayment);

            // Mint interest to treasury
            IYoloAsset(_yoloAsset).mint(treasury, interestPayment);
        }

        // Calculate principal payment (if any remains after interest payment)
        principalPayment = repayAmount - interestPayment;

        if (principalPayment > 0) {
            // Update position's minted amount
            position.yoloAssetMinted -= principalPayment;

            // Burn principal payment from user
            IYoloAsset(_yoloAsset).burn(msg.sender, principalPayment);
        }

        // Treat dust amounts as fully repaid (≤1 wei)
        if (position.yoloAssetMinted <= 1 && position.accruedInterest <= 1) {
            position.yoloAssetMinted = 0;
            position.accruedInterest = 0;
        }

        // Check if the position is fully repaid
        if (position.yoloAssetMinted == 0 && position.accruedInterest == 0) {
            if (_claimCollateral) {
                // Auto-return collateral if requested
                uint256 colBal = position.collateralSuppliedAmount;
                position.collateralSuppliedAmount = 0;

                // Check if this would exceed collateral cap after withdrawal
                CollateralConfiguration storage colConfig = collateralConfigs[_collateral];
                if (colConfig.maxSupplyCap > 0) {
                    // Additional check not strictly necessary for withdrawal, but good for consistency
                    require(
                        IERC20(_collateral).balanceOf(address(this)) <= colConfig.maxSupplyCap,
                        "YoloProtocolHook: exceeds collateral cap"
                    );
                }

                // Return collateral to user
                IERC20(_collateral).safeTransfer(msg.sender, colBal);

                // Remove position from user's positions list
                _removeUserPositionKey(msg.sender, _collateral, _yoloAsset);
            }

            emit PositionFullyRepaid(
                msg.sender,
                _collateral,
                _yoloAsset,
                repayAmount,
                _claimCollateral ? position.collateralSuppliedAmount : 0
            );
        } else {
            emit PositionPartiallyRepaid(
                msg.sender,
                _collateral,
                _yoloAsset,
                repayAmount,
                interestPayment,
                principalPayment,
                position.yoloAssetMinted,
                position.accruedInterest
            );
        }
    }

    /// @notice     Redeem up to `amount` of your collateral, provided your loan stays solvent
    /// @param      _collateral    The collateral token address
    /// @param      _yoloAsset     The YoloAsset token address
    /// @param      _amount        How much collateral to withdraw
    function withdraw(address _collateral, address _yoloAsset, uint256 _amount) external {
        UserPosition storage pos = positions[msg.sender][_collateral][_yoloAsset];
        require(pos.borrower == msg.sender, "YoloProtocolHook: no position");
        require(_amount > 0 && _amount <= pos.collateralSuppliedAmount, "YoloProtocolHook: invalid amount");

        // Check if collateral is paused (optional, depends on your design intent)
        CollateralConfiguration storage colConfig = collateralConfigs[_collateral];
        require(colConfig.maxSupplyCap > 0, "YoloProtocolHook: collateral is paused");

        // Accrue any outstanding interest before checking solvency
        _accrueInterest(pos, pos.storedInterestRate);

        // Calculate new collateral amount after withdrawal
        uint256 newCollateralAmount = pos.collateralSuppliedAmount - _amount;

        // If there's remaining debt, ensure the post-withdraw position stays solvent
        if (pos.yoloAssetMinted + pos.accruedInterest > 0) {
            // Temporarily reduce collateral for solvency check
            uint256 origCollateral = pos.collateralSuppliedAmount;
            pos.collateralSuppliedAmount = newCollateralAmount;

            // Check solvency using existing function
            CollateralToYoloAssetConfiguration storage pairConfig = pairConfigs[_collateral][_yoloAsset];
            bool isSolvent = _isSolvent(pos, _collateral, _yoloAsset, pairConfig.ltv);

            // Restore collateral amount
            pos.collateralSuppliedAmount = origCollateral;

            require(isSolvent, "YoloProtocolHook: would breach LTV");
        }

        // Update position state
        pos.collateralSuppliedAmount = newCollateralAmount;

        // Transfer collateral to user
        IERC20(_collateral).safeTransfer(msg.sender, _amount);

        // Clean up empty positions
        if (newCollateralAmount == 0 && pos.yoloAssetMinted == 0 && pos.accruedInterest == 0) {
            _removeUserPositionKey(msg.sender, _collateral, _yoloAsset);
            delete positions[msg.sender][_collateral][_yoloAsset];
        }

        emit Withdrawn(msg.sender, _collateral, _yoloAsset, _amount);
    }

    /// @notice Liquidate an under‐collateralized position
    /// @param _user        The borrower whose position is being liquidated
    /// @param _collateral  The collateral token address
    /// @param _yoloAsset   The YoloAsset token address
    /// @param _repayAmount How much of the borrower’s debt to cover (0 == full debt)
    function liquidate(address _user, address _collateral, address _yoloAsset, uint256 _repayAmount) external {
        // 1) load config & position
        CollateralToYoloAssetConfiguration storage cfg = pairConfigs[_collateral][_yoloAsset];
        require(cfg.collateral != address(0), "pair not configured");

        UserPosition storage pos = positions[_user][_collateral][_yoloAsset];
        require(pos.borrower == _user, "no such position");

        // 2) accrue interest so interest+principal is up to date
        _accrueInterest(pos, pos.storedInterestRate);

        // 3) verify it’s under-collateralized
        require(!_isSolvent(pos, _collateral, _yoloAsset, cfg.ltv), "position still solvent");

        // 4) determine how much debt we’ll cover
        uint256 debt = pos.yoloAssetMinted + pos.accruedInterest;
        uint256 repayAmt = _repayAmount == 0 ? debt : _repayAmount;
        require(repayAmt <= debt, "repay exceeds debt");

        // 5) pull in YoloAsset from liquidator & burn
        IERC20(_yoloAsset).safeTransferFrom(msg.sender, address(this), repayAmt);
        IYoloAsset(_yoloAsset).burn(address(this), repayAmt);

        // 6) split into interest vs principal
        uint256 interestPaid = repayAmt <= pos.accruedInterest ? repayAmt : pos.accruedInterest;
        pos.accruedInterest -= interestPaid;
        uint256 principalPaid = repayAmt - interestPaid;
        pos.yoloAssetMinted -= principalPaid;

        // 7) figure out how much collateral to seize based on oracle prices
        uint256 priceColl = yoloOracle.getAssetPrice(_collateral);
        uint256 priceYol = yoloOracle.getAssetPrice(_yoloAsset);
        // value in “oracle units” = repayAmt * priceYol
        uint256 usdValueRepaid = repayAmt * priceYol;
        // raw collateral units = value / priceColl
        uint256 rawCollateralSeize = (usdValueRepaid + priceColl - 1) / priceColl; // Round up
        // bonus for liquidator (penalty)
        uint256 bonus = (rawCollateralSeize * cfg.liquidationPenalty) / PRECISION_DIVISOR;
        uint256 totalSeize = rawCollateralSeize + bonus;
        require(totalSeize <= pos.collateralSuppliedAmount, "Insufficient collateral to seize");

        // 8) update the stored collateral
        //    — we only deduct the raw portion; the bonus comes out of protocol’s buffer
        pos.collateralSuppliedAmount -= rawCollateralSeize;

        // 9) clean up if fully closed

        // Treat dust amounts as fully liquidated (≤1 wei)
        if (pos.yoloAssetMinted <= 1 && pos.accruedInterest <= 1) {
            pos.yoloAssetMinted = 0;
            pos.accruedInterest = 0;
        }

        if (pos.yoloAssetMinted == 0 && pos.accruedInterest == 0 && pos.collateralSuppliedAmount == 0) {
            delete positions[_user][_collateral][_yoloAsset];
            _removeUserPositionKey(_user, _collateral, _yoloAsset);
        }

        // 10) transfer seized collateral to liquidator
        IERC20(_collateral).safeTransfer(msg.sender, totalSeize);

        emit Liquidated(_user, _collateral, _yoloAsset, repayAmt, totalSeize);
    }
    /**
     * @dev     Executes a single flash loan for a YoloAsset.
     * @param   _yoloAsset  The address of the YoloAsset to borrow.
     * @param   _amount     The amount of the asset to borrow.
     *  @ @param   _data       The data to be passed to the IFlashBorrower contract for execution
     */

    function simpleFlashLoan(address _yoloAsset, uint256 _amount, bytes calldata _data) external {
        require(isYoloAsset[_yoloAsset], "YoloProtocolHook: not a registered YoloAsset");
        // Check if yolo asset is paused
        YoloAssetConfiguration storage assetConfig = yoloAssetConfigs[_yoloAsset];
        require(assetConfig.maxMintableCap > 0, "YoloProtocolHook: yolo asset is paused");

        uint256 fee = (_amount * flashLoanFee) / PRECISION_DIVISOR;
        uint256 totalRepayment = _amount + fee;

        // Transfer the flash loan to the borrower
        IYoloAsset(_yoloAsset).mint(msg.sender, _amount);

        // Call the borrower's callback function
        IFlashBorrower(msg.sender).onFlashLoan(msg.sender, _yoloAsset, _amount, fee, _data);

        // Ensure repayment
        IYoloAsset(_yoloAsset).burn(msg.sender, totalRepayment);

        // Mint fee to protocol treasury
        IYoloAsset(_yoloAsset).mint(treasury, fee);

        emit FlashLoanExecuted(msg.sender, _yoloAsset, _amount, fee);
    }

    /**
     * @dev     Executes a batch flash loan for multiple YoloAssets.
     * @param   _yoloAssets  Array of YoloAsset addresses to borrow.
     * @param   _amounts     Array of amounts to borrow per asset.
     * @param   _data        Arbitrary call data passed to the borrower.
     */
    function flashLoan(address[] calldata _yoloAssets, uint256[] calldata _amounts, bytes calldata _data) external {
        require(_yoloAssets.length == _amounts.length, "YoloProtocolHook: params length mismatch");

        uint256[] memory fees = new uint256[](_yoloAssets.length);
        uint256[] memory totalRepayments = new uint256[](_yoloAssets.length);

        // Mint flash loans to the borrower
        for (uint256 i = 0; i < _yoloAssets.length; i++) {
            require(isYoloAsset[_yoloAssets[i]], "YoloProtocolHook: not a registered YoloAsset");

            YoloAssetConfiguration storage assetConfig = yoloAssetConfigs[_yoloAssets[i]];
            require(assetConfig.maxMintableCap > 0, "YoloProtocolHook: yolo asset is paused");

            // Calculate the fee and total repayment
            uint256 fee = (_amounts[i] * flashLoanFee) / PRECISION_DIVISOR;
            fees[i] = fee;
            totalRepayments[i] = _amounts[i] + fee;

            // Mint the YoloAsset to the borrower
            IYoloAsset(_yoloAssets[i]).mint(msg.sender, _amounts[i]);
        }

        // Call the borrower's callback function
        IFlashBorrower(msg.sender).onBatchFlashLoan(msg.sender, _yoloAssets, _amounts, fees, _data);

        // Burn the amount + fee from the borrower and mint fee to the treasury
        for (uint256 i = 0; i < _yoloAssets.length; i++) {
            // Ensure repayment
            IYoloAsset(_yoloAssets[i]).burn(msg.sender, totalRepayments[i]);

            // Mint the fee to the protocol treasury
            IYoloAsset(_yoloAssets[i]).mint(treasury, fees[i]);
        }

        emit BatchFlashLoanExecuted(msg.sender, _yoloAssets, _amounts, fees);
    }

    // *********************** //
    // *** ADMIN FUNCTIONS *** //
    // *********************** //

    function setFlashLoanFee(uint256 _newFlashLoanFee) external onlyOwner {
        uint256 oldFlashLoanFee = flashLoanFee;
        flashLoanFee = _newFlashLoanFee;
        emit UpdateFlashLoanFee(_newFlashLoanFee, oldFlashLoanFee);
    }

    function createNewYoloAsset(string calldata _name, string calldata _symbol, uint8 _decimals, address _priceSource)
        external
        onlyOwner
        returns (address)
    {
        // 1. Deploy the token
        YoloAsset asset = new YoloAsset(_name, _symbol, _decimals);
        address a = address(asset);

        // 2. Register it
        isYoloAsset[a] = true;
        yoloAssetConfigs[a] =
            YoloAssetConfiguration({yoloAssetAddress: a, maxMintableCap: 0, maxFlashLoanableAmount: 0});

        // 3. Wire its price feed in the Oracle
        address[] memory assets = new address[](1);
        address[] memory priceSources = new address[](1);
        assets[0] = a;
        priceSources[0] = _priceSource;
        yoloOracle.setAssetSources(assets, priceSources);

        emit YoloAssetCreated(a, _name, _symbol, _decimals, _priceSource);

        // 4. Automatically create a synthetic pool vs. the anchor (USY)
        //    and mark it in our mapping so _beforeSwap kicks in correctly.
        bool anchorIs0 = address(anchor) < a;
        Currency c0 = Currency.wrap(anchorIs0 ? address(anchor) : a);
        Currency c1 = Currency.wrap(anchorIs0 ? a : address(anchor));

        PoolKey memory pk =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});

        // initialize price at 1:1 (sqrtPriceX96 = 2^96)
        poolManager.initialize(pk, uint160(1) << 96);

        // mark it synthetic
        isSyntheticPool[PoolId.unwrap(pk.toId())] = true;

        return a;
    }

    function setYoloAssetConfig(address _asset, uint256 _newMintCap, uint256 _newFlashLoanCap) external onlyOwner {
        require(isYoloAsset[_asset], "YoloProtocolHook: not Yolo asset");
        YoloAssetConfiguration storage cfg = yoloAssetConfigs[_asset];
        cfg.maxMintableCap = _newMintCap;
        cfg.maxFlashLoanableAmount = _newFlashLoanCap;
        emit YoloAssetConfigurationUpdated(_asset, _newMintCap, _newFlashLoanCap);
    }

    function setCollateralConfig(address _collateral, uint256 _newSupplyCap, address _priceSource) external onlyOwner {
        isWhiteListedCollateral[_collateral] = true;
        CollateralConfiguration storage cfg = collateralConfigs[_collateral];
        cfg.collateralAsset = _collateral;
        cfg.maxSupplyCap = _newSupplyCap;
        if (_priceSource != address(0)) {
            address[] memory assets = new address[](1);
            address[] memory priceSources = new address[](1);
            assets[0] = _collateral;
            priceSources[0] = _priceSource;

            yoloOracle.setAssetSources(assets, priceSources);
        }
        emit CollateralConfigurationUpdated(_collateral, _newSupplyCap, _priceSource);
    }

    function setPairConfig(
        address _collateral,
        address _yoloAsset,
        uint256 _interestRate,
        uint256 _ltv,
        uint256 _liquidationPenalty
    ) external onlyOwner {
        require(isWhiteListedCollateral[_collateral], "YoloProtocolHook: collateral not whitelisted");
        require(isYoloAsset[_yoloAsset], "YoloProtocolHook: not Yolo asset");

        pairConfigs[_collateral][_yoloAsset] = CollateralToYoloAssetConfiguration({
            collateral: _collateral,
            yoloAsset: _yoloAsset,
            interestRate: _interestRate,
            ltv: _ltv,
            liquidationPenalty: _liquidationPenalty
        });

        collateralToSupportedYoloAssets[_collateral].push(_yoloAsset);
        yoloAssetsToSupportedCollateral[_yoloAsset].push(_collateral);

        emit PairConfigUpdated(_collateral, _yoloAsset, _interestRate, _ltv, _liquidationPenalty);
    }

    function removePairConfig(address _collateral, address _yoloAsset) external onlyOwner {
        // 1) remove the config mapping
        delete pairConfigs[_collateral][_yoloAsset];

        // 2) remove from collateral→assets list
        _removeFromArray(collateralToSupportedYoloAssets[_collateral], _yoloAsset);

        // 3) remove from asset→collaterals list
        _removeFromArray(yoloAssetsToSupportedCollateral[_yoloAsset], _collateral);

        emit PairDropped(_collateral, _yoloAsset);
    }

    function recoverERC20(address _token, uint256 _amount, address _to) external onlyOwner {
        IERC20(_token).safeTransfer(_to, _amount);
    }

    function setNewPriceSource(address _asset, address _priceSource) external onlyOwner {
        require(_priceSource != address(0), "YoloProtocolHook: cannot set address(0) as oracle");

        address oldPriceSource = yoloOracle.getSourceOfAsset(_asset);

        address[] memory assets = new address[](1);
        address[] memory priceSources = new address[](1);
        assets[0] = _asset;
        priceSources[0] = _priceSource;

        yoloOracle.setAssetSources(assets, priceSources);

        emit PriceSourceUpdated(_asset, _priceSource, oldPriceSource);
    }

    // ************************** //
    // *** INTERNAL FUNCTIONS *** //
    // *******&****************** //

    function _accrueInterest(UserPosition storage _pos, uint256 _rate) internal {
        if (_pos.yoloAssetMinted == 0) {
            _pos.lastUpdatedTimeStamp = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp - _pos.lastUpdatedTimeStamp;
        // simple pro-rata APR: principal * rate * dt / (1yr * PRECISION_DIVISOR)
        _pos.accruedInterest += (_pos.yoloAssetMinted * _rate * dt) / (365 days * PRECISION_DIVISOR);
        _pos.lastUpdatedTimeStamp = block.timestamp;
    }

    function _isSolvent(UserPosition storage _pos, address _collateral, address _yoloAsset, uint256 _ltv)
        internal
        view
        returns (bool)
    {
        uint256 collateralDecimals = IERC20Metadata(_collateral).decimals();
        uint256 yoloAssetDecimals = IERC20Metadata(_yoloAsset).decimals();

        uint256 colVal =
            yoloOracle.getAssetPrice(_collateral) * _pos.collateralSuppliedAmount / (10 ** collateralDecimals);
        uint256 debtVal = yoloOracle.getAssetPrice(_yoloAsset) * (_pos.yoloAssetMinted + _pos.accruedInterest)
            / (10 ** yoloAssetDecimals);

        return debtVal * PRECISION_DIVISOR <= colVal * _ltv;
    }
    // ************************** //
    // *** HELPER FUNCTIONS *** //
    // *******&****************** //

    function _removeFromArray(address[] storage arr, address elem) internal {
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            if (arr[i] == elem) {
                // swap with last element and pop
                arr[i] = arr[len - 1];
                arr.pop();
                break;
            }
        }
    }

    /**
     * @notice Helper function to remove a position key from a user's positions array
     * @param _user The user address
     * @param _collateral The collateral asset address
     * @param _yoloAsset The yolo asset address
     */
    function _removeUserPositionKey(address _user, address _collateral, address _yoloAsset) internal {
        UserPositionKey[] storage keys = userPositionKeys[_user];
        for (uint256 i = 0; i < keys.length; i++) {
            if (keys[i].collateral == _collateral && keys[i].yoloAsset == _yoloAsset) {
                // Swap with last element and pop
                keys[i] = keys[keys.length - 1];
                keys.pop();
                break;
            }
        }
    }

    // ****************************************** //
    // *** HOOK FUNCTIONS *** //
    // ****************************************** //

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // Block direct adding liquidity
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, //
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, //
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function addUSDCLiquidity(uint256 amountUSDC) external {
        // reconstruct the exact same PoolKey we used in constructor:
        address tokenA = address(usdc);
        address tokenB = address(anchor);
        bool usdcIs0 = tokenA < tokenB;

        Currency cur0 = usdcIs0 ? Currency.wrap(tokenA) : Currency.wrap(tokenB);
        Currency cur1 = usdcIs0 ? Currency.wrap(tokenB) : Currency.wrap(tokenA);

        PoolKey memory pk =
            PoolKey({currency0: cur0, currency1: cur1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});
        bytes32 id = PoolId.unwrap(pk.toId());
        require(isAnchorPool[id], "YoloProtocolHook: not anchor pool");

        // pull real USDC into PM
        cur0.settle(poolManager, msg.sender, amountUSDC, false);
        // mint USDC‐claim tokens to us
        cur0.take(poolManager, address(this), amountUSDC, true);

        // mint matching USY into hook
        IYoloAsset(address(anchor)).mint(address(this), amountUSDC);

        // notify PM of our balanced (x == y) liquidity change
        emit AnchorLiquidityAdded(PoolId.unwrap(pk.toId()), msg.sender, amountUSDC);
    }

    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert("YoloProtocolHook: Liquidity shouldn't be added directly to PoolManager");
    }

    function _beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bytes32 id = PoolId.unwrap(key.toId());
        require(isAnchorPool[id] || isSyntheticPool[id], "YoloProtocolHook: unrecognized pool");

        // If amountSpecified is > 0 (exact‐output swap), amountInOutPositive = amountSpecified.
        // If amountSpecified is < 0 (exact‐input swap), amountInOutPositive = –amountSpecified.
        uint256 amountInOutPositive =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        // Cancel out amount to bypass PoolManager's default swap logic
        BeforeSwapDelta beforeSwapDelta =
            toBeforeSwapDelta(int128(-params.amountSpecified), int128(params.amountSpecified));

        if (isAnchorPool[id]) {
            // Stable Swap or CSMM Swap

            //
            // ── ANCHOR SWAP: USDC ⇄ USY @1:1 (minus hook fee) ───────────────────────
            //
            (Currency curIn, Currency curOut) =
                params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

            uint256 inFee = (amountInOutPositive * hookSwapFee) / PRECISION_DIVISOR;
            uint256 netIn = amountInOutPositive - inFee;
            // if user is selling USDC for USY
            if (Currency.unwrap(curIn) == address(usdc)) {
                // pull USDC from user → PM
                curIn.settle(poolManager, sender, amountInOutPositive, /*burnClaim=*/ false);

                // mint USY to user + fee to treasury
                IYoloAsset(address(anchor)).mint(sender, netIn);
                IYoloAsset(address(anchor)).mint(treasury, inFee);
                emit HookSwapExecuted(
                    id,
                    sender,
                    params.zeroForOne,
                    address(Currency.unwrap(curIn)), // USDC
                    netIn, // net USDC in after fee
                    address(Currency.unwrap(curOut)), // USY
                    netIn, // 1:1 mint
                    inFee // fee in USDC
                );
            } else {
                // user is selling USY for USDC

                // burn user’s USY directly
                IYoloAsset(address(anchor)).burn(sender, amountInOutPositive);

                // pay out USDC from PM → user & fee → treasury
                curOut.settle(poolManager, sender, netIn, /*burnClaim=*/ false);
                curOut.settle(poolManager, treasury, inFee, /*burnClaim=*/ false);
                emit HookSwapExecuted(
                    id,
                    sender,
                    params.zeroForOne,
                    address(Currency.unwrap(curIn)), // USY
                    netIn, // net USY in after fee
                    address(Currency.unwrap(curOut)), // USDC
                    netIn, // 1:1 payout
                    inFee // fee in USY
                );
            }
        } else {
            //
            // ── SYNTHETIC SWAP ─────────────────────────────────────────────────────
            //

            // 1) pick currencies
            (Currency curIn, Currency curOut) =
                params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

            // 2) compute fee & net
            uint256 inFee = (amountInOutPositive * hookSwapFee) / PRECISION_DIVISOR;
            uint256 netIn = amountInOutPositive - inFee;

            // 3) pull the full amount from the user into the PoolManager
            //    (this burns the user's ERC-20 and leaves a debit in PM)
            curIn.settle(poolManager, sender, amountInOutPositive, /*burnClaim=*/ false);

            // 4) mint claim-tokens in PM for the fee straight to the treasury
            curIn.take(poolManager, treasury, inFee, /*mintClaim=*/ true);

            // 5) mint claim-tokens in PM for the net amount into this hook
            curIn.take(poolManager, address(this), netIn, /*mintClaim=*/ true);

            // 6) burn those net claim-tokens to remove them from supply
            IYoloAsset(address(Currency.unwrap(curIn))).burn(address(this), netIn);

            // 7) oracle-convert and mint out to the user
            uint256 priceIn = yoloOracle.getAssetPrice(address(Currency.unwrap(curIn)));
            uint256 priceOut = yoloOracle.getAssetPrice(address(Currency.unwrap(curOut)));
            uint256 usdValue = netIn * priceIn;
            uint256 outAmt = usdValue / priceOut;
            IYoloAsset(address(Currency.unwrap(curOut))).mint(sender, outAmt);

            emit HookSwapExecuted(
                id,
                sender,
                params.zeroForOne,
                address(Currency.unwrap(curIn)), // e.g. YOLO-JPY
                netIn, // net “in” asset after fee
                address(Currency.unwrap(curOut)), // e.g. YOLO-USD
                outAmt, // price-converted “out”
                inFee // fee in input asset
            );
        }
        return (this.beforeSwap.selector, beforeSwapDelta, /*poolFee*/ 0);
    }
}
