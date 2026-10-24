// Menu for every backend endpoint. The backend builds each transaction; this script signs and
// sends it with web3.js: approvals first (ERC20 quote tokens), then the transaction itself.
//
//   cp .env.example .env    # RPC_URL, API_URL, ADMIN_PRIVATE_KEY, USER_PRIVATE_KEY
//   npm install && npm start
import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import { Web3 } from 'web3';

try {
  process.loadEnvFile(new URL('.env', import.meta.url));
} catch {
  // no .env: fall back to the shell's environment
}

const { RPC_URL, ADMIN_PRIVATE_KEY, USER_PRIVATE_KEY } = process.env;
const API_URL = (process.env.API_URL ?? 'http://localhost:3000').replace(/\/$/, '');
if (!RPC_URL || !ADMIN_PRIVATE_KEY || !USER_PRIVATE_KEY) {
  console.error('Set RPC_URL, ADMIN_PRIVATE_KEY and USER_PRIVATE_KEY in scripts/.env (see .env.example)');
  process.exit(1);
}

const web3 = new Web3(RPC_URL);
// web3 gives up after 50 blocks (~40 s on BSC); busy testnet blocks can take longer than that.
web3.transactionBlockTimeout = 400;
const withPrefix = (k) => (k.startsWith('0x') ? k : `0x${k}`);
// The wallet keeps one entry per address, so both keys may be the same wallet.
const accounts = {
  admin: web3.eth.accounts.privateKeyToAccount(withPrefix(ADMIN_PRIVATE_KEY)),
  user: web3.eth.accounts.privateKeyToAccount(withPrefix(USER_PRIVATE_KEY)),
};
const wallets = {};
for (const [role, account] of Object.entries(accounts)) {
  if (!web3.eth.accounts.wallet.get(account.address)) web3.eth.accounts.wallet.add(account);
  wallets[role] = account.address;
}
if (wallets.admin === wallets.user) {
  console.log('! ADMIN_PRIVATE_KEY and USER_PRIVATE_KEY are the same wallet; both roles sign with it');
}

const rl = createInterface({ input: stdin, output: stdout });
rl.on('close', () => process.exit(0));

let actingAs = 'user'; // who signs the non-admin actions; admin actions always use the admin key
let currentPool = ''; // last pool launched or typed, offered as the default

// ------------------------------------------------------------------ actions
//
// Each field is [name, label, default]. A default of '' means "leave it to the backend".
// `pool` defaults to the current pool; `@user` / `@admin` default to that wallet's address.

