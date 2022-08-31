"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: Offer
// Description: Simple Offer Reach App
// Author: Nicholas Shellabarger
// Version: 1.1.0 - add offer target and ttl
// Requires Reach v0.1.11-rc7 (27cb9643) or later
// ----------------------------------------------

// CONSTS

const SERIAL_VER = 0; // serial version of reach app reserved to release identical contracts under a separate plana id

const FEE_MIN_ACCEPT = 6000;
const FEE_MIN_CONSTRUCT = 4000;
const FEE_MIN_RELAY = 5000;
const FEE_MIN_TIMEOUT = 3000;

export const Event = () => [];

export const Participants = () => [
  Participant("Offerer", {
    getParams: Fun(
      [],
      Object({
        tokenAmount: UInt, // token amount in case not dec0
        offer: UInt, // initial offer amount
        acceptFee: UInt, // fee for accepting offer
        constructFee: UInt, // fee for construction
        relayFee: UInt, // fee for relaying
        timeoutFee: UInt, // fee for timeout
        creator: Address, // address of creator
        offerEndTime: UInt, // timeout in seconds
        offerTarget: Address, // address of offer target
      })
    ),
    signal: Fun([], Null),
  }),
  ParticipantClass("Relay", {}),
];

const State = Tuple(
  /*manger*/ Address,
  /*token*/ Token,
  /*tokenAmount*/ UInt,
  /*offer*/ UInt,
  /*counterOffer*/ UInt,
  /*closed*/ Bool,
  /*who*/ Address,
  /*creator*/ Address,
  /*royaltyCents*/ UInt,
  /*offerEndTime*/ UInt
);

const STATE_OFFER = 3;
const STATE_COUNTER_OFFER = 4;
const STATE_CLOSED = 5;
const STATE_WHO = 6;
const STATE_ROYAlTY_CENTS = 8;

export const Views = () => [
  View({
    state: State,
  }),
];

