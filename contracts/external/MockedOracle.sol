// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../interfaces/IOracle.sol";
import "../utils/Errors.sol";

contract MockedOracle is IOracle {

  mapping(string => uint) public prices;
    
  function getAssetPrice(string memory symbol) override public view returns (uint) {
    if (prices[symbol] > 0) {
      return prices[symbol];
    } else {
      revert GenericError(ErrorCode.PRICE_ERROR);
    }
  }

  function setPrice(string memory symbol, uint value) public {
      prices[symbol] = value;
  }

}