const actions = [
  { section: 'Pools (user)' },
  {
    label: 'Launch a coin', path: '/launch',
    fields: [
      ['name', 'Name', 'Test Coin'], ['symbol', 'Symbol', 'TEST'], ['description', 'Description', ''],
      ['imageUrl', 'Image URL', ''], ['website', 'Website', ''], ['twitter', 'Twitter', ''],
      ['quoteToken', 'Quote token (native or ERC20 address)', 'native'],
      ['buyFeeBps', 'Buy tax bps (100 = 1%)', '100'], ['sellFeeBps', 'Sell tax bps', '100'],
      ['creatorBps', 'Tax split: creator bps', '10000'], ['burnBps', 'Tax split: burn bps', '0'],
      ['buybackBps', 'Tax split: buyback bps', '0'], ['holdersBps', 'Tax split: holders bps', '0'],
      ['totalSupply', 'Total supply (coins)', '10000'],
      ['graduationThreshold', 'Graduation threshold (quote)', '0.1'],
      ['firstBuyAmount', 'Tax-free first buy (quote, 0 = none)', '0'],
    ],
  },
  { label: 'Buy an exact number of coins', path: '/buy', fields: [['pool'], ['tokenAmount', 'Coins to buy', '100'], ['slippageBps', 'Slippage bps', '100']] },
  { label: 'Buy with an exact amount of quote', path: '/buy-exact-in', fields: [['pool'], ['amountIn', 'Quote to spend', '0.001'], ['slippageBps', 'Slippage bps', '100']] },
  { label: 'Sell coins', path: '/sell', fields: [['pool'], ['tokenAmount', 'Coins to sell', '50'], ['slippageBps', 'Slippage bps', '100']] },
  { label: 'Migrate a graduated pool to PancakeSwap', path: '/migrate', fields: [['pool']] },
  { label: 'Claim creator fees', path: '/claim-creator-fees', fields: [['pool']] },
  { label: 'Claim holder rewards', path: '/claim-rewards', fields: [['pool']] },
  { label: 'Transfer coins', path: '/transfer', fields: [['pool'], ['to', 'To address', '@admin'], ['amount', 'Coins', '10']] },
  { label: 'Transfer coins from (approved spender)', path: '/transfer-from', fields: [['pool'], ['owner', 'Owner address', '@admin'], ['to', 'To address', '@user'], ['amount', 'Coins', '10']] },
  { label: 'Approve a spender for coins', path: '/approve', fields: [['pool'], ['spender', 'Spender address', '@admin'], ['amount', 'Coins (or max, 0 = revoke)', '10']] },

  { section: 'Read (no transaction)' },
  { label: 'Pool info', path: '/pool-info', read: true, fields: [['pool'], ['holder', 'Holder address (blank = none)', '@me']] },
  { label: 'All pools', path: '/get-all-pool-info', read: true, fields: [['offset', 'Offset', '0'], ['limit', 'Limit (blank = all)', '']], summary: true },

  { section: 'Admin (signed with ADMIN_PRIVATE_KEY)' },
  { label: 'Allow / reprice / remove a quote token', path: '/set-quote-token', admin: true, fields: [['token', 'Token (native or ERC20 address)', ''], ['startPrice', 'Start price per coin (0 = remove)', '']] },
  { label: 'Set launch fee', path: '/set-launch-fee', admin: true, fields: [['launchFee', 'Launch fee (BNB)', '0.002']] },
  { label: 'Withdraw platform fees', path: '/claim-admin-fees', admin: true, fields: [['token', 'Token (native or ERC20 address)', 'native'], ['to', 'Send to', '@admin']] },
  { label: 'Transfer factory ownership', path: '/transfer-ownership', admin: true, fields: [['newOwner', 'New owner address', '']] },
  { label: 'Renounce factory ownership (PERMANENT)', path: '/renounce-ownership', admin: true, fields: [], renounce: true },
];

// -------------------------------------------------------------------- helpers

async function api(path, params) {
  const query = new URLSearchParams(Object.entries(params).filter(([, v]) => v !== ''));
  const res = await fetch(`${API_URL}${path}?${query}`);
  const body = await res.json().catch(() => ({ message: `HTTP ${res.status}` }));
  if (!res.ok) {
    const detail = body.error && body.error !== 'Bad Request' ? ` [${body.error}${body.args?.length ? ` ${body.args.join(', ')}` : ''}]` : '';
    throw new Error(`${res.status}: ${body.message}${detail}`);
  }
  return body;
}

async function ask(label, fallback) {
  const answer = (await rl.question(`  ${label}${fallback ? ` [${fallback}]` : ''}: `)).trim();
  return answer || fallback;
}

function resolveDefault(value, signer) {
  if (value === '@me') return wallets[signer];
  if (value === '@user' || value === '@admin') return wallets[value.slice(1)];
  return value ?? '';
}

async function collect(action, signer) {
  const params = {};
  for (const [name, label, fallback] of action.fields) {
    if (name === 'pool') {
      const pool = await ask('Pool address', currentPool);
      if (!pool) throw new Error('a pool address is needed (launch one first, or paste one)');
      params.pool = currentPool = pool;
    } else {
      params[name] = await ask(label, resolveDefault(fallback, signer));
    }
  }
  return params;
}

const explorer = { 56: 'https://bscscan.com/tx/', 97: 'https://testnet.bscscan.com/tx/' };

async function sendTx(tx, label, chainId) {
  // Print the hash as soon as it is sent, so it can be checked in the explorer even if waiting fails.
  const receipt = await web3.eth
    .sendTransaction(tx)
    .on('transactionHash', (hash) => console.log(`  … ${label} sent: ${hash}${explorer[chainId] ? `  ${explorer[chainId]}${hash}` : ''}`));
  const ok = receipt.status === 1n;
  console.log(`  ${ok ? '✓' : '✗'} ${label} mined in block ${receipt.blockNumber} (gas ${receipt.gasUsed})`);
  if (!ok) throw new Error(`${label} reverted`);
  return receipt;
}

const POOL_CREATED = web3.utils.sha3('PoolCreated(address,address,address,string,string)');

