#!/bin/bash
plan_id="${1}"
cp -vf build/index.main.mjs /Users/nicholasshellabarger/Desktop/repos/dapp-base-offer/d-app/src/services/utils/app/offer/build/index.main.mjs
{
  cat << EOF
const PLAN_ID = "${plan_id}";

export default {
  PLAN_ID
};
EOF
} > /Users/nicholasshellabarger/Desktop/repos/dapp-base-offer/d-app/src/services/utils/app/offer/config.ts
