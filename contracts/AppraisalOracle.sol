pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

contract AppraisalOracle is Ownable {

    // get 
    mapping(address => uint256) public getPair;

    // returns price multiplied by 1e8
    function setPrice(address _pair, uint256 _price) public onlyOwner {
        getPair[_pair] = _price;
    }

    function setPrices(address[] calldata _pairs, uint256[] calldata _prices) external onlyOwner {
        uint len = _pairs.length;

        for (uint i = 0; i < len; ) {
            getPair[_pairs[i]] = _prices[i];
            unchecked {
                ++i;
            }
        }
    }
}