function printQuote(quote) {
  const flat = (v) => (v && typeof v === 'object' && 'formatted' in v ? v.formatted : v);
  for (const [k, v] of Object.entries(quote)) {
    const shown = v && typeof v === 'object' && !('formatted' in v) ? JSON.stringify(v) : flat(v);
    console.log(`    ${k}: ${shown}`);
  }
}

// ----------------------------------------------------------------------- run

async function run(action) {
  const signer = action.admin ? 'admin' : actingAs;
  const params = await collect(action, signer);

  if (action.read) {
    const body = await api(action.path, params);
    if (action.summary) {
      console.log(`  ${body.total} pools (synced to block ${body.syncedBlock})`);
      for (const p of body.pools) {
        console.log(`   #${p.index} ${p.pool}  ${p.name} (${p.symbol})  quote ${p.quoteToken.symbol}  ` +
          `price ${p.currentPrice.formatted}  progress ${p.progressPercent}%  ${p.migrated ? 'migrated' : p.graduated ? 'graduated' : 'trading'}`);
      }
    } else {
      console.log(JSON.stringify(body, null, 2));
    }
    return;
  }

  if (action.renounce) {
    const typed = await ask('This can never be undone. Type RENOUNCE to continue', '');
    if (typed !== 'RENOUNCE') return console.log('  cancelled');
    params.confirm = 'true';
  }

  const from = wallets[signer];
  const body = await api(action.path, { ...params, from });
  console.log(`  ${action.path} as ${signer} (${from}), chain ${body.chainId}:`);
  printQuote(body.quote);
  if (body.approvals.length) console.log(`    (needs ${body.approvals.length} approval tx first)`);
  if ((await ask('Send? (y/N)', 'N')).toLowerCase() !== 'y') return console.log('  cancelled');

  for (const approval of body.approvals) await sendTx(approval, 'approve', body.chainId);
  const receipt = await sendTx(body.transaction, action.path.slice(1), body.chainId);

  const created = receipt.logs.find((l) => l.topics?.[0] === POOL_CREATED);
  if (created) {
    currentPool = web3.utils.toChecksumAddress(`0x${created.topics[1].slice(26)}`);
    console.log(`  new pool: ${currentPool} (now the default pool; the indexer lists it within a few seconds)`);
  }
}

async function showWallets() {
  for (const [role, address] of Object.entries(wallets)) {
    const bnb = web3.utils.fromWei(await web3.eth.getBalance(address), 'ether');
    console.log(`  ${role.padEnd(5)} ${address}  ${bnb} BNB${role === actingAs ? '   <- signs user actions' : ''}`);
  }
}

function printMenu() {
  console.log(`\n=== Allo menu  (API ${API_URL}, user actions signed by ${actingAs}${currentPool ? `, pool ${currentPool}` : ''}) ===`);
  let n = 0;
  for (const a of actions) {
    if (a.section) console.log(`\n ${a.section}`);
    else console.log(`  ${String(++n).padStart(2)}. ${a.label}`);
  }
  console.log('\n   w. Wallets and balances    s. Switch who signs user actions    q. Quit');
}

const numbered = actions.filter((a) => !a.section);

const [chainId, health] = await Promise.all([
  web3.eth.getChainId(),
  api('/get-all-pool-info', { limit: 0 }).catch((e) => e),
]);
console.log(`RPC chain ${chainId}`);
if (health instanceof Error) {
  console.log(`! backend not reachable at ${API_URL} (${health.message}); start it with: cd backend && npm run start:prod`);
} else {
  console.log(`backend: chain ${health.chainId}, factory ${health.factory}, ${health.total} pools indexed`);
  if (BigInt(health.chainId) !== chainId) console.log('! RPC_URL and the backend are on different chains');
}
await showWallets();

while (true) {
  printMenu();
  const choice = (await rl.question('\nChoose: ')).trim().toLowerCase();
  try {
    if (choice === 'q') break;
    else if (choice === 'w') await showWallets();
    else if (choice === 's') {
      actingAs = actingAs === 'user' ? 'admin' : 'user';
      console.log(`  user actions are now signed by ${actingAs} (${wallets[actingAs]})`);
    } else if (numbered[Number(choice) - 1]) await run(numbered[Number(choice) - 1]);
    else console.log('  unknown choice');
  } catch (err) {
    console.log(`  ✗ ${err.message}`);
  }
}
rl.close();
