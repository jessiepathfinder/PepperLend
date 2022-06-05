pragma solidity ^0.8.0;
//SPDX-License-Identifier: AGPL-3.0-or-later

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IERC20DebtToken.sol";

contract ERC20DebtToken is ERC20, IERC20DebtToken {
	uint8 private immutable _decimals;
	address public immutable owner;
	function decimals() public view override returns (uint8){
		return _decimals;
	}
	constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_){
		_decimals = decimals_;
		owner = msg.sender;
	}
	modifier onlyOwner(){
		require(msg.sender == owner, "PepperLend: Owner only!");
		_;
	}
	
	//Burning and minting
	function burn(address account, uint256 amount) external onlyOwner{
        _burn(account, amount);
    }
	function mint(address account, uint256 amount) external onlyOwner{
        _mint(account, amount);
    }
}