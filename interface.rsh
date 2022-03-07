"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: Interface Template
// Description: NP Rapp simple
// Author: Nicholas Shellabarger
// Version: 0.1.0 - offer initial
// Requires Reach v0.1.7 (stable)
// ----------------------------------------------
export const Participants = () => [
  Participant("Offerer", {
    getParams: Fun(
      [],
      Object({
        token: Token, // token id
        tokenAmount: UInt, // token amount in case not dec0
        offer: UInt, // initial offer amount
      })
    ),
    signal: Fun([], Null),
  }),
  Participant("Relay", {}),
];
export const Views = () => [
  View({
    token: Token,
    highestBidder: Address,
    currentPrice: UInt,
    closed: Bool,
  }),
];
export const Api = () => [
  API({
    getOffer: Fun([UInt], Null),
    acceptOffer: Fun([UInt], Null),
    retractOffer: Fun([], Null),
    close: Fun([], Null),
  }),
];
export const App = (map) => {
  const [
    {
      addr: creatorAddr, // address to send royalties
      addr2: platformAddr, // address to send fees
      amt: getOfferFee, // api fee i
      amt2: acceptOfferFee, // api fee ii
      amt3: retractOfferFee, // api fee iii
      amt4: closeFee, // api fee iv
    },
    [Offerer, Relay],
    [v],
    [a],
  ] = map;
  Offerer.only(() => {
    const { token, tokenAmount, offer } = declassify(interact.getParams());
    assume(offer > 0);
    assume(tokenAmount > 0);
  });
  Offerer.publish(token, tokenAmount, offer);
  require(offer > 0);
  require(tokenAmount > 0);
  Offerer.only(() => interact.signal());
  v.token.set(token);
  const [keepGoing, highestBidder, currentPrice] = parallelReduce([
    true,
    Offerer,
    offer,
  ])
    .define(() => {
      v.highestBidder.set(highestBidder);
      v.currentPrice.set(currentPrice);
    })
    .invariant(balance() >= 0)
    .while(keepGoing)
    .paySpec([token])
    // API get offer
    // - allow offer upgrades
    .api(
      a.getOffer,
      (msg) => assume(true && msg > currentPrice),
      (msg) => [msg + getOfferFee, [tokenAmount, token]],
      (msg, k) => {
        require(true && msg > currentPrice);
        transfer(currentPrice).to(highestBidder);
        k(null);
        return [true, this, msg];
      }
    )
    // API accept offer
    // - allow token holder to accept offer
    .api(
      a.acceptOffer,
      (msg) => assume(true && currentPrice > 0 && msg >= 0 && msg <= 99),
      (_) => [acceptOfferFee, [tokenAmount, token]],
      (msg, k) => {
        require(true && currentPrice > 0 && msg >= 0 && msg <= 99);
        k(null);
        const cent = balance() / 100;
        const platformAmount = cent;
        const royaltyAmount = msg * cent; // Royalties
        const recvAmount = balance() - (platformAmount + royaltyAmount);
        transfer(recvAmount).to(this);
        transfer(royaltyAmount).to(creatorAddr);
        transfer([[balance(token), token]]).to(highestBidder);
        return [false, highestBidder, currentPrice];
      }
    )
    // API retract offer
    // - the current offer holder can cancel
    .api(
      a.retractOffer,
      () => assume(true && this == highestBidder && currentPrice > 0),
      () => [retractOfferFee, [0, token]],
      (k) => {
        require(true && this == highestBidder && currentPrice > 0);
        k(null);
        transfer(balance()).to(highestBidder);
        return [true, this, 0];
      }
    )
    // API close
    // - anybody can close offer contract for 1 ALGO
    .api(
      a.close,
      () => assume(true && currentPrice == 0),
      () => [closeFee, [0, token]], // discourage meddling
      (k) => {
        require(true && currentPrice == 0);
        k(null);
        return [false, this, 0];
      }
    )
    .timeout(false);
  v.closed.set(true); // Set View Closed
  commit();
  Relay.publish(); // Anybody can participate as the relay
  transfer(balance()).to(platformAddr);
  transfer(balance(token), token).to(platformAddr);
  commit();
  exit();
};
// ----------------------------------------------
