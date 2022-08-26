"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: Offer
// Description: Simple Offer Reach App
// Author: Nicholas Shellabarger
// Version: 1.0.0 - offer initial
// Requires Reach v0.1.11-rc7 or later
// ----------------------------------------------

// CONSTS

const SERIAL_VER = 0; // serial version of reach app reserved to release identical contracts under a separate plana id

const FEE_MIN_ACCEPT = 0;
const FEE_MIN_CONSTRUCT = 0;
const FEE_MIN_RELAY = 0;

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
        creator: Address, // address of creator
        offerTtl: UInt, // timeout in seconds
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
  /*closed*/ Bool,
  /*who*/ Address,
  /*creator*/ Address,
  /*royaltyCents*/ UInt
);

const STATE_OFFER = 3;
const STATE_CLOSED = 4;
const STATE_WHO = 5;
const STATE_ROYAlTY_CENTS = 7;

export const Views = () => [
  View({
    state: State,
  }),
];

export const Api = () => [
  API({
    getOffer: Fun([UInt], Null),
    acceptOffer: Fun([UInt], Null),
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
      offerTtl,
    } = declassify(interact.getParams());
  });

  // Step 1

  Offerer.publish(
    tokenAmount,
    offer,
    acceptFee,
    constructFee,
    relayFee,
    creator,
    offerTtl
  )
    .check(() => {
      check(offer > 0, "Offer must be greater than 0");
      check(tokenAmount > 0, "Token amount must be greater than 0");
      check(acceptFee > FEE_MIN_ACCEPT, "Accept fee must be greater than 0");
      check(
        constructFee > FEE_MIN_CONSTRUCT,
        "Construct fee must be greater than 0"
      );
      check(relayFee > FEE_MIN_RELAY, "Relay fee must be greater than 0");
    })
    .pay([amt + offer + (constructFee + acceptFee + relayFee) + SERIAL_VER])
    .timeout(relativeTime(ttl), () => {
      // Step 2
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
    /*closed*/ false,
    /*who*/ Offerer,
    /*creator*/ creator,
    /*royalty*/ 0,
  ];

  // Step 5

  const [state, who] = parallelReduce([initialState, Offerer])
    .define(() => {
      v.state.set(state);
    })
    .invariant(balance(token) == 0, "token balance accurate")
    .invariant(
      implies(!state[STATE_CLOSED], balance() == state[STATE_OFFER] + acceptFee + relayFee),
      "balance accurate before closed"
    )
    .invariant(
      implies(state[STATE_CLOSED], balance() == relayFee),
      "balance accurate after closed"
    )
    .while(!state[STATE_CLOSED])
    .paySpec([token])
    // API get offer
    // - allow manager to upgrade offer
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
    // API accept offer
    // - allow token holder to accept offer
    .api_(a.acceptOffer, (msg) => {
      check(msg >= 0, "Royalty must be greater than or equal to 0");
      check(msg <= 99, "Royalty must be less than or equal to 99");
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
              Tuple.set(state, STATE_CLOSED, true),
              STATE_ROYAlTY_CENTS,
              msg
            ),
            this,
          ];
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
            Tuple.set(Tuple.set(state, STATE_CLOSED, true), STATE_OFFER, 0),
            this,
          ];
        },
      ];
    })
    .timeout(false);
  /*
    // allow offer ttl
    .timeout(relativeTime(offerTtl), () => {
      Relay.only(() => {
        const rAddr = this;
      });
      Relay.publish(rAddr);
      transfer(relayFee).to(rAddr);
      transfer(state[STATE_OFFER]+acceptFee).to(Offerer);
      return [state, who];
    });
    */
   v.state.set(Tuple.set(state, STATE_WHO, who));
  commit();
  Relay.only(() => {
    const rAddr = this;
  });

  // Step 4

  Relay.publish(rAddr); // Anybody can participate as the relay
  transfer(relayFee).to(rAddr);
  commit();
  exit();
};
// ----------------------------------------------
