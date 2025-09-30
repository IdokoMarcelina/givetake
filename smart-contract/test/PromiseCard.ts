import { expect } from "chai";
import { ethers } from "hardhat";
import type { Contract } from "ethers";
import "@typechain/hardhat";

describe("PromiseCard", function () {
  let PromiseCard: Contract;
  let MockERC20: Contract;
  let deployer: any;
  let alice: any;
  let bob: any;

  beforeEach(async function () {
    [deployer, alice, bob] = await ethers.getSigners();

    const Mock = await ethers.getContractFactory("MockERC20");
    MockERC20 = await Mock.deploy("Mock", "MCK");
    await MockERC20.waitForDeployment();

    const PC = await ethers.getContractFactory("PromiseCard");
    PromiseCard = await PC.deploy(250, ethers.parseEther("0.01"), 60 * 60 * 24); // 2.5% fee
    await PromiseCard.waitForDeployment();

    // preload native balance
    await deployer.sendTransaction({ to: PromiseCard.target, value: ethers.parseEther("1") });
  });

  it("creates a promise, accepts ETH donation and fulfills", async function () {
    await PromiseCard.connect(alice).createPromise(
      "Help me study",
      "Need funds for books",
      "Education",
      "QmMediaHash",
      ethers.ZeroAddress, // ETH
      ethers.parseEther("0.05"),
      true,
      0
    );

    const id = 1;
    const promise = await PromiseCard.promises(id);
    expect(promise.creator).to.equal(alice.address);
    expect(promise.amountRequested).to.equal(ethers.parseEther("0.05"));

    // donate in ETH (no token arg anymore)
    await PromiseCard.connect(bob).donate(id, ethers.parseEther("0.01"), { value: ethers.parseEther("0.01") });

    const donated = await PromiseCard.donations(id, bob.address);

    const expected = (ethers.parseEther("0.01") * 975n) / 1000n;
    expect(donated).to.equal(expected);

    const rep = await PromiseCard.reputation(bob.address);
    expect(Number(rep)).to.be.greaterThan(0);

    // only creator can fulfill now
    await PromiseCard.connect(alice).fulfillPromise(id, bob.address);

    const p2 = await PromiseCard.promises(id);
    expect(p2.fulfilled).to.be.true;
    expect(p2.fulfiller).to.equal(bob.address);
  });

  it("accepts ERC20 donations", async function () {
    await PromiseCard.connect(alice).createPromise(
      "Buy supplies",
      "Stationery",
      "Education",
      "",
      MockERC20.target, // ERC20
      ethers.parseUnits("1000", 18),
      true,
      0
    );

    const id = 1;
    await MockERC20.connect(deployer).mint(bob.address, ethers.parseUnits("500", 18));
    await MockERC20.connect(bob).approve(PromiseCard.target, ethers.parseUnits("200", 18));

    // donate with ERC20 (no token arg, contract enforces promise.token)
    await PromiseCard.connect(bob).donate(id, ethers.parseUnits("200", 18));

    const donated = await PromiseCard.donations(id, bob.address);
    const expected = (ethers.parseUnits("200", 18) * 975n) / 1000n;
    expect(donated).to.equal(expected);
  });

  it("faucet claim respects cooldown", async function () {
    await PromiseCard.connect(bob).claimFaucet();
    const last = await PromiseCard.lastFaucetClaim(bob.address);
    expect(last).to.be.gt(0);

    await expect(PromiseCard.connect(bob).claimFaucet()).to.be.revertedWith("cooldown");
  });
});
