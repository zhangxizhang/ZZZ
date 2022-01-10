// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ERC721Like {
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function awardItem(address player, string memory _tokenURI)
        external
        returns (uint256);
        
    function approveForMarket(address _owner, address _msgsender, address _operator, uint256 _tokenId) external;
    function setApproval(address _owner, address _operator, bool _approved) external;
    function tokenURI(uint256 tokenId) external returns (string memory);
    function ownerOf(uint256 tokenId) external returns (address);
}

contract Owned {
    address public owner;
    address public newOwner;

    event OwnershipTransferred(address indexed _from, address indexed _to);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner {
        require(msg.sender == owner, "you are not the owner");
        _;
    }

    function transferOwnership(address _newOwner) public onlyOwner {
        newOwner = _newOwner;
    }

    function acceptOwnership() public {
        require(msg.sender == newOwner, "you are not the owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        newOwner = address(0);
    }
}

library Counters {
    struct Counter {
        uint256 _value;
    }
    function current(Counter storage counter) internal view returns (uint256) {
        return counter._value;
    }
    function increment(Counter storage counter) internal {
        unchecked {
            counter._value += 1;
        }
    }
    function decrement(Counter storage counter) internal {
        uint256 value = counter._value;
        require(value > 0, "Counter: decrement overflow");
        unchecked {
            counter._value = value - 1;
        }
    }
}

abstract contract Market is Owned {
    address public nftAsset;
    address public revenueRecipient;
    string public constant version = "2.0.5";
    uint public constant mintFee = 10 * 1e8;
    uint256 public constant transferFee = 5;
    // // with multisteps
    // struct InputPramas {
    //     bool isDonated;
    //     address[] creators;
    //     string[] tokenURIs;
    //     uint256 royalty;
    //     bool isBid;
    //     uint256 minSalePrice;
    //     uint256 endTime;
    //     uint256 reward;
    //     address organization;
    // }

    struct Bid {
        uint256 tokenID;
        address bidder;
        uint256 value;
    }

    struct Royalty {
        address originator;
        uint256 royalty;
        bool recommended;
        uint256 bundledID;
    }

    event BidEntered(
        uint256 indexed tokenID,
        address fromAddress,
        uint256 value,
        bool indexed isBid,
        bool indexed isDonated
    );
    event Bought(
        address indexed fromAddress,
        address indexed toAddress,
        uint256 indexed tokenID,
        uint256 value
    );
    event NoLongerForSale(uint256 indexed tokenID);
    event AuctionPass(uint256 indexed tokenID);
    event DealTransaction(
        uint256 indexed tokenID,
        bool indexed isDonated,
        address creator,
        address indexed seller
    );

    mapping(uint256 => Royalty) public royalty;
    // NFTs isExist or not 
    mapping(address => mapping(string => uint256)) public isExist;
    // donated oraganizations are approved or not
    mapping(address => bool) public isApprovedOrg;
    // danotion across
    mapping(address => mapping(string => bool)) public isSencond;

    bool private _mutex;
    modifier _lock_() virtual {
        require(!_mutex, "reentry");
        _mutex = true;
        _;
        _mutex = false;
    }

    // approve the donated oraganizations
    function approveOrganization(address _organization) public _lock_ {
        require(_organization != address(0), "organization is null");
        isApprovedOrg[_organization] = true;
    }
}

contract BaseMarket is Market {
    struct Offer {
        bool isForSale;
        uint256 tokenID;
        address originator;
        address seller;
        address organization;
        bool isBid;
        bool isDonated;
        uint256 minValue;
        uint256 endTime;
        uint256 reward;
    }
    // transaction
    struct Transaction {
        uint256 tokenID;
        address caller;
        bool isDonated;
        bool isBid;
        address creator;
        address seller;
    }

    mapping(uint256 => Offer) public nftOfferedForSale;
    mapping(uint256 => Bid) public nftBids;
    mapping(uint256 => mapping(address => uint256)) public offerBalances;
    mapping(uint256 => address[]) public bidders;
    mapping(uint256 => mapping(address => bool)) public bade;
    // txhash 
    mapping(uint256 => Transaction) public txMessage;

    event Offered(
        uint256 indexed tokenID,
        bool indexed isBid,
        bool indexed isDonated,
        uint256 minValue
    );
    
    function recommend(uint256 tokenID) external onlyOwner {
        royalty[tokenID].recommended = true;
    }

    function cancelRecommend(uint256 tokenID) external onlyOwner {
        royalty[tokenID].recommended = false;
    }

    function sell(
        uint256 tokenID,
        bool isBid,
        bool isDonated,
        uint256 minSalePrice,
        uint256 endTime,
        uint256 reward,
        address organization
    ) public _lock_ returns(uint256){
        if(isBid) {
            require(endTime <= block.timestamp + 30 days, "Maximum time exceeded");
            require(endTime > block.timestamp + 5 minutes, "Below minimum time");
        } 
        
        require(
            reward * 2 < 200 - transferFee - royalty[tokenID].royalty * 2,
            "Excessive reward"
        );
        ERC721Like(nftAsset).transferFrom(msg.sender, address(this), tokenID);
        
        //sell
        nftOfferedForSale[tokenID] = Offer(
            true,
            tokenID,
            royalty[tokenID].originator,
            msg.sender,
            organization,
            isBid,
            isDonated,
            minSalePrice,
            endTime,
            reward
        );
        
        emit Offered(tokenID, isBid, isDonated, minSalePrice);
        return tokenID;
    }

    function noLongerForSale(uint256 tokenID) internal _lock_ {
        Offer memory offer = nftOfferedForSale[tokenID];
        require(offer.isForSale, "nft not actually for sale");
        require(msg.sender == offer.seller, "Only the seller can operate");
        require(!offer.isBid, "The auction cannot be cancelled");

        ERC721Like(nftAsset).transferFrom(address(this), offer.seller, tokenID);
        delete nftOfferedForSale[tokenID];
        emit NoLongerForSale(tokenID);
    }

    function buy(uint256 tokenID) external payable  _lock_ returns(bool){
        Offer memory offer = nftOfferedForSale[tokenID];
        require(offer.isForSale, "nft not actually for sale");
        require(!offer.isBid, "nft is auction mode");

        uint256 share1 = (offer.minValue * transferFee) / 200;
        uint256 share2 = (offer.minValue * royalty[tokenID].royalty) / 100;

        require(
            msg.value >= offer.minValue,
            "Sorry, your credit is running low"
        );
        
        payable(royalty[tokenID].originator).transfer(share2);
        if(offer.isDonated) {
            require(offer.organization != address(0), "The donated organization is null");
            require(isApprovedOrg[offer.organization], "the organization is not approved");
            payable(offer.organization).transfer(offer.minValue - share2);
        }else {
            payable(revenueRecipient).transfer(share1);
            payable(offer.seller).transfer(offer.minValue - share1 - share2);
        }
        
        txMessage[tokenID] = Transaction(
            tokenID,
            msg.sender,
            false,
            false,
            royalty[tokenID].originator,
            offer.seller
        );
        ERC721Like(nftAsset).transferFrom(address(this), msg.sender, tokenID);
        
        emit Bought(
            offer.seller,
            msg.sender,
            tokenID,
            offer.minValue
        );
        
        emit DealTransaction(
            tokenID,
            offer.isDonated,
            royalty[tokenID].originator,
            offer.seller
        );
        delete nftOfferedForSale[tokenID];
        return txMessage[tokenID].isDonated;
    }

    function enterBidForNft(uint256 tokenID) external payable _lock_ 
    {
        Offer memory offer = nftOfferedForSale[tokenID];
        require(offer.isForSale, "nft not actually for sale");
        require(offer.isBid, "nft must beauction mode");
        require(block.timestamp < offer.endTime, "The auction is over");

        if (!bade[tokenID][msg.sender]) {
            bidders[tokenID].push(msg.sender);
            bade[tokenID][msg.sender] = true;
            
        }

        Bid memory bid = nftBids[tokenID];
        require(
            msg.value + offerBalances[tokenID][msg.sender] >=
                offer.minValue,
            "The bid cannot be lower than the starting price"
        );
        require(
            msg.value + offerBalances[tokenID][msg.sender] > bid.value,
            "This quotation is less than the current quotation"
        );
        nftBids[tokenID] = Bid(
            tokenID,
            msg.sender,
            msg.value + offerBalances[tokenID][msg.sender]
        );
        emit BidEntered(tokenID, msg.sender, msg.value, offer.isBid, offer.isDonated);
        offerBalances[tokenID][msg.sender] += msg.value;
    
    }

//  deal for donation or not
    function deal(uint256 tokenID) public _lock_ returns(bool) {
        Offer memory offer = nftOfferedForSale[tokenID];
        require(offer.isForSale, "nft not actually for sale");
        require(offer.isBid, "must be auction mode");
        require(offer.endTime < block.timestamp, "The auction is not over yet");

        Bid memory bid = nftBids[tokenID];

        if (bid.value >= offer.minValue) {
            uint256 share1 = (bid.value * transferFee) / 200;
            uint256 share2 = (bid.value * royalty[tokenID].royalty) / 100;
            uint256 share3 = 0;
            uint256 totalBid = 0;

            for (uint256 i = 0; i < bidders[tokenID].length; i++) {
                if (bid.bidder != bidders[tokenID][i]) {
                    totalBid += offerBalances[tokenID][bidders[tokenID][i]];
                }
            }
            for (uint256 i = 0; i < bidders[tokenID].length; i++) {
                if (bid.bidder != bidders[tokenID][i]) {
                    uint256 tempC =
                        (bid.value *
                            offer.reward *
                            offerBalances[tokenID][bidders[tokenID][i]]) /
                            totalBid /
                            100;
                    payable(bidders[tokenID][i]).transfer(tempC);
                    share3 += tempC;
                    payable(bidders[tokenID][i]).transfer(
                        offerBalances[tokenID][bidders[tokenID][i]]
                    );
                    offerBalances[tokenID][bidders[tokenID][i]] = 0;
                    delete bade[tokenID][bidders[tokenID][i]];
                }
            }

            uint256 tempD = bid.value - share2 - share3;
            payable(royalty[tokenID].originator).transfer(share2);
            
            if(offer.isDonated) {
                require(offer.organization != address(0), "The donated organization is null");
                require(isApprovedOrg[offer.organization], "the organization is not approved");
                payable(offer.organization).transfer(tempD);
            }else {
                tempD = bid.value - share1 - share2 - share3;
                payable(revenueRecipient).transfer(share1);
                payable(offer.seller).transfer(tempD);
            }

            offerBalances[tokenID][bid.bidder] = 0;
            delete bade[tokenID][bid.bidder];
            delete bidders[tokenID];

            txMessage[tokenID] = Transaction(
                tokenID,
                msg.sender,
                offer.isDonated,
                offer.isBid,
                royalty[tokenID].originator,
                offer.seller
            );
            
            ERC721Like(nftAsset).transferFrom(
                address(this),
                bid.bidder,
                tokenID
            );
            
            emit Bought(
                offer.seller,
                bid.bidder,
                tokenID,
                bid.value
            );
            
            emit DealTransaction(
                tokenID,
                offer.isDonated,
                royalty[tokenID].originator,
                offer.seller
            );
        } else {
            ERC721Like(nftAsset).transferFrom(
                address(this),
                offer.seller,
                tokenID
            );
            emit AuctionPass(tokenID);
        }
        delete nftOfferedForSale[tokenID];
        delete nftBids[tokenID];
        
        string memory _tokenURI = ERC721Like(nftAsset).tokenURI(tokenID);
        delete nftOfferedForSale[tokenID];
        delete nftBids[tokenID];
        if(isSencond[offer.originator][_tokenURI]) {
            delete isSencond[offer.originator][_tokenURI];
        }
        
        return txMessage[tokenID].isDonated;
    }
}

contract ExtendMarket is BaseMarket {
    // create bundledID
    using Counters for Counters.Counter;
    Counters.Counter private _bundledID; 
    
    // bundle sell
    struct BundleOffer {
        bool isForSale;
        uint256[] tokenIDs;
        address seller;
        address organization;
        bool isBid;
        bool isDonated;
        uint256 minValue;
        uint256 endTime;
        uint256 reward;
    }
    // transaction
    struct BundleTransaction {
        uint256[] tokenIDs;
        address caller;
        bool isDonated;
        bool isBid;
        address seller;
    }

    // NFTId
    mapping(uint256 => bool) public isBundled;
    mapping(uint256 => BundleOffer) public nftBundledForSale;
    // own bundled NFT assets
    mapping(address => uint256[]) public bundledAssets;
    mapping(uint256 => mapping(address => bool)) public bundleBade;
    mapping(uint256 => Bid) public bundleBids;
    mapping(uint256 => address[]) public bundleBidders;
    mapping(uint256 => mapping(address => uint256)) public offerBundleBalances;
    //txhash
    mapping(uint256 => BundleTransaction) public txBundleMessage;
 
    event BundleOffered(
        uint256[] indexed tokenIDs,
        bool indexed isBid,
        bool indexed isDonated,
        uint256 minValue,
        address seller
    );

    function NewNft(string memory _tokenURI, uint256 _royalty) external payable _lock_ returns (uint256)
    {
        require(_royalty < 30, "Excessive copyright fees");
        require(msg.value == mintFee, "The mintFee is 10 * 1e8");

        uint256 tokenID = ERC721Like(nftAsset).awardItem(msg.sender, _tokenURI);

        royalty[tokenID] = Royalty(msg.sender, _royalty, false, 0);
        isExist[msg.sender][_tokenURI] = tokenID;
        payable(revenueRecipient).transfer(mintFee);

        return tokenID;
    }

    constructor(
        address _nftAsset,
        address _revenueRecipient
    ) {
        require(_nftAsset != address(0), "_nftAsset address cannot be 0");
        require(
            _revenueRecipient != address(0),
            "_revenueRecipient address cannot be 0"
        );
        nftAsset = _nftAsset;
        revenueRecipient = _revenueRecipient;
    }

    // fake create NFTs (donate the value to the organization; usual transaction)
    function buyNFTWithMultiStep(
        bool isDonated,
        address creator,
        string memory tokenURI,
        uint256 _royalty,
        bool isBid,
        uint256 minSalePrice,
        uint256 endTime,
        uint256 reward,
        address organization) public payable _lock_ returns(uint256, bool) {
        require(_royalty < 30, "Excessive copyright fees");
        
        uint256 _tokenid = isExist[creator][tokenURI];
        address seller = creator;
        if(isExist[creator][tokenURI] == 0) {
            
            //create
            uint256 tokenID = ERC721Like(nftAsset).awardItem(creator, tokenURI);
            royalty[tokenID] = Royalty(creator, _royalty, false, 0);
            isExist[creator][tokenURI] = tokenID;
            _tokenid = isExist[creator][tokenURI];
            
        } else {
            seller = ERC721Like(nftAsset).ownerOf(_tokenid);
        }
        
        //approve 
        ERC721Like(nftAsset).setApproval(seller, msg.sender, true);
        
        ERC721Like(nftAsset).approveForMarket(seller, msg.sender, address(this), _tokenid);
        
        //register 
        if(isBid) {
            require(endTime <= block.timestamp + 30 days, "Maximum time exceeded");
            require(endTime > block.timestamp + 5 minutes, "Below minimum time");
        }
        require(
            reward * 2 < 200 - transferFee - royalty[_tokenid].royalty * 2,
            "Excessive reward"
        );
        ERC721Like(nftAsset).transferFrom(seller, address(this), _tokenid);
        nftOfferedForSale[_tokenid] = Offer(
            true,
            _tokenid,
            creator,
            seller,
            organization,
            isBid,
            isDonated,
            minSalePrice,
            endTime,
            reward
        );
        emit Offered(_tokenid, isBid, isDonated, minSalePrice);
        
        // buy
        Offer memory offer = nftOfferedForSale[_tokenid];
        require(offer.isForSale, "nft not actually for sale");
        require(!offer.isBid, "nft is auction mode");

        uint256 share1 = (offer.minValue * royalty[_tokenid].royalty) / 100;
        uint256 share2 = (offer.minValue * transferFee) / 200;

        require(
            msg.value >= offer.minValue,
            "Sorry, your credit is running low"
        );
        payable(royalty[_tokenid].originator).transfer(share1);
        
        if(!isDonated) {
            // No donation
           payable(revenueRecipient).transfer(share2); 
           payable(offer.seller).transfer(offer.minValue - share1 - share2);
        }else {
            // donate
            require(isApprovedOrg[organization], "the organization is not approved");
            payable(organization).transfer(offer.minValue - share1);
        }
    
        txMessage[_tokenid] = Transaction(
            _tokenid,
            msg.sender,
            offer.isDonated,
            isBid,
            royalty[_tokenid].originator,
            offer.seller
        );
        
        ERC721Like(nftAsset).transferFrom(address(this), msg.sender, _tokenid);
        
        emit Bought(
            offer.seller,
            msg.sender,
            _tokenid,
            offer.minValue
        );
        
        emit DealTransaction(
            _tokenid,
            offer.isDonated,
            royalty[_tokenid].originator,
             offer.seller
        );
        delete nftOfferedForSale[_tokenid];
        
        return (_tokenid, txMessage[_tokenid].isDonated);
    }
    
    //the auction
    function enterBidWithMultiStep(
        bool isDonated,
        address creator,
        string memory tokenURI,
        uint256 _royalty,
        bool isBid,
        uint256 minSalePrice,
        uint256 endTime,
        uint256 reward,
        address organization
    ) public payable _lock_ returns(uint256) {
        uint256 _tokenid = isExist[creator][tokenURI];
        address seller = creator;
    
        // is the first offer
        if(isExist[creator][tokenURI] == 0 || !isSencond[creator][tokenURI]) {
            require(_royalty < 30, "Excessive copyright fees");
            isSencond[creator][tokenURI] = true;
            
            if(isExist[creator][tokenURI] == 0) {
                //create
                uint256 tokenID = ERC721Like(nftAsset).awardItem(creator, tokenURI);
                royalty[tokenID] = Royalty(creator, _royalty, false, 0);
                _tokenid = tokenID;
                isExist[creator][tokenURI] = tokenID;
            }
            
            if(isExist[creator][tokenURI] != 0) {
                seller = ERC721Like(nftAsset).ownerOf(_tokenid);
            }
            
            //approve 
            ERC721Like(nftAsset).setApproval(seller, msg.sender, true);
            
            ERC721Like(nftAsset).approveForMarket(seller, msg.sender, address(this), _tokenid);
            
            //register 
            require(endTime <= block.timestamp + 30 days, "Maximum time exceeded");
            require(endTime > block.timestamp + 5 minutes, "Below minimum time");
            require(
                reward * 2 < 200 - transferFee - royalty[_tokenid].royalty * 2,
                "Excessive reward"
            );
            ERC721Like(nftAsset).transferFrom(seller, address(this), _tokenid);
            nftOfferedForSale[_tokenid] = Offer(
                true,
                _tokenid,
                creator,
                seller,
                organization,
                isBid,
                isDonated,
                minSalePrice,
                endTime,
                reward
            );
            emit Offered(_tokenid, isBid, isDonated, minSalePrice);
        }
        
        // enterForBid
        Offer memory offer = nftOfferedForSale[_tokenid];
        require(offer.isForSale, "nft not actually for sale");
        require(offer.isBid, "nft must beauction mode");
        
        // offer again
        if(block.timestamp < offer.endTime) {
            if (!bade[_tokenid][msg.sender]) {
                bidders[_tokenid].push(msg.sender);
                bade[_tokenid][msg.sender] = true;
            }
    
            Bid memory bid = nftBids[_tokenid];
           
            require(
                msg.value + offerBalances[_tokenid][msg.sender] >=
                    offer.minValue,
                "The bid cannot be lower than the starting price"
            );
            require(
                msg.value + offerBalances[_tokenid][msg.sender] > bid.value,
                "This quotation is less than the current quotation"
            );
            nftBids[_tokenid] = Bid(
                _tokenid,
                msg.sender,
                msg.value + offerBalances[_tokenid][msg.sender]
            );
            emit BidEntered(_tokenid, msg.sender, msg.value, offer.isBid, offer.isDonated);
            offerBalances[_tokenid][msg.sender] += msg.value;
        }
        
        return _tokenid;
    }

    function bundleSell(
        bool isBid,
        bool isDonated,
        uint256[] memory tokenIDs,
        uint256 minSalePrice,
        uint256 endTime,
        uint256 reward,
        address organization
    ) public _lock_ returns(uint256, uint256[] memory){
        if(isBid) {
            require(endTime <= block.timestamp + 30 days, "Maximum time exceeded");
            require(endTime > block.timestamp + 5 minutes, "Below minimum time");
        } 

        bool baseBid = nftOfferedForSale[tokenIDs[0]].isBid;
        bool baseDonated = nftOfferedForSale[tokenIDs[0]].isDonated;
        address baseSeller = nftOfferedForSale[tokenIDs[0]].seller;
        uint256 maxRoyalty = royalty[tokenIDs[0]].royalty;
        for(uint i = 0; i < tokenIDs.length; i++) {
            require(nftOfferedForSale[tokenIDs[i]].isBid == baseBid, "The isBid of tokenIDs are not the same");
            require(nftOfferedForSale[tokenIDs[i]].isDonated == baseDonated, "The isDonated of tokenIDs are not the same");
            require(nftOfferedForSale[tokenIDs[i]].seller == baseSeller, "The seller of tokenIDs are not the same");
            require(!isBundled[tokenIDs[i]], "The tokenID already could be bundled");
            isBundled[tokenIDs[i]] = true;

            if(royalty[tokenIDs[i]].royalty > maxRoyalty) {
                maxRoyalty = royalty[tokenIDs[i]].royalty;
            }
                // approve 
            ERC721Like(nftAsset).transferFrom(msg.sender, address(this), tokenIDs[i]);
        }
        
        require(
            //convert to integer operation
            reward * 2 < 200 - transferFee - maxRoyalty * 2,
            "Excessive reward"
        );
        _bundledID.increment();
        uint256 newBundleId = _bundledID.current();
        for(uint8 i = 0; i < tokenIDs.length; i++) {
            royalty[tokenIDs[i]].bundledID = newBundleId;
        }
        nftBundledForSale[newBundleId] = BundleOffer(
            true,
            tokenIDs,
            msg.sender,
            organization,
            isBid,
            isDonated,
            minSalePrice,
            endTime,
            reward
        );
        
        bundledAssets[msg.sender].push(newBundleId);
        
        emit BundleOffered(tokenIDs, baseBid, baseDonated, minSalePrice, baseSeller);
        return (newBundleId,tokenIDs);
        
    }

    function buyBundle(uint256 tokenID) external payable _lock_ returns(bool){
        uint256 share1;
        uint256 share2;
        BundleOffer memory offer = nftBundledForSale[tokenID];
        require(offer.isForSale, "nft not actually for sale");
        require(!offer.isBid, "nft is auction mode");
        require(
            msg.value >= offer.minValue,
            "Sorry, your credit is running low"
        );
        
        // actually transaction transferfee 2.5%
        share1 = (offer.minValue * transferFee) / 200;

        uint i;
        if(offer.isDonated) {
            require(offer.organization != address(0), "The donated organization is null");
            require(isApprovedOrg[offer.organization], "the organization is not approved");
            payable(offer.organization).transfer(offer.minValue);
            for(i = 0; i < offer.tokenIDs.length; i++) {
                isBundled[offer.tokenIDs[i]] = false;
                royalty[offer.tokenIDs[i]].bundledID = 0;
                ERC721Like(nftAsset).transferFrom(address(this), msg.sender, offer.tokenIDs[i]);
            }
        } else {
            uint256 total;
            payable(revenueRecipient).transfer(share1);
            for(i = 0; i < offer.tokenIDs.length; i++) {
                share2 = (offer.minValue * royalty[offer.tokenIDs[i]].royalty) / 100;
                total += share2;
                payable(royalty[offer.tokenIDs[i]].originator).transfer(share2);
                isBundled[offer.tokenIDs[i]] = false;
                royalty[offer.tokenIDs[i]].bundledID = 0;
                ERC721Like(nftAsset).transferFrom(address(this), msg.sender, offer.tokenIDs[i]);
            }
            payable(offer.seller).transfer(offer.minValue - share1 - total);
        }
        
        txBundleMessage[tokenID] = BundleTransaction(
            offer.tokenIDs,
            msg.sender,
            offer.isDonated,
            offer.isBid,
            offer.seller
        );
        emit Bought(
            offer.seller,
            msg.sender,
            tokenID,
            offer.minValue
        );
            
        emit DealTransaction(
            tokenID,
            offer.isDonated,
            offer.seller,
            offer.seller
        );
        delete nftBundledForSale[tokenID];
             
        return offer.isDonated;    
    }

    function enterBidForBundle(uint256 tokenID) external payable _lock_ 
    {
        Bid memory bid = bundleBids[tokenID];
        BundleOffer memory offer = nftBundledForSale[tokenID];
        require(offer.isForSale, "nft not actually for sale");
        require(offer.isBid, "nft must beauction mode");
        require(block.timestamp < offer.endTime, "The auction is over");
        if(!bundleBade[tokenID][msg.sender]) {
            bundleBidders[tokenID].push(msg.sender);
            bundleBade[tokenID][msg.sender] = true;
        } 
        require(
            msg.value + offerBundleBalances[tokenID][msg.sender] >=
                offer.minValue,
            "The bid cannot be lower than the starting price"
        );
        require(
            msg.value + offerBundleBalances[tokenID][msg.sender] > bid.value,
            "This quotation is less than the current quotation"
        );
        bundleBids[tokenID] = Bid(
            tokenID,
            msg.sender,
            msg.value + offerBundleBalances[tokenID][msg.sender]
        );
        offerBundleBalances[tokenID][msg.sender] += msg.value;
    
        emit BidEntered(tokenID, msg.sender, msg.value, offer.isBid, offer.isDonated);
    }

    //  deal for donation or not
    function dealForBundle(uint256 tokenID) public _lock_ returns(bool) {
        Bid memory bid = bundleBids[tokenID];
        BundleOffer memory offer = nftBundledForSale[tokenID];
        uint256 share1 = 0;
        uint256 share2 = 0;
        uint256 share3 = 0;
        uint256 total = 0;
        uint256 tempC = 0;
        uint256 i;

        require(offer.isForSale, "nft not actually for sale");
        require(offer.isBid, "must be auction mode");
        require(offer.endTime < block.timestamp, "The auction is not over yet");
    
        if (bid.value >= offer.minValue) {
            // actually transaction transferfee 2.5%
            share1 = (bid.value * transferFee) / 200;
    
            for (i = 0; i < bundleBidders[tokenID].length; i++) {
                if (bid.bidder != bundleBidders[tokenID][i]) {
                    total += offerBundleBalances[tokenID][bundleBidders[tokenID][i]];
                }
            }
            for (i = 0; i < bundleBidders[tokenID].length; i++) {
                if (bid.bidder != bundleBidders[tokenID][i]) {
                    tempC =
                        (bid.value *
                            offer.reward *
                            offerBundleBalances[tokenID][bundleBidders[tokenID][i]]) /
                            total /
                            100;
                    payable(bundleBidders[tokenID][i]).transfer(tempC);
                    share3 += tempC;
                    payable(bundleBidders[tokenID][i]).transfer(
                        offerBundleBalances[tokenID][bundleBidders[tokenID][i]]
                    );
                    offerBundleBalances[tokenID][bundleBidders[tokenID][i]] = 0;
                    delete bundleBade[tokenID][bundleBidders[tokenID][i]];
                }
            }
        
            if(offer.isDonated) {
                require(offer.organization != address(0), "The donated organization is null");
                require(isApprovedOrg[offer.organization], "the organization is not approved");
                payable(offer.organization).transfer(bid.value - share3);
                for(i = 0; i < offer.tokenIDs.length; i++) {
                    isBundled[offer.tokenIDs[i]] = false;
                    royalty[offer.tokenIDs[i]].bundledID = 0;
                    ERC721Like(nftAsset).transferFrom(address(this), bid.bidder, offer.tokenIDs[i]);
                }
                offerBundleBalances[tokenID][bid.bidder] = 0;
                delete bundleBade[tokenID][bid.bidder];
                delete bundleBids[tokenID];
            
            } else {
                total =0;
                payable(revenueRecipient).transfer(share1);
                for(i = 0; i < offer.tokenIDs.length; i++) {
                    isBundled[offer.tokenIDs[i]] = false;
                    royalty[offer.tokenIDs[i]].bundledID = 0;
                    share2 = (offer.minValue * royalty[offer.tokenIDs[i]].royalty) / 100;
                    total += share2;
                    payable(royalty[offer.tokenIDs[i]].originator).transfer(share2);
                    ERC721Like(nftAsset).transferFrom(address(this), bid.bidder, offer.tokenIDs[i]);
                }
                payable(offer.seller).transfer(bid.value - share1 - total - share3);
                offerBundleBalances[tokenID][bid.bidder] = 0;
                delete bundleBade[tokenID][bid.bidder];
                delete bundleBids[tokenID];
            }    
            txBundleMessage[tokenID] = BundleTransaction(
                offer.tokenIDs,
                msg.sender,
                offer.isDonated,
                offer.isBid,
                offer.seller
            );
            emit Bought(
                offer.seller,
                bid.bidder,
                tokenID,
                bid.value
            );
            emit DealTransaction(
                tokenID,
                offer.isDonated,
                offer.seller,
                offer.seller
            );   
        } else {
            for(i = 0; i < offer.tokenIDs.length; i++) {
                ERC721Like(nftAsset).transferFrom(address(this), offer.seller, offer.tokenIDs[i]);
            }
            emit AuctionPass(tokenID);        
        }
        delete nftBundledForSale[tokenID];
        delete bundleBids[tokenID];
        
        string memory _tokenURI;
        for(i = 0; i < offer.tokenIDs.length; i++) {
            _tokenURI = ERC721Like(nftAsset).tokenURI(offer.tokenIDs[i]);
            if(isSencond[royalty[offer.tokenIDs[i]].originator][_tokenURI]) {
                delete isSencond[royalty[offer.tokenIDs[i]].originator][_tokenURI];
            }
        }
        return offer.isDonated;   
    }
 }



