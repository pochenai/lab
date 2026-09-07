package lab.eth;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.web3j.abi.FunctionEncoder;
import org.web3j.abi.FunctionReturnDecoder;
import org.web3j.abi.TypeReference;
import org.web3j.abi.Utils;
import org.web3j.abi.datatypes.Address;
import org.web3j.abi.datatypes.Function;
import org.web3j.abi.datatypes.Type;
import org.web3j.abi.datatypes.generated.Uint256;
import org.web3j.crypto.Hash;
import org.web3j.protocol.ObjectMapperFactory;
import org.web3j.utils.Numeric;
import tools.jackson.databind.JsonNode;

class AbiCalldataTest {
    // ABI 是 decode calldata 时识别 selector 与参数类型的依据，方法名不可省略。
    private static final String CONTRACT_ABI =
            """
            [
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
            ]
            """;

    record TransferCall(String methodName, String to, BigInteger amount) {}

    record AbiMethod(String name, List<TypeReference<?>> inputTypeReferences) {}

    @Test
    void encodeAndDecodeCalldata() throws Exception {
        String to = "0x1111111111111111111111111111111111111111";
        BigInteger amount = BigInteger.valueOf(100);

        Function transfer =
                new Function(
                        "transfer",
                        List.of(new Address(to), new Uint256(amount)),
                        List.of());

        // Encode: 0x + 4-byte method selector + ABI encoded arguments.
        String calldata = FunctionEncoder.encode(transfer);
        assertEquals("0xa9059cbb", calldata.substring(0, 10));

        TransferCall decoded = decodeTransfer(CONTRACT_ABI, calldata);
        assertEquals("transfer", decoded.methodName());
        assertEquals(to, decoded.to());
        assertEquals(amount, decoded.amount());
    }

    private static TransferCall decodeTransfer(String contractABI, String calldata) throws Exception {
        if (calldata == null || calldata.length() < 10) {
            throw new IllegalArgumentException("calldata is too short");
        }

        String selector = calldata.substring(0, 10);
        JsonNode abiItems = ObjectMapperFactory.getObjectMapper().readTree(contractABI);
        AbiMethod matchedMethod = null;
        for (JsonNode abiItem : abiItems) {
            if (!"function".equals(abiItem.path("type").asText())) {
                continue;
            }

            String methodName = abiItem.path("name").asText();
            List<String> inputTypes = new ArrayList<>();
            List<TypeReference<?>> inputTypeReferences = new ArrayList<>();
            for (JsonNode input : abiItem.path("inputs")) {
                String inputType = input.path("type").asText();
                inputTypes.add(inputType);
                inputTypeReferences.add(TypeReference.makeTypeReference(inputType));
            }

            String methodSignature = methodName + "(" + String.join(",", inputTypes) + ")";
            String methodSelector =
                    Numeric.toHexString(Hash.sha3(methodSignature.getBytes(StandardCharsets.UTF_8)))
                            .substring(0, 10);
            if (!selector.equals(methodSelector)) {
                continue;
            }

            if (matchedMethod != null) {
                throw new IllegalArgumentException("ambiguous method selector: " + selector);
            }
            matchedMethod = new AbiMethod(methodName, inputTypeReferences);
        }

        if (matchedMethod == null) {
            throw new IllegalArgumentException("method selector is not present in contract ABI: " + selector);
        }

        // FunctionReturnDecoder 同样可用于按 ABI 类型解码 calldata 的参数部分。
        List<Type> arguments =
                FunctionReturnDecoder.decode(
                        "0x" + calldata.substring(10),
                        Utils.convert(matchedMethod.inputTypeReferences()));
        if (!"transfer".equals(matchedMethod.name()) || arguments.size() != 2) {
            throw new IllegalArgumentException("this demo only maps transfer to TransferCall");
        }

        return new TransferCall(
                matchedMethod.name(),
                ((Address) arguments.get(0)).getValue(),
                ((Uint256) arguments.get(1)).getValue());
    }
}
