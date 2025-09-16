# KipuBank

Um simples Smart Contract para armazenamento de ETH.

Aqui, é possível:
- **Depósitar** uma quantidade de ETH passada via `msg.value`.
- **Sacar** uma quantidade de ETH. Existe um limite máxima de saque por transação (`ETHER_WITHDRAW_LIMIT`).

## Sumário
- [Resumo](#resumo)
- [Detalhes do Contrato](#detalhes-do-contrato)
- [Como fazer deploy (Remix)](#deploy-remix)
- [Como interagir](#como-interagir)
- [Endereço implantado](#endereço-implantado)

## Resumo
- `MAX_BANK_CAP` (`immutable`): teto global definido no deploy.
- `currentBankCap`: capacidade restante, ou seja, quanto ainda cabe depositar.
- `balances[address]`: saldo individual de cada conta que eventualmente depositar.
- `ETHER_WITHDRAW_LIMIT` (`constant`): limite de saque por tx.
- Contadores: `countDeposits`, `countWithdrawals`.

## Detalhes do Contrato

### Funções
- `deposit() external payable onlyValidValue(msg.value)`
  Deposita `msg.value` no seu saldo. Reverte com:
  - `InvalidValue()` se `msg.value <= 0`
  - `BankCapExceeded(requested, available)` se exceder `currentBankCap`

- `withdraw(uint256 value) external onlyValidValue(value)`
  Saca `value` do seu saldo. Reverte com:
  - `InvalidValue()` se `value <= 0`
  - `WithdrawLimitExceeded(requested, limit)` se `value > ETHER_WITHDRAW_LIMIT`
  - `InsufficientBalance(requested, available)` se `value > balance`

- `getBalance(address account) external onlyOwner view returns (uint256)`
  Retorna o saldo de `account`.

- `getBalance() external view returns (uint256)`
  Retorna o saldo do `msg.sender`.

- `updateOwner(address newOwner) external onlyOwner`
  Atualiza o `owner`. Reverte com `Unauthorized()` se `msg.sender != owner`.

- `countTransactions() private view returns (uint256)`
  Retorna a soma de `countDeposits + countWithdrawals`.

- `essentialFunction() private`
  Não faz nada. :)

### Eventos
- `event Deposit(address indexed account, uint256 value)`
- `event Withdraw(address indexed account, uint256 value)`

### Modifiers
- `onlyOwner()`
  Restringe o acesso a funções apenas para o `owner`.

- `onlyValidValue(uint256 value)`
  Reverte com `InvalidValue()` se `value <= 0`.

### Erros personalizados
`InvalidValue()`,
`BankCapExceeded(uint256 requested, uint256 available)`,
`WithdrawLimitExceeded(uint256 requested, uint256 limit)`,
`InsufficientBalance(uint256 requested, uint256 available)`,
`TransferFailed()`,
`Unauthorized()`.

## Como fazer deploy (Remix)

### Pré-requisitos
- **MetaMask** (ou outra carteira) conectada a uma **testnet** (ex.: **Sepolia**).
- Algum **ETH de testnet** (use um *faucet*).
- Acesse: https://remix.ethereum.org

### Passo a passo
1. Abra o Remix, vá em **File Explorer** → **Create New File** → `KipuBank.sol` e cole o contrato.
2. Aba **Solidity Compiler**:
   - Versão: qualquer acima de **0.8.20** (igual ao pragma do contrato).
   - Clique **Compile KipuBank.sol**.
3. Aba **Deploy & Run Transactions**:
   - **Environment**: *Injected Provider – MetaMask* (usa a rede da sua carteira).
   - **Account**: selecione a conta com ETH de testnet.
   - **Contract**: `KipuBank – contracts/KipuBank.sol`.
   - Clique **Deploy** e confirme na carteira.
4. Copie o **endereço do contrato** após o deploy (aparece no painel do Remix e no explorer).

## Como interagir

### Via Remix
- **deposit**
  No topo da aba **Deploy & Run Transactions**, no campo **VALUE**, informe por exemplo `0.1 ether` e chame `deposit()`.

- **withdraw**
  Chame `withdraw(value)`. Ex.: `0.05 ether` (ou `50000000000000000` wei).

- **getBalance**
  Clique para ler; retorna seu saldo em **wei**.

- **getBalance(address account)**
  Informe o `address` e clique para ler (somente o `owner` pode chamar).

- **updateOwner**
  Informe `newOwner` (endereço) e execute (somente o `owner` atual pode chamar).

## Endereço implantado

- **Rede:** Sepolia
- **Endereço:** `0x33902A5646Fdd4e1f1580FeD429CFE022ECF049D`
 **Explorer:** `https://sepolia.etherscan.io/tx/0xa0c969b9dfbd120231e9055f1744ad7daacc35adc35874212b573796cee4d6a3`
