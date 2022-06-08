const { expect } = require("chai");
const { ethers, waffle } = require("hardhat");

const provider = waffle.provider;
const NULL_ADDR = "0x0000000000000000000000000000000000000000";

function computeDebt(num){
  return num*1001/1000;
}

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
        await this.borrowedToken.mint(this.minter.address, 1000000);
        await this.borrowedToken.deployed();

        // token being used as collateral (bob)

        this.collateralToken = await this.ERC20Mock.deploy("collateral Token", "LEND", this.bob.address, 1000000);
        await this.collateralToken.mint(this.minter.address, 1000000);
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
  it("should take out a standard debt position", async function () {

    await this.collateralToken.connect(this.bob).approve(this.debtPosition.address, 1000000);

    await this.debtPosition.connect(this.bob).borrow(1000000);         // borrow against 1000000 tokens of collateral

    expect(await this.borrowedToken.balanceOf(this.bob.address)).to.equal(500000);            // bob should now have 500000 tokens borrowed

    this.borrowedToken.mint(this.bob.address,computeDebt(500000)-500000);                     // bob obtains the means to repay the debt with fees 

    expect(await this.borrowedToken.balanceOf(this.bob.address)).to.equal(500500);            // bob should now have exactly enough tokens to repay the debt

    await this.borrowedToken.connect(this.bob).approve(this.debtPosition.address, computeDebt(500000)); 

    await this.debtPosition.connect(this.bob).repay(1,computeDebt(500000)); 

    expect(await this.collateralToken.balanceOf(this.bob.address)).to.equal(1000000);

    await this.debtPosition.withdraw(1000000);

    expect(await this.borrowedToken.balanceOf(this.alice.address)).to.equal(1000500);

    this.borrowedToken.mint(500000); 

    await expect(this.debtPosition.connect(this.bob).repay(1,10000)).to.be.revertedWith("PepperLend: Repayment exceeds outstanding debt amount!");
  });

  it("should take out a debt position and pay it back in pieces", async function () {

    await this.collateralToken.connect(this.bob).approve(this.debtPosition.address, 1000000);

    await this.debtPosition.connect(this.bob).borrow(1000000);         // borrow against 1000000 tokens of collateral

    expect(await this.borrowedToken.balanceOf(this.bob.address)).to.equal(500000);            // bob should now have 500000 tokens borrowed

    this.borrowedToken.mint(this.bob.address,computeDebt(500000)-500000);                     // bob obtains the means to repay the debt with fees 

    expect(await this.borrowedToken.balanceOf(this.bob.address)).to.equal(500500);            // bob should now have exactly enough tokens to repay the debt

    await this.borrowedToken.connect(this.bob).approve(this.debtPosition.address, computeDebt(500000)); 

    await this.debtPosition.connect(this.bob).repay(1,computeDebt(200000)); 

    expect(await this.collateralToken.balanceOf(this.bob.address)).to.equal(400000);

    await this.debtPosition.connect(this.bob).repay(1,computeDebt(100000));

    expect(await this.collateralToken.balanceOf(this.bob.address)).to.equal(600000);

    await this.debtPosition.connect(this.bob).repay(1,computeDebt(200000)); 

    expect(await this.collateralToken.balanceOf(this.bob.address)).to.equal(1000000);

    await this.debtPosition.withdraw(1000000);

    expect(await this.borrowedToken.balanceOf(this.alice.address)).to.equal(1000500);

  });

  it("should be able to liquidate overdue debt positions", async function () {

    await this.collateralToken.connect(this.bob).approve(this.debtPosition.address, 1000000);

    await this.debtPosition.connect(this.bob).borrow(500000);
    

    const debtRepayDate = (await this.debtPosition.debts(1)).expiry;

    await expect(this.debtPosition.connect(this.bob).liquidate(1,5000)).to.be.revertedWith("PepperLend: Debt position is not overdue!");

    console.log('repay by: ',new Date(debtRepayDate.toNumber()*1000));

    await network.provider.send("evm_setNextBlockTimestamp", [debtRepayDate.add(1).toNumber()]);
    await network.provider.send("evm_mine");

    expect((await this.debtPosition.estimateLiquidation(1,500000)).toNumber()).to.equal(500000); // start off at oracle price

    await network.provider.send("evm_setNextBlockTimestamp", [debtRepayDate.add(3601*10).toNumber()]);                 // one hour later
    await network.provider.send("evm_mine");

    await this.collateralToken.connect(this.minter).approve(this.debtPosition.address, 1000000);
    await this.debtPosition.connect(this.minter).borrow(500000);


    await this.borrowedToken.mint(this.alice.address,5000000);
    console.log(await this.collateralToken.balanceOf(this.alice.address));

    await this.borrowedToken.approve(this.debtPosition.address, 700000);
    await this.debtPosition.liquidate(1,700000);
    console.log(await this.collateralToken.balanceOf(this.alice.address));

    console.log(await this.borrowedToken.balanceOf(this.debtPosition.address));

    // console.log(await this.debtPosition.debts(2),computeDebt(250000));

    await this.debtPosition.connect(this.minter).repay(2,computeDebt(250000)); 




    // console.log('liquidationOutput: ',liquidationOutput.toNumber());    
  });

});