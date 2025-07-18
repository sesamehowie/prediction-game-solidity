// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

contract PredictionGame is Ownable, ReentrancyGuard, Pausable {
    IPyth public pythContract;
    bytes32 private constant priceId = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    address public constant pyth = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    address public operator;
    uint256 public constant ROUND_STAGE_DURATION = 20;
    uint256 public constant PAYOUT_MULTIPLIER = 19;
    uint256 public constant PAYOUT_DIVISOR = 10;
    uint256 public constant MAX_BUFFER_SECONDS = 300;
    uint256 public minBetAmount = 0.1 ether;
    uint256 public maxBetAmount = 10 ether;
    uint256 public currentRoundId;
    uint256 public currentPrice;
    uint8 public genesisStarted = 0;
    uint8 public genesisLocked = 0;

    enum Position {
        None,
        Pump,
        Dump
    } 

    struct Round {
        uint256 roundId;
        uint256 startTimestamp;
        uint256 lockTimestamp;
        uint256 closeTimestamp;
        uint256 lockPrice;
        uint256 closePrice;
        uint256 betVolume;
        uint256 pumpAmount;
        uint256 dumpAmount;
        uint256 totalPayout;
        bool oracleCalled;
        bool rewardsCalculated;
        bool roundCancelled;
        Position winner;
    }

    struct BetInfo {
        uint256 pumpAmount;
        uint256 dumpAmount;
        bool claimed;
    }

    mapping(uint256 => Round) public rounds;
    mapping(address => uint256[]) public userRounds;
    mapping(uint256 => mapping(address => BetInfo)) public userBetsInRound;
    mapping(address => uint256) public userClaimableAmount;
    mapping(address => mapping(uint256 => uint256)) public userClaimableRounds;
    mapping(uint256 => address[]) public usersInRound;

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    modifier onlyOwnerOrOperator() {
        require(msg.sender == owner() || msg.sender == operator, "Not owner or operator");
        _;
    }

    modifier notContract() {
        require(msg.sender == tx.origin, "Proxy not allowed");
        address sender = msg.sender;
        uint256 size;
        assembly {
            size := extcodesize(sender)
        }
        require(size == 0, "Contract not allowed"); 
        _;
    }

    event ClaimedRewards(address indexed user, uint256 totalReward);
    event FundsWithdrawn(uint256 amount);
    event MinBetUpdated(uint256 minBet);
    event MaxBetUpdated(uint256 maxBet);
    event OperatorUpdated(address operator);
    event StartRound(uint256 indexed roundId);
    event LockRound(uint256 indexed roundId, uint256 lockPrice, uint256 betVolume);
    event EndRound(uint256 indexed roundId, uint256 closePrice, uint256 pumpAmount, uint256 dumpAmount, uint256 betVolume, uint256 totalPayout, Position winnerPosition);
    event RoundCancelled(uint256 indexed roundId, string reason);
    event BetPlaced(address indexed user, uint256 indexed roundId, uint256 amount, Position position);
    event RewardsCalculated(
        uint256 indexed roundId,
        uint256 closePrice,
        uint256 pumpAmount,
        uint256 dumpAmount,
        uint256 totalPayout,
        Position position
    );
    event PlayerRefunded(address indexed player, uint256 indexed roundId, uint256 amount);
    event ClaimedRewardsInRound(address indexed user, uint256 indexed roundId, uint256 amount);

    constructor(address _operator) {
        operator = _operator;
        pythContract = IPyth(pyth);
    }

    function genesisStartRound() public onlyOperator whenNotPaused {
        require(genesisStarted == 0, "Genesis already started");
        currentRoundId = 1;
        _startRound(currentRoundId);
        genesisStarted = 1;
    }

    function genesisLockRound(bytes[] calldata pythPriceUpdate) public payable onlyOperator whenNotPaused {
        require(genesisStarted == 1, "Genesis not started");
        require(genesisLocked == 0, "Genesis lock already done");
        require(roundLockable(currentRoundId), "Round not lockable");
        
        uint256 price = updateAndGetPrice(pythPriceUpdate);
        currentPrice = price;
        
        _safeLockRound(currentRoundId, price);
        currentRoundId = currentRoundId + 1;
        _startRound(currentRoundId);
        genesisLocked = 1;
    }

    function executeRound(bytes[] calldata pythPriceUpdate) public payable onlyOperator whenNotPaused {
        require(
            genesisStarted == 1 && genesisLocked == 1,
            "Can only run after genesisStartRound and genesisLockRound is triggered"
        );
        
        uint256 price = updateAndGetPrice(pythPriceUpdate);
        currentPrice = price;
        
        _safeLockRound(currentRoundId, price);
        _safeEndRound(currentRoundId - 1, price);
        
        if (!rounds[currentRoundId - 1].roundCancelled && !rounds[currentRoundId - 1].rewardsCalculated) {
            _calculateRewards(currentRoundId - 1);
        }
        
        currentRoundId = currentRoundId + 1;
        _safeStartRound(currentRoundId);
    }

    function _safeStartRound(uint256 roundId) internal {
        require(genesisStarted == 1, "Can only run after genesisStartRound is triggered");
        require(rounds[roundId - 2].closeTimestamp != 0, "Can only start round after round n-2 has ended");
        require(
            block.timestamp >= rounds[roundId - 2].closeTimestamp,
            "Can only start new round after round n-2 closeTimestamp"
        );
        _startRound(roundId);
    }

    function _safeLockRound(uint256 roundId, uint256 price) internal {
        require(rounds[roundId].startTimestamp != 0, "Can only lock round after round has started");
        require(block.timestamp >= rounds[roundId].lockTimestamp, "Can only lock round after lockTimestamp");
        require(
            block.timestamp <= rounds[roundId].lockTimestamp + MAX_BUFFER_SECONDS,
            "Can only lock round within bufferSeconds"
        );
        
        Round storage round = rounds[roundId];
        round.closeTimestamp = block.timestamp + (ROUND_STAGE_DURATION);
        round.lockPrice = price;
        round.oracleCalled = true;
        
        emit LockRound(roundId, round.lockPrice, round.betVolume);
    }

    function _safeEndRound(uint256 roundId, uint256 price) internal {
        require(rounds[roundId].lockTimestamp != 0, "Can only end round after round has locked");
        require(block.timestamp >= rounds[roundId].closeTimestamp, "Can only end round after closeTimestamp");
        require(
            block.timestamp <= rounds[roundId].closeTimestamp + MAX_BUFFER_SECONDS,
            "Can only end round within bufferSeconds"
        );
        
        Round storage round = rounds[roundId];
        round.closePrice = price;
        
        emit EndRound(roundId, round.closePrice, round.pumpAmount, round.dumpAmount, round.betVolume, round.totalPayout, round.winner);
    }

    function _startRound(uint256 roundId) internal {
        Round storage round = rounds[roundId];
        round.roundId = roundId;
        round.startTimestamp = block.timestamp;

        uint256 prevCloseTimestamp = roundId > 1 ? rounds[roundId - 1].closeTimestamp : block.timestamp;
        round.lockTimestamp = prevCloseTimestamp;
        round.closeTimestamp = prevCloseTimestamp + ROUND_STAGE_DURATION;
        
        emit StartRound(roundId);
    }


    function updatePrice(bytes[] memory pythPriceUpdate) public payable {
        uint256 updateFee = pythContract.getUpdateFee(pythPriceUpdate);
        pythContract.updatePriceFeeds{value: updateFee}(pythPriceUpdate);
    }

    function updateAndGetPrice(bytes[] memory pythPriceUpdate) public payable returns (uint256) {
        updatePrice(pythPriceUpdate);
        PythStructs.Price memory price = pythContract.getPriceNoOlderThan(priceId, 20);
        int256 fullPrice = int256(price.price);
        require(fullPrice > 0, "Negative price");
        return uint256(fullPrice);
    }

    function betPump() external payable nonReentrant whenNotPaused notContract {
        _placeBet(Position.Pump);
    }

    function betDump() external payable nonReentrant whenNotPaused notContract {
        _placeBet(Position.Dump);
    }

    function _placeBet(Position position) internal {
        require(bettable(currentRoundId), "Round not bettable");
        require(position == Position.Pump || position == Position.Dump, "Invalid position");

        BetInfo storage bet = userBetsInRound[currentRoundId][msg.sender];
        uint256 currentTotal = bet.pumpAmount + bet.dumpAmount;
        uint256 newTotal = currentTotal + msg.value;
        
        require(msg.value >= minBetAmount, "Below min bet");
        require(newTotal <= maxBetAmount, "Exceeds max bet per round");

        if (currentTotal == 0) {
            userRounds[msg.sender].push(currentRoundId);
            usersInRound[currentRoundId].push(msg.sender);
        }

        if (position == Position.Pump) {
            bet.pumpAmount += msg.value;
        } else {
            bet.dumpAmount += msg.value;
        }

        Round storage round = rounds[currentRoundId];
        round.betVolume += msg.value;
        if (position == Position.Pump) {
            round.pumpAmount += msg.value;
        } else {
            round.dumpAmount += msg.value;
        }

        emit BetPlaced(msg.sender, currentRoundId, msg.value, position);
    }

    function claimRewardInRound(uint256 roundId) external nonReentrant notContract {
        address user = msg.sender;
        uint256 totalClaimableAmount = userClaimableAmount[user];
        require(totalClaimableAmount > 0, "No claimable amt");
        uint256 claimableAmtInRound = userClaimableRounds[user][roundId];
        require(claimableAmtInRound > 0, "Round not claimable"); 
        userClaimableAmount[user] = totalClaimableAmount - claimableAmtInRound;
        userClaimableRounds[user][roundId] = 0;
        userBetsInRound[roundId][user].claimed = true;
        require(address(this).balance >= claimableAmtInRound, "Insufficient Contract balance");
        emit ClaimedRewardsInRound(user, roundId, claimableAmtInRound); 
        (bool ok, ) = payable(user).call{value: claimableAmtInRound}("");
        require(ok, "Transfer Fail");
    }

    function claimAllRewards() external nonReentrant notContract {
        uint256 totalReward = userClaimableAmount[msg.sender];
        require(totalReward > 0, "Nothing to claim");
        require(address(this).balance >= totalReward, "Insufficient Contract Balance");
        userClaimableAmount[msg.sender] = 0;
        emit ClaimedRewards(msg.sender, totalReward);
        (bool ok, ) = payable(msg.sender).call{value: totalReward}("");
        require(ok, "Transfer Fail");
    }


    function cancelRound(uint256 roundId, bytes[] calldata pythPriceUpdate) public payable onlyOwnerOrOperator nonReentrant {
        uint256 price = updateAndGetPrice(pythPriceUpdate);
        currentPrice = price;

        _cancelRoundInternal(roundId, price);
    }

    function _cancelRoundInternal(uint256 roundId, uint256 price) internal {
        Round storage round = rounds[roundId];

        require(!round.rewardsCalculated && !round.roundCancelled, "Round finished");
        require(block.timestamp > round.closeTimestamp + MAX_BUFFER_SECONDS, "Buffer time not passed");

        round.roundCancelled = true;

        emit RoundCancelled(roundId, "Timeout");

        _refundPlayersInRound(roundId);

        if (roundId == currentRoundId) {
            _resetGameState(price);
        } else if (roundId == currentRoundId - 1) {
            round.closeTimestamp = block.timestamp;
            round.rewardsCalculated = true;

            Round storage currentRound = rounds[currentRoundId];
            if (currentRound.startTimestamp != 0 && !currentRound.oracleCalled) {
                currentRound.startTimestamp = block.timestamp;
                currentRound.lockTimestamp = block.timestamp;
                currentRound.closeTimestamp = block.timestamp + ROUND_STAGE_DURATION;
                emit StartRound(currentRoundId);
            }
        }
    }

    function _resetGameState(uint256 price) internal {
        currentRoundId = currentRoundId + 1;

        if (genesisStarted == 0) {
            genesisStarted = 1;
        }
        if (genesisLocked == 0 && currentRoundId > 1) {
            genesisLocked = 1;
        }

        _startRound(currentRoundId);

        if (currentRoundId > 1) {
            Round storage prevRound = rounds[currentRoundId - 1];
            if (!prevRound.rewardsCalculated) {
                prevRound.closeTimestamp = block.timestamp;
                prevRound.lockTimestamp = block.timestamp - ROUND_STAGE_DURATION;
                prevRound.startTimestamp = block.timestamp - (ROUND_STAGE_DURATION * 2);
                if (prevRound.roundCancelled) {
                    prevRound.rewardsCalculated = true;
                } else {
                    prevRound.lockPrice = price;
                    prevRound.closePrice = price;
                    prevRound.oracleCalled = true;
                }
            }
        }
    }
        
    function _refundPlayersInRound(uint256 roundId) internal {
        Round storage round = rounds[roundId];
        require(round.roundCancelled, "Round not cancelled");
        address[] memory players = usersInRound[roundId];

        for (uint256 i = 0; i < players.length;) {
            address player = players[i];
            BetInfo storage bet = userBetsInRound[roundId][player];
            uint256 refundAmount = bet.pumpAmount + bet.dumpAmount;
            
            if (refundAmount > 0 && !bet.claimed) {
                userClaimableAmount[player] += refundAmount;
                userClaimableRounds[player][roundId] = refundAmount;
                emit PlayerRefunded(player, roundId, refundAmount);
            }
            unchecked {i++;}
        }
    }

    function _calculateRewards(uint256 roundId) internal {
        require(!rounds[roundId].rewardsCalculated, "Rewards already calculated");

        Round storage round = rounds[roundId];

        if (round.roundCancelled) {
            round.rewardsCalculated = true;
            emit RewardsCalculated(roundId, 0, 0, 0, 0, Position.None);
            return;
        }

        require(round.oracleCalled, "Oracle not called");
        
        address[] memory users = usersInRound[roundId];
        
        if (round.lockPrice == round.closePrice) {
            _cancelRoundInternal(roundId, round.closePrice);
            emit RewardsCalculated(roundId, round.closePrice, 0, 0, 0, Position.None);
        } else {
            round.winner = round.closePrice > round.lockPrice ? Position.Pump : Position.Dump;
            
            uint256 totalWinningAmount = round.winner == Position.Pump ? round.pumpAmount : round.dumpAmount;
            uint256 totalLosingAmount = round.winner == Position.Pump ? round.dumpAmount : round.pumpAmount;
            
            for (uint256 i = 0; i < users.length;) {
                address user = users[i];
                BetInfo storage bet = userBetsInRound[roundId][user];
                
                if (!bet.claimed) {
                    uint256 winAmount = round.winner == Position.Pump ? bet.pumpAmount : bet.dumpAmount;
                    if (winAmount > 0) {
                        uint256 reward = (winAmount * (totalLosingAmount * PAYOUT_MULTIPLIER / PAYOUT_DIVISOR)) / totalWinningAmount;
                        reward += winAmount;
                        userClaimableAmount[user] += reward;
                        userClaimableRounds[user][roundId] = reward;
                        round.totalPayout += reward;
                    }
                }
                unchecked {i++;}
            }
            
            emit RewardsCalculated(
                roundId,
                round.closePrice,
                round.pumpAmount,
                round.dumpAmount,
                round.totalPayout,
                round.winner
            );
        }
        
        round.rewardsCalculated = true;
    }

    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        require(address(this).balance >= amount, "Withdraw amt > balance");
        emit FundsWithdrawn(amount);
        (bool ok, ) = payable(owner()).call{value: amount}("");
        require(ok, "Transfer fail");
    }

    function calculatePotentialPayout(uint256 betAmount) public pure returns (uint256) {
        return betAmount * PAYOUT_MULTIPLIER / PAYOUT_DIVISOR;
    }

    function bettable(uint256 roundId) public view returns (bool) {
        return
            rounds[roundId].startTimestamp != 0 &&
            rounds[roundId].lockTimestamp != 0 &&
            block.timestamp > rounds[roundId].startTimestamp &&
            block.timestamp < rounds[roundId].lockTimestamp;
    }

    function roundLockable(uint256 roundId) public view returns (bool) {
        return
            rounds[roundId].startTimestamp != 0 &&
            rounds[roundId].lockTimestamp != 0 &&
            block.timestamp >= rounds[roundId].lockTimestamp &&
            block.timestamp <= rounds[roundId].lockTimestamp + MAX_BUFFER_SECONDS &&
            !rounds[roundId].oracleCalled;
    }

    function roundSettlable(uint256 roundId) public view returns (bool) {
        return
            rounds[roundId].oracleCalled &&
            rounds[roundId].closeTimestamp != 0 &&
            block.timestamp >= rounds[roundId].closeTimestamp &&
            block.timestamp <= rounds[roundId].closeTimestamp + MAX_BUFFER_SECONDS;
    }

    function setOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "Zero address");
        operator = _operator;
        emit OperatorUpdated(_operator);
    }

    function setMinBet(uint256 _minBetAmount) external onlyOwner {
        require(_minBetAmount > 0, "Must be > 0");
        minBetAmount = _minBetAmount;
        emit MinBetUpdated(_minBetAmount);
    }

    function setMaxBet(uint256 _maxBetAmount) external onlyOwner {
        require(_maxBetAmount > minBetAmount, "Must be > min");
        maxBetAmount = _maxBetAmount;
        emit MaxBetUpdated(_maxBetAmount);
    }

    function getUserClaimableAmount(address user) external view returns (uint256) {
        return userClaimableAmount[user];
    }

    function getUserRounds(address user) external view returns (uint256[] memory) {
        return userRounds[user];
    }

    function getUsersInRound(uint256 roundId) external view returns (address[] memory) {
        return usersInRound[roundId];
    }

    function isRoundClaimable(address user, uint256 roundId) external view returns (bool) {
        return userClaimableRounds[user][roundId] > 0;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getCurrentRoundInfo() external view returns (
        uint256 roundId,
        uint256 startTimestamp,
        uint256 lockTimestamp,
        uint256 closeTimestamp,
        uint256 lockPrice,
        uint256 closePrice,
        uint256 pumpAmount,
        uint256 dumpAmount,
        bool oracleCalled,
        bool rewardCalculated
    ) {
        Round storage round = rounds[currentRoundId];
        return (
            round.roundId,
            round.startTimestamp,
            round.lockTimestamp,
            round.closeTimestamp,
            round.lockPrice,
            round.closePrice,
            round.pumpAmount,
            round.dumpAmount,
            round.oracleCalled,
            round.rewardsCalculated
        );
    }

    receive() external payable onlyOwnerOrOperator {}
    fallback() external payable onlyOwnerOrOperator {}
}