pragma solidity ^0.8.0;
//SPDX-License-Identifier: AGPL-3.0-or-later

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IAppraisalOracle.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ERC20DebtToken.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

struct NFTDebtPosition{
	uint256 collateral;
	uint192 debt;
	uint64 expiry;
}



contract NFTDebtPositions is ERC721{
	using SafeERC20 for IERC20;
	using SafeCast for uint256;
	
	//Static pool info
	IERC20 public immutable collateralToken;
	IERC20 public immutable borrowedToken;
	IERC20DebtToken public immutable debtToken;
	uint256 public constant oracleRatio=1e8;
	uint256 public constant collateralRatio=2e8;	// given where 1e8 = 100% collateral etc
	bool public immutable reversePair;				// if true reverse the prices in a Pair 
	uint public constant term = 1 weeks;
	uint256 public constant feeRate = 1; 			// fees are in 0.1% increments

	using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;
	mapping(uint256 => NFTDebtPosition) public debts;
	
	//oracle 
	IAppraisalOracle public immutable oracle;
	address public immutable pair; 

	//Pool balances
	uint256 public totalPoolBalance;
	uint256 public availablePoolBalance;
	
	constructor(
		string memory name_, 
		string memory symbol_, 
		string memory name1_, 
		string memory symbol1_, 
		uint8 decimals1_, 
		IERC20 collateralToken_, 
		IERC20 borrowedToken_,
		address pair_,
		IAppraisalOracle oracle_,
		bool reverse_) ERC721(name_, symbol_) {
		collateralToken = collateralToken_;
		borrowedToken = borrowedToken_;
		debtToken = new ERC20DebtToken(name1_, symbol1_, decimals1_);
		pair = pair_;
		oracle = oracle_;
		reversePair = reverse_;
    }
	
	function deposit(uint256 amount) external {
		uint256 totalPoolBalanceCache = totalPoolBalance;
		uint256 supply = debtToken.totalSupply();
		if(supply == 0 || totalPoolBalanceCache == 0){
			debtToken.mint(msg.sender, amount);
		} else{
			debtToken.mint(msg.sender, (amount * supply) / totalPoolBalanceCache);
		}
		
		totalPoolBalance = totalPoolBalanceCache + amount;
		availablePoolBalance += amount;
		borrowedToken.safeTransferFrom(msg.sender, address(this), amount);
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
	
	function withdraw(uint256 amount) external {
		uint256 supply = debtToken.totalSupply();
		debtToken.burn(msg.sender, amount);
		uint256 totalPoolBalanceCache = totalPoolBalance;
		uint256 withdrawn = (amount * totalPoolBalanceCache) / supply;
		
		_reduceAvailableBalance(withdrawn, false);
		totalPoolBalance = totalPoolBalanceCache - withdrawn;
		borrowedToken.safeTransfer(msg.sender, withdrawn);
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
	function max(uint256 a, uint256 b) public pure returns (uint256) {
		return a >= b ? a : b;
	}

	function borrow(uint256 amount) external {
		uint256 credit = getCredit(amount);
		uint256 fees = max(1, feeRate * credit / 1000);
		uint256 debt = credit + fees;
		require(debt <= type(uint192).max, "PepperLend: Debt amount exceeds 192-bit limit!");

		_reduceAvailableBalance(credit, true);
		totalPoolBalance += fees;

		uint256 newItemId = _tokenIds.current();

        _safeMint(msg.sender, newItemId);

		debts[newItemId] = NFTDebtPosition(amount, uint192(debt), (block.timestamp+term).toUint64());
		
		collateralToken.safeTransferFrom(msg.sender, address(this), amount);
		borrowedToken.safeTransfer(msg.sender, credit);
	}
	
	function repay(uint256 position, uint256 amount, bool withLenderToken) external{
		NFTDebtPosition memory loandata = debts[position];
		require(loandata.expiry > block.timestamp, "PepperLend: Liquidation in progress!");
		
		require(loandata.debt >= amount, "PepperLend: Repayment exceeds outstanding debt amount!");
		
		uint256 returnedCollateral = (amount * loandata.collateral) / loandata.debt;
		
		unchecked{
			loandata.debt -= uint192(amount);	
		}
		
		availablePoolBalance += amount;
		debts[position] = loandata;
		if(withLenderToken){
			//Repay with lender token feature will come in handy if there is a severe shortage of liquidity
			debtToken.burn(msg.sender, (amount * debtToken.totalSupply()) / totalPoolBalance);
		} else{
			borrowedToken.safeTransferFrom(msg.sender, address(this), amount);
		}
		
		collateralToken.safeTransfer(msg.sender, returnedCollateral);
	}
	
	
	function liquidate(uint256 position, uint256 amount) external{
		NFTDebtPosition memory loandata = debts[position];
		require(block.timestamp > loandata.expiry, "PepperLend: Debt still current!");
		uint256 basePrice;
		if(reversePair){
			basePrice = 1e16 / oracle.getPair(pair);
		} else{
			basePrice = oracle.getPair(pair);
		}
		unchecked{
			uint256 overdue = (loandata.expiry - block.timestamp) / 1 hours;
			for(uint256 i = 0; i++ < overdue; ){
				basePrice -= (basePrice / 100);
			}
		}
		
		uint256 output = (amount * oracleRatio) / basePrice;
		uint256 returnedCollateral = (amount * loandata.collateral) / loandata.debt;
		
		if(output > returnedCollateral){
			//Debit losses from total pool balance
			totalPoolBalance -= ((output - returnedCollateral) * loandata.debt) / loandata.collateral;
		} else if(returnedCollateral > output){
			//Credit profits to total pool balance
			totalPoolBalance += ((returnedCollateral - output) * loandata.debt) / loandata.collateral;
		}
		
		availablePoolBalance += amount;
		
		debts[position] = loandata;
		borrowedToken.safeTransferFrom(msg.sender, address(this), amount);
		collateralToken.safeTransfer(msg.sender, output);
	}
	
	function donate(uint256 amount) external{ //Used for liquidity mining/insurance compensation
		availablePoolBalance += amount;
		totalPoolBalance += amount;
		borrowedToken.safeTransferFrom(msg.sender, address(this), amount);
	}
}