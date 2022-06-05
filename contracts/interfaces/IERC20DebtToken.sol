pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20DebtToken is IERC20{
	function burn(address account, uint256 amount) external;
	function mint(address account, uint256 amount) external;
}