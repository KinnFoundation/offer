'reach 0.1';
'use strict'
// -----------------------------------------------
// Name: ALGO/ETH/CFX NFT Jam Offer Contract
// Author: Nicholas Shellabarger
// Version: 0.0.2 - use utils
// Requires Reach v0.1.6rc1
// -----------------------------------------------
import { 
  constructorInteract,
  relayInteract,
  max,
  construct,
  common
} from 'util.rsh'
export const main = Reach.App(() => {
  const Constructor = Participant('Constructor', constructorInteract)
  const Relay = Participant('Relay', relayInteract)
  const Auctioneer = Participant('Auctioneer', {
    ...common,
    getParams: Fun([], Object({
      token: Token, // NFT token
      creator: Address, // Creator
      offer: UInt // Offer amt
    })),
    signal: Fun([], Null)
  })
  const Bid = API('Bid', {
      getOffer: Fun([UInt], Null ),
      acceptOffer: Fun([UInt], Null ),
      retractOffer: Fun([], Null),
      close: Fun([], Null)
  })
  const Auction = View('Auction', {
    token: Token, 
    highestBidder: Address,
    currentPrice: UInt,
    closed: Bool, 
  })
  init();
  //deploy();

  const { addr, addr2, addr3, addr4 } = construct(Constructor, Relay);

  Auctioneer.only(() => {
    const {
      token, 
      creator,
      offer
    } = declassify(interact.getParams());
    assume(offer > 0)
  })
  Auctioneer
    .publish(
      token,
      creator,
      offer
    )
    .pay(offer+100000) // 0.1 ALGO
  require(offer > 0)

  // transfer fees
  transfer(20000).to(addr) // discovery, 0.02 algo
  transfer(30000).to(addr3) // constructor, 0.03 algo
  transfer(50000).to(addr4) // faucet, 0.05 algo

  Auctioneer.only(() => interact.signal());
  each([Auctioneer], () => interact.log("Start Auction"));
  const [
    keepGoing,
    highestBidder, 
    currentPrice, 
  ] =
    parallelReduce([
      true,
      Auctioneer,
      offer,
    ])
      .define(() => {
        Auction.token.set(token) 
        Auction.highestBidder.set(highestBidder) 
        Auction.currentPrice.set(currentPrice) 
      })
      .invariant(balance() >= 0)
      .while(keepGoing)
      .paySpec([token])
      .api(Bid.getOffer,
        ((msg) => assume(msg > currentPrice)),
        ((msg) => [msg, [0, token]]),
        ((msg, k) => {
          require(msg > currentPrice)
          transfer(currentPrice).to(highestBidder)
          k(null)
          return [
            true,
            this,
            msg, 
          ]
        }))
      .api(Bid.acceptOffer,
        ((msg) => assume(true
          && currentPrice > 0
          && msg >= 0 && msg <= 99
        )),
        ((_) => [0, [1, token]]),
        ((msg, k) => {
          require(true
            && currentPrice > 0
            && msg >= 0 && msg <= 99
          )
          k(null)
          const cent = balance() / 100
          const platformAmount = cent 
          const royaltyAmount = msg * cent // Royalties
          const recvAmount = balance() - (platformAmount + royaltyAmount)
          transfer(recvAmount).to(this)
          transfer(royaltyAmount).to(creator)
          transfer([[balance(token), token]]).to(highestBidder)
          return [
            false,
            highestBidder,
            currentPrice
          ]
        }))
      .api(Bid.retractOffer,
        (() => assume(true
          && this == highestBidder
          && currentPrice > 0
        )),
        (() => [0, [0, token]]),
        ((k) => {
          require(true
            && this == highestBidder
            && currentPrice > 0
          )
          k(null)
          transfer(balance()).to(highestBidder)
          return [
            true,
            Constructor,
            0
          ]
        }))
        .api(Bid.close,
        (() => assume(true
          && this == addr4
          && currentPrice == 0
        )),
        (() => [0, [0, token]]),
        ((k) => {
          require(true
            && this == addr4
            && currentPrice == 0
          )
          k(null)
          return [
            false,
            Constructor,
            0
          ]
        }))  
      .timeout(false)

  Auction.closed.set(true) // Set View Closed

  commit()
  Relay.publish()

  transfer(balance()).to(addr2)
  transfer([[balance(token), token]]).to(addr2)
  commit();
  exit();
  // ---------------------------------------------
});