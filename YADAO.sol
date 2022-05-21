// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.0.0/contracts/token/ERC721/ERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.0.0/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
//import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.0.0/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
 

    struct Member { 
        address member;
        uint256 activationDate;
        uint256 memberId;
        uint32 reputation;
        uint32 loyalty;
        uint32 voteWeight;
        uint32 numTokens;
        uint32 numProposals;
        uint32 numAcceptedProposals;
        uint32 numVotes;
        uint8 roles; //Bitmap of roles
        bool isContract;
        bool isRemoved;
        // uint256 subject = hash of address + salt.
        // extend or prune as required
    }

    uint8 constant MAX_PROPOSALS = 10;

    struct ProposalAction {
        address contractSelector;
        address addr;
        uint genericUint; //updaters will check range and downcast
        bytes32 genericBytes;
        Member member;
        bytes4 functionSelector;
        bool decision;
        uint8 proposalID; //Must link back to the Proposal Control record.
    }

    // Up to 8 roles (as bit masks)
    uint8 constant DAO_MEMBER = 1;
    uint8 constant DAO_ARTIST = 2;
    uint8 constant DAO_STEWARD  = 4;

/*
interface IYADAO_NFT {
    // function _transfer() internal override; // overide - in implementation
    struct NFTAttributes {
       string media1;
       string media2;
       string media3;
       uint8[64] attributes;
    }
    function setDAOAddress() external;
    function getAttributes()external;
}
*/

interface IYADAO {
 
    function mint(address _to, string calldata _url) external returns (uint256);
    function transferNotification(address from, address to)external;
    function memberCount() external view returns (uint32);
    function memberInfo(address _member) external view returns (Member memory);

    function isGated(Member calldata _member, uint _platform) external view returns(bool);

    // Proposal management.
    function createProposal(bytes32 _name, uint8 _proposalNumber, uint256 _deadline, uint8 _threshold, uint8 _quorum) external;
    function execProposal(uint8 _proposalNumber) external;

    // Proposal argument types
    // _selector - the modifier function selector
    // _v - the typed argument to be supplied to the selected modifier fundtion
    function propose( bytes4 _selector, bytes32 _v, uint8 _proposalControl )external;
    function propose( bytes4 _selector, bool _v, uint8 _proposalControl) external;
    function propose( bytes4 _selector, uint256 _v, uint8 _proposalControl) external;
    function propose( bytes4 _selector,address  _v, uint8 _proposalControl) external;
    function propose(bytes4 __selector, Member calldata _v, uint8 _proposalControl)external;

    // proposal execution functions - must check eligibility to exectute and re-validate arguments.
    function removeMember(ProposalAction calldata)external;
    function setMember(ProposalAction calldata)external;
    function setLoyaltyStrategy(ProposalAction calldata)external;
    function setReputationStratey(ProposalAction calldata)external;
    function setVoteStratey(ProposalAction calldata)external;
//    function setRoyaltyStrategy(ProposalAction calldata)external;
//    function setRoleRoyalty(ProposalAction calldata)external;
//    function setRoyaltySplitter(ProposalAction calldata)external;
    function setSelectorControl(ProposalAction calldata)external;
    function addProposalType(ProposalAction calldata)external;

}

interface IYADAO_VoteCalculator {
    function calcVote(Member calldata _member) external view returns (uint32);
}
/*
interface IYADAO_Royalties{ // is IERC2981  
    function allocateFunds(address _token, uint256 _value)external; // Address 0 is ETH
    function claimFunds(address _claimant)external view returns(address[] memory _tokens, uint256[] memory _values); 
    function claimAll() external view returns(address[] memory _tokens, uint256[] memory _values);
    function addMemberRoles(address _member, uint32 _role) external; //first role creates the member.
    function removeMemberRoles(address _member, uint32 _roles) external; //when member has no roles, they are removed.
    function royaltyInfo (uint256 _tokenId, uint256 _value) external view returns (address _receiver, uint256 _amount);
}
*/

interface IYADAO_Vault {
    function getTotal() external view returns ( uint256 _value);
//    function getTotalRoyalties() external view returns (uint256 _value);
    function sendFunds(address payable _member, uint256 _amount) external payable;
}

interface IYADAO_ReputationCalculator{
    function calcReputation(Member calldata) external view returns (uint32);
}

interface IYADAO_LoyaltyCalculator{
    function calcLoyalty(Member calldata) external view returns (uint32);
}

