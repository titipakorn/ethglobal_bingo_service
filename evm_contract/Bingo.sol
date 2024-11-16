// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/// @title Bingo Game Smart Contract
/// @notice Implements a decentralized Bingo game with automated number drawing
/// @dev Includes security features and proper state management
contract BingoGame is ReentrancyGuard, Pausable, Ownable {
    using Counters for Counters.Counter;

    // Custom errors
    error GameAlreadyInProgress();
    error GameNotInProgress();
    error InvalidCardPurchase();
    error InvalidDrawInterval();
    error InvalidWinClaim();
    error MaximumWinnersReached();
    error InsufficientPlayers();
    error InvalidCardId();

    // Constants
    uint256 public constant CARD_PRICE = 0.00001 ether;
    uint256 public constant DRAW_INTERVAL = 5 seconds;
    uint256 public constant MAX_WINNERS = 3;
    uint256 public constant MIN_PLAYERS = 1;
    uint256 public constant BOARD_SIZE = 25;
    uint256 public constant MAX_NUMBER = 99;

    // Counters
    Counters.Counter private gameIds;
    Counters.Counter private cardIds;

    // Storage
    struct BingoCard {
        uint256 cardId;
        address owner;
        uint8[25] numbers;
        uint256 gameId;
        bool hasWon;
    }

    struct GameState {
        uint256 gameId;
        uint256 startTime;
        uint256 lastDrawTime;
        uint256[] drawnNumbers;
        bool gameEnded;
        uint256 prizePool;
        uint256 winnerCount;
        mapping(address => bool) winners;
    }

    // State variables
    mapping(uint256 => BingoCard) public cards;
    mapping(uint256 => GameState) public games;
    mapping(address => uint256) private userCards;
    mapping(uint256 => uint256) private gamePlayerCount;
    mapping(uint256 => mapping(address => bool)) private gamePlayers;
    uint256 public currentGameId;
    mapping(uint256 => mapping(uint256 => bool)) private usedNumbers;
    
    // Events
    event GameStarted(uint256 indexed gameId, uint256 timestamp);
    event CardPurchased(address indexed player, uint256 indexed cardId);
    event NumberDrawn(uint256 indexed gameId, uint256 number);
    event WinClaimed(address indexed player, uint256 indexed cardId, uint256 prize);
    event GameEnded(uint256 indexed gameId, uint256 timestamp);

    /// @notice Initializes the contract
    constructor() Ownable(msg.sender) {
        gameIds.increment(); // Start with gameId 1
        currentGameId = gameIds.current();
    }

    /// @notice Initializes a new game session (internal)
    /// @dev Called automatically when minimum players is reached
    function _startNewGame() private {
        currentGameId = gameIds.current();
        GameState storage newGame = games[currentGameId];
        newGame.gameId = currentGameId;
        newGame.startTime = block.timestamp;
        newGame.lastDrawTime = block.timestamp;
        newGame.gameEnded = false;

        // Initialize drawn numbers with 0 as the first number
        newGame.drawnNumbers = new uint256[](1);
        newGame.drawnNumbers[0] = 0;
        usedNumbers[currentGameId][0] = true;

        emit GameStarted(currentGameId, block.timestamp);
        emit NumberDrawn(currentGameId, 0);
        gameIds.increment();
    }

    /// @notice Allows players to purchase a bingo card
    /// @dev Generates random card numbers and assigns ownership
    /// @return cardId The ID of the purchased card
    /// @return numbers The numbers on the purchased card
    function purchaseCard() external payable nonReentrant whenNotPaused returns (uint256 cardId, uint8[25] memory numbers) {
        if (msg.value != CARD_PRICE) {
            revert InvalidCardPurchase();
        }
        if (currentGameId == 0 || games[currentGameId].gameEnded) {
            revert GameNotInProgress();
        }

        cardId = cardIds.current();
        numbers = generateCardNumbers();
        
        cards[cardId] = BingoCard({
            cardId: cardId,
            owner: msg.sender,
            numbers: numbers,
            gameId: currentGameId,
            hasWon: false
        });

        // Add card to user's collection
        userCards[msg.sender]=cardId;

        // Track unique players in the game
        if (!gamePlayers[currentGameId][msg.sender]) {
            gamePlayers[currentGameId][msg.sender] = true;
            gamePlayerCount[currentGameId]++;

            // Auto-start game when minimum players is reached
            if (gamePlayerCount[currentGameId] == MIN_PLAYERS) {
                games[currentGameId].startTime = block.timestamp;
                games[currentGameId].lastDrawTime = block.timestamp;
                emit GameStarted(currentGameId, block.timestamp);
            }
        }


        games[currentGameId].prizePool += msg.value;
        
        emit CardPurchased(msg.sender, cardId);
        cardIds.increment();

        return (cardId, numbers);
    }

    /// @notice Gets all cards owned by a specific player for the current game
    /// @return cardNumbers 2D array of card numbers
    function getPlayerCards() external view returns (
        uint8[25] memory
    ) {
        require(userCards[msg.sender]==0, "No card!");
        uint256 playerCardIds = userCards[msg.sender];
        uint8[25] memory storedNumbers = cards[playerCardIds].numbers;
        return storedNumbers;
    }

    /// @notice Draws a new number for the current game
    /// @dev Can only be called after DRAW_INTERVAL has passed
    function drawNumber() external whenNotPaused {
        GameState storage game = games[currentGameId];
        
        if (game.gameEnded || currentGameId == 0) {
            revert GameNotInProgress();
        }
        if (gamePlayerCount[currentGameId] < MIN_PLAYERS) {
            revert InsufficientPlayers();
        }
        if (block.timestamp < game.lastDrawTime + DRAW_INTERVAL) {
            revert InvalidDrawInterval();
        }

        uint256 newNumber = generateRandomNumber() % MAX_NUMBER + 1;
        while (usedNumbers[currentGameId][newNumber]) {
            newNumber = (newNumber + 1) % MAX_NUMBER + 1;
        }

        game.drawnNumbers.push(newNumber);
        usedNumbers[currentGameId][newNumber] = true;
        game.lastDrawTime = block.timestamp;

        emit NumberDrawn(currentGameId, newNumber);

        // End game if all numbers are drawn
        if (game.drawnNumbers.length >= MAX_NUMBER) {
            endGame();
        }
    }

    /// @notice Allows players to claim a win
    /// @param cardId The ID of the winning card
    function claimWin(uint256 cardId) external nonReentrant whenNotPaused {
        GameState storage game = games[currentGameId];
        BingoCard storage card = cards[cardId];

        if (card.owner != msg.sender || card.gameId != currentGameId || card.hasWon) {
            revert InvalidWinClaim();
        }
        if (!verifyWin(cardId)) {
            revert InvalidWinClaim();
        }
        if (game.winnerCount >= MAX_WINNERS) {
            revert MaximumWinnersReached();
        }

        card.hasWon = true;
        game.winnerCount++;
        game.winners[msg.sender] = true;

        uint256 prize = game.prizePool / game.winnerCount;
        payable(msg.sender).transfer(prize);

        emit WinClaimed(msg.sender, cardId, prize);

        if (game.winnerCount >= MAX_WINNERS) {
            endGame();
        }
    }

    /// @notice Ends the current game
    /// @dev Can be called by owner or automatically when conditions are met
    function endGame() public whenNotPaused {
        GameState storage game = games[currentGameId];
        
        if (game.gameEnded) {
            revert GameNotInProgress();
        }

        game.gameEnded = true;
        emit GameEnded(currentGameId, block.timestamp);
    }

    /// @notice Gets the numbers on a specific card
    /// @param cardId The ID of the card to check
    /// @return An array of the card's numbers
    function getCardNumbers(uint256 cardId) external view returns (uint8[25] memory) {
        return cards[cardId].numbers;
    }

    /// @notice Gets all drawn numbers for the current game
    /// @return An array of drawn numbers
    function getDrawnNumbers() external view returns (uint256[] memory) {
        return games[currentGameId].drawnNumbers;
    }

    /// @notice Gets the current game state including player count
    /// @return gameId Current game ID
    /// @return startTime Game start timestamp
    /// @return lastDrawTime Last number draw timestamp
    /// @return numberCount Count of drawn numbers
    /// @return isEnded Whether the game has ended
    /// @return prizePool Current prize pool
    /// @return playerCount Current number of players
    /// @return isStarted Whether the game has officially started
    function getCurrentGameState() external view returns (
        uint256 gameId,
        uint256 startTime,
        uint256 lastDrawTime,
        uint256 numberCount,
        bool isEnded,
        uint256 prizePool,
        uint256 playerCount,
        bool isStarted
    ) {
        GameState storage game = games[currentGameId];
        return (
            game.gameId,
            game.startTime,
            game.lastDrawTime,
            game.drawnNumbers.length,
            game.gameEnded,
            game.prizePool,
            gamePlayerCount[currentGameId],
            gamePlayerCount[currentGameId] >= MIN_PLAYERS
        );
    }


    /// @notice Verifies if a card has a winning pattern
    /// @param cardId The ID of the card to verify
    /// @return bool Whether the card has won
    function verifyWin(uint256 cardId) public view returns (bool) {
        BingoCard storage card = cards[cardId];
        GameState storage game = games[currentGameId];
        
        // Check rows
        for (uint256 i = 0; i < 5; i++) {
            bool rowWin = true;
            for (uint256 j = 0; j < 5; j++) {
                uint256 num = card.numbers[i * 5 + j];
                bool numberDrawn = false;
                for (uint256 k = 0; k < game.drawnNumbers.length; k++) {
                    if (game.drawnNumbers[k] == num) {
                        numberDrawn = true;
                        break;
                    }
                }
                if (!numberDrawn) {
                    rowWin = false;
                    break;
                }
            }
            if (rowWin) return true;
        }

        // Check columns
        for (uint256 i = 0; i < 5; i++) {
            bool colWin = true;
            for (uint256 j = 0; j < 5; j++) {
                uint256 num = card.numbers[j * 5 + i];
                bool numberDrawn = false;
                for (uint256 k = 0; k < game.drawnNumbers.length; k++) {
                    if (game.drawnNumbers[k] == num) {
                        numberDrawn = true;
                        break;
                    }
                }
                if (!numberDrawn) {
                    colWin = false;
                    break;
                }
            }
            if (colWin) return true;
        }

        // Check diagonals
        bool diag1Win = true;
        bool diag2Win = true;
        for (uint256 i = 0; i < 5; i++) {
            uint256 num1 = card.numbers[i * 5 + i];
            uint256 num2 = card.numbers[i * 5 + (4 - i)];
            
            bool num1Drawn = false;
            bool num2Drawn = false;
            
            for (uint256 k = 0; k < game.drawnNumbers.length; k++) {
                if (game.drawnNumbers[k] == num1) num1Drawn = true;
                if (game.drawnNumbers[k] == num2) num2Drawn = true;
            }
            
            if (!num1Drawn) diag1Win = false;
            if (!num2Drawn) diag2Win = false;
        }

        return diag1Win || diag2Win;
    }

    /// @notice Generates a shuffled array of numbers from 1 to 99
    /// @dev Uses Fisher-Yates shuffle with bytes from a single random number
    /// @return First 24 numbers from the shuffled array plus 0 in the middle
    function generateCardNumbers() private view returns (uint8[25] memory) {
        uint8[25] memory cardNumbers;
        uint8[99] memory numberPool;
        
        // Initialize number pool from 1 to 99
        for (uint256 i = 0; i < 99; i++) {
            numberPool[i] = uint8(i + 1);
        }
        
        // Generate a single random number
        uint256 randomness = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            msg.sender
        )));
        
        // Use each byte of the random number to shuffle the first 24 positions
        for (uint256 i = 0; i < 24; i++) {
            // Extract the next byte from randomness and map it to remaining range
            uint256 remainingNumbers = 99 - i;
            uint8 swapIndex = uint8((uint8(randomness >> (i * 8)) % remainingNumbers) + i);
            
            // Swap current position with randomly selected position
            (numberPool[i], numberPool[swapIndex]) = (numberPool[swapIndex], numberPool[i]);
        }
        
        // Fill the card numbers, placing 0 in the middle
        for (uint256 i = 0; i < 12; i++) {
            cardNumbers[i] = numberPool[i];
        }
        cardNumbers[12] = 0; // Middle space
        for (uint256 i = 12; i < 24; i++) {
            cardNumbers[i + 1] = numberPool[i];
        }
        
        return cardNumbers;
    }

    /// @notice Generates a random number for drawing
    /// @dev Uses block properties for randomness
    /// @return A random number
    function generateRandomNumber() private view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            block.number
        )));
    }

    /// @notice Pauses the contract
    /// @dev Only owner can pause
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    /// @dev Only owner can unpause
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Allows owner to withdraw excess funds
    /// @dev Only callable by owner after game ends
    function withdrawFunds() external onlyOwner {
        require(games[currentGameId].gameEnded, "Game must be ended");
        uint256 balance = address(this).balance;
        payable(owner()).transfer(balance);
    }

    /// @notice Checks if a player has already joined the current game
    function isPlayerInGame(address player) external view returns (bool) {
        return gamePlayers[currentGameId][player];
    }

    /// @notice Returns the number of unique players in the current game
    function getCurrentPlayerCount() external view returns (uint256) {
        return gamePlayerCount[currentGameId];
    }
}