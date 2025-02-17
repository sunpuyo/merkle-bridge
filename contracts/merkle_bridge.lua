------------------------------------------------------------------------------
-- Merkle bridge contract
------------------------------------------------------------------------------

-- Internal type check function
-- @type internal
-- @param x variable to check
-- @param t (string) expected type
local function _typecheck(x, t)
  if (x and t == 'address') then
    assert(type(x) == 'string', "address must be string type")
    -- check address length
    assert(52 == #x, string.format("invalid address length: %s (%s)", x, #x))
    -- check character
    local invalidChar = string.match(x, '[^123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz]')
    assert(nil == invalidChar, string.format("invalid address format: %s contains invalid char %s", x, invalidChar or 'nil'))
  elseif (x and t == 'ubig') then
    -- check unsigned bignum
    assert(bignum.isbignum(x), string.format("invalid type: %s != %s", type(x), t))
    assert(x >= bignum.number(0), string.format("%s must be positive number", bignum.tostring(x)))
  else
    -- check default lua types
    assert(type(x) == t, string.format("invalid type: %s != %s", type(x), t or 'nil'))
  end
end

-- Stores latest finalised state root of connected blockchain at regular intervals.
-- Enables Users to verify state information of the connected chain 
-- using merkle proofs for the finalised state root.
state.var {
    -- Trie root of the opposit side bridge contract. _mints and _unlocks require a merkle proof
    -- of state inclusion in this last Root.
    -- (0x hex string)
    _anchorRoot = state.value(),
    -- Height of the last block anchored
    _anchorHeight = state.value(),

    -- _tAnchor is the anchoring periode of the bridge
    -- (uint)
    _tAnchor = state.value(),
    -- _tFinal is the time after which the bridge operator consideres a block finalised
    -- this value is only useful if the anchored chain doesn't have LIB.
    -- (uint)
    _tFinal = state.value(),
    -- oracle that controls this bridge.
    _oracle = state.value(),

    -- Registers locked balances per account reference: user provides merkle proof of locked balance
    -- (account ref string) -> (string uint)
    _locks = state.map(),
    -- Registers unlocked balances per account reference: prevents unlocking more than was burnt
    -- (account ref string) -> (string uint)
    _unlocks = state.map(),
    -- Registers burnt balances per account reference : user provides merkle proof of burnt balance
    -- (account ref string) -> (string uint)
    _burns = state.map(),
    -- Registers minted balances per account reference : prevents minting more than what was locked
    -- (account ref string) -> (string uint)
    _mints = state.map(),
    -- Registers freezed balances per account reference : user provides merkle proof of locked balance
    -- (account ref string) -> (string uint)
    _freezes = state.map(),
    -- Registers unfreezed balances per account reference : prevents unfreezing more than was locked
    -- (account ref string) -> (string uint)
    _unfreezes = state.map(),
    -- _bridgeTokens keeps track of tokens that were received through the bridge
    -- (address) -> (address)
    _bridgeTokens = state.map(),
    -- _mintedTokens is the same as _bridgeTokens but keys and values are swapped
    -- _mintedTokens is used for preventing a minted token from being locked instead of burnt.
    -- (address) -> (address)
    _mintedTokens = state.map(),
}


--------------------- Utility Functions -------------------------

local function _onlyOracle()
    assert(system.getSender() == _oracle:get(), string.format("Only oracle can call, expected: %s, got: %s", _oracle:get(), system.getSender()))
end

-- check if the ith bit is set in hex string bytes
-- @type    query
-- @param   bits (hex string) hex string without 0x
-- @param   i (uint) index of bit to check
-- @return  (bool) true if ith bit is 1
function bitIsSet(bits, i)
    require "bit"
    -- get the hex byte containing ith bit
    local byteIndex = math.floor(i/8)*2 + 1
    local byteHex = string.sub(bits, byteIndex, byteIndex + 1)
    local byte = tonumber(byteHex, 16)
    return bit.band(byte, bit.lshift(1,7-i%8)) ~= 0
end

-- compute the merkle proof verification
-- @type    query
-- @param   ap ([] hex string without 0x) merkle proof nodes (audit path)
-- @param   keyIndex (uint) step counter in merkle proof iteration
-- @param   key (hex string) key for which the merkle proof is created
-- @param   leafHash (hex string) value stored in the smt
-- @return  (0x hex string) hash of the smt root with given merkle proof
function verifyProof(key, leafHash, ap, keyIndex)
    if keyIndex == #ap then
        return leafHash
    end
    if bitIsSet(key, keyIndex) then
        local right = verifyProof(key, leafHash, ap, keyIndex+1)
        return crypto.sha256("0x"..ap[#ap-keyIndex]..string.sub(right, 3))
    end
    local left = verifyProof(key, leafHash, ap, keyIndex+1)
    return crypto.sha256(left..ap[#ap-keyIndex])
end

-- We dont need to use compressed merkle proofs in lua because byte(0) is easilly 
-- passed in the merkle proof array.
-- (In solidity, only bytes32[] is supported, so byte(0) cannot be passed and it is
-- more efficient to use a compressed proof)
-- @type    query
-- @param   ap ([] hex string without 0x) merkle proof nodes (audit path)
-- @param   mapName (string) name of mapping variable
-- @param   key (string) key stored in mapName
-- @param   value (string) value of key in mapName
-- @return  (bool) merkle proof of inclusion is valid
function verifyDepositProof(mapName, key, value, root, ap)
    local varId = "_sv_" .. mapName .. "-" .. key
    local trieKey = crypto.sha256(varId)
    local trieValue = crypto.sha256(value)
    local leafHash = crypto.sha256(trieKey..string.sub(trieValue, 3)..string.format('%02x', 256-#ap))
    return root == verifyProof(string.sub(trieKey, 3), leafHash, ap, 0)
end

-- deploy new contract
-- @type    internal
-- @param   tokenOrigin (address) address of token locked used as pegged token name
local function _deployMintableToken(tokenOrigin)
    addr, success = contract.deploy(mintedToken, tokenOrigin)
    assert(success, "failed to create peg token contract")
    return addr
end

-- lock tokens in the bridge contract
-- @type    internal
-- @param   tokenAddress (address) token locked
-- @param   amount (ubig) amount of tokens to send
-- @param   receiver (address) receiver accross the bridge
-- @event   lock(receiver, amount, tokenAddress)
local function _lock(tokenAddress, amount, receiver)
    _typecheck(receiver, 'address')
    _typecheck(amount, 'ubig')
    assert(_mintedTokens[tokenAddress] == nil, "this token was minted by the bridge so it should be burnt to transfer back to origin, not locked")
    assert(amount > bignum.number(0), "amount must be positive")

    -- Add locked amount to total
    local accountRef = receiver .. tokenAddress
    local old = _locks[accountRef]
    local lockedBalance
    if old == nil then
        lockedBalance = amount
    else
        lockedBalance = bignum.number(old) + amount
    end
    _locks[accountRef] = bignum.tostring(lockedBalance)
    contract.event("lock", receiver, amount, tokenAddress)
end

-- Create a new bridge contract
-- @type    __init__
-- @param   tAnchor (uint) anchoring periode
-- @param   tFinal (uint) finality of anchored chain
function constructor(tAnchor, tFinal)
    _tAnchor:set(tAnchor)
    _tFinal:set(tFinal)
    _anchorRoot:set("constructor")
    _anchorHeight:set(0)
    -- the oracle is set to the sender who must transfer ownership to oracle contract
    -- with oracleUpdate(), once deployed
    _oracle:set(system.getSender())
end

--------------------- Bridge Operator Functions -------------------------

function default()
  contract.event("initializeVault", system.getSender(), system.getAmount())
  -- needed to send the vault funds when starting the bridge
  -- consider disabling after 1st transfer so users don't send 
  -- funds by mistake
end

-- Replace the oracle with another one
-- @type    call
-- @param   newOracle (address) Aergo address of the new oracle
-- @event   oracleUpdate(proposer, newOracle)
function oracleUpdate(newOracle)
    _onlyOracle()
    _oracle:set(newOracle)
    contract.event("oracleUpdate", system.getSender(), newOracle)
end

-- Register a new anchor
-- @type    call
-- @param   root (0x hex string) bytes of Aergo storage root
-- @param   height (uint) block height of root
-- @event   newAnchor(proposer, height, root)
function newAnchor(root, height)
    _onlyOracle()
    -- check Height to prevent spamming and leave minimum time for users to make transfers.
    assert(height > _anchorHeight:get() + _tAnchor:get(), "Next anchor height not reached")
    _anchorRoot:set(root)
    _anchorHeight:set(height)
    contract.event("newAnchor", system.getSender(), height, root)
end

-- Register new anchoring periode
-- @type    call
-- @param   tAnchor (uint) new anchoring periode
-- @event   tAnchorUpdate(proposer, tAnchor)
function tAnchorUpdate(tAnchor)
    _onlyOracle()
    _tAnchor:set(tAnchor)
    contract.event("tAnchorUpdate", system.getSender(), tAnchor)
end

-- Register new finality of anchored chain
-- @type    call
-- @param   tFinal (uint) new finality of anchored chain
-- @event   tFinalUpdate(proposer, tFinal)
function tFinalUpdate(tFinal)
    _onlyOracle()
    _tFinal:set(tFinal)
    contract.event("tFinalUpdate", system.getSender(), tFinal)
end

--------------------- User Transfer Functions -------------------------

-- The ARC1 smart contract calls this function on the recipient after a 'transfer'
-- @type    call
-- @param   operator    (address) the address which called token 'transfer' function
-- @param   from        (address) the sender's address
-- @param   value       (ubig) an amount of token to send
-- @param   receiver    (address) receiver accross the bridge
function tokensReceived(operator, from, value, receiver)
    return _lock(system.getSender(), value, receiver)
end

-- mint a token locked on a bridged chain
-- anybody can mint, the receiver is the account who's locked balance is recorded
-- @type    call
-- @param   receiver (address) designated receiver in lock
-- @param   balance (ubig) total balance of tokens locked
-- @param   tokenOrigin (address) token locked address on origin
-- @param   merkleProof ([]hex string without 0x) merkle proof of inclusion of locked balance
-- @return  (address, uint) pegged token Aergo address, minted amount
-- @event   mint(minter, receiver, amount, tokenOrigin)
function mint(receiver, balance, tokenOrigin, merkleProof)
    _typecheck(receiver, 'address')
    _typecheck(balance, 'ubig')
    _typecheck(tokenOrigin, 'address')
    assert(balance > bignum.number(0), "mintable balance must be positive")

    -- Verify merkle proof of locked balance
    local accountRef = receiver .. tokenOrigin
    local balanceStr = "\""..bignum.tostring(balance).."\""
    if not verifyDepositProof("_locks", accountRef, balanceStr, _anchorRoot:get(), merkleProof) then
        error("failed to verify deposit balance merkle proof")
    end
    -- Calculate amount to mint
    local amountToTransfer
    mintedSoFar = _mints[accountRef]
    if mintedSoFar == nil then
        amountToTransfer = balance
    else
        amountToTransfer  = balance - bignum.number(mintedSoFar)
    end
    assert(amountToTransfer > bignum.number(0), "make a deposit before minting")
    -- Deploy or get the minted token
    local mintAddress
    if _bridgeTokens[tokenOrigin] == nil then
        -- Deploy new mintable token controlled by bridge
        mintAddress = _deployMintableToken(tokenOrigin)
        _bridgeTokens[tokenOrigin] = mintAddress
        _mintedTokens[mintAddress] = tokenOrigin
    else
        mintAddress = _bridgeTokens[tokenOrigin]
    end
    -- Record total amount minted
    _mints[accountRef] = bignum.tostring(balance)
    -- Mint tokens
    contract.call(mintAddress, "mint", receiver, amountToTransfer)
    contract.event("mint", system.getSender(), receiver, amountToTransfer, tokenOrigin)
    return mintAddress, amountToTransfer
end

-- burn a pegged token
-- @type    call
-- @param   receiver (address) receiver accross the bridge
-- @param   amount (ubig) number of tokens to burn
-- @param   mintAddress (address) pegged token to burn
-- @return  (address) origin token to be unlocked
-- @event   brun(owner, receiver, amount, mintAddress)
function burn(receiver, amount, mintAddress)
    _typecheck(receiver, 'address')
    _typecheck(amount, 'ubig')
    assert(amount > bignum.number(0), "amount must be positive")
    local originAddress = _mintedTokens[mintAddress]
    assert(originAddress ~= nil, "cannot burn token : must have been minted by bridge")
    -- Add burnt amount to total
    local accountRef = receiver .. originAddress
    local old = _burns[accountRef]
    local burntBalance
    if old == nil then
        burntBalance = amount
    else
        burntBalance = bignum.number(old) + amount
    end
    _burns[accountRef] = bignum.tostring(burntBalance)
    -- Burn token
    contract.call(mintAddress, "burn", system.getSender(), amount)
    contract.event("burn", system.getSender(), receiver, amount, mintAddress)
    return originAddress
end

-- unlock tokens
-- anybody can unlock, the receiver is the account who's burnt balance is recorded
-- @type    call
-- @param   receiver (address) designated receiver in burn
-- @param   balance (ubig) total balance of tokens burnt
-- @param   tokenAddress (address) token to unlock
-- @param   merkleProof ([]hex string without 0x) merkle proof of inclusion of burnt balance
-- @return  (uint) unlocked amount
-- @event   unlock(unlocker, receiver, amount, tokenAddress)
function unlock(receiver, balance, tokenAddress, merkleProof)
    _typecheck(receiver, 'address')
    _typecheck(tokenAddress, 'address')
    _typecheck(balance, 'ubig')
    assert(balance > bignum.number(0), "unlockable balance must be positive")

    -- Verify merkle proof of burnt balance
    local accountRef = receiver .. tokenAddress
    local balanceStr = "\""..bignum.tostring(balance).."\""
    if not verifyDepositProof("_burns", accountRef, balanceStr, _anchorRoot:get(), merkleProof) then
        error("failed to verify burnt balance merkle proof")
    end

    -- Calculate amount to unlock
    local unlockedSoFar = _unlocks[accountRef]
    local amountToTransfer
    if unlockedSoFar == nil then
        amountToTransfer = balance
    else
        amountToTransfer = balance - bignum.number(unlockedSoFar)
    end
    assert(amountToTransfer > bignum.number(0), "burn minted tokens before unlocking")

    -- Record total amount unlocked so far
    _unlocks[accountRef] = bignum.tostring(balance)

    -- Unlock tokens
    contract.call(tokenAddress, "transfer", receiver, amountToTransfer)
    contract.event("unlock", system.getSender(), receiver, amountToTransfer, tokenAddress)
    return amountToTransfer
end

-- freeze mainnet aergo
-- @type    call
-- @param   receiver (address) Aergo address of receiver
-- @param   amount (ubig) number of aergo to freeze
-- @event   freeze(owner, receiver, amount)
function freeze(receiver, amount)
  _typecheck(receiver, 'address')
  _typecheck(amount, 'ubig')
  -- passing amount is not necessary but system.getAmount() would have to be converted to bignum anyway.
  assert(amount > bignum.number(0), "amount must be positive")
  assert(system.getAmount() == bignum.tostring(amount), "for safety and clarity, amount must match the amount sent in the tx")

  -- Add freezed amount to total
  local accountRef = receiver
  local old = _freezes[accountRef]
  local freezedBalance
  if old == nil then
      freezedBalance = amount
  else
      freezedBalance = bignum.number(old) + amount
  end
  _freezes[accountRef] = bignum.tostring(freezedBalance)
  contract.event("freeze", system.getSender(), receiver, amount)
end


-- unfreeze mainnet aergo
-- anybody can unfreeze, the receiver is the account who's burnt balance is recorded
-- @type    call
-- @param   receiver (address) Aergo address of receiver
-- @param   balance (ubig) total balance of aergo locked on another network
-- @param   merkleProof ([]hex string without 0x) merkle proof of inclusion of freezed balance
-- @return  (uint) unfreezed amount
-- @event   unfreeze(unfreezer, receiver, amount)
function unfreeze(receiver, balance, merkleProof)
  _typecheck(receiver, 'address')
  _typecheck(balance, 'ubig')
  assert(balance > bignum.number(0), "unfreezable balance must be positive")

  -- Verify merkle proof of freezed balance
  local accountRef = receiver
  local balanceStr = "\""..bignum.tostring(balance).."\""
  if not verifyDepositProof("_freezes", accountRef, balanceStr, _anchorRoot:get(), merkleProof) then
      error("failed to verify freezed balance merkle proof")
  end

  -- Calculate amount to unfreeze
  local unfreezedSoFar = _unfreezes[accountRef]
  local amountToTransfer
  if unfreezedSoFar == nil then
      amountToTransfer = balance
  else
      amountToTransfer = balance - bignum.number(unfreezedSoFar)
  end
  assert(amountToTransfer > bignum.number(0), "freeze Aergo on another network before unfreezing")
  -- Record total amount unlocked so far
  _unfreezes[accountRef] = bignum.tostring(balance)
  -- Unfreeze Aer
  contract.send(receiver, amountToTransfer)
  
  contract.event("unfreeze", system.getSender(), receiver, amountToTransfer)
  return amountToTransfer
end

mintedToken = [[
------------------------------------------------------------------------------
-- Aergo Standard Token Interface (Proposal) - 20190731
------------------------------------------------------------------------------

-- A internal type check function
-- @type internal
-- @param x variable to check
-- @param t (string) expected type
local function _typecheck(x, t)
  if (x and t == 'address') then
    assert(type(x) == 'string', "address must be string type")
    -- check address length
    assert(52 == #x, string.format("invalid address length: %s (%s)", x, #x))
    -- check character
    local invalidChar = string.match(x, '[^123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz]')
    assert(nil == invalidChar, string.format("invalid address format: %s contains invalid char %s", x, invalidChar or 'nil'))
  elseif (x and t == 'ubig') then
    -- check unsigned bignum
    assert(bignum.isbignum(x), string.format("invalid type: %s != %s", type(x), t))
    assert(x >= bignum.number(0), string.format("%s must be positive number", bignum.tostring(x)))
  else
    -- check default lua types
    assert(type(x) == t, string.format("invalid type: %s != %s", type(x), t or 'nil'))
  end
end

address0 = '1111111111111111111111111111111111111111111111111111'

-- The bridge token is a mintable and burnable token controlled by
-- the bridge contract. It represents tokens pegged on the other side of the 
-- bridge with a 1:1 ratio.
-- This contract is depoyed by the merkle bridge when a new type of token 
-- is transfered
state.var {
    _balances = state.map(), -- address -> unsigned_bignum
    _operators = state.map(), -- address/address -> bool

    _totalSupply = state.value(),
    _name = state.value(),
    _symbol = state.value(),
    _decimals = state.value(),

    _master = state.value(),
}

local function _callTokensReceived(from, to, value, ...)
  if to ~= address0 and system.isContract(to) then
    contract.call(to, "tokensReceived", system.getSender(), from, value, ...)
  end
end

local function _transfer(from, to, value, ...)
  _typecheck(from, 'address')
  _typecheck(to, 'address')
  _typecheck(value, 'ubig')

  assert(_balances[from] and _balances[from] >= value, "not enough balance")

  _balances[from] = _balances[from] - value
  _balances[to] = (_balances[to] or bignum.number(0)) + value

  _callTokensReceived(from, to, value, ...)

  contract.event("transfer", from, to, value)
end

local function _mint(to, value, ...)
  _typecheck(to, 'address')
  _typecheck(value, 'ubig')

  _totalSupply:set((_totalSupply:get() or bignum.number(0)) + value)
  _balances[to] = (_balances[to] or bignum.number(0)) + value

  _callTokensReceived(address0, to, value, ...)

  contract.event("transfer", address0, to, value)
end

local function _burn(from, value)
  _typecheck(from, 'address')
  _typecheck(value, 'ubig')

  assert(_balances[from] and _balances[from] >= value, "not enough balance")

  _totalSupply:set(_totalSupply:get() - value)
  _balances[from] = _balances[from] - value

  contract.event("transfer", from, address0, value)
end

-- call this at constructor
local function _init(name, symbol, decimals)
  _typecheck(name, 'string')

  _name:set(name)
  _symbol:set(symbol)
  _decimals:set(decimals)
end

------------  Main Functions ------------

-- Get a total token supply.
-- @type    query
-- @return  (ubig) total supply of this token
function totalSupply()
  return _totalSupply:get()
end

-- Get a token name
-- @type    query
-- @return  (string) name of this token
function name()
  return _name:get()
end

-- Get a token symbol
-- @type    query
-- @return  (string) symbol of this token
function symbol()
  return _symbol:get()
end

-- Get a token decimals
-- @type    query
-- @return  (number) decimals of this token
function decimals()
  return _decimals:get()
end

-- Get a balance of an owner.
-- @type    query
-- @param   owner  (address) a target address
-- @return  (ubig) balance of owner
function balanceOf(owner)
  return _balances[owner] or bignum.number(0)
end

-- Transfer sender's token to target 'to'
-- @type    call
-- @param   to      (address) a target address
-- @param   value   (ubig) an amount of token to send
-- @param   ...     addtional data, MUST be sent unaltered in call to 'tokensReceived' on 'to'
-- @event   transfer(from, to, value)
function transfer(to, value, ...)
  _transfer(system.getSender(), to, value, ...)
end

-- Get allowance from owner to spender
-- @type    query
-- @param   owner       (address) owner's address
-- @param   operator    (address) allowed address
-- @return  (bool) true/false
function isApprovedForAll(owner, operator)
  return (owner == operator) or (_operators[owner.."/".. operator] == true)
end

-- Allow operator to use all sender's token
-- @type    call
-- @param   operator  (address) a operator's address
-- @param   approved  (boolean) true/false
-- @event   approve(owner, operator, approved)
function setApprovalForAll(operator, approved)
  _typecheck(operator, 'address')
  _typecheck(approved, 'boolean')
  assert(system.getSender() ~= operator, "cannot set approve self as operator")

  _operators[system.getSender().."/".. operator] = approved

  contract.event("approve", system.getSender(), operator, approved)
end

-- Transfer 'from's token to target 'to'.
-- Tx sender have to be approved to spend from 'from'
-- @type    call
-- @param   from    (address) a sender's address
-- @param   to      (address) a receiver's address
-- @param   value   (ubig) an amount of token to send
-- @param   ...     addtional data, MUST be sent unaltered in call to 'tokensReceived' on 'to'
-- @event   transfer(from, to, value)
function transferFrom(from, to, value, ...)
  assert(isApprovedForAll(from, system.getSender()), "caller is not approved for holder")

  _transfer(from, to, value, ...)
end

-------------- Merkle Bridge functions -----------------
--------------------------------------------------------

-- Mint tokens to 'to'
-- @type        call
-- @param to    a target address
-- @param value string amount of token to mint
-- @return      success
function mint(to, value)
    assert(system.getSender() == _master:get(), "Only bridge contract can mint")
    _mint(to, value)
end

-- burn the tokens of 'from'
-- @type        call
-- @param from  a target address
-- @param value an amount of token to send
-- @return      success
function burn(from, value)
    assert(system.getSender() == _master:get(), "Only bridge contract can burn")
    _burn(from, value)
end

--------------- Custom constructor ---------------------
--------------------------------------------------------
function constructor(originAddress) 
    _init(originAddress, "PEG", "Query decimals at token origin")
    _totalSupply:set(bignum.number(0))
    _master:set(system.getSender())
    return true
end
--------------------------------------------------------

abi.register(transfer, transferFrom, setApprovalForAll, mint, burn)
abi.register_view(name, symbol, decimals, totalSupply, balanceOf, isApprovedForAll)


]]

abi.register(bitIsSet, verifyProof, verifyDepositProof, oracleUpdate, newAnchor, tAnchorUpdate, tFinalUpdate, tokensReceived, mint, burn, unlock, unfreeze)
abi.payable(freeze, default)