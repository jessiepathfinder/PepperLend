pragma solidity ^0.8.0;
//SPDX-License-Identifier: AGPL-3.0-or-later

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ERC20DebtToken.sol";

struct NFTDebtPosition{
	uint128 initialDebt;
	uint128 collateral;
	uint128 expiry;
}



contract NFTDebtPositions is ERC721{
	using SafeERC20 for IERC20;
	
	//Static pool info
	uint8 public immutable decimals;
	IERC20 public immutable collateralToken;
	IERC20 public immutable borrowedToken;
	IERC20DebtToken public immutable debtToken;
	
	//Pool balances
	uint256 public totalPoolBalance;
	uint256 public availablePoolBalance;
	uint256 public collateralPendingLiquidation;
	
	//Liquidation auction
	uint256 public lastBidPrice;
	uint256 public lastBidAmount;
	uint256 public auctionTimer;
	
	//Re-entrancy lock
	uint256 private lock;
	modifier locked(){
		require(lock < 2, "PepperLend: LOCKED");
		lock = 2;
		_;
		lock = 1;
	}
	
	constructor(string memory name_, string memory symbol_, uint8 decimals_, string memory name1_, string memory symbol1_, uint8 decimals1_, IERC20 collateralToken_, IERC20 borrowedToken_) ERC721(name_, symbol_) {
		decimals = decimals_;
		collateralToken = collateralToken_;
		borrowedToken = borrowedToken_;
		debtToken = new ERC20DebtToken(name1_, symbol1_, decimals1_);
    }
	
	function deposit(uint256 amount) external locked{
		if(amount > 0){
			borrowedToken.safeTransferFrom(msg.sender, address(this), amount);
			uint256 totalPoolBalanceCache = totalPoolBalance;
			uint256 supply = debtToken.totalSupply();
			if(supply == 0){
				debtToken.mint(msg.sender, amount);
			} else{
				debtToken.mint(msg.sender, (amount * supply) / totalPoolBalanceCache);
			}
			
			totalPoolBalance = totalPoolBalanceCache + amount;
			availablePoolBalance += amount;
		}
	}
	
	//When processing withdraws and borrows, the available pool balance is reduced.
	function _reduceAvailableBalance(uint256 amount, bool borrows) private{
		uint256 availablePoolBalanceCache = availablePoolBalance;
		
		//If we are borrowing, require a minimum 20% reserve ratio
		require((borrows ? (amount + totalPoolBalance / 5) : amount) < availablePoolBalanceCache, "PepperLend: Insufficient available balance!");
		
		unchecked{
			availablePoolBalance = availablePoolBalanceCache - amount;
		}
	}
	
	function withdraw(uint256 amount) external locked{
		if(amount > 0){
			uint256 supply = debtToken.totalSupply();
			debtToken.burn(msg.sender, amount);
			uint256 totalPoolBalanceCache = totalPoolBalance;
			uint256 withdrawn = (amount * totalPoolBalanceCache) / supply;
			borrowedToken.safeTransfer(msg.sender, withdrawn);
			_reduceAvailableBalance(withdrawn, false);
			totalPoolBalance = totalPoolBalanceCache - withdrawn;
		}
	}
}