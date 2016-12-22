-module(block).
-export([hash/1,check2/1,test/0,mine_test/0,genesis/0,make/3,mine/2,height/1,accounts/1,channels/1,accounts_hash/1,channels_hash/1,save/1,absorb/1,read/1,binary_to_file/1]).
-record(block, {height, prev_hash, txs, channels, accounts, mines_block, time, difficulty}).%tries: txs, channels, census, 
-record(block_plus, {block, accounts, channels, accumulative_difficulty = 0}).%The accounts and channels in this structure only matter for the local node. they are pointers to the locations in memory that are the root locations of the account and channel tries on this node.
%prev_hash is the hash of the previous block.
%this gets wrapped in a signature and then wrapped in a pow.
channels(Block) ->
    Block#block_plus.channels.
channels_hash(BP) when is_record(BP, block_plus) ->
    channels_hash(BP#block_plus.block);
channels_hash(Block) -> Block#block.channels.
accounts(BP) ->
    BP#block_plus.accounts.
accounts_hash(BP) when is_record(BP, block_plus) ->
    accounts_hash(BP#block_plus.block);
accounts_hash(Block) ->
    Block#block.accounts.
height(BP) when is_record(BP, block_plus) ->
    height(BP#block_plus.block);
height(Block) when is_record(Block, block)->
    Block#block.height;
height(X) ->
    io:fwrite("error. should be a block, "),
    io:fwrite(X).

hash(BP) when is_record(BP, block_plus) ->
    hash(BP#block_plus.block);
hash(Block) ->
    B2 = term_to_binary(Block),
    hash:doit(B2).

time_now() ->
    (os:system_time() div (1000000 * constants:time_units())) - 1480952170.
genesis() ->
    Address = constants:master_address(),
    ID = 1,
    First = account:new(ID, Address, constants:initial_coins(), 0),
    Accounts = account:write(0, First),
    AccRoot = account:root_hash(Accounts),
    ChaRoot = trie:root_hash(channels, 0),
    Block = 
	#block{height = 0,
	       txs = [],
	       channels = ChaRoot,
	       accounts = AccRoot,
	       mines_block = <<"9zpTqk93izqvN76Z">>,
	       time = 0,
	       difficulty = constants:initial_difficulty()},
    #block_plus{block = Block, channels = 0, accounts = Accounts}.
make(PrevHash, Txs, ID) ->%ID is the user who gets rewarded for mining this block.
    ParentPlus = read(PrevHash),
    Parent = ParentPlus#block_plus.block,
    Height = Parent#block.height + 1,
    {NewChannels, NewAccounts} = 
	txs:digest(Txs, 
		   ParentPlus#block_plus.channels, 
		   ParentPlus#block_plus.accounts,
		   Height),
    CHash = trie:root_hash(channels, NewChannels),
    AHash = account:root_hash(NewAccounts),
    NextDifficulty = next_difficulty(PrevHash),
    #block_plus{
       block = 
	   #block{height = Height,
		  prev_hash = PrevHash,
		  txs = Txs,
		  channels = CHash,
		  accounts = AHash,
		  mines_block = ID,
		  time = time_now()-5,
		  difficulty = NextDifficulty},
       accumulative_difficulty = next_acc(ParentPlus, NextDifficulty),
       channels = NewChannels, 
       accounts = NewAccounts
      }.
next_acc(Parent, ND) ->
    Parent#block_plus.accumulative_difficulty + pow:sci2int(ND).
    %We need to reward the miner for his POW.
    %We need to reward the miner the sum of transaction fees.
mine(Block, Times) ->
    Difficulty = Block#block.difficulty,
    pow:pow(Block, Difficulty, Times).

next_difficulty(PrevHash) ->
    ParentPlus = read(PrevHash),
    Parent = ParentPlus#block_plus.block,
    Height = Parent#block.height + 1,
    RF = constants:retarget_frequency(),
    X = Height rem RF,
    OldDiff = Parent#block.difficulty,
    if
	Height < (RF+1) -> OldDiff;
	X == 0 -> retarget(PrevHash, Parent#block.difficulty);
	true ->  OldDiff
    end.
median(L) ->
    S = length(L),
    F = fun(A, B) -> A > B end,
    Sorted = lists:sort(F, L),
    lists:nth(S div 2, Sorted).
    
retarget(PrevHash, Difficulty) ->    
    F = constants:retarget_frequency() div 2,
    {Times1, Hash2000} = retarget2(PrevHash, F, []),
    {Times2, _} = retarget2(Hash2000, F, []),
    M1 = median(Times1),
    M2 = median(Times2),
    Tbig = M1 - M2,
    T = Tbig div F,
    %io:fwrite([Ratio, Difficulty]),%10/2, 4096
    ND = pow:recalculate(Difficulty, constants:block_time(), T),
    max(ND, constants:initial_difficulty()).
retarget2(Hash, 0, L) -> {L, Hash};
retarget2(Hash, N, L) -> 
    BP = read(Hash),
    B = BP#block_plus.block,
    T = B#block.time,
    H = B#block.prev_hash,
    retarget2(H, N-1, [T|L]).
   
check1(PowBlock) -> 
    %check1 makes no assumption about the parent's existance.
    Block = pow:data(PowBlock),
    Difficulty = Block#block.difficulty,
    true = Difficulty > constants:initial_difficulty(),
    pow:above_min(PowBlock, Difficulty),
 
    true = Block#block.time < time_now(),
    {hash(Block), Block#block.prev_hash}.


check2(Block) ->%this is a different function than absorb because we don't want to do any POW for tests. We want to test this code to make sure it works.
    %check that the time is later than the median of the last 100 blocks.

    %check2 assumes that the parent is in the database already.
    %Block = pow:data(PowBlock),
    Difficulty = Block#block.difficulty,
    PH = Block#block.prev_hash,
    Difficulty = next_difficulty(PH),
    %pow:above_min(PowBlock, Difficulty),
   
    PrevPlus = read(PH),
    Prev = PrevPlus#block_plus.block,
    true = (Block#block.height-1) == Prev#block.height,
    %true = Block#block.time < time_now(),
    {CH, AH} = {Block#block.channels, Block#block.accounts},
    {CR, AR} = txs:digest(Block#block.txs, 
		   PrevPlus#block_plus.channels,
		   PrevPlus#block_plus.accounts,
		   Block#block.height),
    CH = trie:root_hash(channels, CR),
    AH = account:root_hash(AR),
    #block_plus{block = Block, channels = CR, accounts = AR, accumulative_difficulty = next_acc(PrevPlus, Block#block.difficulty)}.



%next_difficulty(_Block) ->
    %take the median time on the last 2000 blocks, subtract it from the current time, divide by 1000. This is the current blockrate. Adjust the difficulty to make the rate better.
%    constants:initial_difficulty().
absorb(PowBlock) ->
    Block = pow:data(PowBlock),
    BH = hash(Block),
    false = block_hashes:check(BH),%If we have seen this block before, then don't process it again.
    block_hashes:add(BH),%Don't waste time checking invalid blocks more than once.
    check1(PowBlock),
    BlockPlus = check2(Block),
    save(BlockPlus),
    top:add(Block).
binary_to_file(B) ->
    C = base58:binary_to_base58(B),
    H = C,
    "blocks/"++H++".db".
read(Hash) ->
    BF = binary_to_file(Hash),
    Z = db:read(BF),
    binary_to_term(zlib:uncompress(Z)).
save(BlockPlus) ->
    Block = BlockPlus#block_plus.block,
    Z = zlib:compress(term_to_binary(BlockPlus)),
    Hash = hash(Block),
    BF = binary_to_file(hash(Block)),
    db:save(BF, Z),
    Hash.


test() ->
    block:read(top:doit()),
    PH = top:doit(),
    BP = read(PH),
    Accounts = BP#block_plus.accounts,
    _ = account:get(1, Accounts),
    {block_plus, Block, _, _, _} = make(PH, [], 1),
    check2(Block),
    success.
mine_test() ->
    PH = top:doit(),
    {block_plus, Block, _, _, _} = make(PH, [], 1),
    PBlock = mine(Block, 1000000000),
    absorb(PBlock),
    mine_blocks(10),
    success.
    
mine_blocks(0) -> success;
mine_blocks(N) -> 
    io:fwrite("mining block "),
    io:fwrite(integer_to_list(N)),
    io:fwrite(" time "),
    io:fwrite(integer_to_list(time_now())),
    io:fwrite(" diff "),
    
    PH = top:doit(),
    %BP = read(PH),
    {block_plus, Block, _, _} = make(PH, [], 1),
    io:fwrite(integer_to_list(Block#block.difficulty)),
    io:fwrite("\n"),
    PBlock = mine(Block, 1000000000),
    absorb(PBlock),
    mine_blocks(N-1).
