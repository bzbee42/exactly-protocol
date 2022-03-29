// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { PoolAccounting, IInterestRateModel } from "../PoolAccounting.sol";
import { FixedLender } from "../FixedLender.sol";

contract PoolAccountingHarness is PoolAccounting {
  struct ReturnValues {
    uint256 totalOwedNewBorrow;
    uint256 currentTotalDeposit;
    uint256 actualRepayAmount;
    uint256 earningsSP;
    uint256 debtCovered;
    uint256 redeemAmountDiscounted;
  }

  ReturnValues public returnValues;
  uint256 public timestamp;

  constructor(
    IInterestRateModel interestRateModel,
    uint256 penaltyRate,
    uint256 smartPoolReserveFactor
  ) PoolAccounting(interestRateModel, penaltyRate, smartPoolReserveFactor) {
    timestamp = block.timestamp;
  }

  function borrowMPWithReturnValues(
    uint256 maturityDate,
    address borrower,
    uint256 amount,
    uint256 maxAmountAllowed,
    uint256 eTokenTotalSupply
  ) external {
    (returnValues.totalOwedNewBorrow, returnValues.earningsSP) = borrowMP(
      maturityDate,
      borrower,
      amount,
      maxAmountAllowed,
      eTokenTotalSupply
    );
  }

  function depositMPWithReturnValues(
    uint256 maturityDate,
    address supplier,
    uint256 amount,
    uint256 minAmountRequired
  ) external {
    (returnValues.currentTotalDeposit, returnValues.earningsSP) = depositMP(
      maturityDate,
      supplier,
      amount,
      minAmountRequired
    );
  }

  function withdrawMPWithReturnValues(
    uint256 maturityDate,
    address redeemer,
    uint256 amount,
    uint256 minAmountRequired,
    uint256 eTokenTotalSupply
  ) external {
    (returnValues.redeemAmountDiscounted, returnValues.earningsSP) = withdrawMP(
      maturityDate,
      redeemer,
      amount,
      minAmountRequired,
      eTokenTotalSupply
    );
  }

  function repayMPWithReturnValues(
    uint256 maturityDate,
    address borrower,
    uint256 repayAmount,
    uint256 maxAmountAllowed
  ) external {
    (returnValues.actualRepayAmount, returnValues.debtCovered, returnValues.earningsSP) = repayMP(
      maturityDate,
      borrower,
      repayAmount,
      maxAmountAllowed
    );
  }
}
