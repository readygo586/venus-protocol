pragma solidity ^0.5.16;

import "../../Comptroller/ComptrollerInterface.sol";
import "../../Utils/ErrorReporter.sol";
import "../../Utils/Exponential.sol";
import "../../Utils/SafeMath.sol";
import "../../Tokens/EIP20Interface.sol";
import "../../Tokens/EIP20NonStandardInterface.sol";
import "../../InterestRateModels/InterestRateModel.sol";
import "./VTokenInterfaces.sol";
import "../../InterestRateModels/StableRateModel.sol";

/**
 * @title Venus's vToken Contract
 * @notice Abstract base for vTokens
 * @author Venus
 */
contract VToken is VTokenInterface, Exponential, TokenErrorReporter {
    using SafeMath for uint;
    struct MintLocalVars {
        MathError mathErr;
        uint exchangeRateMantissa;
        uint mintTokens;
        uint totalSupplyNew;
        uint accountTokensNew;
        uint actualMintAmount;
    }

    struct RedeemLocalVars {
        MathError mathErr;
        uint exchangeRateMantissa;
        uint redeemTokens;
        uint redeemAmount;
        uint totalSupplyNew;
        uint accountTokensNew;
    }

    struct BorrowLocalVars {
        MathError mathErr;
        uint accountBorrows;
        uint accountBorrowsNew;
        uint totalBorrowsNew;
    }

    struct RepayBorrowLocalVars {
        Error err;
        MathError mathErr;
        uint repayAmount;
        uint borrowerIndex;
        uint accountBorrows;
        uint accountBorrowsNew;
        uint totalBorrowsNew;
        uint actualRepayAmount;
    }

    /*** Reentrancy Guard ***/

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    // @custom:event Emits Transfer event
    function transfer(address dst, uint256 amount) external nonReentrant returns (bool) {
        return transferTokens(msg.sender, msg.sender, dst, amount) == uint(Error.NO_ERROR);
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    // @custom:event Emits Transfer event
    function transferFrom(address src, address dst, uint256 amount) external nonReentrant returns (bool) {
        return transferTokens(msg.sender, src, dst, amount) == uint(Error.NO_ERROR);
    }

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param amount The number of tokens that are approved (-1 means infinite)
     * @return Whether or not the approval succeeded
     */
    // @custom:event Emits Approval event on successful approve
    function approve(address spender, uint256 amount) external returns (bool) {
        address src = msg.sender;
        transferAllowances[src][spender] = amount;
        emit Approval(src, spender, amount);
        return true;
    }

    /**
     * @notice Get the underlying balance of the `owner`
     * @dev This also accrues interest in a transaction
     * @param owner The address of the account to query
     * @return The amount of underlying owned by `owner`
     */
    function balanceOfUnderlying(address owner) external returns (uint) {
        Exp memory exchangeRate = Exp({ mantissa: exchangeRateCurrent() });
        (MathError mErr, uint balance) = mulScalarTruncate(exchangeRate, accountTokens[owner]);
        require(mErr == MathError.NO_ERROR, "balance could not be calculated");
        return balance;
    }

    /**
     * @notice Returns the current total borrows plus accrued interest
     * @return The total borrows with interest
     */
    function totalBorrowsCurrent() external nonReentrant returns (uint) {
        require(accrueInterest() == uint(Error.NO_ERROR), "accrue interest failed");
        return totalBorrows;
    }

    /**
     * @notice Accrue interest to updated borrowIndex and then calculate account's borrow balance using the updated borrowIndex
     * @param account The address whose balance should be calculated after updating borrowIndex
     * @return The calculated balance
     */
    function borrowBalanceCurrent(address account) external nonReentrant returns (uint) {
        require(accrueInterest() == uint(Error.NO_ERROR), "accrue interest failed");
        return borrowBalanceStored(account);
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Will fail unless called by another vToken during the process of liquidation.
     *  Its absolutely critical to use msg.sender as the borrowed vToken and not a parameter.
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of vTokens to seize
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    // @custom:event Emits Transfer event
    function seize(address liquidator, address borrower, uint seizeTokens) external nonReentrant returns (uint) {
        return seizeInternal(msg.sender, liquidator, borrower, seizeTokens);
    }

    /**
     * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @param newPendingAdmin New pending admin.
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    // @custom:event Emits NewPendingAdmin event with old and new admin addresses
    function _setPendingAdmin(address payable newPendingAdmin) external returns (uint) {
        // Check caller = admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PENDING_ADMIN_OWNER_CHECK);
        }

        // Save current value, if any, for inclusion in log
        address oldPendingAdmin = pendingAdmin;

        // Store pendingAdmin with value newPendingAdmin
        pendingAdmin = newPendingAdmin;

        // Emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin)
        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
     * @dev Admin function for pending admin to accept role and update admin
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    // @custom:event Emits NewAdmin event on successful acceptance
    // @custom:event Emits NewPendingAdmin event with null new pending admin
    function _acceptAdmin() external returns (uint) {
        // Check caller is pendingAdmin
        if (msg.sender != pendingAdmin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.ACCEPT_ADMIN_PENDING_ADMIN_CHECK);
        }

        // Save current values for inclusion in log
        address oldAdmin = admin;
        address oldPendingAdmin = pendingAdmin;

        // Store admin with value pendingAdmin
        admin = pendingAdmin;

        // Clear the pending value
        pendingAdmin = address(0);

        emit NewAdmin(oldAdmin, admin);
        emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice accrues interest and sets a new reserve factor for the protocol using `_setReserveFactorFresh`
     * @dev Admin function to accrue interest and set a new reserve factor
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    // @custom:event Emits NewReserveFactor event
    function _setReserveFactor(uint newReserveFactorMantissa) external nonReentrant returns (uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but on top of that we want to log the fact that an attempted reserve factor change failed.
            return fail(Error(error), FailureInfo.SET_RESERVE_FACTOR_ACCRUE_INTEREST_FAILED);
        }
        // _setReserveFactorFresh emits reserve-factor-specific logs on errors, so we don't need to.
        return _setReserveFactorFresh(newReserveFactorMantissa);
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring to admin
     * @param reduceAmount Amount of reduction to reserves
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    // @custom:event Emits ReservesReduced event
    function _reduceReserves(uint reduceAmount) external nonReentrant returns (uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but on top of that we want to log the fact that an attempted reduce reserves failed.
            return fail(Error(error), FailureInfo.REDUCE_RESERVES_ACCRUE_INTEREST_FAILED);
        }
        // _reduceReservesFresh emits reserve-reduction-specific logs on errors, so we don't need to.
        return _reduceReservesFresh(reduceAmount);
    }

    /**
     * @notice Get the current allowance from `owner` for `spender`
     * @param owner The address of the account which owns the tokens to be spent
     * @param spender The address of the account which may transfer tokens
     * @return The number of tokens allowed to be spent (-1 means infinite)
     */
    function allowance(address owner, address spender) external view returns (uint256) {
        return transferAllowances[owner][spender];
    }

    /**
     * @notice Get the token balance of the `owner`
     * @param owner The address of the account to query
     * @return The number of tokens owned by `owner`
     */
    function balanceOf(address owner) external view returns (uint256) {
        return accountTokens[owner];
    }

    /**
     * @notice Get a snapshot of the account's balances, and the cached exchange rate
     * @dev This is used by comptroller to more efficiently perform liquidity checks.
     * @param account Address of the account to snapshot
     * @return (possible error, token balance, borrow balance, exchange rate mantissa)
     */
    function getAccountSnapshot(address account) external view returns (uint, uint, uint, uint) {
        uint vTokenBalance = accountTokens[account];
        uint borrowBalance;
        uint exchangeRateMantissa;

        MathError mErr;

        (mErr, borrowBalance) = borrowBalanceStoredInternal(account);
        if (mErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0, 0, 0);
        }

        (mErr, exchangeRateMantissa) = exchangeRateStoredInternal();
        if (mErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0, 0, 0);
        }

        return (uint(Error.NO_ERROR), vTokenBalance, borrowBalance, exchangeRateMantissa);
    }

    /**
     * @notice Returns the current per-block supply interest rate for this vToken
     * @return The supply interest rate per block, scaled by 1e18
     */
    function supplyRatePerBlock() external view returns (uint) {
        if (totalBorrows == 0) {
            return 0;
        }
        uint256 utilizationRate = utilizationRate(getCashPrior(), totalBorrows, totalReserves);
        uint256 averageMarketBorrowRate = _averageMarketBorrowRate();
        return
            (averageMarketBorrowRate.mul(utilizationRate).mul(mantissaOne.sub(reserveFactorMantissa))).div(
                mantissaOne.mul(mantissaOne)
            );
    }

    /// @notice Calculate the average market borrow rate with respect to variable and stable borrows
    function _averageMarketBorrowRate() internal view returns (uint256) {
        uint256 variableBorrowNew;
        uint256 stbleBorrowNew;
        uint256 totalBorrowNew;
        uint256 _averageMarketBorrowRate;
        uint256 variableBorrowRate = interestRateModel.getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
        (MathError mathErr, uint256 variableBorrows) = subUInt(totalBorrows, stableBorrows);
        if (mathErr != MathError.NO_ERROR) {
            revert("math error");
        }
        (mathErr, variableBorrowNew) = mulUInt(variableBorrows, variableBorrowRate);
        if (mathErr != MathError.NO_ERROR) {
            revert("math error");
        }
        (mathErr, stbleBorrowNew) = mulUInt(stableBorrows, averageStableBorrowRate);
        if (mathErr != MathError.NO_ERROR) {
            revert("math error");
        }
        (mathErr, totalBorrowNew) = addUInt(variableBorrowNew, stbleBorrowNew);
        if (mathErr != MathError.NO_ERROR) {
            revert("math error");
        }
        (mathErr, _averageMarketBorrowRate) = divUInt(totalBorrowNew, totalBorrows);
        if (mathErr != MathError.NO_ERROR) {
            revert("math error");
        }
        return _averageMarketBorrowRate;
    }

    /**
     * @notice Calculate the current per-block borrow interest rate for this vToken
     * @return The borrow interest rate per block, scaled by 1e18
     */
    function borrowRatePerBlock() external view returns (uint) {
        return interestRateModel.getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
    }

    /**
     * @notice Get cash balance of this vToken in the underlying asset
     * @return The quantity of underlying asset owned by this contract
     */
    function getCash() external view returns (uint) {
        return getCashPrior();
    }

    /**
     * @notice Initialize the money market
     * @param comptroller_ The address of the Comptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ EIP-20 name of this token
     * @param symbol_ EIP-20 symbol of this token
     * @param decimals_ EIP-20 decimal precision of this token
     */
    function initialize(
        ComptrollerInterface comptroller_,
        InterestRateModel interestRateModel_,
        uint initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) public {
        require(msg.sender == admin, "only admin may initialize the market");
        require(accrualBlockNumber == 0 && borrowIndex == 0, "market may only be initialized once");

        // Set initial exchange rate
        initialExchangeRateMantissa = initialExchangeRateMantissa_;
        require(initialExchangeRateMantissa > 0, "initial exchange rate must be greater than zero.");

        // Set the comptroller
        uint err = _setComptroller(comptroller_);
        require(err == uint(Error.NO_ERROR), "setting comptroller failed");

        // Initialize block number and borrow index (block number mocks depend on comptroller being set)
        accrualBlockNumber = getBlockNumber();
        borrowIndex = mantissaOne;

        // Set the interest rate model (depends on block number / borrow index)
        err = _setInterestRateModelFresh(interestRateModel_);
        require(err == uint(Error.NO_ERROR), "setting interest rate model failed");

        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
        _notEntered = true;
    }

    /**
     * @notice Accrue interest then return the up-to-date exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateCurrent() public nonReentrant returns (uint) {
        require(accrueInterest() == uint(Error.NO_ERROR), "accrue interest failed");
        return exchangeRateStored();
    }

    /**
     * @notice Applies accrued interest to total borrows and reserves
     * @dev This calculates interest accrued from the last checkpointed block
     *   up to the current block and writes new checkpoint to storage.
     */
    // @custom:event Emits AccrueInterest event
    function accrueInterest() public returns (uint) {
        /* Remember the initial block number */
        uint currentBlockNumber = getBlockNumber();
        uint accrualBlockNumberPrior = accrualBlockNumber;

        /* Short-circuit accumulating 0 interest */
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return uint(Error.NO_ERROR);
        }

        /* Read the previous values out of storage */
        uint cashPrior = getCashPrior();
        uint borrowsPrior = totalBorrows - stableBorrows;
        uint reservesPrior = totalReserves;
        uint borrowIndexPrior = borrowIndex;

        /* Calculate the current borrow interest rate */
        uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "borrow rate is absurdly high");

        /* Calculate the number of blocks elapsed since the last accrual */
        (MathError mathErr, uint blockDelta) = subUInt(currentBlockNumber, accrualBlockNumberPrior);
        require(mathErr == MathError.NO_ERROR, "could not calculate block delta");

        /*
         * Calculate the interest accumulated into borrows and reserves and the new index:
         *  simpleInterestFactor = borrowRate * blockDelta
         *  interestAccumulated = simpleInterestFactor * totalBorrows
         *  totalBorrowsNew = interestAccumulated + totalBorrows
         *  totalReservesNew = interestAccumulated * reserveFactor + totalReserves
         *  borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
         */

        Exp memory simpleInterestFactor;
        uint interestAccumulated;
        uint totalBorrowsNew;
        uint totalReservesNew;
        uint borrowIndexNew;

        (mathErr, simpleInterestFactor) = mulScalar(Exp({ mantissa: borrowRateMantissa }), blockDelta);
        if (mathErr != MathError.NO_ERROR) {
            return
                failOpaque(
                    Error.MATH_ERROR,
                    FailureInfo.ACCRUE_INTEREST_SIMPLE_INTEREST_FACTOR_CALCULATION_FAILED,
                    uint(mathErr)
                );
        }

        (mathErr, interestAccumulated) = mulScalarTruncate(simpleInterestFactor, borrowsPrior);
        if (mathErr != MathError.NO_ERROR) {
            return
                failOpaque(
                    Error.MATH_ERROR,
                    FailureInfo.ACCRUE_INTEREST_ACCUMULATED_INTEREST_CALCULATION_FAILED,
                    uint(mathErr)
                );
        }

        (mathErr, totalBorrowsNew) = addUInt(interestAccumulated, borrowsPrior);
        if (mathErr != MathError.NO_ERROR) {
            return
                failOpaque(
                    Error.MATH_ERROR,
                    FailureInfo.ACCRUE_INTEREST_NEW_TOTAL_BORROWS_CALCULATION_FAILED,
                    uint(mathErr)
                );
        }

        totalBorrowsNew = totalBorrowsNew + stableBorrows;

        (mathErr, totalReservesNew) = mulScalarTruncateAddUInt(
            Exp({ mantissa: reserveFactorMantissa }),
            interestAccumulated,
            reservesPrior
        );
        if (mathErr != MathError.NO_ERROR) {
            return
                failOpaque(
                    Error.MATH_ERROR,
                    FailureInfo.ACCRUE_INTEREST_NEW_TOTAL_RESERVES_CALCULATION_FAILED,
                    uint(mathErr)
                );
        }

        (mathErr, borrowIndexNew) = mulScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);
        if (mathErr != MathError.NO_ERROR) {
            return
                failOpaque(
                    Error.MATH_ERROR,
                    FailureInfo.ACCRUE_INTEREST_NEW_BORROW_INDEX_CALCULATION_FAILED,
                    uint(mathErr)
                );
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /* We write the previously calculated values into storage */
        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        uint256 err = _accrueStableInterest(blockDelta);

        if (err != 0) {
            return err;
        }

        /* We emit an AccrueInterest event */
        emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew, stableBorrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets a new comptroller for the market
     * @dev Admin function to set a new comptroller
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    // @custom:event Emits NewComptroller event
    function _setComptroller(ComptrollerInterface newComptroller) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COMPTROLLER_OWNER_CHECK);
        }

        ComptrollerInterface oldComptroller = comptroller;
        // Ensure invoke comptroller.isComptroller() returns true
        require(newComptroller.isComptroller(), "marker method returned false");

        // Set market's comptroller to newComptroller
        comptroller = newComptroller;

        // Emit NewComptroller(oldComptroller, newComptroller)
        emit NewComptroller(oldComptroller, newComptroller);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Accrues interest and updates the interest rate model using _setInterestRateModelFresh
     * @dev Admin function to accrue interest and update the interest rate model
     * @param newInterestRateModel The new interest rate model to use
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    function _setInterestRateModel(InterestRateModel newInterestRateModel) public returns (uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but on top of that we want to log the fact that an attempted change of interest rate model failed
            return fail(Error(error), FailureInfo.SET_INTEREST_RATE_MODEL_ACCRUE_INTEREST_FAILED);
        }
        // _setInterestRateModelFresh emits interest-rate-model-update-specific logs on errors, so we don't need to.
        return _setInterestRateModelFresh(newInterestRateModel);
    }

    /**
     * @notice Accrues interest and updates the stable interest rate model using _setStableInterestRateModelFresh
     * @dev Admin function to accrue interest and update the stable interest rate model
     * @param newStableInterestRateModel The new interest rate model to use
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     * custom:events Emits NewMarketInterestRateModel event; may emit AccrueInterest
     * custom:events Emits NewMarketStableInterestRateModel, after setting the new stable rate model
     */
    function setStableInterestRateModel(StableRateModel newStableInterestRateModel) public returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_STABLE_INTEREST_RATE_MODEL_OWNER_CHECK);
        }

        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but on top of that we want to log the fact that an attempted change of interest rate model failed
            return fail(Error(error), FailureInfo.SET_INTEREST_RATE_MODEL_ACCRUE_INTEREST_FAILED);
        }

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.SET_STABLE_INTEREST_RATE_MODEL_FRESH_CHECK);
        }

        // _setInterestRateModelFresh emits interest-rate-model-update-specific logs on errors, so we don't need to.
        return _setStableInterestRateModelFresh(newStableInterestRateModel);
    }

    /**
     * @notice Calculate the current per-block borrow interest rate for this vToken
     * @return rate The Stable borrow interest rate per block, scaled by 1e18
     */
    function stableBorrowRatePerBlock() public view returns (uint256) {
        uint256 variableBorrowRate = interestRateModel.getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
        return stableRateModel.getBorrowRate(stableBorrows, totalBorrows, variableBorrowRate);
    }

    /**
     * @notice Calculates the utilization rate of the market: `borrows / (cash + borrows - reserves)`
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market (currently unused)
     * @return The utilization rate as a mantissa between [0, 1e18]
     */
    function utilizationRate(uint cash, uint borrows, uint reserves) public pure returns (uint) {
        // Utilization rate is 0 when there are no borrows
        if (borrows == 0) {
            return 0;
        }
        return (borrows * mantissaOne) / (cash + borrows - reserves);
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return The calculated balance
     */
    function borrowBalanceStored(address account) public view returns (uint) {
        (uint256 stableBorrowAmount, , ) = _stableBorrowBalanceStored(account);
        (, uint256 _borrowBalanceStored) = borrowBalanceStoredInternal(account);
        return stableBorrowAmount + _borrowBalanceStored;
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the VToken
     * @dev This function does not accrue interest before calculating the exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateStored() public view returns (uint) {
        (MathError err, uint result) = exchangeRateStoredInternal();
        require(err == MathError.NO_ERROR, "exchangeRateStored: exchangeRateStoredInternal failed");
        return result;
    }

    /**
     * @notice Applies accrued interest to stable borrows and reserves
     * @dev This calculates interest accrued from the last checkpointed block
     *   up to the current block and writes new checkpoint to storage.
     * @param blockDelta the number of blocks elapsed since the last accrual
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _accrueStableInterest(uint256 blockDelta) internal returns (uint256) {
        uint256 stableIndexPrior = stableBorrowIndex;

        uint256 stableBorrowRateMantissa = stableBorrowRatePerBlock();
        require(stableBorrowRateMantissa <= stableBorrowRateMaxMantissa, "vToken: stable borrow rate is absurdly high");

        Exp memory simpleStableInterestFactor = mul_(Exp({ mantissa: stableBorrowRateMantissa }), blockDelta);

        uint256 stableBorrowIndexNew = mul_ScalarTruncateAddUInt(
            simpleStableInterestFactor,
            stableIndexPrior,
            stableIndexPrior
        );

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /* We write the previously calculated values into storage */
        stableBorrowIndex = stableBorrowIndexNew;

        return uint256(MathError.NO_ERROR);
    }

    /**
     * @notice Return the stable borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return Stable borrowBalance the calculated balance
     * custom:events UpdatedUserStableBorrowBalance event emitted after updating account's borrow
     */
    function _updateUserStableBorrowBalance(address account) internal returns (uint256) {
        StableBorrowSnapshot storage borrowSnapshot = accountStableBorrows[account];

        Exp memory simpleStableInterestFactor;
        uint256 principalUpdated;
        uint256 stableBorrowIndexNew;

        (principalUpdated, stableBorrowIndexNew, simpleStableInterestFactor) = _stableBorrowBalanceStored(account);
        uint256 stableBorrowsPrior = stableBorrows;
        uint256 totalBorrowsPrior = totalBorrows;
        uint256 totalReservesPrior = totalReserves;

        uint256 stableInterestAccumulated = mul_ScalarTruncate(simpleStableInterestFactor, borrowSnapshot.principal);
        uint256 stableBorrowsUpdated = stableBorrowsPrior + stableInterestAccumulated;
        uint256 totalBorrowsUpdated = totalBorrowsPrior + stableInterestAccumulated;
        uint256 totalReservesUpdated = mul_ScalarTruncateAddUInt(
            Exp({ mantissa: reserveFactorMantissa }),
            stableInterestAccumulated,
            totalReservesPrior
        );

        stableBorrows = stableBorrowsUpdated;
        totalBorrows = totalBorrowsUpdated;
        totalReserves = totalReservesUpdated;
        borrowSnapshot.interestIndex = stableBorrowIndexNew;
        borrowSnapshot.principal = principalUpdated;
        borrowSnapshot.lastBlockAccrued = getBlockNumber();

        emit UpdatedUserStableBorrowBalance(account, principalUpdated);
        return principalUpdated;
    }

    /**
     * @notice Transfers `tokens` tokens from `src` to `dst` by `spender`
     * @dev Called by both `transfer` and `transferFrom` internally
     * @param spender The address of the account performing the transfer
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param tokens The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferTokens(address spender, address src, address dst, uint tokens) internal returns (uint) {
        /* Fail if transfer not allowed */
        uint allowed = comptroller.transferAllowed(address(this), src, dst, tokens);
        if (allowed != 0) {
            return failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.TRANSFER_COMPTROLLER_REJECTION, allowed);
        }

        /* Do not allow self-transfers */
        if (src == dst) {
            return fail(Error.BAD_INPUT, FailureInfo.TRANSFER_NOT_ALLOWED);
        }

        /* Get the allowance, infinite for the account owner */
        uint startingAllowance = 0;
        if (spender == src) {
            startingAllowance = uint(-1);
        } else {
            startingAllowance = transferAllowances[src][spender];
        }

        /* Do the calculations, checking for {under,over}flow */
        MathError mathErr;
        uint allowanceNew;
        uint srvTokensNew;
        uint dstTokensNew;

        (mathErr, allowanceNew) = subUInt(startingAllowance, tokens);
        if (mathErr != MathError.NO_ERROR) {
            return fail(Error.MATH_ERROR, FailureInfo.TRANSFER_NOT_ALLOWED);
        }

        (mathErr, srvTokensNew) = subUInt(accountTokens[src], tokens);
        if (mathErr != MathError.NO_ERROR) {
            return fail(Error.MATH_ERROR, FailureInfo.TRANSFER_NOT_ENOUGH);
        }

        (mathErr, dstTokensNew) = addUInt(accountTokens[dst], tokens);
        if (mathErr != MathError.NO_ERROR) {
            return fail(Error.MATH_ERROR, FailureInfo.TRANSFER_TOO_MUCH);
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        accountTokens[src] = srvTokensNew;
        accountTokens[dst] = dstTokensNew;

        /* Eat some of the allowance (if necessary) */
        if (startingAllowance != uint(-1)) {
            transferAllowances[src][spender] = allowanceNew;
        }

        /* We emit a Transfer event */
        emit Transfer(src, dst, tokens);

        comptroller.transferVerify(address(this), src, dst, tokens);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sender supplies assets into the market and receives vTokens in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param mintAmount The amount of the underlying asset to supply
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mintInternal(uint mintAmount) internal nonReentrant returns (uint, uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted mint failed
            return (fail(Error(error), FailureInfo.MINT_ACCRUE_INTEREST_FAILED), 0);
        }
        // mintFresh emits the actual Mint event if successful and logs on errors, so we don't need to
        return mintFresh(msg.sender, mintAmount);
    }

    /**
     * @notice User supplies assets into the market and receives vTokens in exchange
     * @dev Assumes interest has already been accrued up to the current block
     * @param minter The address of the account which is supplying the assets
     * @param mintAmount The amount of the underlying asset to supply
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mintFresh(address minter, uint mintAmount) internal returns (uint, uint) {
        /* Fail if mint not allowed */
        uint allowed = comptroller.mintAllowed(address(this), minter, mintAmount);
        if (allowed != 0) {
            return (failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.MINT_COMPTROLLER_REJECTION, allowed), 0);
        }

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.MINT_FRESHNESS_CHECK), 0);
        }

        MintLocalVars memory vars;

        (vars.mathErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal();
        if (vars.mathErr != MathError.NO_ERROR) {
            return (failOpaque(Error.MATH_ERROR, FailureInfo.MINT_EXCHANGE_RATE_READ_FAILED, uint(vars.mathErr)), 0);
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         *  We call `doTransferIn` for the minter and the mintAmount.
         *  Note: The vToken must handle variations between BEP-20 and BNB underlying.
         *  `doTransferIn` reverts if anything goes wrong, since we can't be sure if
         *  side-effects occurred. The function returns the amount actually transferred,
         *  in case of a fee. On success, the vToken holds an additional `actualMintAmount`
         *  of cash.
         */
        vars.actualMintAmount = doTransferIn(minter, mintAmount);

        /*
         * We get the current exchange rate and calculate the number of vTokens to be minted:
         *  mintTokens = actualMintAmount / exchangeRate
         */

        (vars.mathErr, vars.mintTokens) = divScalarByExpTruncate(
            vars.actualMintAmount,
            Exp({ mantissa: vars.exchangeRateMantissa })
        );
        require(vars.mathErr == MathError.NO_ERROR, "MINT_EXCHANGE_CALCULATION_FAILED");

        /*
         * We calculate the new total supply of vTokens and minter token balance, checking for overflow:
         *  totalSupplyNew = totalSupply + mintTokens
         *  accountTokensNew = accountTokens[minter] + mintTokens
         */
        (vars.mathErr, vars.totalSupplyNew) = addUInt(totalSupply, vars.mintTokens);
        require(vars.mathErr == MathError.NO_ERROR, "MINT_NEW_TOTAL_SUPPLY_CALCULATION_FAILED");

        (vars.mathErr, vars.accountTokensNew) = addUInt(accountTokens[minter], vars.mintTokens);
        require(vars.mathErr == MathError.NO_ERROR, "MINT_NEW_ACCOUNT_BALANCE_CALCULATION_FAILED");

        /* We write previously calculated values into storage */
        totalSupply = vars.totalSupplyNew;
        accountTokens[minter] = vars.accountTokensNew;

        /* We emit a Mint event, and a Transfer event */
        emit Mint(minter, vars.actualMintAmount, vars.mintTokens, vars.accountTokensNew);
        emit Transfer(address(this), minter, vars.mintTokens);

        /* We call the defense hook */
        comptroller.mintVerify(address(this), minter, vars.actualMintAmount, vars.mintTokens);

        return (uint(Error.NO_ERROR), vars.actualMintAmount);
    }

    /**
     * @notice Sender supplies assets into the market and receiver receives vTokens in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param receiver The address of the account which is receiving the vTokens
     * @param mintAmount The amount of the underlying asset to supply
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mintBehalfInternal(address receiver, uint mintAmount) internal nonReentrant returns (uint, uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted mintBehalf failed
            return (fail(Error(error), FailureInfo.MINT_ACCRUE_INTEREST_FAILED), 0);
        }
        // mintBelahfFresh emits the actual Mint event if successful and logs on errors, so we don't need to
        return mintBehalfFresh(msg.sender, receiver, mintAmount);
    }

    /**
     * @notice Payer supplies assets into the market and receiver receives vTokens in exchange
     * @dev Assumes interest has already been accrued up to the current block
     * @param payer The address of the account which is paying the underlying token
     * @param receiver The address of the account which is receiving vToken
     * @param mintAmount The amount of the underlying asset to supply
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mintBehalfFresh(address payer, address receiver, uint mintAmount) internal returns (uint, uint) {
        require(receiver != address(0), "receiver is invalid");
        /* Fail if mint not allowed */
        uint allowed = comptroller.mintAllowed(address(this), receiver, mintAmount);
        if (allowed != 0) {
            return (failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.MINT_COMPTROLLER_REJECTION, allowed), 0);
        }

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.MINT_FRESHNESS_CHECK), 0);
        }

        MintLocalVars memory vars;

        (vars.mathErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal();
        if (vars.mathErr != MathError.NO_ERROR) {
            return (failOpaque(Error.MATH_ERROR, FailureInfo.MINT_EXCHANGE_RATE_READ_FAILED, uint(vars.mathErr)), 0);
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         *  We call `doTransferIn` for the payer and the mintAmount.
         *  Note: The vToken must handle variations between BEP-20 and BNB underlying.
         *  `doTransferIn` reverts if anything goes wrong, since we can't be sure if
         *  side-effects occurred. The function returns the amount actually transferred,
         *  in case of a fee. On success, the vToken holds an additional `actualMintAmount`
         *  of cash.
         */
        vars.actualMintAmount = doTransferIn(payer, mintAmount);

        /*
         * We get the current exchange rate and calculate the number of vTokens to be minted:
         *  mintTokens = actualMintAmount / exchangeRate
         */

        (vars.mathErr, vars.mintTokens) = divScalarByExpTruncate(
            vars.actualMintAmount,
            Exp({ mantissa: vars.exchangeRateMantissa })
        );
        require(vars.mathErr == MathError.NO_ERROR, "MINT_EXCHANGE_CALCULATION_FAILED");

        /*
         * We calculate the new total supply of vTokens and receiver token balance, checking for overflow:
         *  totalSupplyNew = totalSupply + mintTokens
         *  accountTokensNew = accountTokens[receiver] + mintTokens
         */
        (vars.mathErr, vars.totalSupplyNew) = addUInt(totalSupply, vars.mintTokens);
        require(vars.mathErr == MathError.NO_ERROR, "MINT_NEW_TOTAL_SUPPLY_CALCULATION_FAILED");

        (vars.mathErr, vars.accountTokensNew) = addUInt(accountTokens[receiver], vars.mintTokens);
        require(vars.mathErr == MathError.NO_ERROR, "MINT_NEW_ACCOUNT_BALANCE_CALCULATION_FAILED");

        /* We write previously calculated values into storage */
        totalSupply = vars.totalSupplyNew;
        accountTokens[receiver] = vars.accountTokensNew;

        /* We emit a MintBehalf event, and a Transfer event */
        emit MintBehalf(payer, receiver, vars.actualMintAmount, vars.mintTokens, vars.accountTokensNew);
        emit Transfer(address(this), receiver, vars.mintTokens);

        /* We call the defense hook */
        comptroller.mintVerify(address(this), receiver, vars.actualMintAmount, vars.mintTokens);

        return (uint(Error.NO_ERROR), vars.actualMintAmount);
    }

    /**
     * @notice Sender redeems vTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of vTokens to redeem into underlying
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    function redeemInternal(uint redeemTokens) internal nonReentrant returns (uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted redeem failed
            return fail(Error(error), FailureInfo.REDEEM_ACCRUE_INTEREST_FAILED);
        }
        // redeemFresh emits redeem-specific logs on errors, so we don't need to
        return redeemFresh(msg.sender, redeemTokens, 0);
    }

    /**
     * @notice Sender redeems vTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemAmount The amount of underlying to receive from redeeming vTokens
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    function redeemUnderlyingInternal(uint redeemAmount) internal nonReentrant returns (uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted redeem failed
            return fail(Error(error), FailureInfo.REDEEM_ACCRUE_INTEREST_FAILED);
        }
        // redeemFresh emits redeem-specific logs on errors, so we don't need to
        return redeemFresh(msg.sender, 0, redeemAmount);
    }

    /**
     * @notice User redeems vTokens in exchange for the underlying asset
     * @dev Assumes interest has already been accrued up to the current block
     * @param redeemer The address of the account which is redeeming the tokens
     * @param redeemTokensIn The number of vTokens to redeem into underlying (only one of redeemTokensIn or redeemAmountIn may be non-zero)
     * @param redeemAmountIn The number of underlying tokens to receive from redeeming vTokens (only one of redeemTokensIn or redeemAmountIn may be non-zero)
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    // solhint-disable-next-line code-complexity
    function redeemFresh(address payable redeemer, uint redeemTokensIn, uint redeemAmountIn) internal returns (uint) {
        require(redeemTokensIn == 0 || redeemAmountIn == 0, "one of redeemTokensIn or redeemAmountIn must be zero");

        RedeemLocalVars memory vars;

        /* exchangeRate = invoke Exchange Rate Stored() */
        (vars.mathErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal();
        if (vars.mathErr != MathError.NO_ERROR) {
            revert("math error");
        }

        /* If redeemTokensIn > 0: */
        if (redeemTokensIn > 0) {
            /*
             * We calculate the exchange rate and the amount of underlying to be redeemed:
             *  redeemTokens = redeemTokensIn
             *  redeemAmount = redeemTokensIn x exchangeRateCurrent
             */
            vars.redeemTokens = redeemTokensIn;

            (vars.mathErr, vars.redeemAmount) = mulScalarTruncate(
                Exp({ mantissa: vars.exchangeRateMantissa }),
                redeemTokensIn
            );
            if (vars.mathErr != MathError.NO_ERROR) {
                revert("math error");
            }
        } else {
            /*
             * We get the current exchange rate and calculate the amount to be redeemed:
             *  redeemTokens = redeemAmountIn / exchangeRate
             *  redeemAmount = redeemAmountIn
             */

            (vars.mathErr, vars.redeemTokens) = divScalarByExpTruncate(
                redeemAmountIn,
                Exp({ mantissa: vars.exchangeRateMantissa })
            );
            if (vars.mathErr != MathError.NO_ERROR) {
                revert("math error");
            }

            vars.redeemAmount = redeemAmountIn;
        }

        /* Fail if redeem not allowed */
        uint allowed = comptroller.redeemAllowed(address(this), redeemer, vars.redeemTokens);
        if (allowed != 0) {
            revert("math error");
        }

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            revert("math error");
        }

        /*
         * We calculate the new total supply and redeemer balance, checking for underflow:
         *  totalSupplyNew = totalSupply - redeemTokens
         *  accountTokensNew = accountTokens[redeemer] - redeemTokens
         */
        (vars.mathErr, vars.totalSupplyNew) = subUInt(totalSupply, vars.redeemTokens);
        if (vars.mathErr != MathError.NO_ERROR) {
            revert("math error");
        }

        (vars.mathErr, vars.accountTokensNew) = subUInt(accountTokens[redeemer], vars.redeemTokens);
        if (vars.mathErr != MathError.NO_ERROR) {
            revert("math error");
        }

        /* Fail gracefully if protocol has insufficient cash */
        if (getCashPrior() < vars.redeemAmount) {
            revert("math error");
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /* We write previously calculated values into storage */
        totalSupply = vars.totalSupplyNew;
        accountTokens[redeemer] = vars.accountTokensNew;

        /*
         * We invoke doTransferOut for the redeemer and the redeemAmount.
         *  Note: The vToken must handle variations between BEP-20 and BNB underlying.
         *  On success, the vToken has redeemAmount less of cash.
         *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
         */

        uint feeAmount;
        uint remainedAmount;
        if (IComptroller(address(comptroller)).treasuryPercent() != 0) {
            (vars.mathErr, feeAmount) = mulUInt(
                vars.redeemAmount,
                IComptroller(address(comptroller)).treasuryPercent()
            );
            if (vars.mathErr != MathError.NO_ERROR) {
                revert("math error");
            }

            (vars.mathErr, feeAmount) = divUInt(feeAmount, 1e18);
            if (vars.mathErr != MathError.NO_ERROR) {
                revert("math error");
            }

            (vars.mathErr, remainedAmount) = subUInt(vars.redeemAmount, feeAmount);
            if (vars.mathErr != MathError.NO_ERROR) {
                revert("math error");
            }

            doTransferOut(address(uint160(IComptroller(address(comptroller)).treasuryAddress())), feeAmount);

            emit RedeemFee(redeemer, feeAmount, vars.redeemTokens);
        } else {
            remainedAmount = vars.redeemAmount;
        }

        doTransferOut(redeemer, remainedAmount);

        /* We emit a Transfer event, and a Redeem event */
        emit Transfer(redeemer, address(this), vars.redeemTokens);
        emit Redeem(redeemer, remainedAmount, vars.redeemTokens, vars.accountTokensNew);

        /* We call the defense hook */
        comptroller.redeemVerify(address(this), redeemer, vars.redeemAmount, vars.redeemTokens);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Receiver gets the borrow on behalf of the borrower address
     * @param borrower The borrower, on behalf of whom to borrow
     * @param receiver The account that would receive the funds (can be the same as the borrower)
     * @param borrowAmount The amount of the underlying asset to borrow
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    function borrowInternal(
        address borrower,
        address payable receiver,
        uint borrowAmount
    ) internal nonReentrant returns (uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted borrow failed
            return fail(Error(error), FailureInfo.BORROW_ACCRUE_INTEREST_FAILED);
        }
        // borrowFresh emits borrow-specific logs on errors, so we don't need to
        return borrowFresh(borrower, receiver, borrowAmount, InterestRateMode.VARIABLE);
    }

    function borrowStableInternal(
        address borrower,
        address payable receiver,
        uint256 borrowAmount
    ) internal nonReentrant returns (uint) {
        accrueInterest();

        // borrowFresh emits borrow-specific logs on errors, so we don't need to
        return borrowFresh(borrower, receiver, borrowAmount, InterestRateMode.STABLE);
    }

    struct stableBorrowVars {
        uint256 accountBorrowsPrev;
        uint256 stableBorrowsNew;
        uint256 stableBorrowRate;
        uint256 averageStableBorrowRateNew;
        uint256 stableRateMantissaNew;
    }

    /**
     * @notice Receiver gets the borrow on behalf of the borrower address
     * @dev Before calling this function, ensure that the interest has been accrued
     * @param borrower The borrower, on behalf of whom to borrow
     * @param receiver The account that would receive the funds (can be the same as the borrower)
     * @param borrowAmount The amount of the underlying asset to borrow
     * @param interestRateMode The interest rate mode at which the user wants to borrow: 1 for Stable, 2 for Variable
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    function borrowFresh(
        address borrower,
        address payable receiver,
        uint borrowAmount,
        InterestRateMode interestRateMode
    ) internal returns (uint) {
        /* Fail if borrow not allowed */
        uint allowed = comptroller.borrowAllowed(address(this), borrower, borrowAmount);
        if (allowed != 0) {
            return (failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.BORROW_COMPTROLLER_REJECTION, allowed));
        }

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            revert("math error");
        }

        /* Fail gracefully if protocol has insufficient underlying cash */
        if (getCashPrior() < borrowAmount) {
            revert("math error");
        }

        uint256 totalBorrowsNew;
        uint256 accountBorrowsNew;
        if (InterestRateMode(interestRateMode) == InterestRateMode.STABLE) {
            stableBorrowVars memory vars;
            /*
             * We calculate the new borrower and total borrow balances, failing on overflow:
             *  accountBorrowNew = accountStableBorrow + borrowAmount
             *  totalBorrowsNew = totalBorrows + borrowAmount
             */
            vars.accountBorrowsPrev = _updateUserStableBorrowBalance(borrower);
            accountBorrowsNew = vars.accountBorrowsPrev.add(borrowAmount);
            totalBorrowsNew = totalBorrows.add(borrowAmount);

            /**
             * Calculte the average stable borrow rate for the total stable borrows
             */

            vars.stableBorrowsNew = stableBorrows.add(borrowAmount);
            vars.stableBorrowRate = stableBorrowRatePerBlock();
            vars.averageStableBorrowRateNew = (
                stableBorrows.mul(averageStableBorrowRate).add(borrowAmount.mul(vars.stableBorrowRate))
            ).div(vars.stableBorrowsNew);

            vars.stableRateMantissaNew = (
                vars.accountBorrowsPrev.mul(accountStableBorrows[borrower].stableRateMantissa).add(
                    borrowAmount.mul(vars.stableBorrowRate)
                )
            ).div(accountBorrowsNew);

            /////////////////////////
            // EFFECTS & INTERACTIONS
            // (No safe failures beyond this point)

            /*
             * We write the previously calculated values into storage.
             *  Note: Avoid token reentrancy attacks by writing increased borrow before external transfer.
             */

            accountStableBorrows[borrower].principal = accountBorrowsNew;
            accountStableBorrows[borrower].interestIndex = stableBorrowIndex;
            accountStableBorrows[borrower].stableRateMantissa = vars.stableRateMantissaNew;
            stableBorrows = vars.stableBorrowsNew;
            averageStableBorrowRate = vars.averageStableBorrowRateNew;
        } else {
            /*
             * We calculate the new borrower and total borrow balances, failing on overflow:
             *  accountBorrowNew = accountBorrow + borrowAmount
             *  totalBorrowsNew = totalBorrows + borrowAmount
             */
            (, uint256 accountBorrowsPrev) = borrowBalanceStoredInternal(borrower);
            accountBorrowsNew = accountBorrowsPrev.add(borrowAmount);
            totalBorrowsNew = totalBorrows.add(borrowAmount);

            /////////////////////////
            // EFFECTS & INTERACTIONS
            // (No safe failures beyond this point)

            /*
             * We write the previously calculated values into storage.
             *  Note: Avoid token reentrancy attacks by writing increased borrow before external transfer.
             */
            accountBorrows[borrower].principal = accountBorrowsNew;
            accountBorrows[borrower].interestIndex = borrowIndex;
        }

        totalBorrows = totalBorrowsNew;

        /*
         * We invoke doTransferOut for the borrower and the borrowAmount.
         *  Note: The vToken must handle variations between BEP-20 and BNB underlying.
         *  On success, the vToken borrowAmount less of cash.
         *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
         */
        doTransferOut(receiver, borrowAmount);

        /* We emit a Borrow event */
        emit Borrow(borrower, borrowAmount, accountBorrowsNew, totalBorrowsNew);
        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBorrowInternal(uint repayAmount) internal nonReentrant returns (uint, uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted borrow failed
            return (fail(Error(error), FailureInfo.REPAY_BORROW_ACCRUE_INTEREST_FAILED), 0);
        }
        // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
        return repayBorrowFresh(msg.sender, msg.sender, repayAmount, InterestRateMode.VARIABLE);
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay, or -1 for the full outstanding amount
     * @return error Always NO_ERROR for compatilibily with Venus core tooling
     * custom:events Emits RepayBorrow event; may emit AccrueInterest
     * custom:access Not restricted
     */
    function repayBorrowStable(uint256 repayAmount) internal nonReentrant returns (uint256) {
        accrueInterest();
        // _repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
        repayBorrowFresh(msg.sender, msg.sender, repayAmount, InterestRateMode.STABLE);
        return uint256(MathError.NO_ERROR);
    }

    /**
     * @notice Sender repays a borrow belonging to another borrowing account
     * @param borrower The account with the debt being payed off
     * @param repayAmount The amount to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBorrowBehalfInternal(address borrower, uint repayAmount) internal nonReentrant returns (uint, uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted borrow failed
            return (fail(Error(error), FailureInfo.REPAY_BEHALF_ACCRUE_INTEREST_FAILED), 0);
        }
        // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
        return repayBorrowFresh(msg.sender, borrower, repayAmount, InterestRateMode.VARIABLE);
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @param borrower the account with the debt being payed off
     * @param repayAmount The amount to repay, or -1 for the full outstanding amount
     * @return error Always NO_ERROR for compatilibily with Venus core tooling
     * custom:events Emits RepayBorrow event; may emit AccrueInterest
     * custom:access Not restricted
     */
    function repayBorrowStableBehalf(address borrower, uint repayAmount) internal nonReentrant returns (uint) {
        accrueInterest();
        // _repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
        repayBorrowFresh(msg.sender, borrower, repayAmount, InterestRateMode.STABLE);
        return uint(MathError.NO_ERROR);
    }

    /**
     * @notice Borrows are repaid by another user (possibly the borrower).
     * @param payer The account paying off the borrow
     * @param borrower The account with the debt being payed off
     * @param repayAmount The amount of undelrying tokens being returned
     * @param interestRateMode The interest rate mode of the debt the user wants to repay: 1 for Stable, 2 for Variable
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBorrowFresh(
        address payer,
        address borrower,
        uint repayAmount,
        InterestRateMode interestRateMode
    ) internal returns (uint, uint) {
        /* Fail if repayBorrow not allowed */
        uint allowed = comptroller.repayBorrowAllowed(address(this), payer, borrower, repayAmount);
        if (allowed != 0) {
            return (
                failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.REPAY_BORROW_COMPTROLLER_REJECTION, allowed),
                0
            );
        }

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.REPAY_BORROW_FRESHNESS_CHECK), 0);
        }

        uint256 accountBorrowsPrev;
        if (InterestRateMode(interestRateMode) == InterestRateMode.STABLE) {
            accountBorrowsPrev = _updateUserStableBorrowBalance(borrower);
        } else {
            /* We fetch the amount the borrower owes, with accumulated interest */
            (, accountBorrowsPrev) = borrowBalanceStoredInternal(borrower);
        }

        if (accountBorrowsPrev == 0) {
            return (uint(Error.NO_ERROR), 0);
        }

        /* If repayAmount == -1, repayAmount = accountBorrows */
        uint256 repayAmountFinal = repayAmount > accountBorrowsPrev ? accountBorrowsPrev : repayAmount;

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         * We call doTransferIn for the payer and the repayAmount
         *  Note: The vToken must handle variations between BEP-20 and BNB underlying.
         *  On success, the vToken holds an additional repayAmount of cash.
         *  doTransferIn reverts if anything goes wrong, since we can't be sure if side effects occurred.
         *   it returns the amount actually transferred, in case of a fee.
         */
        uint256 actualRepayAmount = doTransferIn(payer, repayAmountFinal);

        /*
         * We calculate the new borrower and total borrow balances, failing on underflow:
         *  accountBorrowsNew = accountBorrows - actualRepayAmount
         *  totalBorrowsNew = totalBorrows - actualRepayAmount
         */
        uint256 accountBorrowsNew = accountBorrowsPrev.sub(actualRepayAmount);
        uint256 totalBorrowsNew = totalBorrows.sub(actualRepayAmount);

        if (InterestRateMode(interestRateMode) == InterestRateMode.STABLE) {
            uint256 stableBorrowsNew = stableBorrows - actualRepayAmount;

            uint256 averageStableBorrowRateNew;
            if (stableBorrowsNew == 0) {
                averageStableBorrowRateNew = 0;
            } else {
                uint256 stableRateMantissa = accountStableBorrows[borrower].stableRateMantissa;
                averageStableBorrowRateNew = (
                    stableBorrows.mul(averageStableBorrowRate).sub(actualRepayAmount.mul(stableRateMantissa))
                ).div(stableBorrowsNew);
            }

            accountStableBorrows[borrower].principal = accountBorrowsNew;
            accountStableBorrows[borrower].interestIndex = stableBorrowIndex;

            stableBorrows = stableBorrowsNew;
            averageStableBorrowRate = averageStableBorrowRateNew;
        } else {
            accountBorrows[borrower].principal = accountBorrowsNew;
            accountBorrows[borrower].interestIndex = borrowIndex;
        }
        totalBorrows = totalBorrowsNew;

        /* We emit a RepayBorrow event */
        emit RepayBorrow(payer, borrower, actualRepayAmount, accountBorrowsNew, totalBorrowsNew);

        /* We call the defense hook */
        comptroller.repayBorrowVerify(address(this), payer, borrower, actualRepayAmount, borrowIndex);

        return (uint(Error.NO_ERROR), actualRepayAmount);
    }

    /**
     * @notice Checks before swapping borrow rate mode
     * @param account Address of the borrow holder
     * @return (uint256, uint256) returns the variableDebt and stableDebt for the account
     */
    function _swapBorrowRateModePreCalculation(address account) internal returns (uint256, uint256) {
        /* Fail if swapBorrowRateMode not allowed */
        comptroller.swapBorrowRateModeAllowed(address(this));

        accrueInterest();

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            revert("math error");
        }

        (, uint256 variableDebt) = borrowBalanceStoredInternal(account);
        uint256 stableDebt = _updateUserStableBorrowBalance(account);

        return (variableDebt, stableDebt);
    }

    /**
     * @notice Update states for the stable borrow while swapping
     * @param swappedAmount Amount need to be swapped
     * @param stableDebt Stable debt for the account
     * @param variableDebt Variable debt for the account
     * @param account Address of the account
     * @param accountBorrowsNew New stable borrow for the account
     * @return (uint256, uint256) returns updated stable borrow for the account and updated average stable borrow rate
     */
    function _updateStatesForStableRateSwap(
        uint256 swappedAmount,
        uint256 stableDebt,
        uint256 variableDebt,
        address account,
        uint256 accountBorrowsNew
    ) internal returns (uint256, uint256) {
        uint256 stableBorrowsNew = stableBorrows + swappedAmount;
        uint256 stableBorrowRate = stableBorrowRatePerBlock();

        uint256 averageStableBorrowRateNew = ((stableBorrows * averageStableBorrowRate) +
            (swappedAmount * stableBorrowRate)) / stableBorrowsNew;

        uint256 stableRateMantissaNew = ((stableDebt * accountStableBorrows[account].stableRateMantissa) +
            (swappedAmount * stableBorrowRate)) / accountBorrowsNew;

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        accountStableBorrows[account].principal = accountBorrowsNew;
        accountStableBorrows[account].interestIndex = stableBorrowIndex;
        accountStableBorrows[account].stableRateMantissa = stableRateMantissaNew;

        accountBorrows[account].principal = variableDebt - swappedAmount;
        accountBorrows[account].interestIndex = borrowIndex;

        return (stableBorrowsNew, averageStableBorrowRateNew);
    }

    /**
     * @notice Update states for the variable borrow during the swap
     * @param swappedAmount Amount need to be swapped
     * @param stableDebt Stable debt for the account
     * @param variableDebt Variable debt for the account
     * @param account Address of the account
     * @return (uint256, uint256) returns updated stable borrow for the account and updated average stable borrow rate
     */
    function _updateStatesForVariableRateSwap(
        uint256 swappedAmount,
        uint256 stableDebt,
        uint256 variableDebt,
        address account
    ) internal returns (uint256, uint256) {
        uint256 newStableDebt = stableDebt - swappedAmount;
        uint256 stableBorrowsNew = stableBorrows - swappedAmount;

        uint256 stableRateMantissa = accountStableBorrows[account].stableRateMantissa;
        uint256 averageStableBorrowRateNew;
        if (stableBorrowsNew == 0) {
            averageStableBorrowRateNew = 0;
        } else {
            averageStableBorrowRateNew =
                ((stableBorrows * averageStableBorrowRate) - (swappedAmount * stableRateMantissa)) /
                stableBorrowsNew;
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)
        accountBorrows[account].principal = variableDebt + swappedAmount;
        accountBorrows[account].interestIndex = borrowIndex;

        accountStableBorrows[account].principal = newStableDebt;
        accountStableBorrows[account].interestIndex = stableBorrowIndex;

        return (stableBorrowsNew, averageStableBorrowRateNew);
    }

    /**
     * @dev Allows a borrower to swap his debt between stable and variable mode, or vice versa with specific amount
     * @param rateMode The rate mode that the user wants to swap to
     * @param sentAmount The amount that the user wants to convert form stable to variable mode or vice versa.
     * custom:access Not restricted
     **/
    function swapBorrowRateModeWithAmount(uint256 rateMode, uint256 sentAmount) external {
        address account = msg.sender;
        (uint256 variableDebt, uint256 stableDebt) = _swapBorrowRateModePreCalculation(account);

        uint256 stableBorrowsNew;
        uint256 averageStableBorrowRateNew;
        uint256 swappedAmount;

        if (InterestRateMode(rateMode) == InterestRateMode.STABLE) {
            require(variableDebt > 0, "vToken: swapBorrowRateMode variable debt is 0");

            swappedAmount = sentAmount > variableDebt ? variableDebt : sentAmount;
            uint256 accountBorrowsNew = stableDebt + swappedAmount;

            (stableBorrowsNew, averageStableBorrowRateNew) = _updateStatesForStableRateSwap(
                swappedAmount,
                stableDebt,
                variableDebt,
                account,
                accountBorrowsNew
            );
        } else {
            require(stableDebt > 0, "vToken: swapBorrowRateMode stable debt is 0");

            swappedAmount = sentAmount > stableDebt ? stableDebt : sentAmount;

            (stableBorrowsNew, averageStableBorrowRateNew) = _updateStatesForVariableRateSwap(
                swappedAmount,
                stableDebt,
                variableDebt,
                account
            );
        }

        stableBorrows = stableBorrowsNew;
        averageStableBorrowRate = averageStableBorrowRateNew;

        emit SwapBorrowRateMode(account, rateMode, swappedAmount);
    }

    /**
     * @notice Rebalances the stable interest rate of a user to the current stable borrow rate.
     * - Users can be rebalanced if the following conditions are satisfied:
     *     1. Utilization rate is above rebalanceUtilizationRateThreshold.
     *     2. Average market borrow rate should be less than the rebalanceRateFractionThreshold fraction of variable borrow rate.
     * @param account The address of the account to be rebalanced
     * custom:events RebalancedStableBorrowRate - Emits after rebalancing the stable borrow rate for the user.
     **/
    function rebalanceStableBorrowRate(address account) external {
        accrueInterest();

        validateRebalanceStableBorrowRate();
        _updateUserStableBorrowBalance(account);

        uint256 stableBorrowRate = stableBorrowRatePerBlock();

        accountStableBorrows[account].stableRateMantissa = stableBorrowRate;

        emit RebalancedStableBorrowRate(account, stableBorrowRate);
    }

    /// Validate the conditions to rebalance the stable borrow rate.
    function validateRebalanceStableBorrowRate() public view returns (bool) {
        require(rebalanceUtilizationRateThreshold > 0, "vToken: rebalanceUtilizationRateThreshold is not set.");
        require(rebalanceRateFractionThreshold > 0, "vToken: rebalanceRateFractionThreshold is not set.");

        uint256 utRate = utilizationRate(getCashPrior(), totalBorrows, totalReserves);
        uint256 variableBorrowRate = interestRateModel.getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
        /// Utilization rate is above rebalanceUtilizationRateThreshold.
        /// Average market borrow rate should be less than the rebalanceRateFractionThreshold fraction of variable borrow rate.
        require(utRate >= rebalanceUtilizationRateThreshold, "vToken: low utilization rate for rebalacing.");
        require(
            _averageMarketBorrowRate() < (variableBorrowRate * rebalanceRateFractionThreshold),
            "vToken: average borrow rate higher than variable rate threshold."
        );

        return true;
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this vToken to be liquidated
     * @param vTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function liquidateBorrowInternal(
        address borrower,
        uint repayAmount,
        VTokenInterface vTokenCollateral
    ) internal nonReentrant returns (uint, uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted liquidation failed
            return (fail(Error(error), FailureInfo.LIQUIDATE_ACCRUE_BORROW_INTEREST_FAILED), 0);
        }

        error = vTokenCollateral.accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted liquidation failed
            return (fail(Error(error), FailureInfo.LIQUIDATE_ACCRUE_COLLATERAL_INTEREST_FAILED), 0);
        }

        // liquidateBorrowFresh emits borrow-specific logs on errors, so we don't need to
        return liquidateBorrowFresh(msg.sender, borrower, repayAmount, vTokenCollateral);
    }

    /**
     * @notice The liquidator liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this vToken to be liquidated
     * @param liquidator The address repaying the borrow and seizing collateral
     * @param vTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    // solhint-disable-next-line code-complexity
    function liquidateBorrowFresh(
        address liquidator,
        address borrower,
        uint repayAmount,
        VTokenInterface vTokenCollateral
    ) internal returns (uint, uint) {
        /* Fail if liquidate not allowed */
        uint allowed = comptroller.liquidateBorrowAllowed(
            address(this),
            address(vTokenCollateral),
            liquidator,
            borrower,
            repayAmount
        );
        if (allowed != 0) {
            return (failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.LIQUIDATE_COMPTROLLER_REJECTION, allowed), 0);
        }

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.LIQUIDATE_FRESHNESS_CHECK), 0);
        }

        /* Verify vTokenCollateral market's block number equals current block number */
        if (vTokenCollateral.accrualBlockNumber() != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.LIQUIDATE_COLLATERAL_FRESHNESS_CHECK), 0);
        }

        /* Fail if borrower = liquidator */
        if (borrower == liquidator) {
            return (fail(Error.INVALID_ACCOUNT_PAIR, FailureInfo.LIQUIDATE_LIQUIDATOR_IS_BORROWER), 0);
        }

        /* Fail if repayAmount = 0 */
        if (repayAmount == 0) {
            return (fail(Error.INVALID_CLOSE_AMOUNT_REQUESTED, FailureInfo.LIQUIDATE_CLOSE_AMOUNT_IS_ZERO), 0);
        }

        /* Fail if repayAmount = -1 */
        if (repayAmount == uint(-1)) {
            return (fail(Error.INVALID_CLOSE_AMOUNT_REQUESTED, FailureInfo.LIQUIDATE_CLOSE_AMOUNT_IS_UINT_MAX), 0);
        }

        /* Fail if repayBorrow fails */
        (, uint actualRepayAmount) = repayBorrowFresh(liquidator, borrower, repayAmount, InterestRateMode.VARIABLE);
        (, uint actualRepayAmountStable) = repayBorrowFresh(liquidator, borrower, repayAmount, InterestRateMode.STABLE);

        actualRepayAmount += actualRepayAmountStable;

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /* We calculate the number of collateral tokens that will be seized */
        (uint amountSeizeError, uint seizeTokens) = comptroller.liquidateCalculateSeizeTokens(
            address(this),
            address(vTokenCollateral),
            actualRepayAmount
        );
        require(amountSeizeError == uint(Error.NO_ERROR), "LIQUIDATE_COMPTROLLER_CALCULATE_AMOUNT_SEIZE_FAILED");

        /* Revert if borrower collateral token balance < seizeTokens */
        require(vTokenCollateral.balanceOf(borrower) >= seizeTokens, "LIQUIDATE_SEIZE_TOO_MUCH");

        // If this is also the collateral, run seizeInternal to avoid re-entrancy, otherwise make an external call
        uint seizeError;
        if (address(vTokenCollateral) == address(this)) {
            seizeError = seizeInternal(address(this), liquidator, borrower, seizeTokens);
        } else {
            seizeError = vTokenCollateral.seize(liquidator, borrower, seizeTokens);
        }

        /* Revert if seize tokens fails (since we cannot be sure of side effects) */
        require(seizeError == uint(Error.NO_ERROR), "token seizure failed");

        /* We emit a LiquidateBorrow event */
        emit LiquidateBorrow(liquidator, borrower, actualRepayAmount, address(vTokenCollateral), seizeTokens);

        /* We call the defense hook */
        comptroller.liquidateBorrowVerify(
            address(this),
            address(vTokenCollateral),
            liquidator,
            borrower,
            actualRepayAmount,
            seizeTokens
        );

        return (uint(Error.NO_ERROR), actualRepayAmount);
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Called only during an in-kind liquidation, or by liquidateBorrow during the liquidation of another vToken.
     *  Its absolutely critical to use msg.sender as the seizer vToken and not a parameter.
     * @param seizerToken The contract seizing the collateral (i.e. borrowed vToken)
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of vTokens to seize
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    function seizeInternal(
        address seizerToken,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) internal returns (uint) {
        /* Fail if seize not allowed */
        uint allowed = comptroller.seizeAllowed(address(this), seizerToken, liquidator, borrower, seizeTokens);
        if (allowed != 0) {
            return failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.LIQUIDATE_SEIZE_COMPTROLLER_REJECTION, allowed);
        }

        /* Fail if borrower = liquidator */
        if (borrower == liquidator) {
            return fail(Error.INVALID_ACCOUNT_PAIR, FailureInfo.LIQUIDATE_SEIZE_LIQUIDATOR_IS_BORROWER);
        }

        MathError mathErr;
        uint borrowerTokensNew;
        uint liquidatorTokensNew;

        /*
         * We calculate the new borrower and liquidator token balances, failing on underflow/overflow:
         *  borrowerTokensNew = accountTokens[borrower] - seizeTokens
         *  liquidatorTokensNew = accountTokens[liquidator] + seizeTokens
         */
        (mathErr, borrowerTokensNew) = subUInt(accountTokens[borrower], seizeTokens);
        if (mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.LIQUIDATE_SEIZE_BALANCE_DECREMENT_FAILED, uint(mathErr));
        }

        (mathErr, liquidatorTokensNew) = addUInt(accountTokens[liquidator], seizeTokens);
        if (mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.LIQUIDATE_SEIZE_BALANCE_INCREMENT_FAILED, uint(mathErr));
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /* We write the previously calculated values into storage */
        accountTokens[borrower] = borrowerTokensNew;
        accountTokens[liquidator] = liquidatorTokensNew;

        /* Emit a Transfer event */
        emit Transfer(borrower, liquidator, seizeTokens);

        /* We call the defense hook */
        comptroller.seizeVerify(address(this), seizerToken, liquidator, borrower, seizeTokens);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets a new reserve factor for the protocol (requires fresh interest accrual)
     * @dev Admin function to set a new reserve factor
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    function _setReserveFactorFresh(uint newReserveFactorMantissa) internal returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_RESERVE_FACTOR_ADMIN_CHECK);
        }

        // Verify market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.SET_RESERVE_FACTOR_FRESH_CHECK);
        }

        // Check newReserveFactor ≤ maxReserveFactor
        if (newReserveFactorMantissa > reserveFactorMaxMantissa) {
            return fail(Error.BAD_INPUT, FailureInfo.SET_RESERVE_FACTOR_BOUNDS_CHECK);
        }

        uint oldReserveFactorMantissa = reserveFactorMantissa;
        reserveFactorMantissa = newReserveFactorMantissa;

        emit NewReserveFactor(oldReserveFactorMantissa, newReserveFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Accrues interest and adds reserves by transferring from `msg.sender`
     * @param addAmount Amount of addition to reserves
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    function _addReservesInternal(uint addAmount) internal nonReentrant returns (uint) {
        uint error = accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but on top of that we want to log the fact that an attempted reduce reserves failed.
            return fail(Error(error), FailureInfo.ADD_RESERVES_ACCRUE_INTEREST_FAILED);
        }

        // _addReservesFresh emits reserve-addition-specific logs on errors, so we don't need to.
        (error, ) = _addReservesFresh(addAmount);
        return error;
    }

    /**
     * @notice Add reserves by transferring from caller
     * @dev Requires fresh interest accrual
     * @param addAmount Amount of addition to reserves
     * @return (uint, uint) An error code (0=success, otherwise a failure (see ErrorReporter.sol for details)) and the actual amount added, net token fees
     */
    function _addReservesFresh(uint addAmount) internal returns (uint, uint) {
        // totalReserves + actualAddAmount
        uint totalReservesNew;
        uint actualAddAmount;

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.ADD_RESERVES_FRESH_CHECK), actualAddAmount);
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         * We call doTransferIn for the caller and the addAmount
         *  Note: The vToken must handle variations between BEP-20 and BNB underlying.
         *  On success, the vToken holds an additional addAmount of cash.
         *  doTransferIn reverts if anything goes wrong, since we can't be sure if side effects occurred.
         *  it returns the amount actually transferred, in case of a fee.
         */

        actualAddAmount = doTransferIn(msg.sender, addAmount);

        totalReservesNew = totalReserves + actualAddAmount;

        /* Revert on overflow */
        require(totalReservesNew >= totalReserves, "add reserves unexpected overflow");

        // Store reserves[n+1] = reserves[n] + actualAddAmount
        totalReserves = totalReservesNew;

        /* Emit NewReserves(admin, actualAddAmount, reserves[n+1]) */
        emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);

        /* Return (NO_ERROR, actualAddAmount) */
        return (uint(Error.NO_ERROR), actualAddAmount);
    }

    /**
     * @notice Reduces reserves by transferring to admin
     * @dev Requires fresh interest accrual
     * @param reduceAmount Amount of reduction to reserves
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    function _reduceReservesFresh(uint reduceAmount) internal returns (uint) {
        // totalReserves - reduceAmount
        uint totalReservesNew;

        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.REDUCE_RESERVES_ADMIN_CHECK);
        }

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.REDUCE_RESERVES_FRESH_CHECK);
        }

        // Fail gracefully if protocol has insufficient underlying cash
        if (getCashPrior() < reduceAmount) {
            return fail(Error.TOKEN_INSUFFICIENT_CASH, FailureInfo.REDUCE_RESERVES_CASH_NOT_AVAILABLE);
        }

        // Check reduceAmount ≤ reserves[n] (totalReserves)
        if (reduceAmount > totalReserves) {
            return fail(Error.BAD_INPUT, FailureInfo.REDUCE_RESERVES_VALIDATION);
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        totalReservesNew = totalReserves - reduceAmount;

        // Store reserves[n+1] = reserves[n] - reduceAmount
        totalReserves = totalReservesNew;

        // doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
        doTransferOut(admin, reduceAmount);

        emit ReservesReduced(admin, reduceAmount, totalReservesNew);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice updates the interest rate model (requires fresh interest accrual)
     * @dev Admin function to update the interest rate model
     * @param newInterestRateModel the new interest rate model to use
     * @return uint Returns 0 on success, otherwise returns a failure code (see ErrorReporter.sol for details).
     */
    function _setInterestRateModelFresh(InterestRateModel newInterestRateModel) internal returns (uint) {
        // Used to store old model for use in the event that is emitted on success
        InterestRateModel oldInterestRateModel;

        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_INTEREST_RATE_MODEL_OWNER_CHECK);
        }

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.SET_INTEREST_RATE_MODEL_FRESH_CHECK);
        }

        // Track the market's current interest rate model
        oldInterestRateModel = interestRateModel;

        // Ensure invoke newInterestRateModel.isInterestRateModel() returns true
        require(newInterestRateModel.isInterestRateModel(), "marker method returned false");

        // Set the interest rate model to newInterestRateModel
        interestRateModel = newInterestRateModel;

        // Emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel)
        emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Updates the stable interest rate model (requires fresh interest accrual)
     * @dev Admin function to update the stable interest rate model
     * @param newStableInterestRateModel The new stable interest rate model to use
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setStableInterestRateModelFresh(StableRateModel newStableInterestRateModel) internal returns (uint256) {
        // Used to store old model for use in the event that is emitted on success
        StableRateModel oldStableInterestRateModel;

        // Track the market's current stable interest rate model
        oldStableInterestRateModel = stableRateModel;

        // Ensure invoke newInterestRateModel.isInterestRateModel() returns true
        require(newStableInterestRateModel.isInterestRateModel(), "marker method returned false");

        // Set the interest rate model to newStableInterestRateModel
        stableRateModel = newStableInterestRateModel;

        // Emit NewMarketStableInterestRateModel(oldStableInterestRateModel, newStableInterestRateModel)
        emit NewMarketStableInterestRateModel(oldStableInterestRateModel, newStableInterestRateModel);

        return uint(Error.NO_ERROR);
    }

    /*** Safe Token ***/

    /**
     * @dev Performs a transfer in, reverting upon failure. Returns the amount actually transferred to the protocol, in case of a fee.
     *  This may revert due to insufficient balance or insufficient allowance.
     */
    function doTransferIn(address from, uint amount) internal returns (uint);

    /**
     * @dev Performs a transfer out, ideally returning an explanatory error code upon failure rather than reverting.
     *  If caller has not called checked protocol's balance, may revert due to insufficient cash held in the contract.
     *  If caller has checked protocol's balance, and verified it is >= amount, this should not revert in normal conditions.
     */
    function doTransferOut(address payable to, uint amount) internal;

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return borrowBalance the calculated balance
     */
    function _stableBorrowBalanceStored(address account) internal view returns (uint256, uint256, Exp memory) {
        /* Get borrowBalance and borrowIndex */
        StableBorrowSnapshot storage borrowSnapshot = accountStableBorrows[account];
        Exp memory simpleStableInterestFactor;

        /* If borrowBalance = 0 then borrowIndex is likely also 0.
         * Rather than failing the calculation with a division by 0, we immediately return 0 in this case.
         */
        if (borrowSnapshot.principal == 0) {
            return (0, borrowSnapshot.interestIndex, simpleStableInterestFactor);
        }

        uint256 currentBlockNumber = getBlockNumber();

        /* Short-circuit accumulating 0 interest */
        if (borrowSnapshot.lastBlockAccrued == currentBlockNumber) {
            return (borrowSnapshot.principal, borrowSnapshot.interestIndex, simpleStableInterestFactor);
        }

        /* Calculate the number of blocks elapsed since the last accrual */
        uint256 blockDelta = currentBlockNumber - borrowSnapshot.lastBlockAccrued;

        simpleStableInterestFactor = mul_(Exp({ mantissa: borrowSnapshot.stableRateMantissa }), blockDelta);

        uint256 stableBorrowIndexNew = mul_ScalarTruncateAddUInt(
            simpleStableInterestFactor,
            borrowSnapshot.interestIndex,
            borrowSnapshot.interestIndex
        );
        uint256 principalUpdated = (borrowSnapshot.principal * stableBorrowIndexNew) / borrowSnapshot.interestIndex;

        return (principalUpdated, stableBorrowIndexNew, simpleStableInterestFactor);
    }

    /**
     * @dev Function to simply retrieve block number
     *  This exists mainly for inheriting test contracts to stub this result.
     */
    function getBlockNumber() internal view returns (uint) {
        return block.number;
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return Tuple of error code and the calculated balance or 0 if error code is non-zero
     */
    function borrowBalanceStoredInternal(address account) internal view returns (MathError, uint) {
        /* Note: we do not assert that the market is up to date */
        MathError mathErr;
        uint principalTimesIndex;
        uint result;

        /* Get borrowBalance and borrowIndex */
        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

        /* If borrowBalance = 0 then borrowIndex is likely also 0.
         * Rather than failing the calculation with a division by 0, we immediately return 0 in this case.
         */
        if (borrowSnapshot.principal == 0) {
            return (MathError.NO_ERROR, 0);
        }

        /* Calculate new borrow balance using the interest index:
         *  recentBorrowBalance = borrower.borrowBalance * market.borrowIndex / borrower.borrowIndex
         */
        (mathErr, principalTimesIndex) = mulUInt(borrowSnapshot.principal, borrowIndex);
        if (mathErr != MathError.NO_ERROR) {
            return (mathErr, 0);
        }

        (mathErr, result) = divUInt(principalTimesIndex, borrowSnapshot.interestIndex);
        if (mathErr != MathError.NO_ERROR) {
            return (mathErr, 0);
        }

        return (MathError.NO_ERROR, result);
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the vToken
     * @dev This function does not accrue interest before calculating the exchange rate
     * @return Tuple of error code and calculated exchange rate scaled by 1e18
     */
    function exchangeRateStoredInternal() internal view returns (MathError, uint) {
        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            /*
             * If there are no tokens minted:
             *  exchangeRate = initialExchangeRate
             */
            return (MathError.NO_ERROR, initialExchangeRateMantissa);
        } else {
            /*
             * Otherwise:
             *  exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
             */
            uint totalCash = getCashPrior();
            uint cashPlusBorrowsMinusReserves;
            Exp memory exchangeRate;
            MathError mathErr;

            (mathErr, cashPlusBorrowsMinusReserves) = addThenSubUInt(totalCash, totalBorrows, totalReserves);
            if (mathErr != MathError.NO_ERROR) {
                return (mathErr, 0);
            }

            (mathErr, exchangeRate) = getExp(cashPlusBorrowsMinusReserves, _totalSupply);
            if (mathErr != MathError.NO_ERROR) {
                return (mathErr, 0);
            }

            return (MathError.NO_ERROR, exchangeRate.mantissa);
        }
    }

    /**
     * @notice Sets the utilization threshold for stable rate rebalancing
     * @param utilizationRateThreshold The utilization rate threshold
     * custom:access Only Governance
     */
    function setRebalanceUtilizationRateThreshold(uint256 utilizationRateThreshold) external {
        require(msg.sender == admin, "only admin can set ACL address");
        require(utilizationRateThreshold > 0, "vToken: utilization rate should be greater than zero.");
        rebalanceUtilizationRateThreshold = utilizationRateThreshold;
    }

    /**
     * @notice Sets the fraction threshold for stable rate rebalancing
     * @param fractionThreshold The fraction threshold for the validation of the stable rate rebalancing
     * custom:access Only Governance
     */
    function setRebalanceRateFractionThreshold(uint256 fractionThreshold) external {
        require(msg.sender == admin, "only admin can set ACL address");
        require(fractionThreshold > 0, "vToken: fraction threshold should be greater than zero.");
        rebalanceRateFractionThreshold = fractionThreshold;
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying owned by this contract
     */
    function getCashPrior() internal view returns (uint);
}
