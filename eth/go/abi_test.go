package main

import (
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/stretchr/testify/require"
)

type TransferCall struct {
	To     common.Address `abi:"to"`
	Amount *big.Int       `abi:"amount"`
}

func TestABICalldataEncodeDecode(t *testing.T) {
	const contractABI = `[
		{
			"type": "function",
			"name": "transfer",
			"stateMutability": "nonpayable",
			"inputs": [
				{"name": "to", "type": "address"},
				{"name": "amount", "type": "uint256"}
			],
			"outputs": [{"name": "", "type": "bool"}]
		}
	]`

	parsedABI, err := abi.JSON(strings.NewReader(contractABI))
	require.NoError(t, err)

	to := common.HexToAddress("0x1111111111111111111111111111111111111111")
	amount := big.NewInt(100)

	// Encode: 前 4 字节是 transfer(address,uint256) 的 method ID，后面是参数。
	calldata, err := parsedABI.Pack("transfer", to, amount)
	require.NoError(t, err)
	require.GreaterOrEqual(t, len(calldata), 4)

	// Decode: 先根据 method ID 找到方法名，再解码其输入参数。
	method, err := parsedABI.MethodById(calldata[:4])
	require.NoError(t, err)
	require.Equal(t, "transfer", method.Name)

	args, err := method.Inputs.Unpack(calldata[4:])
	require.NoError(t, err)

	var decoded TransferCall
	require.NoError(t, method.Inputs.Copy(&decoded, args))
	require.Equal(t, to, decoded.To)
	require.Zero(t, amount.Cmp(decoded.Amount))
}
