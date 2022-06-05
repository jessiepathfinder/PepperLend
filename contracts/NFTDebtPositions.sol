pragma solidity ^0.8.0;
//SPDX-License-Identifier: AGPL-3.0-or-later

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IAppraisalOracle.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ERC20DebtToken.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";


struct NFTDebtPosition{
	uint256 initialDebt;
	uint256 collateral;
	uint256 expiry;
}



contract NFTDebtPositions is ERC721,ReentrancyGuard{
	using SafeERC20 for IERC20;
	
	//Static pool info
	uint8 public immutable decimals;
	IERC20 public immutable collateralToken;
	IERC20 public immutable borrowedToken;
	IERC20DebtToken public immutable debtToken;
	uint256 public immutable collateralRatio=2e8;	// given where 1e8 = 100% collateral etc
	bool public immutable reversePair;				// if true reverse the prices in a Pair 
	uint public term = 1 weeks;

	using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;
	mapping(uint256 => NFTDebtPosition) private _loanData;
	
	//oracle 
	IAppraisalOracle public immutable oracle;
	address public immutable pair; 

	//Pool balances
	uint256 public totalPoolBalance;
	uint256 public availablePoolBalance;
	uint256 public collateralPendingLiquidation;
	
	//Liquidation auction
	uint256 public lastBidPrice;
	uint256 public lastBidAmount;
	uint256 public auctionTimer;
	//


	
	
	constructor(
		string memory name_, 
		string memory symbol_, 
		uint8 decimals_, 
		string memory name1_, 
		string memory symbol1_, 
		uint8 decimals1_, 
		IERC20 collateralToken_, 
		IERC20 borrowedToken_,
		address pair_,
		IAppraisalOracle oracle_,
		bool reverse_) ERC721(name_, symbol_) {
		decimals = decimals_;
		collateralToken = collateralToken_;
		borrowedToken = borrowedToken_;
		debtToken = new ERC20DebtToken(name1_, symbol1_, decimals1_);
		pair = pair_;
		oracle = oracle_;
		reversePair = reverse_;
    }
	
	function deposit(uint256 amount) external nonReentrant {
		
		borrowedToken.safeTransferFrom(msg.sender, address(this), amount);
		uint256 totalPoolBalanceCache = totalPoolBalance;
		uint256 supply = debtToken.totalSupply();
		if(supply == 0 || totalPoolBalanceCache == 0){
			debtToken.mint(msg.sender, amount);
		} else{
			debtToken.mint(msg.sender, (amount * supply) / totalPoolBalanceCache);
		}
		
		totalPoolBalance = totalPoolBalanceCache + amount;
		availablePoolBalance += amount;
	}
	
	//When processing withdraws and borrows, the available pool balance is reduced.
	function _reduceAvailableBalance(uint256 amount, bool borrows) private {
		uint256 availablePoolBalanceCache = availablePoolBalance;
		
		//If we are borrowing, require a minimum 20% reserve ratio
		require((borrows ? (amount + totalPoolBalance / 5) : amount) <= availablePoolBalanceCache, "PepperLend: Insufficient available balance!");
		
		unchecked{
			availablePoolBalance = availablePoolBalanceCache - amount;
		}
	}
	
	function withdraw(uint256 amount) external nonReentrant {
		uint256 supply = debtToken.totalSupply();
		debtToken.burn(msg.sender, amount);
		uint256 totalPoolBalanceCache = totalPoolBalance;
		uint256 withdrawn = (amount * totalPoolBalanceCache) / supply;
		borrowedToken.safeTransfer(msg.sender, withdrawn);
		_reduceAvailableBalance(withdrawn, false);
		totalPoolBalance = totalPoolBalanceCache - withdrawn;
	}

	/*
		returns the credit extended for a certain amount of collateral
	*/
	function getCredit(uint256 amount) public view returns(uint256 out) {
		if(reversePair){
			out = ((amount*1e16)/oracle.getPair(pair))/collateralRatio;
		}else{
			out = (amount*oracle.getPair(pair))/collateralRatio;
		}
	}

	function estimateCredit(uint256 amount) external view returns(uint256 out) {
		out = getCredit(amount);
		require((out + totalPoolBalance / 5)<=availablePoolBalance,"PepperLend: Insufficient available balance!");
	}

	function borrow(uint256 amount) external nonReentrant {

		collateralToken.safeTransferFrom(msg.sender, address(this), amount);

		uint256 credit = getCredit(amount);

		borrowedToken.safeTransfer(msg.sender, credit);

		_reduceAvailableBalance(credit, true);

		uint256 newItemId = _tokenIds.current();

        _mint(msg.sender, newItemId);

		_loanData[newItemId] = NFTDebtPosition(credit,amount,block.timestamp+term);
	}
}