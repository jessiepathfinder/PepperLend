pragma solidity ^0.8.0;

interface IAppraisalOracle {
    function getPair(address pair) external view returns (uint256);
}