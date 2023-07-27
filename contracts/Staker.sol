// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { WETH, ERC20, SafeTransferLib } from "solmate/src/tokens/WETH.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import {
  ERC20PermitUpgradeable,
  IERC20Upgradeable as IERC20,
  IERC20PermitUpgradeable as IERC20Permit
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { RewardsController, ClaimPermit } from "./RewardsController.sol";

contract Staker is ERC20PermitUpgradeable {
  using SafeERC20Upgradeable for IERC20Permit;
  using FixedPointMathLib for uint256;
  using SafeTransferLib for address payable;
  using SafeTransferLib for ERC20;
  using SafeTransferLib for WETH;

  /// @notice The EXA asset.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ERC20 public immutable exa;
  /// @notice The WETH asset.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  WETH public immutable weth;
  /// @notice The VELO asset.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ERC20 public immutable velo;
  /// @notice The liquidity pool.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPool public immutable pool;
  /// @notice The gauge used to stake the liquidity pool tokens.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IGauge public immutable gauge;
  /// @notice Velodrome's voter.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IVoter public immutable voter;
  /// @notice The factory where the fee will be fetched from.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPoolFactory public immutable factory;
  /// @notice Velodrome's voting escrow.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IVotingEscrow public immutable votingEscrow;
  /// @notice The rewards controller.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  RewardsController public immutable rewardsController;

  uint256 public lockId;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    ERC20 exa_,
    WETH weth_,
    IVoter voter_,
    IPoolFactory factory_,
    IVotingEscrow votingEscrow_,
    RewardsController rewardsController_
  ) {
    exa = exa_;
    weth = weth_;
    voter = voter_;
    factory = factory_;
    votingEscrow = votingEscrow_;
    rewardsController = rewardsController_;
    velo = votingEscrow_.token();
    pool = factory_.getPool(exa_, weth_, false);
    gauge = voter_.gauges(pool);

    _disableInitializers();
  }

  function initialize() external initializer {
    __ERC20_init("exactly staker", "stEXA");
    __ERC20Permit_init("exactly staker");

    velo.safeApprove(address(votingEscrow), type(uint256).max);
    ERC20(address(pool)).safeApprove(address(gauge), type(uint256).max);
  }

  function stake(address payable account, uint256 inEXA, uint256 minEXA, uint256 keepETH) internal {
    if (keepETH >= msg.value) return returnAssets(account, inEXA);

    uint256 inETH = msg.value - keepETH;
    uint256 reserveEXA;
    uint256 reserveWETH;
    {
      (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
      (reserveEXA, reserveWETH) = address(exa) < address(weth) ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    uint256 minETH = inEXA.mulDivDown(reserveWETH, reserveEXA);
    if (inETH < minETH) return returnAssets(account, inEXA);

    uint256 outEXA = 0;
    uint256 swapETH = 0;
    if (inETH > minETH) {
      swapETH = (inETH / 2).mulDivDown(inETH + reserveWETH, reserveWETH);
      outEXA = swapETH.mulDivDown(inEXA + reserveEXA, inETH + reserveWETH).mulDivDown(
        10_000 - factory.getFee(pool, false),
        10_000
      );
      if (outEXA + inEXA < minEXA) return returnAssets(account, inEXA);

      weth.deposit{ value: inETH }();
      weth.safeTransfer(address(pool), swapETH);
      (uint256 amount0Out, uint256 amount1Out) = address(exa) < address(weth)
        ? (outEXA, uint256(0))
        : (uint256(0), outEXA);
      pool.swap(amount0Out, amount1Out, this, "");
    } else {
      weth.deposit{ value: inETH }();
    }

    exa.safeTransfer(address(pool), inEXA + outEXA);
    weth.safeTransfer(address(pool), inETH - swapETH);
    uint256 liquidity = pool.mint(this);
    gauge.deposit(liquidity);
    _mint(account, liquidity);

    harvestVELO();

    if (keepETH != 0) account.safeTransferETH(keepETH);
  }

  function unstake(address account, uint256 percentage) external {
    assert(percentage != 0);

    uint256 liquidity = balanceOf(account).mulWadDown(percentage);
    if (msg.sender != account) _spendAllowance(account, msg.sender, liquidity);
    _burn(account, liquidity);

    gauge.withdraw(liquidity);
    (uint256 amount0, uint256 amount1) = pool.burn(this);

    harvestVELO();

    (uint256 amountEXA, uint256 amountETH) = address(exa) < address(weth) ? (amount0, amount1) : (amount1, amount0);
    exa.safeTransfer(msg.sender, amountEXA);
    weth.withdraw(amountETH);
    payable(msg.sender).safeTransferETH(amountETH);
  }

  function harvestVELO() internal {
    uint256 earnedVELO = gauge.earned(this);
    if (earnedVELO > 0) {
      gauge.getReward(this);
      lockVELO(earnedVELO);
    }
  }

  function lockVELO(uint256 amount) internal returns (uint256 id) {
    id = lockId;
    if (id == 0) {
      IPool[] memory pools = new IPool[](1);
      uint256[] memory weights = new uint256[](1);
      pools[0] = pool;
      weights[0] = 100e18;
      id = votingEscrow.createLock(amount, 4 * 365 days);
      votingEscrow.lockPermanent(id);
      voter.vote(id, pools, weights);
      lockId = id;
    } else {
      votingEscrow.increaseAmount(id, amount);
      voter.poke(id);
    }
  }

  function returnAssets(address payable account, uint256 amountEXA) internal {
    account.safeTransferETH(msg.value);
    exa.safeTransfer(account, amountEXA);
  }

  function stakeETH(address payable account, uint256 minEXA, uint256 keepETH) external payable {
    stake(account, 0, minEXA, keepETH);
  }

  function stakeBalance(Permit calldata p, uint256 minEXA, uint256 keepETH) external payable {
    IERC20Permit(address(exa)).safePermit(p.owner, address(this), p.value, p.deadline, p.v, p.r, p.s);
    exa.safeTransferFrom(p.owner, address(this), p.value);
    stake(p.owner, p.value, minEXA, keepETH);
  }

  function stakeRewards(ClaimPermit calldata p, uint256 minEXA, uint256 keepETH) external payable {
    if (p.assets.length != 1 || address(p.assets[0]) != address(exa)) {
      return payable(p.owner).safeTransferETH(msg.value);
    }
    (, uint256[] memory claimedAmounts) = rewardsController.claim(rewardsController.allMarketsOperations(), p);
    if (claimedAmounts[0] == 0) return payable(p.owner).safeTransferETH(msg.value);
    stake(payable(p.owner), claimedAmounts[0], minEXA, keepETH);
  }

  function donateVELO(uint256 amount) public {
    velo.safeTransferFrom(msg.sender, address(this), amount);
    lockVELO(amount);
  }

  function donateVELO(Permit calldata p) public {
    IERC20Permit(address(velo)).safePermit(p.owner, address(this), p.value, p.deadline, p.v, p.r, p.s);
    velo.safeTransferFrom(p.owner, address(this), p.value);
    lockVELO(p.value);
  }

  function previewETH(uint256 amountEXA) public view returns (uint256) {
    (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
    return
      address(exa) < address(weth)
        ? amountEXA.mulDivDown(reserve1, reserve0)
        : amountEXA.mulDivDown(reserve0, reserve1);
  }
}

struct Permit {
  address payable owner;
  uint256 value;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}

interface IPool is IERC20, IERC20Permit {
  function mint(Staker to) external returns (uint256 liquidity);

  function burn(Staker to) external returns (uint256 amount0, uint256 amount1);

  function swap(uint256 amount0Out, uint256 amount1Out, Staker to, bytes calldata data) external;

  function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
}

interface IGauge is IERC20, IERC20Permit {
  function earned(Staker account) external view returns (uint256);

  function deposit(uint256 amount) external;

  function withdraw(uint256 amount) external;

  function getReward(Staker account) external;
}

interface IVoter {
  function gauges(IPool pool) external view returns (IGauge);

  function poke(uint256 tokenId) external;

  function vote(uint256 tokenId, IPool[] calldata poolVote, uint256[] calldata weights) external;

  function weights(IPool pool) external view returns (uint256);

  function usedWeights(uint256 tokenId) external view returns (uint256);
}

interface IVotingEscrow {
  function token() external view returns (ERC20);

  function locked(uint256 tokenId) external view returns (LockedBalance memory);

  function createLock(uint256 value, uint256 lockDuration) external returns (uint256);

  function lockPermanent(uint256 tokenId) external;

  function increaseAmount(uint256 tokenId, uint256 value) external;
}

interface IPoolFactory {
  function getFee(IPool pool, bool stable) external view returns (uint256);

  function getPool(ERC20 tokenA, ERC20 tokenB, bool stable) external view returns (IPool);
}

struct LockedBalance {
  int128 amount;
  uint256 end;
  bool isPermanent;
}
