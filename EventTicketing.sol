// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title EventTicketing
 * @notice Decentralized event ticketing platform with NFT tickets and on-chain verification
 * @dev Each ticket is an ERC-721 NFT with a unique verification code stored on-chain
 */
contract EventTicketing is ERC721, ERC721URIStorage, ReentrancyGuard {
    using Counters for Counters.Counter;
    using Strings for uint256;

    // ─── Counters ───────────────────────────────────────────────────────────
    Counters.Counter private _eventIdCounter;
    Counters.Counter private _tokenIdCounter;

    // ─── Structs ────────────────────────────────────────────────────────────

    struct Event {
        uint256 id;
        address creator;
        string  name;
        string  description;
        string  location;
        string  imageURI;
        uint256 startTime;
        uint256 endTime;
        uint256 ticketPrice;   // in wei (0 = free)
        uint256 maxCapacity;
        uint256 ticketsSold;
        bool    isActive;
        bool    isCancelled;
    }

    struct Ticket {
        uint256 tokenId;
        uint256 eventId;
        address owner;
        bytes32 verificationCode;   // keccak256 of (eventId, tokenId, owner, salt)
        bool    isUsed;
        uint256 issuedAt;
    }

    // ─── Storage ────────────────────────────────────────────────────────────

    // eventId => Event
    mapping(uint256 => Event) public events;

    // tokenId => Ticket
    mapping(uint256 => Ticket) public tickets;

    // eventId => array of tokenIds
    mapping(uint256 => uint256[]) private _eventTickets;

    // address => array of tokenIds they own
    mapping(address => uint256[]) private _userTickets;

    // eventId => user address => tokenId (0 means no ticket)
    mapping(uint256 => mapping(address => uint256)) public userEventTicket;

    // verificationCode => bool (used during check-in)
    mapping(bytes32 => bool) public usedCodes;

    // creator => array of eventIds
    mapping(address => uint256[]) private _creatorEvents;

    // ─── Events ─────────────────────────────────────────────────────────────

    event EventCreated(
        uint256 indexed eventId,
        address indexed creator,
        string  name,
        uint256 ticketPrice,
        uint256 maxCapacity,
        uint256 startTime
    );

    event TicketMinted(
        uint256 indexed tokenId,
        uint256 indexed eventId,
        address indexed attendee,
        bytes32 verificationCode
    );

    event TicketVerified(
        uint256 indexed tokenId,
        uint256 indexed eventId,
        address indexed attendee,
        uint256 timestamp
    );

    event EventCancelled(uint256 indexed eventId, address indexed creator);
    event ProceedsWithdrawn(address indexed creator, uint256 amount);

    // ─── State ──────────────────────────────────────────────────────────────

    // creator => accumulated proceeds
    mapping(address => uint256) public creatorProceeds;

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor() ERC721("EventTicket", "ETKT") {}

    // ─── Modifiers ──────────────────────────────────────────────────────────

    modifier eventExists(uint256 eventId) {
        require(eventId > 0 && eventId <= _eventIdCounter.current(), "Event does not exist");
        _;
    }

    modifier onlyEventCreator(uint256 eventId) {
        require(events[eventId].creator == msg.sender, "Not event creator");
        _;
    }

    // ─── Creator Functions ──────────────────────────────────────────────────

    /**
     * @notice Create a new event
     * @param name        Display name of the event
     * @param description Short description
     * @param location    Physical or virtual location string
     * @param imageURI    IPFS or HTTP URI for the event banner
     * @param startTime   Unix timestamp for event start
     * @param endTime     Unix timestamp for event end
     * @param ticketPrice Price per ticket in wei (0 for free events)
     * @param maxCapacity Maximum number of tickets that can be sold
     */
    function createEvent(
        string memory name,
        string memory description,
        string memory location,
        string memory imageURI,
        uint256 startTime,
        uint256 endTime,
        uint256 ticketPrice,
        uint256 maxCapacity
    ) external returns (uint256 eventId) {
        require(bytes(name).length > 0,        "Name required");
        require(startTime > block.timestamp,   "Start must be in the future");
        require(endTime > startTime,           "End must be after start");
        require(maxCapacity > 0,              "Capacity must be > 0");

        _eventIdCounter.increment();
        eventId = _eventIdCounter.current();

        events[eventId] = Event({
            id:           eventId,
            creator:      msg.sender,
            name:         name,
            description:  description,
            location:     location,
            imageURI:     imageURI,
            startTime:    startTime,
            endTime:      endTime,
            ticketPrice:  ticketPrice,
            maxCapacity:  maxCapacity,
            ticketsSold:  0,
            isActive:     true,
            isCancelled:  false
        });

        _creatorEvents[msg.sender].push(eventId);

        emit EventCreated(eventId, msg.sender, name, ticketPrice, maxCapacity, startTime);
    }

    /**
     * @notice Cancel an event (only creator, only before it starts)
     */
    function cancelEvent(uint256 eventId)
        external
        eventExists(eventId)
        onlyEventCreator(eventId)
    {
        Event storage evt = events[eventId];
        require(!evt.isCancelled, "Already cancelled");
        require(block.timestamp < evt.startTime, "Event already started");

        evt.isCancelled = true;
        evt.isActive    = false;

        emit EventCancelled(eventId, msg.sender);
    }

    /**
     * @notice Update event metadata (before ticket sales or start)
     */
    function updateEvent(
        uint256 eventId,
        string memory name,
        string memory description,
        string memory location,
        string memory imageURI
    ) external eventExists(eventId) onlyEventCreator(eventId) {
        Event storage evt = events[eventId];
        require(!evt.isCancelled, "Event cancelled");

        if (bytes(name).length        > 0) evt.name        = name;
        if (bytes(description).length > 0) evt.description = description;
        if (bytes(location).length    > 0) evt.location    = location;
        if (bytes(imageURI).length    > 0) evt.imageURI    = imageURI;
    }

    // ─── Attendee Functions ─────────────────────────────────────────────────

    /**
     * @notice Register for an event and mint an NFT ticket
     * @param eventId The event to register for
     * @param salt    A client-supplied random bytes32 for verification code uniqueness
     */
    function registerForEvent(uint256 eventId, bytes32 salt)
        external
        payable
        nonReentrant
        eventExists(eventId)
        returns (uint256 tokenId, bytes32 verificationCode)
    {
        Event storage evt = events[eventId];

        require(evt.isActive && !evt.isCancelled,          "Event not available");
        require(block.timestamp < evt.startTime,           "Registration closed");
        require(evt.ticketsSold < evt.maxCapacity,         "Sold out");
        require(userEventTicket[eventId][msg.sender] == 0, "Already registered");
        require(msg.value >= evt.ticketPrice,              "Insufficient payment");

        // Refund overpayment
        if (msg.value > evt.ticketPrice) {
            payable(msg.sender).transfer(msg.value - evt.ticketPrice);
        }

        // Accumulate proceeds for creator
        if (evt.ticketPrice > 0) {
            creatorProceeds[evt.creator] += evt.ticketPrice;
        }

        // Mint NFT
        _tokenIdCounter.increment();
        tokenId = _tokenIdCounter.current();

        _safeMint(msg.sender, tokenId);

        // Build token URI (simple on-chain JSON)
        string memory tokenURI = _buildTokenURI(eventId, tokenId, evt.name, evt.imageURI);
        _setTokenURI(tokenId, tokenURI);

        // Generate deterministic verification code
        verificationCode = keccak256(abi.encodePacked(eventId, tokenId, msg.sender, salt, block.timestamp));

        tickets[tokenId] = Ticket({
            tokenId:          tokenId,
            eventId:          eventId,
            owner:            msg.sender,
            verificationCode: verificationCode,
            isUsed:           false,
            issuedAt:         block.timestamp
        });

        evt.ticketsSold++;
        _eventTickets[eventId].push(tokenId);
        _userTickets[msg.sender].push(tokenId);
        userEventTicket[eventId][msg.sender] = tokenId;

        emit TicketMinted(tokenId, eventId, msg.sender, verificationCode);
    }

    // ─── Verification Functions ─────────────────────────────────────────────

    /**
     * @notice Verify a ticket at the event gate (only event creator)
     * @param tokenId          The NFT token ID on the ticket
     * @param verificationCode The code shown in the attendee's ticket QR
     */
    function verifyTicket(uint256 tokenId, bytes32 verificationCode)
        external
        returns (bool valid)
    {
        Ticket storage ticket = tickets[tokenId];
        require(ticket.tokenId == tokenId, "Ticket not found");

        uint256 eventId = ticket.eventId;
        require(events[eventId].creator == msg.sender, "Only creator can verify");
        require(!ticket.isUsed,                        "Ticket already used");
        require(ticket.verificationCode == verificationCode, "Invalid code");
        require(!usedCodes[verificationCode],           "Code already redeemed");

        // Mark used
        ticket.isUsed          = true;
        usedCodes[verificationCode] = true;

        emit TicketVerified(tokenId, eventId, ticket.owner, block.timestamp);
        return true;
    }

    /**
     * @notice Read-only check — returns true if the code is valid and unused
     */
    function checkTicket(uint256 tokenId, bytes32 verificationCode)
        external
        view
        returns (bool valid, bool isUsed, address owner, uint256 eventId)
    {
        Ticket storage ticket = tickets[tokenId];
        valid   = ticket.verificationCode == verificationCode && !ticket.isUsed;
        isUsed  = ticket.isUsed;
        owner   = ticket.owner;
        eventId = ticket.eventId;
    }

    // ─── Withdrawal ─────────────────────────────────────────────────────────

    /**
     * @notice Withdraw accumulated ticket sale proceeds
     */
    function withdrawProceeds() external nonReentrant {
        uint256 amount = creatorProceeds[msg.sender];
        require(amount > 0, "No proceeds to withdraw");

        creatorProceeds[msg.sender] = 0;
        payable(msg.sender).transfer(amount);

        emit ProceedsWithdrawn(msg.sender, amount);
    }

    // ─── View Helpers ────────────────────────────────────────────────────────

    function getEvent(uint256 eventId) external view returns (Event memory) {
        return events[eventId];
    }

    function getTicket(uint256 tokenId) external view returns (Ticket memory) {
        return tickets[tokenId];
    }

    function getCreatorEvents(address creator) external view returns (uint256[] memory) {
        return _creatorEvents[creator];
    }

    function getUserTickets(address user) external view returns (uint256[] memory) {
        return _userTickets[user];
    }

    function getEventTickets(uint256 eventId) external view returns (uint256[] memory) {
        return _eventTickets[eventId];
    }

    function totalEvents() external view returns (uint256) {
        return _eventIdCounter.current();
    }

    function totalTickets() external view returns (uint256) {
        return _tokenIdCounter.current();
    }

    // ─── Internal ───────────────────────────────────────────────────────────

    function _buildTokenURI(
        uint256 eventId,
        uint256 tokenId,
        string memory eventName,
        string memory imageURI
    ) internal pure returns (string memory) {
        // Minimal on-chain base64 JSON — replace with IPFS URI in production
        bytes memory json = abi.encodePacked(
            '{"name":"Ticket #', tokenId.toString(),
            ' - ', eventName,
            '","description":"Event NFT Ticket","image":"', imageURI,
            '","attributes":[{"trait_type":"Event ID","value":"', eventId.toString(),
            '"},{"trait_type":"Ticket #","value":"', tokenId.toString(), '"}]}'
        );
        return string(abi.encodePacked("data:application/json;utf8,", json));
    }

    // ─── ERC-721 Overrides ──────────────────────────────────────────────────

    function _burn(uint256 tokenId)
        internal
        override(ERC721, ERC721URIStorage)
    {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
