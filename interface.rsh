"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: Offer
// Description: Simple Offer Reach App
// Author: Nicholas Shellabarger
// Version: 1.1.2 - use base
// Requires Reach v0.1.11-rc7 (27cb9643) or later
// ----------------------------------------------

import {
  State as BaseState,
  Params as BaseParams,
  view
} from "@KinnFoundation/base#base-v0.1.11r1:interface.rsh";

// CONSTANTS

const SERIAL_VER = 0;

// TYPES

export const OfferState = Struct([
  ["token", Token],
  ["tokenAmount", UInt],
  ["offer", UInt],
  ["counterOffer", UInt],
  ["who", Address],
  ["creator", Address],
  ["royaltyCents", UInt],
  ["offerEndTime", UInt],
]);

export const State = Struct([
  ...Struct.fields(BaseState),
  ...Struct.fields(OfferState),
]);

export const OfferParams = Object({
  tokenAmount: UInt, // token amount in case not dec0
  creator: Address, // address of creator
  offer: UInt, // initial offer amount
  offerEndTime: UInt, // timeout in seconds
  offerTarget: Address, // address of offer target
});

export const Params = Object({
  ...Object.fields(BaseParams),
  ...Object.fields(OfferParams),
});

// FUN

const fState = (State) => Fun([], State);
const fGetOffer = Fun([UInt], Null);
const fGetTarget = Fun([Address], Null);
const fAcceptOffer = Fun([UInt], Null);
const fRejectOffer = Fun([], Null);
const fCounterOffer = Fun([UInt], Null);
const fCancel = Fun([], Null);

// REMOTE FUN

export const rState = (ctc, State) => {
  const r = remote(ctc, { state: fState(State) });
  return r.state();
};

export const rAcceptOffer = (ctc) => {
  const r = remote(ctc, { acceptOffer: fAcceptOffer });
  return r.acceptOffer();
};

// API

export const api = {
  getOffer: fGetOffer,
  getTarget: fGetTarget,
  acceptOffer: fAcceptOffer,
  rejectOffer: fRejectOffer,
  counterOffer: fCounterOffer,
  cancel: fCancel,
};

// CONTRACT

export const Event = () => [Events({ appLaunch: [] })];

export const Participants = () => [
  Participant("Manager", {
    getParams: Fun([], Params),
  }),
  Participant("Relay", {}),
];

export const Views = () => [View(view(State))];

export const Api = () => [API(api)];

export const App = (map) => {
  const [
    { amt, ttl, tok0: token },
    [addr, _],
    [Manager, Relay],
    [v],
    [a],
    [e],
  ] = map;

  Manager.only(() => {
    const { tokenAmount, offer, creator, offerEndTime, offerTarget } =
      declassify(interact.getParams());
  });
  Manager.publish(tokenAmount, offer, creator, offerEndTime, offerTarget)
    .check(() => {
      check(offer > 0, "Offer must be greater than 0");
      check(tokenAmount > 0, "Token amount must be greater than 0");
    })
    .pay([amt + SERIAL_VER + offer])
    .timeout(relativeTime(ttl), () => {
      Anybody.publish();
      commit();
      exit();
    });
  transfer(amt + SERIAL_VER).to(addr);

  e.appLaunch();

  const initialState = {
    manager: Manager,
    token,
    tokenAmount,
    offer,
    counterOffer: 0,
    closed: false,
    who: Manager,
    creator,
    royaltyCents: 0,
    offerEndTime,
  };

  // Step
  const [s] = parallelReduce([initialState])
    .define(() => {
      v.state.set(State.fromObject(s));
    })
    .invariant(balance(token) == 0, "token balance accurate")
    .invariant(
      implies(!s.closed, balance() == s.offer),
      "balance accurate before closed"
    )
    .invariant(
      implies(s.closed, balance() == 0),
      "balance accurate after closed"
    )
    .while(!s.closed)
    .paySpec([token])
    // API get offer
    // - allow manager to upgrade offer amount
    .api_(a.getOffer, (msg) => {
      check(this === s.manager, "Only manager can get offer");
      check(msg > 0, "Offer must be greater than 0");
      return [
        [msg, [0, token]],
        (k) => {
          k(null);
          return [
            {
              ...s,
              offer: s.offer + msg,
            },
          ];
        },
      ];
    })
    // API get target
    // - allow manager to update offer target
    .api_(a.getTarget, (msg) => {
      check(this === s.manager, "Only manager can get target");
      return [
        [0, [0, token]],
        (k) => {
          k(null);
          return [
            {
              ...s,
              who: msg,
              counterOffer: 0,
            },
          ];
        },
      ];
    })
    // API accept offer
    // - allow token holder to accept offer
    .api_(a.acceptOffer, (msg) => {
      check(msg >= 0, "Royalty must be greater than or equal to 0");
      check(msg <= 99, "Royalty must be less than or equal to 99");
      check(
        s.who == s.manager || s.who === this,
        "Offer must be accepted by offer target"
      );
      return [
        [0, [tokenAmount, token]],
        (k) => {
          k(null);
          const cent = s.offer / 100;
          const platformAmount = cent;
          const royaltyAmount = msg * cent; // Royalties
          const recvAmount = s.offer - (platformAmount + royaltyAmount);
          transfer(recvAmount).to(this);
          transfer(royaltyAmount).to(creator);
          transfer(platformAmount).to(addr);
          transfer(tokenAmount, token).to(s.manager);
          return [
            {
              ...s,
              closed: true,
              royaltyCents: msg,
              who: this,
            },
          ];
        },
      ];
    })
    // API reject
    // - allow target to reject offer
    // - rejector must reimburse offerer for activation costs
    .api_(a.rejectOffer, () => {
      check(this != s.manager, "Manager cannot reject offer");
      check(s.who == this, "Offer must be rejected by offer target");
      return [
        [amt + SERIAL_VER, [0, token]],
        (k) => {
          k(null);
          transfer(s.offer + amt + SERIAL_VER).to(s.manager);
          return [
            {
              ...s,
              closed: true,
            },
          ];
        },
      ];
    })
    // API counter
    // - allow target to counter offer
    .api_(a.counterOffer, (msg) => {
      check(this != s.manager, "Manager cannot counter offer");
      check(s.who == this, "Counter offer must be made by target");
      check(
        msg > s.counterOffer,
        "Counter offer must be greater than previous offer"
      );
      return [
        [0, [0, token]],
        (k) => {
          k(null);
          return [
            {
              ...s,
              counterOffer: msg,
            },
          ];
        },
      ];
    })
    // API close
    // - manager can close offer contract
    .api_(a.cancel, () => {
      check(this == s.manager, "Only manager can cancel offer");
      return [
        (k) => {
          k(null);
          transfer(s.offer).to(this);
          return [
            {
              ...s,
              closed: true,
              offer: 0,
              who: this,
            },
          ];
        },
      ];
    })
    .timeout(absoluteTime(offerEndTime), () => {
      Anybody.publish();
      transfer(s.offer).to(s.manager);
      return [
        {
          ...s,
          closed: true,
          offer: 0,
          who: s.manager,
        },
      ];
    });
  commit();
  Relay.publish();
  commit();
  exit();
};
// ----------------------------------------------
