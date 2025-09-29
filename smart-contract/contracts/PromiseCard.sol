// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PromiseCard is Ownable, Pausable, ReentrancyGuard {
    uint256 public platformFeeBps;
    uint256 constant BPS_DEN = 10000;
    uint256 public promiseCount;
    uint256 public faucetAmountNative;
    uint256 public faucetCooldown;

    struct Promise {
        address creator;
        string title;
        string description;
        string category;
        string mediaIpfs;
        address token;
        uint256 amountRequested;
        bool partialAllowed;
        uint256 createdAt;
        uint256 expiry;
        uint256 donatedAmount;
        bool fulfilled;
        address fulfiller;
    }

    mapping(uint256 => Promise) public promises;
    mapping(uint256 => mapping(address => uint256)) public donations;
    mapping(address => uint256) public lastFaucetClaim;
    mapping(address => uint256) public reputation;

    event PromiseCreated(uint256 indexed id, address indexed creator);
    event Donated(uint256 indexed id, address indexed donor, address token, uint256 amount);
    event Fulfilled(uint256 indexed id, address indexed fulfiller);
    event Refunded(uint256 indexed id, address indexed to, uint256 amount);
    event FaucetClaim(address indexed user, uint256 amountNative);

    constructor(uint256 _platformFeeBps, uint256 _faucetAmountNative, uint256 _faucetCooldown) {
        require(_platformFeeBps <= BPS_DEN, "invalid fee");
        platformFeeBps = _platformFeeBps;
        faucetAmountNative = _faucetAmountNative;
        faucetCooldown = _faucetCooldown;
    }

    function createPromise(
        string calldata title,
        string calldata description,
        string calldata category,
        string calldata mediaIpfs,
        address token,
        uint256 amountRequested,
        bool partialAllowed,
        uint256 expiry
    ) external whenNotPaused returns (uint256) {
        require(bytes(title).length > 0 && bytes(title).length <= 100, "title length");
        require(bytes(description).length <= 500, "description length");
        require(amountRequested > 0, "amount requested");

        promiseCount += 1;
        Promise storage p = promises[promiseCount];
        p.creator = msg.sender;
        p.title = title;
        p.description = description;
        p.category = category;
        p.mediaIpfs = mediaIpfs;
        p.token = token;
        p.amountRequested = amountRequested;
        p.partialAllowed = partialAllowed;
        p.createdAt = block.timestamp;
        p.expiry = expiry;

        emit PromiseCreated(promiseCount, msg.sender);
        return promiseCount;
    }

    function donate(uint256 id, address token, uint256 amount) external payable nonReentrant whenNotPaused {
        require(id > 0 && id <= promiseCount, "invalid promise");
        Promise storage p = promises[id];
        require(!p.fulfilled, "already fulfilled");
        require(p.expiry == 0 || block.timestamp <= p.expiry, "expired");

        if (token == address(0)) {
            require(msg.value == amount, "msg.value mismatch");
        } else {
            require(msg.value == 0, "don't send native");
            IERC20(token).transferFrom(msg.sender, address(this), amount);
        }

        uint256 fee = (amount * platformFeeBps) / BPS_DEN;
        uint256 net = amount - fee;

        p.donatedAmount += net;
        donations[id][msg.sender] += net;
        reputation[msg.sender] += _reputationPointsForDonation(net);

        emit Donated(id, msg.sender, token, net);
    }

    function batchDonate(uint256[] calldata ids, address token, uint256[] calldata amounts) external payable nonReentrant whenNotPaused {
        require(ids.length == amounts.length, "length mismatch");
        uint256 total = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        if (token == address(0)) {
            require(msg.value == total, "msg.value mismatch");
        } else {
            IERC20(token).transferFrom(msg.sender, address(this), total);
        }
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 amount = amounts[i];
            Promise storage p = promises[id];
            require(!p.fulfilled, "already fulfilled");
            require(p.expiry == 0 || block.timestamp <= p.expiry, "expired");

            uint256 fee = (amount * platformFeeBps) / BPS_DEN;
            uint256 net = amount - fee;
            p.donatedAmount += net;
            donations[id][msg.sender] += net;
            reputation[msg.sender] += _reputationPointsForDonation(net);
            emit Donated(id, msg.sender, token, net);
        }
    }

    function fulfillPromise(uint256 id, address fulfiller) external whenNotPaused {
        require(id > 0 && id <= promiseCount, "invalid id");
        Promise storage p = promises[id];
        require(!p.fulfilled, "already fulfilled");
        p.fulfilled = true;
        p.fulfiller = fulfiller == address(0) ? msg.sender : fulfiller;

        reputation[p.fulfiller] += 50;
        reputation[p.creator] += 20;

        _payout(id);

        emit Fulfilled(id, p.fulfiller);
    }

    function refundToCreator(uint256 id) external onlyOwner {
        _payout(id);
    }

    function _payout(uint256 id) internal nonReentrant {
        Promise storage p = promises[id];
        uint256 amount = p.donatedAmount;
        if (amount == 0) return;
        p.donatedAmount = 0;
        if (p.token == address(0)) {
            (bool ok, ) = p.creator.call{value: amount}("");
            require(ok, "transfer failed");
        } else {
            IERC20(p.token).transfer(p.creator, amount);
        }
    }

    function claimFaucet() external whenNotPaused nonReentrant {
        require(block.timestamp - lastFaucetClaim[msg.sender] >= faucetCooldown, "cooldown");
        lastFaucetClaim[msg.sender] = block.timestamp;

        uint256 amount = faucetAmountNative;
        require(address(this).balance >= amount, "insufficient faucet funds");
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");

        reputation[msg.sender] += 1;

        emit FaucetClaim(msg.sender, amount);
    }

    function setPlatformFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= BPS_DEN);
        platformFeeBps = _bps;
    }

    function setFaucetParams(uint256 _amountNative, uint256 _cooldown) external onlyOwner {
        faucetAmountNative = _amountNative;
        faucetCooldown = _cooldown;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdrawNative(address to, uint256 amount) external onlyOwner {
        require(address(this).balance >= amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    function withdrawERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }

    function _reputationPointsForDonation(uint256 amount) internal pure returns (uint256) {
        return amount / 1e15;
    }

    receive() external payable {}
    fallback() external payable {}
}
