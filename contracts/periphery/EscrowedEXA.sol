// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {
  ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { EXA } from "./EXA.sol";

contract EscrowedEXA is ERC20VotesUpgradeable, OwnableUpgradeable {
  using SafeERC20Upgradeable for EXA;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  EXA public immutable exa;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ISablierV2LockupLinear public immutable sablier;

  uint40 public vestingPeriod;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(EXA exa_, ISablierV2LockupLinear sablier_) {
    exa = exa_;
    sablier = sablier_;

    _disableInitializers();
  }

  function initialize(uint40 vestingPeriod_) external initializer {
    __ERC20_init("escrowed EXA", "esEXA");
    __ERC20Permit_init("escrowed EXA");
    __ERC20Votes_init();
    __Ownable_init();

    setVestingPeriod(vestingPeriod_);
    exa.safeApprove(address(sablier), type(uint256).max);
  }

  function mint(uint256 amount) external {
    assert(amount != 0);
    exa.safeTransferFrom(msg.sender, address(this), amount);
    _mint(msg.sender, amount);
  }

  function vest(uint128 amount) external returns (uint256 streamId) {
    _burn(msg.sender, amount);
    streamId = sablier.createWithDurations(
      CreateWithDurations({
        asset: exa,
        sender: address(this),
        recipient: msg.sender,
        totalAmount: amount,
        cancelable: false,
        durations: Durations({ cliff: 0, total: vestingPeriod }),
        broker: Broker({ account: address(0), fee: 0 })
      })
    );
    emit Vest(msg.sender, streamId, amount);
  }

  function setVestingPeriod(uint40 vestingPeriod_) public onlyOwner {
    vestingPeriod = vestingPeriod_;
    emit VestingPeriodSet(vestingPeriod_);
  }

  function clock() public view override returns (uint48) {
    return exa.clock();
  }

  // solhint-disable-next-line func-name-mixedcase
  function CLOCK_MODE() public view override returns (string memory) {
    return exa.CLOCK_MODE();
  }

  event VestingPeriodSet(uint256 vestingPeriod);
  event Vest(address indexed account, uint256 indexed streamId, uint256 amount);
}

interface ISablierV2LockupLinear {
  function createWithDurations(CreateWithDurations calldata params) external returns (uint256 streamId);
}

struct Durations {
  uint40 cliff;
  uint40 total;
}

struct Broker {
  address account;
  uint256 fee;
}

struct CreateWithDurations {
  address sender;
  address recipient;
  uint128 totalAmount;
  EXA asset;
  bool cancelable;
  Durations durations;
  Broker broker;
}
