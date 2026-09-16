// verify-launch.mjs
//
// Verifies an Argus token against the Portal registry, decodes its launch
// record with the correct layout for the Portal found, and reads real
// state/price from the hook + StateView.
//
// Usage:
//   npm install ethers@6
//   ARC_RPC_URL=https://<your-arc-mainnet-rpc> node verify-launch.mjs 0xTOKENADDRESS
//
// Source for addresses/events/layout: argus.world/docs/integrate and
// argus.world/docs/integrate-markets (see ../onchain/*.md in this repo).
// Always verify chain ID and non-empty bytecode before trusting an address:
// see ../NOTES-LIMITATIONS.md for the known chain-ID discrepancy.

import { ethers } from "ethers";

const RPC_URL = process.env.ARC_RPC_URL;
const TOKEN = process.argv[2];

if (!RPC_URL || !TOKEN) {
  console.error("Usage: ARC_RPC_URL=<rpc> node verify-launch.mjs 0xTOKEN");
  process.exit(1);
}

// --- Portal registry, from onchain/addresses.md. Order: newest to oldest. ---
const PORTALS = [
  { name: "#7", address: "0xB021Be536808f551b31789422Fd28a6c9c6e97Da", words: 11, family: "v4" },
  { name: "#6", address: "0xA5628A11c412596E1f63b75a2C0284F843C549d6", words: 11, family: "v4" },
  { name: "#5", address: "0x07a688a001f416cC433c68Ff56Aa26bC5131Cc6E", words: 10, family: "v4" },
  { name: "#4", address: "0xa36c443A797771Df82533B8B4A86F0AFfd970862", words: 10, family: "v4" },
  { name: "#3", address: "0x7A17Ab0106C46C0be30623F3EB7F299CC0058338", words: 9, family: "v4" },
  { name: "#2", address: "0xBed9880A0ba12722ba4b8791c0B6F8c74338246C", words: 10, family: "v3" },
  { name: "#1", address: "0x0F1C7Cb26D6cD36BD4189E41947658b39437587A", words: 10, family: "v3" },
];

const SHARED = {
  poolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
  stateView: "0xF3334192D15450CdD385c8B70e03f9A6bD9E673b",
  usdc: "0x3600000000000000000000000000000000000000",
};

// Minimal, generic ABI: replace with exact types from the official bundle
// (argus-v4.json / argus-abi.json) before using this in production.
// This is only an orientation reconstruction from the docs, NOT the
// verified ABI.
const PORTAL_ABI_GENERIC = [
  "function launches(address token) view returns (address creator)",
  "function LAUNCH_STRUCT_WORDS() view returns (uint256)",
];

const HOOK_ABI = [
  "function buyTaxBps() view returns (uint16)",
  "function sellTaxBps() view returns (uint16)",
  "function bonded() view returns (bool)",
  "function bondTick() view returns (int24)",
  "function poolId() view returns (bytes32)",
];

const STATEVIEW_ABI = [
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);

  const network = await provider.getNetwork();
  console.log(`Connected. observed chainId = ${network.chainId}`);
  console.log("⚠️  Compare this value against what you expect before trusting anything below.");

  const code = await provider.getCode(TOKEN);
  if (code === "0x") {
    console.error(`No bytecode at ${TOKEN}. Not a contract on this network/RPC.`);
    process.exit(1);
  }
  console.log(`OK: ${TOKEN} has bytecode (${(code.length - 2) / 2} bytes).`);

  // Detect an EIP-1167 minimal proxy: 363d3d373d3d3d363d73<20 bytes>5af43d82803e903d91602b57fd5bf3
  const EIP1167_PREFIX = "363d3d373d3d3d363d73";
  const EIP1167_SUFFIX = "5af43d82803e903d91602b57fd5bf3";
  const bodyHex = code.slice(2); // strip 0x
  let implementation = null;
  if (
    bodyHex.length === 90 &&
    bodyHex.startsWith(EIP1167_PREFIX) &&
    bodyHex.endsWith(EIP1167_SUFFIX)
  ) {
    implementation = "0x" + bodyHex.slice(20, 60);
    console.log(`Detected EIP-1167 minimal proxy. Implementation: ${implementation}`);
    console.log(`  -> Check whether this address is documented elsewhere as the`);
    console.log(`     official Argus token implementation before trusting it.`);
  }

  let found = null;
  for (const portal of PORTALS) {
    try {
      const contract = new ethers.Contract(portal.address, PORTAL_ABI_GENERIC, provider);
      const creator = await contract.launches(TOKEN);
      if (creator && creator !== ethers.ZeroAddress) {
        found = { portal, creator };
        console.log(`Found on Portal ${portal.name} (${portal.address}). creator = ${creator}`);
        break;
      } else {
        console.log(`Portal ${portal.name}: no record (creator = zero address).`);
      }
    } catch (err) {
      console.log(`Portal ${portal.name}: unresolved lookup (${err.shortMessage || err.message}) — NOT a confirmed absence.`);
    }
  }

  if (!found) {
    console.log(
      "\nNo Portal returned a positive record. This does NOT prove the token" +
      " isn't Argus: it could be a different ABI/function name than the generic" +
      " one used here, or a failed lookup. Replace PORTAL_ABI_GENERIC with the" +
      " real ABI from the official bundle (argus-v4.json / argus-abi.json) and" +
      " try again."
    );
    return;
  }

  console.log(
    `\nNext step: decode the record with the real versioned ABI for Portal` +
    ` ${found.portal.name} (${found.portal.words} words, ${found.portal.family} family)` +
    ` — see onchain/launch-record-layout.md — to get hook, locker, splitter, poolId.`
  );

  // From here on you need the real bundle ABI (not the generic one above) to
  // read the full record. Once you have poolId and the hook address:
  //
  // const hook = new ethers.Contract(hookAddress, HOOK_ABI, provider);
  // const [buyTaxBps, sellTaxBps, bonded] = await Promise.all([
  //   hook.buyTaxBps(), hook.sellTaxBps(), hook.bonded(),
  // ]);
  //
  // const stateView = new ethers.Contract(SHARED.stateView, STATEVIEW_ABI, provider);
  // const slot0 = await stateView.getSlot0(poolId);
  // const liquidity = await stateView.getLiquidity(poolId);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
