// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

//contract address:0x720Ab1832B482A528F40E37E7077D8cC3C27f3B2
//revenueRecipient:0x07d15c4f3e02B764F1cF5e5ac78a116773d86833

interface ERC20Like {
    function transfer(address, uint256) external returns (bool);

    function transferFrom(
        address,
        address,
        uint256
    ) external returns (bool);
}

interface ERC721Like {
    function transferFrom(
        address _from,
        address _to,
        uint256 _tokenId
    ) external;

    function awardItem(address _player, string memory _tokenURI)
        external
        returns (uint256);
}

contract Owned {
    address public tOwner;
    address public tNewOwner;

    event OwnershipTransferred(address indexed _from, address indexed _to);

    constructor() {
        tOwner = msg.sender;
    }

    modifier onlyOwner {
        require(msg.sender == tOwner, "you are not the owner");
        _;
    }

    function transferOwnership(address _newOwner) public onlyOwner {
        tNewOwner = _newOwner;
    }

    function acceptOwnership() public {
        require(msg.sender == tNewOwner, "you are not the owner");
        emit OwnershipTransferred(tOwner, tNewOwner);
        tOwner = tNewOwner;
        tNewOwner = address(0);
    }
}

contract NftMarket is Owned {
	address public NFTasset;
	address public ABToken;
    string public constant version = "2.0.5";
    address public revenueRecipient;
    uint256 public constant mintFee = 10 * 1e8;
    uint256 public constant transferFee = 5;

    //edit NFTasset status
    struct Offer {
        bool nft_isForSale;
        uint256 nft_tokenID;
        address nft_seller;
        bool nft_isBid;
        uint256 nft_minValue;
        uint256 nft_endTime;
        address nft_paymentToken;
        uint256 nft_reward;
    }
	
    //NFT is bade
    struct Bid {
        uint256 nft_tokenID;
        address nft_bidder;
        uint256 nft_value;
    }

    //fee
    struct Royalty {
        address nft_originator;
        uint256 nft_royalty;
        bool nft_recommended;
    }

    //ID-->NFTasset
    mapping(uint256 => Offer) public AssetForSale;
	//ID-->BadeAsset
    mapping(uint256 => Bid) public AssetBids;
	//ID-->fee
    mapping(uint256 => Royalty) public royalty;
	//ID-->bidder-->value
    mapping(uint256 => mapping(address => uint256)) public offerBalances;
	//ID-->bidders
    mapping(uint256 => address[]) public bidders;
	//ID-->owner-->isBid/no Bid
    mapping(uint256 => mapping(address => bool)) public bade;

    event Offered(
        uint256 indexed _tokenID,
        uint256 _minValue,
        address _paymentToken
    );
    event BidEntered(
        uint256 indexed _tokenID,
        address indexed _fromAddress,
        uint256 _value
    );
    event Bought(
        address indexed _fromAddress,
        address indexed _toAddress,
        uint256 indexed _tokenID,
        uint256 _value,
        address _paymentToken
    );
    event NoLongerForSale(uint256 indexed _tokenID);
    event AuctionPass(uint256 indexed _tokenID);

    bool private mutex;
    modifier _lock_() {
        require(!mutex, "reentry");
        mutex = true;
        _;
        mutex = false;
    }

    constructor(
        address _nftAsset,
        address _abToken,
        address _revenueRecipient
    ) {
        require(_nftAsset != address(0), "_nftAsset address cannot be 0");
        require(_abToken != address(0), "_abToken address cannot be 0");
        require(
            _revenueRecipient != address(0),
            "_revenueRecipient address cannot be 0"
        );
        NFTasset = _nftAsset;
        ABToken = _abToken;
        revenueRecipient = _revenueRecipient;
    }

    function NewNft(string memory _tokenURI, uint256 _royalty)
        external
        _lock_
        returns (uint256)
    {
        require(_royalty < 30, "Excessive copyright fees");

        ERC20Like(ABToken).transferFrom(msg.sender, address(this), mintFee);
        ERC20Like(ABToken).transfer(revenueRecipient, mintFee);

        uint256 tID = ERC721Like(NFTasset).awardItem(msg.sender, _tokenURI);

        royalty[tID] = Royalty(msg.sender, _royalty, false);

        return tID;
    }

    function recommend(uint256 _tokenID) external onlyOwner {
        royalty[_tokenID].nft_recommended = true;
    }

    function cancelRecommend(uint256 _tokenID) external onlyOwner {
        royalty[_tokenID].nft_recommended = false;
    }

    //set my own NFT on sold(Bid/No Bid)
    function sell(
        uint256 _tokenID,
        bool _isBid,
        uint256 _minSalePrice,
        uint256 _endTime,
        address _paymentToken,
        uint256 _reward
    ) external _lock_ {
        require(_endTime <= block.timestamp + 30 days, "Maximum time exceeded");
        require(_endTime > block.timestamp + 5 minutes, "Below minimum time");
        require(
            _reward < 100 - transferFee - royalty[_tokenID].nft_royalty,
            "Excessive reward"
        );
        ERC721Like(NFTasset).transferFrom(msg.sender, address(this), _tokenID);
        AssetForSale[_tokenID] = Offer(
            true,
            _tokenID,
            msg.sender,
            _isBid,
            _minSalePrice,
            _endTime,
            _paymentToken,
            _reward
        );
        emit Offered(_tokenID, _minSalePrice, _paymentToken);
    }

    function noLongerForSale(uint256 _tokenID) external _lock_ {
        Offer memory offer = AssetForSale[_tokenID];
        require(offer.nft_isForSale, "nft not actually for sale");
        require(msg.sender == offer.nft_seller, "Only the seller can operate");
        require(!offer.nft_isBid, "The auction cannot be cancelled");

        ERC721Like(NFTasset).transferFrom(address(this), offer.nft_seller, _tokenID);
        delete AssetForSale[_tokenID];
        emit NoLongerForSale(_tokenID);
    }

    //purchase NFT (to be owner)
    function buy(uint256 _tokenID) external payable _lock_ {
        Offer memory offer = AssetForSale[_tokenID];
        require(offer.nft_isForSale, "nft not actually for sale");
        require(!offer.nft_isBid, "nft is auction mode");

        uint256 share1 = (offer.nft_minValue * transferFee) / 100;
        uint256 share2 = (offer.nft_minValue * royalty[_tokenID].nft_royalty) / 100;

        if (offer.nft_paymentToken != address(0)) {
            ERC20Like(offer.nft_paymentToken).transferFrom(
                msg.sender,
                address(this),
                offer.nft_minValue
            );

            ERC20Like(offer.nft_paymentToken).transfer(revenueRecipient, share1);
            ERC20Like(offer.nft_paymentToken).transfer(
                royalty[_tokenID].nft_originator,
                share2
            );
            ERC20Like(offer.nft_paymentToken).transfer(
                offer.nft_seller,
                offer.nft_minValue - share1 - share2
            );
        } else {
            require(
                msg.value >= offer.nft_minValue,
                "Sorry, your credit is running low"
            );
            payable(revenueRecipient).transfer(share1);
            payable(royalty[_tokenID].nft_originator).transfer(share2);
            payable(offer.nft_seller).transfer(offer.nft_minValue - share1 - share2);
        }
        ERC721Like(NFTasset).transferFrom(address(this), msg.sender, _tokenID);
        emit Bought(
            offer.nft_seller,
            msg.sender,
            _tokenID,
            offer.nft_minValue,
            offer.nft_paymentToken
        );
        delete AssetForSale[_tokenID];
    }

    //enter a bid about NFT 
    function enterBidForNft(uint256 _tokenID, uint256 _amount)
        external
        payable
        _lock_
    {
        Offer memory offer = AssetForSale[_tokenID];
        require(offer.nft_isForSale, "nft not actually for sale");
        require(offer.nft_isBid, "nft must beauction mode");
        require(block.timestamp < offer.nft_endTime, "The auction is over");

        if (!bade[_tokenID][msg.sender]) {
            bidders[_tokenID].push(msg.sender);
            bade[_tokenID][msg.sender] = true;
        }

        Bid memory bid = AssetBids[_tokenID];
        if (offer.nft_paymentToken != address(0)) {
            require(
                _amount + offerBalances[_tokenID][msg.sender] >= offer.nft_minValue,
                "The bid cannot be lower than the starting price"
            );
            require(
                _amount + offerBalances[_tokenID][msg.sender] > bid.nft_value,
                "This quotation is less than the current quotation"
            );
            ERC20Like(offer.nft_paymentToken).transferFrom(
                msg.sender,
                address(this),
                _amount
            );
            AssetBids[_tokenID] = Bid(
                _tokenID,
                msg.sender,
                _amount + offerBalances[_tokenID][msg.sender]
            );
            emit BidEntered(_tokenID, msg.sender, _amount);
            offerBalances[_tokenID][msg.sender] += _amount;
        } else {
            require(
                msg.value + offerBalances[_tokenID][msg.sender] >=
                    offer.nft_minValue,
                "The bid cannot be lower than the starting price"
            );
            require(
                msg.value + offerBalances[_tokenID][msg.sender] > bid.nft_value,
                "This quotation is less than the current quotation"
            );
            AssetBids[_tokenID] = Bid(
                _tokenID,
                msg.sender,
                msg.value + offerBalances[_tokenID][msg.sender]
            );
            emit BidEntered(_tokenID, msg.sender, msg.value);
            offerBalances[_tokenID][msg.sender] += msg.value;
        }
    }

    //deal with purchase transaction
    function deal(uint256 _tokenID) external _lock_ {
        Offer memory offer = AssetForSale[_tokenID];
        require(offer.nft_isForSale, "nft not actually for sale");
        require(offer.nft_isBid, "must be auction mode");
        require(offer.nft_endTime < block.timestamp, "The auction is not over yet");

        Bid memory bid = AssetBids[_tokenID];

        if (bid.nft_value >= offer.nft_minValue) {
            uint256 share1 = (bid.nft_value * transferFee) / 100;
            uint256 share2 = (bid.nft_value * royalty[_tokenID].nft_royalty) / 100;
            uint256 share3 = 0;
            uint256 totalBid = 0;

            for (uint256 i = 0; i < bidders[_tokenID].length; i++) {
                if (bid.nft_bidder != bidders[_tokenID][i]) {
                    totalBid += offerBalances[_tokenID][bidders[_tokenID][i]];
                }
            }

            if (offer.nft_paymentToken != address(0)) {
                for (uint256 i = 0; i < bidders[_tokenID].length; i++) {
                    if (bid.nft_bidder != bidders[_tokenID][i]) {
                        uint256 tempC =
                            (bid.nft_value *
                                offer.nft_reward *
                                offerBalances[_tokenID][bidders[_tokenID][i]]) /
                                totalBid /
                                100;
                        ERC20Like(offer.nft_paymentToken).transfer(
                            bidders[_tokenID][i],
                            tempC
                        );
                        share3 += tempC;
                        ERC20Like(offer.nft_paymentToken).transfer(
                            bidders[_tokenID][i],
                            offerBalances[_tokenID][bidders[_tokenID][i]]
                        );
                        offerBalances[_tokenID][bidders[_tokenID][i]] = 0;
                        delete bade[_tokenID][bidders[_tokenID][i]];
                    }
                }

                ERC20Like(offer.nft_paymentToken).transfer(
                    revenueRecipient,
                    share1
                );
                ERC20Like(offer.nft_paymentToken).transfer(
                    royalty[_tokenID].nft_originator,
                    share2
                );
                ERC20Like(offer.nft_paymentToken).transfer(
                    offer.nft_seller,
                    bid.nft_value - share1 - share2 - share3
                );
            } else {
                for (uint256 i = 0; i < bidders[_tokenID].length; i++) {
                    if (bid.nft_bidder != bidders[_tokenID][i]) {
                        uint256 tempC =
                            (bid.nft_value *
                                offer.nft_reward *
                                offerBalances[_tokenID][bidders[_tokenID][i]]) /
                                totalBid /
                                100;
                        payable(bidders[_tokenID][i]).transfer(tempC);
                        share3 += tempC;
                        payable(bidders[_tokenID][i]).transfer(
                            offerBalances[_tokenID][bidders[_tokenID][i]]
                        );
                        offerBalances[_tokenID][bidders[_tokenID][i]] = 0;
                        delete bade[_tokenID][bidders[_tokenID][i]];
                    }
                }

                payable(revenueRecipient).transfer(share1);
                payable(royalty[_tokenID].nft_originator).transfer(share2);
                uint256 tempD = bid.nft_value - share1 - share2 - share3;
                payable(offer.nft_seller).transfer(tempD);
            }
            offerBalances[_tokenID][bid.nft_bidder] = 0;
            delete bade[_tokenID][bid.nft_bidder];
            delete bidders[_tokenID];

            ERC721Like(NFTasset).transferFrom(
                address(this),
                bid.nft_bidder,
                _tokenID
            );
            emit Bought(
                offer.nft_seller,
                bid.nft_bidder,
                _tokenID,
                bid.nft_value,
                offer.nft_paymentToken
            );
        } else {
            ERC721Like(NFTasset).transferFrom(
                address(this),
                offer.nft_seller,
                _tokenID
            );
            emit AuctionPass(_tokenID);
        }
        delete AssetForSale[_tokenID];
        delete AssetBids[_tokenID];
    }

    function recoveryEth(uint256 _amount) external onlyOwner {
        payable(tOwner).transfer(_amount);
    }

    receive() external payable {}
}