// this is a DAO contract thatimplements all the interfaces, but they can be replaces
abstract contract YADAO_implementation is 
    IYADAO,
    ERC721, 
    ERC721URIStorage, 
    //IERC2981; TODO - need to add royalties.
    IYADAO_VoteCalculator,
    IYADAO_LoyaltyCalculator, 
    IYADAO_ReputationCalculator, 
    // IYADAO_Royalties,
    IYADAO_Vault {

    IYADAO_VoteCalculator _voteCalculator;
    IYADAO_LoyaltyCalculator _loyaltyCalculator;
    IYADAO_ReputationCalculator _reputationCalculator;
    IYADAO_Vault _vault;
//    IYADAO_Royalties _royaltyContract;

    mapping (address => Member) memberMap;

    struct InternalVault {
        address token;
        uint256 value;
    }

    uint256 _internalVaultValue;
    
    
    uint256 _nextTokenId = 0;
    uint32 _memberCount = 0;

    event voteResult(bytes32 _name, uint32 _for, uint32 _against, uint32 _extraInfo);

    struct Proposal {
        bytes32 name;
        address proposer;
        uint256 deadline;
        uint32 votesFor;
        uint32 votesAgainst;
        uint8 threshold; //percentage of votes
        uint8 quorum;    //percentage of members
    }
    mapping (uint32 => bool)[] memberIdVotes;
    ProposalAction[][] proposalActions;

    bool private _internalCall = false;

    mapping (uint8 => Proposal) proposalMap; //propose must find a free proposal
    uint8 numProposals = 0; //number of active proposals.
    struct SelectorControl{
        address contractSelector;
        uint8 quorum; //members
        uint8 threshold;
        uint8 delay; //hours
    }

    mapping (bytes4 =>  SelectorControl) selectorControlMap;
// function selectors.
    bytes4 constant _removeMember = bytes4(keccak256("removeMember(ProposalAction calldata)"));
    bytes4 constant _setMember = bytes4(keccak256("setMember(ProposalAction calldata)"));
    bytes4 constant _setLoyaltyStrategy = bytes4(keccak256("setLoyaltyStrategy(ProposalAction calldata)"));
    bytes4 constant _setRepuationStrategy = bytes4(keccak256("setReputationStrategy(ProposalAction calldata)"));
    bytes4 constant _setVoteStrategy = bytes4(keccak256("setVoteStrategy(ProposalAction calldata)"));
//    bytes4 constant _setRoyaltyStrategy = bytes4(keccak256("setRoyaltyStrategy(ProposalAction calldata)"));
//    bytes4 constant _setRoleRoyalty = bytes4(keccak256("setRoleRoyalty(ProposalAction calldata)"));
//    bytes4 constant _setRoyaltySplitter = bytes4(keccak256("setRoyaltySplitter(ProposalAction calldata)"));
    bytes4 constant _setSelectorControl = bytes4(keccak256("setSelectorControl(ProposalAction calldata)"));
    bytes4 constant _addProposalType = bytes4(keccak256("addProposalType(ProposalAction calldata)"));

    constructor() ERC721("YADAO_Token", "YADAO") {

        // initialise the selectorControl map.
        selectorControlMap[_removeMember] = SelectorControl(address(this), 25, 50, 48);
        selectorControlMap[_setMember] = SelectorControl(address(this), 25, 50, 48);
        selectorControlMap[_setLoyaltyStrategy] = SelectorControl(address(this), 25, 50, 48);
        selectorControlMap[_setRepuationStrategy] = SelectorControl(address(this), 25, 50, 48);
        selectorControlMap[_setVoteStrategy] = SelectorControl(address(this), 25, 50, 48);
//      selectorControlMap[_setRoyaltyStrategy] = SelectorControl(address(this), 25, 50, 48);
//      selectorControlMap[_setRoleRoyalty] = SelectorControl(address(this), 25, 50, 48);
        selectorControlMap[_setSelectorControl] = SelectorControl(address(this), 25, 50, 48);
        selectorControlMap[_addProposalType] = SelectorControl(address(this), 25, 50, 48);        
    }

    function _senderHasRole (uint8 roles) internal view returns (bool){
        return((memberMap[msg.sender].roles & roles) ==0);
    }

    // from  interface IYADAO_voteCalculator 
    function calcVote(Member calldata _member) public override view returns (uint32) {
        return(_voteCalculator != IYADAO_VoteCalculator(address(0))? IYADAO_VoteCalculator(_voteCalculator).calcVote(_member):calcVote(_member));
    }
    function _calcVote(Member memory _member) private pure returns (uint32){
        return(_member.voteWeight+_member.numTokens + _member.loyalty + _member.reputation);
    }

/*
    // from interface IYADAO_Royalties {
    function setRoyaltyContract(address _contract)public  {
        require(_internalCall, "YADAO: Illegal call");
        _royaltyContract = IYADAO_Royalties(_contract);
    }
    function allocateFunds(address _token, uint256 _value)public override  {
        require(_internalCall, "YADAO: Illegal call");
        if (_royaltyContract == IYADAO_Royalties(address(0)){
            _vault

        } else {
                IYADAO_Royalties(_royaltyContract).allocateFunds(_token, _value)


        }
    }

    function claimFunds(address _claimant)public view override returns(address[] memory _tokens, uint256[] memory _values) {
        require(_internalCall, "YADAO: Illegal call");
        uint a=100;        
    } 

    function claimAll() public view override returns(address[] memory _tokens, uint256[] memory _values) {
        require(_internalCall, "YADAO: Illegal call");
        uint a=100;
    }
    function addMemberRoles(address _member, uint32 _role) public override { //first role creates the member.
        require(_internalCall, "YADAO: Illegal call");
        uint a=100;
        }
        
    function removeMemberRoles(address _member, uint32 _roles) public override{ //when member has no roles, they are removed.
        require(_internalCall, "YADAO: Illegal call");
        uint a=100;
    }

    function royaltyInfo (uint256 _tokenId, uint256 _value) public view override returns (address, uint256){
        require(_internalCall, "YADAO: Illegal call");
        uint a=100;
    }
*/

    //from interface IYADAO_vault {
    function getTotal() public view override returns (uint256 _value){
            return(_vault == IYADAO_Vault(address(0))? IYADAO_Vault(_vault).getTotal():_getTotal());
    }

    function _getTotal() private view returns (uint256 _value){
        return(_internalVaultValue);
    }

    function sendFunds(address payable _member, uint256 _amount) public payable override{

        _vault == IYADAO_Vault(address(0))? IYADAO_Vault(_vault).sendFunds(_member, _amount):_sendFunds(_member, _amount);
    }
    function _sendFunds(address payable _member, uint256 _amount) public {
        require (_amount <= _internalVaultValue, "YADAO: too much");
        _member.transfer(_amount); //send ETH
    }

    // from interface IYADAO_reputationCalculator{
    function calcReputation(Member memory _member) public view override returns (uint32){
        return(_reputationCalculator == IYADAO_ReputationCalculator(address(0))? IYADAO_ReputationCalculator(_reputationCalculator).calcReputation(_member):_calcReputation(_member));
    }

    function _calcReputation(Member memory _member) private pure returns(uint32){
        return(_member.numProposals*4 +_member.numAcceptedProposals*8 + _member.numVotes);
    }


    //from interface IYADAO_loyaltyCalculator{
    function calcLoyalty(Member memory _member) public view override returns (uint32){
        return(_loyaltyCalculator == IYADAO_LoyaltyCalculator(address(0))? IYADAO_LoyaltyCalculator(_loyaltyCalculator).calcLoyalty(_member):_calcLoyalty(_member));
    }

    function _calcLoyalty(Member memory _member) private pure returns(uint32){
        return(uint32(_member.activationDate/(60*60*24*30)) + _member.numVotes); // time in months + votes.
    }


    function _updateCounters(address _member) internal {
        // update member reputation
        memberMap[_member].reputation = calcReputation(memberMap[_member]);

        // update member loyalty
        memberMap[_member].loyalty = calcLoyalty(memberMap[_member]);
    }


    function mint(address _to,  string calldata _url) public override returns (uint256){
        require ( _senderHasRole(DAO_STEWARD|DAO_ARTIST), "YADAO:insufficient privilege");

        _safeMint(_to, _nextTokenId, "");

        // TODO set the URL!!!
        string memory url;
        url = _url;

        if (memberMap[_to].activationDate == 0 ){
            memberMap[_to] =Member(_to, block.timestamp, ++_memberCount, 0,0,0,1,0,0,0,DAO_MEMBER, false, false);
        }else{
            memberMap[_to].numTokens++;
        }
        _updateCounters(_to);

        return(_nextTokenId);
    }

    function _transfer (address _from, address _to, uint256 _tokenId) internal override {
        super._transfer(_from, _to, _tokenId);
        // TODO -- how do we know the transfer succeeded?
        // TODO -- do we even need to test if we are a member?
        // if _from is a member then reduce the count
        if (memberMap[_from].numTokens >0) {
            --memberMap[_from].numTokens;
            _updateCounters(_from);  //TODO surely update both coounters
        }

        // if destination is a member in decrement tokens
        if (memberMap[_to].numTokens >0){
            memberMap[_to].numTokens++;
            _updateCounters(_to);
        }
    }


// BUT NFT == DAO. so this should be inside the _transfer functipon.
// AND if the NFT knows that it needs to do this, it must be friends with the DAO.
    function transferNotification( address _from, address _to)public override {

        // if _from is a member then reduce the count
        if (memberMap[_to].numTokens >0) {
            memberMap[_to].numTokens++;
            _updateCounters(_to);
        }

        // if destination is a member in decrement tokens
        if (memberMap[_from].numTokens >0){
            memberMap[_from].numTokens--;
            _updateCounters(_to);
        }
    }

    function memberCount() public view override returns (uint32){
          return _memberCount;
    }

    function memberInfo(address _member) public view override  returns (Member memory){
        return memberMap[_member];
    }

    function isGated(Member calldata _member, uint _platform) public view override returns(bool){

    }

    // Proposal management.

   
    // Proposer needs to pick an unused proposal slot (0 - 255)
    function createProposal(bytes32 _name, uint8 _proposalNumber, uint256 _deadline, uint8 _threshold, uint8 _quorum) public override {
        // REMOVE? require (_proposalNumber < 255, "YADAU: Proposal number too large");
        require(numProposals < 10, "YADAO: Too many concurrent proposals");
        require (proposalMap[_proposalNumber].proposer == address(0), "YADAO: Proposal in progress");
        require (memberMap[msg.sender].memberId == 0, "YADAO: Not a member");
        require (_threshold <=100 && _quorum <= 100, "YADAO: Not percentage");

        proposalMap[_proposalNumber] = Proposal(_name, msg.sender, _deadline,0, 0, _threshold, _quorum );
        numProposals++;
    }

    function execProposal(uint8 _proposalNumber) public override{
        //execute the function
        require(proposalMap[_proposalNumber].deadline <= block.timestamp, "YADAO_Too early" );
        // TODO require(proposals[proposalNumber].votesFor + proposals[proposalNumber].votesAgainst < proposals[proposalNumber].quorum,
        // "YADAO: No quorum" );
        uint16 carried = 0;
        if(proposalMap[_proposalNumber].votesFor > proposalMap[_proposalNumber].votesAgainst*(proposalMap[_proposalNumber].threshold/100)){
            _internalCall = true;
            for (uint8 i=0; i<proposalActions[_proposalNumber].length;i++) {
                //call proposal selector with proposal action
                (bool success, ) = address(this).call(abi.encodeWithSelector(
                    proposalActions[_proposalNumber][i].functionSelector, 
                    proposalActions[_proposalNumber][i]));
                require(success, "YADAO: Propasal error");
            }
            carried = 10000;
            _internalCall = false;
        }
        emit voteResult(proposalMap[_proposalNumber].name,
            proposalMap[_proposalNumber].votesFor,
            proposalMap[_proposalNumber].votesAgainst, 
            proposalMap[_proposalNumber].threshold*100 + proposalMap[_proposalNumber].quorum + carried);
        delete proposalMap[_proposalNumber];
        --numProposals;
    }

    // Proposal argument types - overloads for each argument type supported
    // first argument is the function selector
    // Action (_v) is appended to the list for execution.
    function propose( bytes4 _selector, bytes32 _v, uint8 _proposalNumber )public override{
        require (proposalMap[_proposalNumber].proposer == msg.sender, "YADAO: Not proposer");
        // Already tested in createProposal? require (memberMap[msg.sender].memberId == 0, "YADAO: Not a member");
        require (proposalActions[_proposalNumber].length < 10, "YADAO: Too many actions");
        proposalActions[_proposalNumber].push(ProposalAction(selectorControlMap[_selector].contractSelector, 
        address(0), 0,_v, Member(address(0),0,0, 0,0,0,0,0,0,0,0, true, true), _selector, true,_proposalNumber));
    }
     address contractSelector;
        address addr;
        uint genericUint; //updaters will check range and downcast
        bytes32 genericBytes;
        Member member;
        bytes4 functionSelector;
        bool decision;
        uint8 proposalID; //Must link back to the Proposal Control record.
   
    //
    // TODO - add the ability to add another proposal type?????? - a contract address and a selctor.
    //       would need to whitelist the contract and selectors.... using a proposal?
    //
    function propose( bytes4 _selector, bool _v, uint8 _proposalNumber) public override{
        require (proposalMap[_proposalNumber].proposer == msg.sender, "YADAO: Not proposer");
        require (proposalActions[_proposalNumber].length < 10, "YADAO: Too many actions");
        // require - whitelist _selector
        proposalActions[_proposalNumber].push(ProposalAction(selectorControlMap[_selector].contractSelector, 
        address(0), 0,"", Member(address(0),0,0, 0,0,0,0,0,0,0,0, true, true), _selector, _v,_proposalNumber));
    }

    function propose( bytes4 _selector, uint256 _v, uint8 _proposalNumber) public override{
        require (proposalMap[_proposalNumber].proposer == msg.sender, "YADAO: Not proposer");
        require (proposalActions[_proposalNumber].length < 10, "YADAO: Too many actions");
        // require - whitelist _selector
        proposalActions[_proposalNumber].push(ProposalAction(selectorControlMap[_selector].contractSelector, 
        address(0),_v, "", Member(address(0),0,0,0,0,0,0,0,0,0,0,true,true), _selector, true,_proposalNumber));
    }

    function propose( bytes4 _selector,address  _v, uint8 _proposalNumber) public override{
        require (proposalMap[_proposalNumber].proposer == msg.sender, "YADAO: Not proposer");
        require (proposalActions[_proposalNumber].length < 10, "YADAO: Too many actions");
        // require - whitelist _selector
        proposalActions[_proposalNumber].push(ProposalAction(selectorControlMap[_selector].contractSelector,
        _v,0, "",  Member(address(0),0,0,0,0,0,0,0,0,0,0,true,true), _selector, true,_proposalNumber));
    }

    function propose(bytes4 _selector, Member calldata _v, uint8 _proposalNumber)public override{
        require (proposalMap[_proposalNumber].proposer == msg.sender, "YADAO: Not proposer");
        require (proposalActions[_proposalNumber].length < 10, "YADAO: Too many actions");
        // require - whitelist _selector
        proposalActions[_proposalNumber].push(ProposalAction(selectorControlMap[_selector].contractSelector, 
        address(0), 0, "",  _v, _selector, true,_proposalNumber));
    }


    // proposal execution functions - must check eligibility to exectute and re-validate arguments.
    function removeMember(ProposalAction calldata _action) public override {
        require(_internalCall, "YADAO: Illegal call");
        delete memberMap[_action.member.member];
        _memberCount--;
    }

    function setMember(ProposalAction calldata _action)public override {
        require(_internalCall, "YADAO: Illegal call");
        if (memberMap[_action.member.member].activationDate == 0){
        _memberCount++;
        }memberMap[_action.member.member] = _action.member;
    }

    function setLoyaltyStrategy(ProposalAction calldata _action )public override {
        require(_internalCall, "YADAO:: Illegal call");
        _loyaltyCalculator = IYADAO_LoyaltyCalculator(_action.addr);
    }

    function setReputationStratey(ProposalAction calldata _action)public override {
        require(_internalCall, "YADAO: Ilegal call");
        _reputationCalculator = IYADAO_ReputationCalculator(_action.addr);
    }

    function setVoteStratey(ProposalAction calldata _action)public override {
        require(_internalCall, "YADAO: Illegal call");
        _voteCalculator = IYADAO_VoteCalculator(_action.addr);
    }

/*
    function setRoyaltyContract(ProposalAction calldata _action)public {
        require(_internalCall, "YADAO: Illegal call");
        _royaltyContract = IYADAO_Royalties(_action.addr);
    }

    function setRoleRoyalty(ProposalAction calldata _action)public override {
        require(_internalCall, "YADAO: Illegal call");
        _royaltyContract.allocateFunds(_action.addr, _action.genericUint); // each utint16. alternately represent Role & royalty basepoint.
    }
*/
    function setSelectorControl(ProposalAction calldata _action)public override {
        require(_internalCall, "YADAO: Illegal call");
        require(selectorControlMap[bytes4(_action.genericBytes)].quorum !=0,"YADAO: Bad selector");
        require(_action.genericUint >> 32 & 0xFF == 0, "YADAO: no quorum"); // 8 bits
        require(_action.genericUint >> 40 & 0xFF == 0, "YADAO: no threshold"); //8 bits
        require(_action.genericUint >> 48 & 0xFFFFFFFF>= 60*60*60*48, "YADAO: Delay < 48 hours"); // top 32 bits in seconds

        selectorControlMap[bytes4(_action.genericBytes)].quorum = uint8(_action.genericUint >> 32 & 0xFF);
        selectorControlMap[bytes4(_action.genericBytes)].threshold = uint8(_action.genericUint >> 40 & 0xFF);
        selectorControlMap[bytes4(_action.genericBytes)].delay = uint8(_action.genericUint >> 48 & 0xFF);
    }

    fallback() external payable {
        _internalVaultValue += msg.value;
    }

    receive() external payable {
        _internalVaultValue+= msg.value;
    }


    // The following functions are overrides required by Solidity.

    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
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

}
