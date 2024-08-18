// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBase.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ZKUno is Ownable, ReentrancyGuard, VRFConsumerBase {
    bytes32 internal keyHash;
    uint256 internal fee;

    uint8 public constant MAX_PLAYERS = 10;
    uint8 public constant INITIAL_CARDS = 7;

    enum CardColor {
        Red,
        Blue,
        Green,
        Yellow,
        Wild
    }
    enum CardType {
        Number,
        Skip,
        Reverse,
        DrawTwo,
        Wild,
        WildDrawFour
    }

    struct Card {
        CardColor color;
        CardType cardType;
        uint8 number;
    }

    struct Player {
        address addr;
        uint8 cardCount;
        bool calledUno;
    }

    struct Game {
        Player[] players;
        uint256 currentPlayerIndex;
        bool isReverse;
        CardColor currentColor;
        Card topCard;
        uint256 gameState;
    }

    mapping(uint256 => Game) public games;
    uint256 public gameCounter;

    event GameCreated(uint256 gameId);
    event PlayerJoined(uint256 gameId, address player);
    event GameStarted(uint256 gameId);
    event CardPlayed(
        uint256 gameId,
        address player,
        CardColor color,
        CardType cardType,
        uint8 number
    );
    event UnoCall(uint256 gameId, address player);
    event GameEnded(uint256 gameId, address winner);

    constructor(
        address _vrfCoordinator,
        address _link,
        bytes32 _keyHash,
        uint256 _fee
    ) VRFConsumerBase(_vrfCoordinator, _link) Ownable(msg.sender) {
        keyHash = _keyHash;
        fee = _fee;
    }

    function createGame() external returns (uint256) {
        gameCounter++;
        games[gameCounter].gameState = 1; // 1 = Waiting for players
        emit GameCreated(gameCounter);
        return gameCounter;
    }

    function joinGame(uint256 _gameId) external {
        require(games[_gameId].gameState == 1, "Game is not in waiting state");
        require(games[_gameId].players.length < MAX_PLAYERS, "Game is full");

        games[_gameId].players.push(
            Player({
                addr: msg.sender,
                cardCount: INITIAL_CARDS,
                calledUno: false
            })
        );

        emit PlayerJoined(_gameId, msg.sender);

        if (games[_gameId].players.length == MAX_PLAYERS) {
            startGame(_gameId);
        }
    }

    function startGame(uint256 _gameId) internal {
        require(games[_gameId].players.length >= 2, "Not enough players");
        games[_gameId].gameState = 2; // 2 = In progress

        // Request randomness for initial setup
        requestRandomness(keyHash, fee);

        emit GameStarted(_gameId);
    }

    function fulfillRandomness(
        bytes32 requestId,
        uint256 randomness
    ) internal override {
        uint256 gameId = gameCounter;
        games[gameId].currentPlayerIndex = uint8(
            randomness % games[gameId].players.length
        );
        games[gameId].currentColor = CardColor(randomness % 4);
        games[gameId].topCard = Card({
            color: games[gameId].currentColor,
            cardType: CardType.Number,
            number: uint8((randomness / 100) % 10)
        });
    }

    function playCard(
        uint256 _gameId,
        CardColor _color,
        CardType _cardType,
        uint8 _number
    ) external nonReentrant {
        Game storage game = games[_gameId];
        require(game.gameState == 2, "Game is not in progress");
        require(
            msg.sender == game.players[game.currentPlayerIndex].addr,
            "Not your turn"
        );

        // Validate the played card
        require(
            isValidPlay(game.topCard, _color, _cardType, _number),
            "Invalid play"
        );

        // Update game state
        game.topCard = Card({
            color: _color,
            cardType: _cardType,
            number: _number
        });
        game.currentColor = _color;
        game.players[game.currentPlayerIndex].cardCount--;

        // Handle special cards
        handleSpecialCards(_gameId, _cardType);

        // Check for win condition
        if (game.players[game.currentPlayerIndex].cardCount == 0) {
            endGame(_gameId);
        } else {
            // Move to next player
            game.currentPlayerIndex = getNextPlayerIndex(_gameId);
        }

        emit CardPlayed(_gameId, msg.sender, _color, _cardType, _number);
    }

    function callUno(uint256 _gameId) external {
        Game storage game = games[_gameId];
        require(game.gameState == 2, "Game is not in progress");

        uint8 playerIndex = getPlayerIndex(_gameId, msg.sender);
        require(playerIndex != type(uint8).max, "Player not in game");
        require(
            game.players[playerIndex].cardCount == 1,
            "Player does not have one card"
        );

        game.players[playerIndex].calledUno = true;
        emit UnoCall(_gameId, msg.sender);
    }

    function isValidPlay(
        Card memory _topCard,
        CardColor _color,
        CardType _cardType,
        uint8 _number
    ) internal pure returns (bool) {
        if (_color == CardColor.Wild) return true;
        if (_color == _topCard.color) return true;
        if (_cardType == _topCard.cardType && _cardType != CardType.Number)
            return true;
        if (_cardType == CardType.Number && _number == _topCard.number)
            return true;
        return false;
    }

    function handleSpecialCards(uint256 _gameId, CardType _cardType) internal {
        Game storage game = games[_gameId];
        if (_cardType == CardType.Skip || _cardType == CardType.DrawTwo) {
            game.currentPlayerIndex = getNextPlayerIndex(_gameId);
        } else if (_cardType == CardType.Reverse) {
            game.isReverse = !game.isReverse;
        }
        // Note: Draw Two and Wild Draw Four effects should be handled in the frontend or in a separate function
    }

    function getNextPlayerIndex(
        uint256 _gameId
    ) internal view returns (uint256) {
        Game storage game = games[_gameId];
        if (game.isReverse) {
            return
                (game.currentPlayerIndex + game.players.length - 1) %
                game.players.length;
        } else {
            return (game.currentPlayerIndex + 1) % game.players.length;
        }
    }

    function getPlayerIndex(
        uint256 _gameId,
        address _player
    ) internal view returns (uint8) {
        Game storage game = games[_gameId];
        for (uint8 i = 0; i < game.players.length; i++) {
            if (game.players[i].addr == _player) {
                return i;
            }
        }
        return type(uint8).max;
    }

    function endGame(uint256 _gameId) internal {
        Game storage game = games[_gameId];
        game.gameState = 3; // 3 = Ended
        emit GameEnded(_gameId, game.players[game.currentPlayerIndex].addr);
    }
}
