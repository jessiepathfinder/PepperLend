pragma solidity ^0.8.0;
//SPDX-License-Identifier: AGPL-3.0-or-later

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IAppraisalOracle.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ERC20DebtToken.sol";
import "hardhat/console.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

struct NFTDebtPosition{
	uint256 collateral;
	uint192 debt;
	uint64 expiry;
}



contract NFTDebtPositions is ERC721, IERC3156FlashLender{
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

	uint256 private _tokenIds;
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

	function _borrow(uint256 amount) private returns (uint256){

		uint256 credit = getCredit(amount);
		uint256 fees = max(1, feeRate * credit / 1000);
		uint256 debt = credit + fees;

		_reduceAvailableBalance(credit, true);
		totalPoolBalance += fees;

		uint256 newItemId = _tokenIds++;

        _safeMint(msg.sender, newItemId);

		debts[newItemId] = NFTDebtPosition(amount, toUint192(debt), (block.timestamp+term).toUint64());

		return credit;
	}
	function borrow(uint256 amount) external  {
		borrowedToken.safeTransfer(msg.sender, _borrow(amount));
		collateralToken.safeTransferFrom(msg.sender, address(this), amount);
	}
	
	//Useful for margin trading - callee may swap borrowed token into collateral
	function borrow2(ILateCollateralBorrower callee, uint256 amount, bytes calldata data) external{
		uint256 borrowedAmount = _borrow(amount);
		borrowedToken.safeTransfer(address(callee), borrowedAmount);
		callee.handleLoan(msg.sender, borrowedAmount, amount, data);
		collateralToken.safeTransferFrom(msg.sender, address(this), amount);
	}
		
	function _repay(uint256 position, uint256 amount) private returns (uint256 returnedCollateral){
		require(_isApprovedOrOwner(msg.sender, position), "PepperLend: Only position owner and approved addresses may repay!");
		NFTDebtPosition memory loandata = debts[position];
		require(loandata.expiry > block.timestamp, "PepperLend: Liquidation in progress!");
		
		require(loandata.debt >= amount, "PepperLend: Repayment exceeds outstanding debt amount!");
		
		returnedCollateral = (amount * loandata.collateral) / loandata.debt;
		
		unchecked{
			loandata.debt -= uint192(amount);
			loandata.collateral -= returnedCollateral;
		}
		
		availablePoolBalance += amount;
		debts[position] = loandata;

	}
	
	function repay(uint256 position, uint256 amount) external{
		collateralToken.safeTransfer(msg.sender, _repay(position, amount));
		borrowedToken.safeTransferFrom(msg.sender, address(this), amount);
	}
	
	function repay2(ILateRepaymentBorrower callee, uint256 position, uint256 amount, bytes calldata data) external{
		uint256 returnedCollateral = _repay(position, amount);
		collateralToken.safeTransfer(address(callee), returnedCollateral);
		callee.handleRepayment(msg.sender, amount, returnedCollateral, data);
		borrowedToken.safeTransferFrom(msg.sender, address(this), amount);
	}
	function estimateLiquidation(uint256 position, uint256 amount) external view returns(uint256 output){
		NFTDebtPosition memory loandata = debts[position];
		require(block.timestamp > loandata.expiry, "PepperLend: Debt position is not overdue!");
		uint256 basePrice;
		if(reversePair){
			basePrice = 1e16 / oracle.getPair(pair);
		} else{
			basePrice = oracle.getPair(pair);
		}
		unchecked{
			uint256 overdue = (block.timestamp - loandata.expiry) / 1 hours;
			if(overdue > 720){
				overdue = 720;
			}
			for(uint256 i = 0; i++ < overdue; ){
				basePrice -= (basePrice / 100);
			}
		}
		
		output = (amount * oracleRatio) / basePrice;
	}
	function toUint192(uint256 value) private pure returns (uint192) {
        require(value <= type(uint192).max, "PepperLend: value doesn't fit in 192 bits");
        return uint192(value);
    }
	function _liquidate(uint256 position, uint256 amount) private returns (uint256){
		NFTDebtPosition memory loandata = debts[position];
		require(block.timestamp > loandata.expiry, "PepperLend: Debt position is not overdue!");
		require(loandata.debt >= amount, "PepperLend: Liquidation amount exceeds remaining debts!");
		uint256 basePrice;
		if(reversePair){
			basePrice = 1e16 / oracle.getPair(pair);
		} else{
			basePrice = oracle.getPair(pair);
		}
		unchecked{
			uint256 overdue = (block.timestamp - loandata.expiry) / 1 hours;
			
			for(uint256 i = 0; i++ < overdue; ){
				basePrice -= (basePrice / 100);
			}
		}
		
		uint256 output = (amount * oracleRatio) / basePrice;
		uint256 returnedCollateral = (amount * loandata.collateral) / loandata.debt;
		
		if(output > returnedCollateral){
			//Debit losses from total pool balance
			uint256 losses = ((output - returnedCollateral) * loandata.debt) / loandata.collateral;
			totalPoolBalance -= losses;
			loandata.debt -= toUint192(amount + losses); //Reduce outstanding balance that have been forgiven
		} else{
			output = returnedCollateral;
			unchecked{
				loandata.debt -= toUint192(amount);
			}
		}
		
		loandata.collateral -= output;
		
		availablePoolBalance += amount;
		
		debts[position] = loandata;
	}
	function liquidate(uint256 position, uint256 amount) external{
		collateralToken.safeTransfer(msg.sender, _liquidate(position, amount));
		borrowedToken.safeTransferFrom(msg.sender, address(this), amount);
	}
	function liquidate2(IFlashLiquidator callee, uint256 position, uint256 amount, bytes calldata data) external{
		uint256 output = _liquidate(position, amount);
		collateralToken.safeTransfer(address(callee), output);
		callee.handleLiquidation(msg.sender, amount, output, data);
		borrowedToken.safeTransferFrom(msg.sender, address(this), amount);
	}
	
	function donate(uint256 amount) external{ //Used for liquidity mining/insurance compensation
		availablePoolBalance += amount;
		totalPoolBalance += amount;
		borrowedToken.safeTransferFrom(msg.sender, address(this), amount);
	}
	
	bytes32 public constant flashReturns = keccak256("ERC3156FlashBorrower.onFlashLoan");
	
	function maxFlashLoan(address token) external view returns (uint256){
		require(token == address(borrowedToken), "PepperLend: This token can't be flash borrowed!");
		return availablePoolBalance;
	}
	
	function flashFee(address token, uint256 amount) external view returns (uint256){
		require(token == address(borrowedToken), "PepperLend: This token can't be flash borrowed!");
		return amount / 1000;
	}
	
	function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool){
		require(token == address(borrowedToken), "PepperLend: This token can't be flash borrowed!");
		uint256 fee = amount / 1000;
		_reduceAvailableBalance(amount, false); //Since this is a flash loan
		borrowedToken.safeTransfer(address(receiver), amount);
		require(receiver.onFlashLoan(msg.sender, address(borrowedToken), amount, fee, data) == flashReturns, "PepperLend: invalid return value!");
		uint256 postfee = amount + fee;
		borrowedToken.safeTransferFrom(address(receiver), address(this), postfee);
		totalPoolBalance += fee;
		availablePoolBalance += postfee;
		return true;
	}	
}

interface ILateCollateralBorrower{
	function handleLoan(address initiator, uint256 borrowedAmount, uint256 collateralAmount, bytes calldata data) external;
}

interface ILateRepaymentBorrower{
	function handleRepayment(address initiator, uint256 borrowedAmount, uint256 collateralAmount, bytes calldata data) external;
}
interface IFlashLiquidator{
	function handleLiquidation(address initiator, uint256 borrowedAmount, uint256 collateralAmount, bytes calldata data) external;
}