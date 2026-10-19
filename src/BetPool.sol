// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title BetPool
/// @notice Live (in-play) pari-mutuel betting pools for NIGHTSHIFT skill games and the Agent Arena.
/// Spectators bet on side A or side B of a match while it is played. Every bet carries a weight that
/// the NIGHTSHIFT server signs into a short-lived ticket; winners get their stake back plus a share of
/// the losing side proportional to their weighted stake, minus a 5% fee taken only from the losing side.
/// Markets, tickets and results are all EIP-712 messages from the NIGHTSHIFT result signer.
/// @dev The owner can rotate the signer, adjust per-bet limits under fixed hard caps and pause new markets
/// and bets. The owner can never move bets, change the fee, the fee recipient or the tokens, or settle.
contract BetPool is Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice The IMD token (18 decimals, no transfer fee).
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    /// @notice The $SHIFT token (18 decimals, no transfer fee).
    address public constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    /// @notice The NIGHTSHIFT fee splitter that receives every fee.
    address public constant FEE_RECIPIENT = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;

    /// @notice Fee on the losing side, in basis points (5%).
    uint256 public constant FEE_BPS = 500;
    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Lowest weight a ticket may carry.
    uint16 public constant MIN_WEIGHT_BPS = 500;
    /// @notice Highest weight a ticket may carry.
    uint16 public constant MAX_WEIGHT_BPS = 10_000;
    /// @notice A ticket's expiry may be at most this far after the block time.
    uint256 public constant MAX_TICKET_TTL = 120;
    /// @notice A market's closesAt may be at most this far after the block time at creation.
    uint256 public constant MAX_MARKET_DURATION = 7 days;
    /// @notice After closesAt plus this delay an unsettled market may be expired into refunds.
    uint256 public constant EXPIRY_DELAY = 24 hours;

    /// @notice Hard cap for the IMD per-bet maximum, fixed at deploy.
    uint256 public constant IMD_HARD_CAP = 10_000 ether;
    /// @notice Hard cap for the SHIFT per-bet maximum, fixed at deploy.
    uint256 public constant SHIFT_HARD_CAP = 500_000_000 ether;

    /// @notice Side and outcome values.
    uint8 public constant SIDE_A = 0;
    uint8 public constant SIDE_B = 1;
    uint8 public constant OUTCOME_VOID = 2;

    bytes32 public constant MARKET_TYPEHASH =
        keccak256("Market(bytes32 marketId,address token,uint64 closesAt,bytes32 game)");
    bytes32 public constant TICKET_TYPEHASH = keccak256(
        "Ticket(bytes32 marketId,address bettor,uint8 side,uint256 amount,uint16 weightBps,uint64 expiry,bytes32 nonce)"
    );
    bytes32 public constant OUTCOME_TYPEHASH = keccak256("Outcome(bytes32 marketId,uint8 outcome,uint256 deadline)");

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct Market {
        address token;
        uint64 closesAt;
        bool settled;
        uint8 outcome;
        bool refundable;
        bytes32 game;
        uint256 totalA;
        uint256 totalB;
        uint256 sharesA;
        uint256 sharesB;
    }

    struct Position {
        uint256 amountA;
        uint256 amountB;
        uint256 sharesA;
        uint256 sharesB;
        bool claimed;
    }

    struct Limits {
        uint256 min;
        uint256 max;
    }

    /// @notice The NIGHTSHIFT result signer; zero until the owner sets it.
    address public signer;

    mapping(bytes32 => Market) private _markets;
    mapping(bytes32 => mapping(address => Position)) private _positions;
    mapping(address => Limits) private _limits;

    /// @notice Whether a ticket nonce has been consumed.
    mapping(bytes32 => bool) public usedNonce;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event SignerSet(address indexed previousSigner, address indexed newSigner);
    event LimitsSet(address indexed token, uint256 min, uint256 max);
    event MarketCreated(bytes32 indexed marketId, address indexed token, uint64 closesAt, bytes32 indexed game);
    event BetPlaced(
        bytes32 indexed marketId, address indexed bettor, uint8 side, uint256 amount, uint16 weightBps, uint256 shares
    );
    event Settled(bytes32 indexed marketId, uint8 outcome, uint256 fee);
    event Expired(bytes32 indexed marketId);
    event Claimed(bytes32 indexed marketId, address indexed bettor, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error SignerNotSet();
    error InvalidSigner();
    error InvalidSignature();
    error ZeroOwner();
    error UnsupportedToken();
    error InvalidLimits();
    error MarketExists();
    error UnknownMarket();
    error InvalidClosesAt();
    error InvalidSide();
    error InvalidOutcome();
    error InvalidWeight();
    error TicketExpired();
    error TicketTooLong();
    error NonceUsed();
    error BettingClosed();
    error MarketSettled();
    error AmountOutOfLimits();
    error ZeroShares();
    error TransferMismatch();
    error SignatureExpired();
    error NotSettled();
    error NotExpirable();
    error AlreadyClaimed();
    error NothingToClaim();
    error RenounceDisabled();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @notice Deploys the pool with the fixed tokens, fee recipient and default per-bet limits.
    /// @dev The result signer starts unset; the owner sets it with setSigner after deployment.
    /// @param owner_ The owner (NIGHTSHIFT's admin wallet).
    constructor(address owner_) Ownable(owner_) EIP712("NightshiftBets", "1") {
        _setLimits(IMD, 0.1 ether, 500 ether);
        _setLimits(SHIFT, 1_000 ether, 25_000_000 ether);
    }

    // ---------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------

    /// @notice Sets the NIGHTSHIFT result signer that signs markets, tickets and outcomes.
    /// @param newSigner The signer address; must not be zero.
    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidSigner();
        emit SignerSet(signer, newSigner);
        signer = newSigner;
    }

    /// @notice Changes a token's per-bet limits, never above its hard cap.
    /// @param token IMD or SHIFT.
    /// @param min Minimum bet amount (greater than zero).
    /// @param max Maximum bet amount (at least min, at most the hard cap).
    function setLimits(address token, uint256 min, uint256 max) external onlyOwner {
        _setLimits(token, min, max);
    }

    /// @notice Pauses creation of new markets and placing of new bets. Settle, expire and claim keep working.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes creation of new markets and placing of new bets.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Disabled: the pool always needs an owner able to rotate the result signer.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Markets and bets
    // ---------------------------------------------------------------------

    /// @notice Opens a market for one match, authorised by the result signer. Anyone may submit it.
    /// @param marketId New unique market id.
    /// @param token IMD or SHIFT; the only token this market accepts.
    /// @param closesAt Hard latest time for bets; in the future and at most 7 days ahead.
    /// @param game Identifier of the game or match.
    /// @param signature EIP-712 signature of Market(marketId, token, closesAt, game) by the signer.
    function createMarket(bytes32 marketId, address token, uint64 closesAt, bytes32 game, bytes calldata signature)
        external
        whenNotPaused
    {
        if (_markets[marketId].token != address(0)) revert MarketExists();
        if (_limits[token].max == 0) revert UnsupportedToken();
        if (closesAt <= block.timestamp || closesAt > block.timestamp + MAX_MARKET_DURATION) {
            revert InvalidClosesAt();
        }
        _verify(keccak256(abi.encode(MARKET_TYPEHASH, marketId, token, closesAt, game)), signature);

        Market storage m = _markets[marketId];
        m.token = token;
        m.closesAt = closesAt;
        m.game = game;
        emit MarketCreated(marketId, token, closesAt, game);
    }

    /// @notice Places a bet with a ticket signed by the result signer for msg.sender.
    /// @param marketId The market.
    /// @param side 0 = A, 1 = B.
    /// @param amount Token amount pulled from msg.sender (needs prior approval).
    /// @param weightBps Weight of this bet, 500..10000.
    /// @param expiry Ticket expiry; not passed and at most 120 seconds after the block time.
    /// @param nonce Single-use ticket nonce.
    /// @param signature EIP-712 signature of the Ticket by the signer.
    function bet(
        bytes32 marketId,
        uint8 side,
        uint256 amount,
        uint16 weightBps,
        uint64 expiry,
        bytes32 nonce,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        Market storage m = _markets[marketId];
        address token = m.token;
        if (token == address(0)) revert UnknownMarket();
        if (m.settled || m.refundable) revert MarketSettled();
        if (block.timestamp >= m.closesAt) revert BettingClosed();
        if (side > SIDE_B) revert InvalidSide();
        if (weightBps < MIN_WEIGHT_BPS || weightBps > MAX_WEIGHT_BPS) revert InvalidWeight();
        if (block.timestamp > expiry) revert TicketExpired();
        if (expiry > block.timestamp + MAX_TICKET_TTL) revert TicketTooLong();
        if (usedNonce[nonce]) revert NonceUsed();
        Limits memory lim = _limits[token];
        if (amount < lim.min || amount > lim.max) revert AmountOutOfLimits();
        uint256 shares = amount * weightBps / BPS;
        if (shares == 0) revert ZeroShares();
        _verify(
            keccak256(abi.encode(TICKET_TYPEHASH, marketId, msg.sender, side, amount, weightBps, expiry, nonce)),
            signature
        );

        usedNonce[nonce] = true;
        Position storage p = _positions[marketId][msg.sender];
        if (side == SIDE_A) {
            m.totalA += amount;
            m.sharesA += shares;
            p.amountA += amount;
            p.sharesA += shares;
        } else {
            m.totalB += amount;
            m.sharesB += shares;
            p.amountB += amount;
            p.sharesB += shares;
        }
        emit BetPlaced(marketId, msg.sender, side, amount, weightBps, shares);

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert TransferMismatch();
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    /// @notice Settles a market with the signed result and closes betting. Anyone may submit it.
    /// @dev A void outcome, or a decided market where either side has no bets, becomes refundable with no fee.
    /// Otherwise 5% of the losing side (rounded down) goes to the fee splitter now.
    /// @param marketId The market.
    /// @param outcome 0 = A won, 1 = B won, 2 = void.
    /// @param deadline Signature expiry (inclusive).
    /// @param signature EIP-712 signature of Outcome(marketId, outcome, deadline) by the signer.
    function settle(bytes32 marketId, uint8 outcome, uint256 deadline, bytes calldata signature) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.token == address(0)) revert UnknownMarket();
        if (m.settled || m.refundable) revert MarketSettled();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (outcome > OUTCOME_VOID) revert InvalidOutcome();
        _verify(keccak256(abi.encode(OUTCOME_TYPEHASH, marketId, outcome, deadline)), signature);

        m.settled = true;
        m.outcome = outcome;
        uint256 fee;
        if (outcome == OUTCOME_VOID || m.sharesA == 0 || m.sharesB == 0) {
            m.refundable = true;
        } else {
            fee = _fee(m, outcome);
        }
        emit Settled(marketId, outcome, fee);

        if (fee > 0) IERC20(m.token).safeTransfer(FEE_RECIPIENT, fee);
    }

    /// @notice Makes a market refundable for everyone, with no fee, if it was not settled within
    /// 24 hours after closesAt. Anyone may call it.
    /// @param marketId The market.
    function expire(bytes32 marketId) external {
        Market storage m = _markets[marketId];
        if (m.token == address(0)) revert UnknownMarket();
        if (m.settled || m.refundable) revert MarketSettled();
        if (block.timestamp <= uint256(m.closesAt) + EXPIRY_DELAY) revert NotExpirable();
        m.settled = true;
        m.outcome = OUTCOME_VOID;
        m.refundable = true;
        emit Expired(marketId);
    }

    // ---------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------

    /// @notice Pays the caller what they are owed by a settled or expired market. Each wallet claims once.
    /// @param marketId The market.
    /// @return amount The amount paid.
    function claim(bytes32 marketId) external nonReentrant returns (uint256 amount) {
        Market storage m = _markets[marketId];
        if (m.token == address(0)) revert UnknownMarket();
        if (!m.settled) revert NotSettled();
        Position storage p = _positions[marketId][msg.sender];
        if (p.claimed) revert AlreadyClaimed();
        amount = _owed(m, p);
        if (amount == 0) revert NothingToClaim();
        p.claimed = true;
        emit Claimed(marketId, msg.sender, amount);
        IERC20(m.token).safeTransfer(msg.sender, amount);
    }

    /// @notice Claims from several markets at once, skipping markets with nothing to claim.
    /// @dev Reverts with NothingToClaim if no listed market paid anything.
    /// @param marketIds The markets.
    /// @return total Sum of amounts paid (across tokens; informational).
    function claimMany(bytes32[] calldata marketIds) external nonReentrant returns (uint256 total) {
        for (uint256 i; i < marketIds.length; ++i) {
            bytes32 marketId = marketIds[i];
            Market storage m = _markets[marketId];
            if (!m.settled) continue;
            Position storage p = _positions[marketId][msg.sender];
            if (p.claimed) continue;
            uint256 amount = _owed(m, p);
            if (amount == 0) continue;
            p.claimed = true;
            total += amount;
            emit Claimed(marketId, msg.sender, amount);
            IERC20(m.token).safeTransfer(msg.sender, amount);
        }
        if (total == 0) revert NothingToClaim();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Returns a market's state.
    /// @param marketId The market.
    function markets(bytes32 marketId)
        external
        view
        returns (
            address token,
            uint64 closesAt,
            bytes32 game,
            uint256 totalA,
            uint256 totalB,
            uint256 sharesA,
            uint256 sharesB,
            bool settled,
            uint8 outcome,
            bool refundable
        )
    {
        Market storage m = _markets[marketId];
        return
            (m.token, m.closesAt, m.game, m.totalA, m.totalB, m.sharesA, m.sharesB, m.settled, m.outcome, m.refundable);
    }

    /// @notice Returns a wallet's position in a market.
    /// @param marketId The market.
    /// @param wallet The bettor.
    function betsOf(bytes32 marketId, address wallet)
        external
        view
        returns (uint256 amountA, uint256 amountB, uint256 sharesA, uint256 sharesB, bool claimed)
    {
        Position storage p = _positions[marketId][wallet];
        return (p.amountA, p.amountB, p.sharesA, p.sharesB, p.claimed);
    }

    /// @notice Amount a wallet could claim from a market right now (0 if unsettled, claimed or lost).
    /// @param marketId The market.
    /// @param wallet The bettor.
    function claimable(bytes32 marketId, address wallet) external view returns (uint256) {
        Market storage m = _markets[marketId];
        Position storage p = _positions[marketId][wallet];
        if (!m.settled || p.claimed) return 0;
        return _owed(m, p);
    }

    /// @notice Returns a token's per-bet limits (both zero for unsupported tokens).
    /// @param token The token.
    function limits(address token) external view returns (uint256 min, uint256 max) {
        Limits memory l = _limits[token];
        return (l.min, l.max);
    }

    /// @notice Hard cap for a token's per-bet maximum (zero for unsupported tokens).
    /// @param token The token.
    function hardCap(address token) public pure returns (uint256) {
        if (token == IMD) return IMD_HARD_CAP;
        if (token == SHIFT) return SHIFT_HARD_CAP;
        return 0;
    }

    /// @notice The EIP-712 domain separator for this chain and contract.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _setLimits(address token, uint256 min, uint256 max) internal {
        uint256 cap = hardCap(token);
        if (cap == 0) revert UnsupportedToken();
        if (min == 0 || min > max || max > cap) revert InvalidLimits();
        _limits[token] = Limits(min, max);
        emit LimitsSet(token, min, max);
    }

    function _verify(bytes32 structHash, bytes calldata signature) internal view {
        address s = signer;
        if (s == address(0)) revert SignerNotSet();
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(_hashTypedDataV4(structHash), signature);
        if (err != ECDSA.RecoverError.NoError || recovered != s) revert InvalidSignature();
    }

    function _fee(Market storage m, uint8 outcome) internal view returns (uint256) {
        uint256 losingTotal = outcome == SIDE_A ? m.totalB : m.totalA;
        return losingTotal * FEE_BPS / BPS;
    }

    /// @dev What a position is owed by a settled market, ignoring the claimed flag.
    function _owed(Market storage m, Position storage p) internal view returns (uint256) {
        if (m.refundable) return p.amountA + p.amountB;
        uint8 outcome = m.outcome;
        (uint256 stake, uint256 shares, uint256 winningShares, uint256 losingTotal) = outcome == SIDE_A
            ? (p.amountA, p.sharesA, m.sharesA, m.totalB)
            : (p.amountB, p.sharesB, m.sharesB, m.totalA);
        if (shares == 0) return stake;
        uint256 distributable = losingTotal - losingTotal * FEE_BPS / BPS;
        return stake + distributable * shares / winningShares;
    }
}
