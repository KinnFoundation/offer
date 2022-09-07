"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: Offer
// Description: Simple Offer Reach App
// Author: Nicholas Shellabarger
// Version: 1.1.1 - use Struct/Object instead of Tuple
// Requires Reach v0.1.11-rc7 (27cb9643) or later
// ----------------------------------------------

// CONSTS

const SERIAL_VER = 0; // serial version of reach app reserved to release identical contracts under a separate plana id

const FEE_MIN_ACCEPT = 6000;
const FEE_MIN_CONSTRUCT = 4000;
const FEE_MIN_RELAY = 5000;
const FEE_MIN_TIMEOUT = 3000;


/*
 * safePercent
 * recommended way of calculating percent of a number
 * where percentPrecision is like 10_000 and percentage is like 500, meaning 5%
 */
const safePercent = (amount, percentage, percentPrecision) =>
  UInt(
    (UInt256(amount) * UInt256(percentPrecision) * UInt256(percentage)) /
      UInt256(percentPrecision)
  );

export const Event = () => [];

const Params = Object({
  tokenAmount: UInt, // token amount in case not dec0
  offer: UInt, // initial offer amount
  acceptFee: UInt, // fee for accepting offer
  constructFee: UInt, // fee for construction
  relayFee: UInt, // fee for relaying
  timeoutFee: UInt, // fee for timeout
  creator: Address, // address of creator
  offerEndTime: UInt, // timeout in seconds
  offerTarget: Address, // address of offer target
});

export const Participants = () => [
  Participant("Offerer", {
    getParams: Fun([], Params),
    signal: Fun([], Null),
  }),
  ParticipantClass("Relay", {}),
];

// TODO consider migrating Tuple to Object when it works in future version if there is nothing wrong with the code
const State = Struct([
  ["manager", Address],
  ["token", Token],
  ["tokenAmount", UInt],
  ["offer", UInt],
  ["counterOffer", UInt],
  ["closed", Bool],
  ["who", Address],
  ["creator", Address],
  ["royaltyCents", UInt],
  ["offerEndTime", UInt],
]);

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

  const initialState = {
    manager: Offerer,
    token,
    tokenAmount,
    offer,
    counterOffer: 0,
    closed: false,
    who: Offerer,
    creator,
    royaltyCents: 0,
    offerEndTime,
  };

  // Step
  const [state] = parallelReduce([initialState])
    .define(() => {
      v.state.set(State.fromObject(state));
    })
    .invariant(balance(token) == 0, "token balance accurate")
    .invariant(
      implies(
        !state.closed,
        balance() == state.offer + acceptFee + relayFee + timeoutFee
      ),
      "balance accurate before closed"
    )
    .invariant(
      implies(state.closed, balance() == relayFee + timeoutFee),
      "balance accurate after closed"
    )
    .while(!state.closed)
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
          return [
            {
              ...state,
              offer: state.offer + msg,
            },
          ];
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
            {
              ...state,
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
        state.who == Offerer || state.who === this,
        "Offer must be accepted by offer target"
      );
      return [
        [0, [tokenAmount, token]],
        (k) => {
          k(null);
          const cent = safePercent(state.offer, 1_000_000, 1_000); // 1%
          const platformAmount = cent;
          const royaltyAmount = msg * cent; // Royalties
          const recvAmount = state.offer - (platformAmount + royaltyAmount);
          transfer(recvAmount + acceptFee).to(this);
          transfer(royaltyAmount).to(creator);
          transfer(platformAmount).to(addr);
          transfer(tokenAmount, token).to(Offerer);
          return [
            {
              ...state,
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
      check(this != Offerer, "Offer must not be rejected by oferer");
      check(state.who == this, "Offer must be rejected by offer target");
      return [
        [amt + constructFee + SERIAL_VER, [0, token]],
        (k) => {
          k(null);
          transfer(
            state.offer + acceptFee + amt + constructFee + SERIAL_VER
          ).to(Offerer);
          return [
            {
              ...state,
              closed: true,
            },
          ];
        },
      ];
    })
    // API counter
    // - allow target to counter offer
    .api_(a.counterOffer, (msg) => {
      check(this != Offerer, "Counter offer must not be made by offerer");
      check(state.who == this, "Counter offer must be made by target");
      check(
        msg > state.counterOffer,
        "Counter offer must be greater than previous offer"
      );
      return [
        [0, [0, token]],
        (k) => {
          k(null);
          return [
            {
              ...state,
              counterOffer: msg,
            },
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
          transfer(state.offer + acceptFee).to(this);
          return [
            {
              ...state,
              closed: true,
              offer: 0,
              who: this,
            },
          ];
        },
      ];
    })
    // allow offer ttl
    .timeout(absoluteTime(offerEndTime), () => {
      // Step
      Relay.publish();
      transfer(state.offer + acceptFee).to(Offerer);
      return [
        {
          ...state,
          closed: true,
          offer: 0,
          who: Offerer,
        },
      ];
    });
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