export const Api = () => [
  API({
    getOffer: Fun([UInt], Null),
    getTarget: Fun([Address], Null),
    acceptOffer: Fun([UInt], Null),
    rejectOffer: Fun([], Null),
    counterOffer: Fun([UInt], Null),
    cancel: Fun([], Null),
  }),
];
export const App = (map) => {
  const [{ amt, ttl, tok0: token }, [addr, _], [Offerer, Relay], [v], [a], _] =
    map;

  Offerer.only(() => {
    const {
      tokenAmount,
      offer,
      creator,
      acceptFee,
      constructFee,
      relayFee,
      timeoutFee,
      offerEndTime,
      offerTarget,
    } = declassify(interact.getParams());
  });
  // Step
  Offerer.publish(
    tokenAmount,
    offer,
    acceptFee,
    constructFee,
    relayFee,
    timeoutFee,
    creator,
    offerEndTime,
    offerTarget
  )
    .check(() => {
      check(offer > 0, "Offer must be greater than 0");
      check(tokenAmount > 0, "Token amount must be greater than 0");
      check(
        acceptFee >= FEE_MIN_ACCEPT,
        "Accept fee must be greater than minimum"
      );
      check(
        constructFee >= FEE_MIN_CONSTRUCT,
        "Construct fee must be greater than minimum"
      );
      check(
        relayFee >= FEE_MIN_RELAY,
        "Relay fee must be greater than minimum"
      );
      check(
        timeoutFee >= FEE_MIN_TIMEOUT,
        "Timeout fee must be greater than minimum"
      );
    })
    .pay([
      amt +
        offer +
        (constructFee + acceptFee + relayFee + timeoutFee) +
        SERIAL_VER,
    ])
    .timeout(relativeTime(ttl), () => {
      // Step
      Anybody.publish();
      commit();
      exit();
    });
  transfer(amt + constructFee + SERIAL_VER).to(addr);

  Offerer.interact.signal();

  const initialState = [
    /*manger*/ Offerer,
    /*token*/ token,
    /*tokenAmount*/ tokenAmount,
    /*offer*/ offer,
    /*counterOffer*/ 0,
    /*closed*/ false,
    /*who*/ offerTarget,
    /*creator*/ creator,
    /*royalty*/ 0,
    /*offerTtl*/ offerEndTime,
  ];
  // Step
  const [state, who] = parallelReduce([initialState, Offerer])
    .define(() => {
      v.state.set(state);
    })
    .invariant(balance(token) == 0, "token balance accurate")
    .invariant(
      implies(
        !state[STATE_CLOSED],
        balance() == state[STATE_OFFER] + acceptFee + relayFee + timeoutFee
      ),
      "balance accurate before closed"
    )
    .invariant(
      implies(state[STATE_CLOSED], balance() == relayFee + timeoutFee),
      "balance accurate after closed"
    )
    .while(!state[STATE_CLOSED])
    .paySpec([token])
    // API get offer
    // - allow manager to upgrade offer amount
    .api_(a.getOffer, (msg) => {
      check(this === Offerer, "Offer must be made by Offerer");
      check(msg > 0, "Offer must be greater than 0");
      return [
        [msg, [0, token]],
        (k) => {
          k(null);
          return [Tuple.set(state, STATE_OFFER, state[STATE_OFFER] + msg), who];
        },
      ];
    })
    // API get target
    // - allow manager to update offer target
    .api_(a.getTarget, (msg) => {
      check(this === Offerer, "Offer target must be modified by Offerer");
      return [
        [0, [0, token]],
        (k) => {
          k(null);
          return [
            Tuple.set(Tuple.set(state, STATE_WHO, msg), STATE_COUNTER_OFFER, 0),
            who,
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
        state[STATE_WHO] == Offerer || state[STATE_WHO] === this,
        "Offer must be accepted by offer target"
      );
      return [
        [0, [tokenAmount, token]],
        (k) => {
          k(null);
          const cent = state[STATE_OFFER] / 100;
          const platformAmount = cent;
          const royaltyAmount = msg * cent; // Royalties
          const recvAmount =
            state[STATE_OFFER] - (platformAmount + royaltyAmount);
          transfer(recvAmount + acceptFee).to(this);
          transfer(royaltyAmount).to(creator);
          transfer(platformAmount).to(addr);
          transfer([[tokenAmount, token]]).to(Offerer);
          return [
            Tuple.set(
              Tuple.set(state, STATE_CLOSED, true), // closes
              STATE_ROYAlTY_CENTS,
              msg
            ),
            this,
          ];
        },
      ];
    })
    // API reject
    // - allow target to reject offer
    // - rejector must reimburse offerer for activation costs
    .api_(a.rejectOffer, () => {
      check(this != Offerer, "Offer must not be rejected by oferer");
      check(state[STATE_WHO] == this, "Offer must be rejected by offer target");
      return [
        [amt + constructFee + SERIAL_VER, [0, token]],
        (k) => {
          k(null);
          transfer(
            state[STATE_OFFER] + acceptFee + amt + constructFee + SERIAL_VER
          ).to(Offerer);
          return [Tuple.set(state, STATE_CLOSED, true), who]; // closes
        },
      ];
    })
    // API counter
    // - allow target to counter offer
    .api_(a.counterOffer, (msg) => {
      check(this != Offerer, "Counter offer must not be made by offerer");
      check(state[STATE_WHO] == this, "Counter offer must be made by target");
      check(
        msg > state[STATE_COUNTER_OFFER],
        "Counter offer must be greater than previous offer"
      );
      return [
        [0, [0, token]],
        (k) => {
          k(null);
          return [Tuple.set(state, STATE_COUNTER_OFFER, msg), who];
        },
      ];
    })
    // API close
    // - manager can close offer contract
    .api_(a.cancel, () => {
      check(this == Offerer, "Offer may only be cancelled by Offerer");
      return [
        (k) => {
          k(null);
          transfer(state[STATE_OFFER] + acceptFee).to(this);
          return [
            Tuple.set(Tuple.set(state, STATE_CLOSED, true), STATE_OFFER, 0), // closes
            this,
          ];
        },
      ];
    })
    // allow offer ttl
    .timeout(absoluteTime(offerEndTime), () => {
      // Step
      Relay.publish();
      transfer(state[STATE_OFFER] + acceptFee).to(Offerer);
      return [
        Tuple.set(Tuple.set(state, STATE_CLOSED, true), STATE_OFFER, 0), // closes
        Offerer,
      ];
    });
  v.state.set(Tuple.set(state, STATE_WHO, who));
  commit();
  Relay.only(() => {
    const rAddr = this;
  });
  // Step
  Relay.publish(rAddr); // Anybody can participate as the relay
  transfer(relayFee + timeoutFee).to(rAddr);
  commit();
  exit();
};
// ----------------------------------------------
