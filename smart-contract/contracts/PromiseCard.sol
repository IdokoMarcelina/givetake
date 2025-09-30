// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PromiseCard is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public platformFeeBps;
    uint256 constant BPS_DEN = 10000;
    uint256 public promiseCount;
    uint256 public faucetAmountNative;
    uint256 public faucetCooldown;

    address public feeRecipient;

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
        uint256 grossDonated; 
        uint256 feesCollected; 
        bool fulfilled;
        address fulfiller;
    }

    mapping(uint256 => Promise) public promises;
    mapping(uint256 => mapping(address => uint256)) public donations; 
    mapping(address => uint256) public lastFaucetClaim;
    mapping(address => uint256) public reputation;

    event PromiseCreated(uint256 indexed id, address indexed creator);
    event Donated(uint256 indexed id, address indexed donor, address token, uint256 grossAmount, uint256 fee, uint256 netAmount);
    event BatchDonated(uint256 totalGross, uint256 totalFee, address token, address indexed donor);
    event FeeCollected(address indexed recipient, address token, uint256 amount);
    event Fulfilled(uint256 indexed id, address indexed fulfiller);
    event Refunded(uint256 indexed id, address indexed to, uint256 amount);
    event FaucetClaim(address indexed user, uint256 amountNative);

    constructor(uint256 _platformFeeBps, uint256 _faucetAmountNative, uint256 _faucetCooldown) {
        require(_platformFeeBps <= BPS_DEN, "invalid fee bps");
        platformFeeBps = _platformFeeBps;
        faucetAmountNative = _faucetAmountNative;
        faucetCooldown = _faucetCooldown;
        feeRecipient = owner();
    }

 
    function setPlatformFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= BPS_DEN, "invalid bps");
        platformFeeBps = _bps;
    }

    function setFaucetParams(uint256 _amountNative, uint256 _cooldown) external onlyOwner {
        faucetAmountNative = _amountNative;
        faucetCooldown = _cooldown;
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), "zero recipient");
        feeRecipient = _recipient;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
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
        require(expiry == 0 || expiry > block.timestamp, "expiry must be 0 or > now");

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

   
    function donate(uint256 id, uint256 amount) external payable nonReentrant whenNotPaused {
        require(id > 0 && id <= promiseCount, "invalid promise");
        require(amount > 0, "zero amount");
        Promise storage p = promises[id];
        require(!p.fulfilled, "already fulfilled");
        require(p.expiry == 0 || block.timestamp <= p.expiry, "expired");

        if (p.token == address(0)) {
            require(msg.value == amount, "msg.value mismatch");
        } else {
            require(msg.value == 0, "do not send native");
            IERC20(p.token).safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 fee = (amount * platformFeeBps) / BPS_DEN;
        uint256 net = amount - fee;

        p.grossDonated += amount;
        p.feesCollected += fee;
        p.donatedAmount += net;
        donations[id][msg.sender] += net;
        reputation[msg.sender] += _reputationPointsForDonation(net);

        if (fee > 0) {
            if (p.token == address(0)) {
                (bool sent, ) = feeRecipient.call{value: fee}("");
                require(sent, "fee transfer failed");
            } else {
                IERC20(p.token).safeTransfer(feeRecipient, fee);
            }
            emit FeeCollected(feeRecipient, p.token, fee);
        }

        emit Donated(id, msg.sender, p.token, amount, fee, net);
    }

  
    function batchDonate(uint256[] calldata ids, uint256[] calldata amounts) external payable nonReentrant whenNotPaused {
        require(ids.length == amounts.length && ids.length > 0, "length mismatch or zero");
        address expectedToken = promises[ids[0]].token;
        uint256 totalGross = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            require(id > 0 && id <= promiseCount, "invalid id in batch");
            Promise storage p = promises[id];
            require(!p.fulfilled, "already fulfilled in batch");
            require(p.expiry == 0 || block.timestamp <= p.expiry, "expired in batch");
            require(p.token == expectedToken, "token mismatch across batch");
            uint256 amount = amounts[i];
            require(amount > 0, "zero amount in batch");
            totalGross += amount;
        }

        if (expectedToken == address(0)) {
            require(msg.value == totalGross, "msg.value mismatch batch");
        } else {
            require(msg.value == 0, "do not send native");
            IERC20(expectedToken).safeTransferFrom(msg.sender, address(this), totalGross);
        }

        uint256 totalFee = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 fee = (amounts[i] * platformFeeBps) / BPS_DEN;
            totalFee += fee;
        }

        if (totalFee > 0) {
            if (expectedToken == address(0)) {
                (bool sent, ) = feeRecipient.call{value: totalFee}("");
                require(sent, "fee transfer failed batch");
            } else {
                IERC20(expectedToken).safeTransfer(feeRecipient, totalFee);
            }
            emit FeeCollected(feeRecipient, expectedToken, totalFee);
        }

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 amount = amounts[i];
            Promise storage p = promises[id];

            uint256 fee = (amount * platformFeeBps) / BPS_DEN;
            uint256 net = amount - fee;

            p.grossDonated += amount;
            p.feesCollected += fee;
            p.donatedAmount += net;
            donations[id][msg.sender] += net;
            reputation[msg.sender] += _reputationPointsForDonation(net);

            emit Donated(id, msg.sender, p.token, amount, fee, net);
        }

        emit BatchDonated(totalGross, totalFee, expectedToken, msg.sender);
    }

 
    function fulfillPromise(uint256 id, address fulfiller) external nonReentrant whenNotPaused {
        require(id > 0 && id <= promiseCount, "invalid id");
        Promise storage p = promises[id];
        require(!p.fulfilled, "already fulfilled");
        require(msg.sender == p.creator, "only creator can fulfill");

        p.fulfilled = true;
        p.fulfiller = fulfiller == address(0) ? msg.sender : fulfiller;

        reputation[p.fulfiller] += 50;
        reputation[p.creator] += 20;

        _payout(id);

        emit Fulfilled(id, p.fulfiller);
    }

    function refundToCreator(uint256 id) external onlyOwner nonReentrant {
        _payout(id);
    }

    function _payout(uint256 id) internal {
        require(id > 0 && id <= promiseCount, "invalid id");
        Promise storage p = promises[id];
        uint256 amount = p.donatedAmount;
        if (amount == 0) {
            return;
        }
        p.donatedAmount = 0;

        if (p.token == address(0)) {
            (bool ok, ) = p.creator.call{value: amount}("");
            require(ok, "native transfer failed");
        } else {
            IERC20(p.token).safeTransfer(p.creator, amount);
        }

        emit Refunded(id, p.creator, amount);
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

  
    function withdrawNative(address to, uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "insufficient balance");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    function withdrawERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

  
    function _reputationPointsForDonation(uint256 amount) internal pure returns (uint256) {
        return amount / 1e15; 
    }

    receive() external payable {}
    fallback() external payable {}
}
