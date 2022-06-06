const { expect } = require("chai");
const { ethers, waffle } = require("hardhat");

const provider = waffle.provider;
const NULL_ADDR = "0x0000000000000000000000000000000000000000";

describe("NFTDebtPositions", function () {
  before(async function () {
    this.signers = await ethers.getSigners()
    this.alice = this.signers[0]
    this.bob = this.signers[1]
    this.carol = this.signers[2]
    this.dev = this.signers[3]
    this.minter = this.signers[4]
    
    this.NFTDebtPosition = await ethers.getContractFactory("NFTDebtPositions");

    this.ERC20Mock = await ethers.getContractFactory("ERC20Mock");

    this.Appraisal = await ethers.getContractFactory("AppraisalOracle");
  });

  beforeEach(async function () {
        // token being borrowed (alice)

        this.borrowedToken = await this.ERC20Mock.deploy("Borrowed Token", "BORROW", this.alice.address, 1000000);
        await this.borrowedToken.deployed();

        // token being used as collateral (bob)

        this.collateralToken = await this.ERC20Mock.deploy("collateral Token", "LEND", this.bob.address, 1000000);
        await this.collateralToken.deployed();

        // oracles

        this.appraisal = await this.Appraisal.deploy();
        await this.appraisal.deployed();

        await this.appraisal.setPrice(NULL_ADDR,1e8); // set price to 1; NULL_ADDR is used in place of the peppermint pair address

        this.debtPosition = await this.NFTDebtPosition.deploy("LEND/BORROW debt position", "LEND-BORROW", "LEND-BORROW LLP", "LLP", 18, this.collateralToken.address, this.borrowedToken.address,NULL_ADDR, this.appraisal.address,false);
        await this.debtPosition.deployed();

        await this.borrowedToken.approve(this.debtPosition.address, 1000000);
        await this.debtPosition.deposit(1000000);

  });

  // sanity check for the contract deployment

  it("should own the LLP token", async function () {
    const debtTokenAddress = await this.debtPosition.debtToken();
    const debtToken = await ethers.getContractAt("ERC20DebtToken", debtTokenAddress);
    expect(await debtToken.owner()).to.equal(this.debtPosition.address);
  });

  it("should be able to withdraw all borrowed tokens", async function () {
    await this.debtPosition.withdraw(1000000);
    expect(await this.borrowedToken.balanceOf(this.debtPosition.address)).to.equal(0);
    expect(await this.borrowedToken.balanceOf(this.alice.address)).to.equal(1000000);
  });

  it("should estimate credit correctly", async function () {
    expect(await this.debtPosition.estimateCredit(1000000)).to.equal(500000);
    await expect(this.debtPosition.estimateCredit(5000000)).to.be.revertedWith("PepperLend: Insufficient available balance!");
  });

});