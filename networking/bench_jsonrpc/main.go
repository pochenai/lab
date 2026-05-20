package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

/*
benchmark 目标是模拟一个典型的 JSON-RPC 请求负载，来衡量服务器处理大请求时的性能表现。我们以 `engine_newPayloadV4` 方法为例。
简化模型为: Engine payload -> JSON-RPC marshal -> localhost HTTP + JWT auth -> EL auth -> JSON-RPC unmarshal -> typed engine payload。

普通 ERC20 transfer：
- gas 通常约 45k-65k
- 500M / 50k ~= 10,000 tx
- signed raw tx 大概 170-250 bytes
- JSON 里 raw tx 是 hex string，所以大概翻倍：340-500 bytes/tx
所以10,000 tx * 400 bytes ~= 4,000,000 bytes ~= 3.8 MiB

go run . -target-json-mib 1 -n 500 -server-parse-mode rawmessage -warmup 20 -tx-bytes 256
*/
const (
	defaultTargetJSONMiB = 4
	defaultIterations    = 200
	defaultWarmup        = 20
	defaultTxBytes       = 256
	defaultParseMode     = parseModeRawMessage

	parseModeRawMessage = "rawmessage"
	parseModeDecoder    = "decoder"
)

type rpcRequest struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  []any  `json:"params"`
	ID      uint64 `json:"id"`
}

type rawRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
	ID      uint64          `json:"id"`
}

type rawRPCRequestWithRawParams struct {
	JSONRPC string            `json:"jsonrpc"`
	Method  string            `json:"method"`
	Params  []json.RawMessage `json:"params"`
	ID      uint64            `json:"id"`
}

type rpcResponse struct {
	JSONRPC string        `json:"jsonrpc"`
	ID      uint64        `json:"id"`
	Result  payloadStatus `json:"result"`
}

type payloadStatus struct {
	Status          string  `json:"status"`
	LatestValidHash string  `json:"latestValidHash"`
	ValidationError *string `json:"validationError"`
}

type executionPayloadV4 struct {
	ParentHash      string       `json:"parentHash"`
	FeeRecipient    string       `json:"feeRecipient"`
	StateRoot       string       `json:"stateRoot"`
	ReceiptsRoot    string       `json:"receiptsRoot"`
	LogsBloom       string       `json:"logsBloom"`
	PrevRandao      string       `json:"prevRandao"`
	BlockNumber     string       `json:"blockNumber"`
	GasLimit        string       `json:"gasLimit"`
	GasUsed         string       `json:"gasUsed"`
	Timestamp       string       `json:"timestamp"`
	ExtraData       string       `json:"extraData"`
	BaseFeePerGas   string       `json:"baseFeePerGas"`
	BlockHash       string       `json:"blockHash"`
	Transactions    []string     `json:"transactions"`
	Withdrawals     []withdrawal `json:"withdrawals"`
	BlobGasUsed     string       `json:"blobGasUsed"`
	ExcessBlobGas   string       `json:"excessBlobGas"`
	WithdrawalsRoot string       `json:"withdrawalsRoot"`
}

type withdrawal struct {
	Index          string `json:"index"`
	ValidatorIndex string `json:"validatorIndex"`
	Address        string `json:"address"`
	Amount         string `json:"amount"`
}

type benchmarkConfig struct {
	iterations    int
	warmup        int
	targetJSONMiB int
	txBytes       int
	addr          string
	parseMode     string
	noKeepAlive   bool
}

type sample struct {
	e2e           time.Duration
	reqMarshal    time.Duration
	reqUnmarshal  time.Duration
	respMarshal   time.Duration
	respUnmarshal time.Duration
}

type summary struct {
	avg time.Duration
	p95 time.Duration
}

func main() {
	cfg := benchmarkConfig{}
	flag.IntVar(&cfg.iterations, "n", defaultIterations, "measured JSON-RPC requests")
	flag.IntVar(&cfg.warmup, "warmup", defaultWarmup, "warmup requests excluded from results")
	flag.IntVar(&cfg.targetJSONMiB, "target-json-mib", defaultTargetJSONMiB, "approximate JSON-RPC request body size in MiB")
	flag.IntVar(&cfg.txBytes, "tx-bytes", defaultTxBytes, "raw bytes per synthetic transaction before hex encoding")
	flag.StringVar(&cfg.addr, "addr", "127.0.0.1:0", "local server listen address")
	flag.StringVar(&cfg.parseMode, "server-parse-mode", defaultParseMode, "server params parse mode: rawmessage or decoder")
	flag.BoolVar(&cfg.noKeepAlive, "no-keepalive", false, "disable HTTP keep-alive")
	flag.Parse()

	if err := cfg.validate(); err != nil {
		log.Fatal(err)
	}

	secret := bytes.Repeat([]byte{0x42}, 32)
	targetJSONBytes := cfg.targetJSONMiB * 1024 * 1024
	payload := buildPayload(targetJSONBytes, cfg.txBytes)
	req := rpcRequest{
		JSONRPC: "2.0",
		Method:  "engine_newPayloadV4",
		Params: []any{
			payload,
			[]string{},
			hashHex(0x77),
			[]string{},
		},
		ID: 1,
	}
	body, err := json.Marshal(req)
	if err != nil {
		log.Fatalf("marshal setup request: %v", err)
	}

	server, endpoint, err := startServer(cfg.addr, secret, cfg.parseMode)
	if err != nil {
		log.Fatal(err)
	}
	defer server.Close()

	client := &http.Client{
		Transport: &http.Transport{
			Proxy:               nil,
			DisableCompression:  true,
			DisableKeepAlives:   cfg.noKeepAlive,
			MaxIdleConns:        1,
			MaxIdleConnsPerHost: 1,
		},
	}

	total := cfg.warmup + cfg.iterations
	results := make([]sample, 0, cfg.iterations)
	for i := 0; i < total; i++ {
		req.ID = uint64(i + 1)
		s, err := callOnce(client, endpoint, secret, req)
		if err != nil {
			log.Fatalf("request %d failed: %v", i+1, err)
		}
		if i >= cfg.warmup {
			results = append(results, s)
		}
	}

	e2e := summarize(results, func(s sample) time.Duration { return s.e2e })
	reqMarshal := summarize(results, func(s sample) time.Duration { return s.reqMarshal })
	reqUnmarshal := summarize(results, func(s sample) time.Duration { return s.reqUnmarshal })
	respMarshal := summarize(results, func(s sample) time.Duration { return s.respMarshal })
	respUnmarshal := summarize(results, func(s sample) time.Duration { return s.respUnmarshal })
	jsonCodecTotal := summarize(results, func(s sample) time.Duration {
		return s.reqMarshal + s.reqUnmarshal + s.respMarshal + s.respUnmarshal
	})

	fmt.Printf("method: engine_newPayloadV4\n")
	fmt.Printf("requests: %d measured + %d warmup\n", cfg.iterations, cfg.warmup)
	fmt.Printf("target_json_mib: %d\n", cfg.targetJSONMiB)
	fmt.Printf("target_json_bytes: %d\n", targetJSONBytes)
	fmt.Printf("actual_json_bytes: %d\n", len(body))
	fmt.Printf("tx_count: %d\n", len(payload.Transactions))
	fmt.Printf("tx_bytes: %d raw bytes each\n", cfg.txBytes)
	fmt.Printf("server_parse_mode: %s\n", cfg.parseMode)
	fmt.Printf("http_keepalive: %v\n", !cfg.noKeepAlive)
	fmt.Println()
	printSummary("e2e", e2e)
	printSummary("json_marshal_client_request", reqMarshal)
	printSummary("json_unmarshal_server_request", reqUnmarshal)
	printSummary("json_marshal_server_response", respMarshal)
	printSummary("json_unmarshal_client_response", respUnmarshal)
	printPercentSummary("json_codec_total/e2e", jsonCodecTotal, e2e)
}

func (cfg benchmarkConfig) validate() error {
	if cfg.iterations <= 0 {
		return errors.New("-n must be positive")
	}
	if cfg.warmup < 0 {
		return errors.New("-warmup must be non-negative")
	}
	if cfg.targetJSONMiB <= 0 {
		return errors.New("-target-json-mib must be positive")
	}
	if cfg.txBytes <= 0 {
		return errors.New("-tx-bytes must be positive")
	}
	switch cfg.parseMode {
	case parseModeRawMessage, parseModeDecoder:
	default:
		return fmt.Errorf("-server-parse-mode must be %q or %q", parseModeRawMessage, parseModeDecoder)
	}
	return nil
}

func callOnce(client *http.Client, endpoint string, secret []byte, req rpcRequest) (sample, error) {
	start := time.Now()
	token, err := makeJWT(secret, time.Now())
	if err != nil {
		return sample{}, err
	}

	marshalStart := time.Now()
	body, err := json.Marshal(req)
	marshalDur := time.Since(marshalStart)
	if err != nil {
		return sample{}, err
	}

	httpReq, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return sample{}, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+token)
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(httpReq)
	if err != nil {
		return sample{}, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return sample{}, err
	}
	if resp.StatusCode != http.StatusOK {
		return sample{}, fmt.Errorf("unexpected status %d: %s", resp.StatusCode, string(respBody))
	}
	var decoded rpcResponse
	respUnmarshalStart := time.Now()
	if err := json.Unmarshal(respBody, &decoded); err != nil {
		return sample{}, err
	}
	respUnmarshalDur := time.Since(respUnmarshalStart)
	if decoded.Result.Status != "VALID" {
		return sample{}, fmt.Errorf("unexpected payload status %q", decoded.Result.Status)
	}

	serverUnmarshal, err := strconv.ParseInt(resp.Header.Get("X-JSONRPC-Unmarshal-Ns"), 10, 64)
	if err != nil {
		return sample{}, fmt.Errorf("missing/invalid server unmarshal timing: %w", err)
	}
	serverRespMarshal, err := strconv.ParseInt(resp.Header.Get("X-JSONRPC-Resp-Marshal-Ns"), 10, 64)
	if err != nil {
		return sample{}, fmt.Errorf("missing/invalid server response marshal timing: %w", err)
	}

	return sample{
		e2e:           time.Since(start),
		reqMarshal:    marshalDur,
		reqUnmarshal:  time.Duration(serverUnmarshal),
		respMarshal:   time.Duration(serverRespMarshal),
		respUnmarshal: respUnmarshalDur,
	}, nil
}

func startServer(addr string, secret []byte, parseMode string) (*http.Server, string, error) {
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, "", err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if err := verifyBearerJWT(secret, r.Header.Get("Authorization"), time.Now()); err != nil {
			http.Error(w, err.Error(), http.StatusUnauthorized)
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		unmarshalStart := time.Now()
		parsed, payload, err := parseEngineNewPayloadV4(body, parseMode)
		unmarshalDur := time.Since(unmarshalStart)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if len(payload.Transactions) == 0 {
			http.Error(w, "payload has no transactions", http.StatusBadRequest)
			return
		}

		resp := rpcResponse{
			JSONRPC: "2.0",
			ID:      parsed.ID,
			Result: payloadStatus{
				Status:          "VALID",
				LatestValidHash: payload.BlockHash,
				ValidationError: nil,
			},
		}
		respMarshalStart := time.Now()
		out, err := json.Marshal(resp)
		respMarshalDur := time.Since(respMarshalStart)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-JSONRPC-Unmarshal-Ns", strconv.FormatInt(unmarshalDur.Nanoseconds(), 10))
		w.Header().Set("X-JSONRPC-Resp-Marshal-Ns", strconv.FormatInt(respMarshalDur.Nanoseconds(), 10))
		_, _ = w.Write(out)
	})

	server := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("server error: %v", err)
		}
	}()
	return server, "http://" + listener.Addr().String(), nil
}

func parseEngineNewPayloadV4(body []byte, mode string) (rawRPCRequest, executionPayloadV4, error) {
	switch mode {
	case parseModeRawMessage:
		return parseEngineNewPayloadV4RawMessages(body)
	case parseModeDecoder:
		return parseEngineNewPayloadV4Decoder(body)
	default:
		return rawRPCRequest{}, executionPayloadV4{}, fmt.Errorf("unknown parse mode %q", mode)
	}
}

func parseEngineNewPayloadV4RawMessages(body []byte) (rawRPCRequest, executionPayloadV4, error) {
	var rawReq rawRPCRequestWithRawParams
	if err := json.Unmarshal(body, &rawReq); err != nil {
		return rawRPCRequest{}, executionPayloadV4{}, err
	}
	req := rawRPCRequest{JSONRPC: rawReq.JSONRPC, Method: rawReq.Method, ID: rawReq.ID}
	if err := validateEngineNewPayloadV4Request(req); err != nil {
		return rawRPCRequest{}, executionPayloadV4{}, err
	}
	if len(rawReq.Params) != 4 {
		return rawRPCRequest{}, executionPayloadV4{}, fmt.Errorf("expected 4 params, got %d", len(rawReq.Params))
	}

	var payload executionPayloadV4
	if err := json.Unmarshal(rawReq.Params[0], &payload); err != nil {
		return rawRPCRequest{}, executionPayloadV4{}, err
	}
	var versionedHashes []string
	if err := json.Unmarshal(rawReq.Params[1], &versionedHashes); err != nil {
		return rawRPCRequest{}, executionPayloadV4{}, err
	}
	var parentBeaconBlockRoot string
	if err := json.Unmarshal(rawReq.Params[2], &parentBeaconBlockRoot); err != nil {
		return rawRPCRequest{}, executionPayloadV4{}, err
	}
	var executionRequests []string
	if err := json.Unmarshal(rawReq.Params[3], &executionRequests); err != nil {
		return rawRPCRequest{}, executionPayloadV4{}, err
	}
	if err := validateEngineNewPayloadV4Params(versionedHashes, parentBeaconBlockRoot, executionRequests); err != nil {
		return rawRPCRequest{}, executionPayloadV4{}, err
	}
	return req, payload, nil
}

func parseEngineNewPayloadV4Decoder(body []byte) (rawRPCRequest, executionPayloadV4, error) {
	var req rawRPCRequest
	if err := json.Unmarshal(body, &req); err != nil {
		return rawRPCRequest{}, executionPayloadV4{}, err
	}
	if err := validateEngineNewPayloadV4Request(req); err != nil {
		return rawRPCRequest{}, executionPayloadV4{}, err
	}

	var payload executionPayloadV4
	var versionedHashes []string
	var parentBeaconBlockRoot string
	var executionRequests []string
	if err := decodeEngineNewPayloadV4Params(req.Params, &payload, &versionedHashes, &parentBeaconBlockRoot, &executionRequests); err != nil {
		return rawRPCRequest{}, executionPayloadV4{}, err
	}
	if err := validateEngineNewPayloadV4Params(versionedHashes, parentBeaconBlockRoot, executionRequests); err != nil {
		return rawRPCRequest{}, executionPayloadV4{}, err
	}
	return req, payload, nil
}

func validateEngineNewPayloadV4Request(req rawRPCRequest) error {
	if req.JSONRPC != "2.0" {
		return fmt.Errorf("unexpected jsonrpc version %q", req.JSONRPC)
	}
	if req.Method != "engine_newPayloadV4" {
		return fmt.Errorf("unexpected method %q", req.Method)
	}
	return nil
}

func validateEngineNewPayloadV4Params(versionedHashes []string, parentBeaconBlockRoot string, executionRequests []string) error {
	if len(versionedHashes) != 0 {
		return errors.New("expected empty versioned hashes")
	}
	if parentBeaconBlockRoot == "" {
		return errors.New("missing parent beacon block root")
	}
	if len(executionRequests) != 0 {
		return errors.New("expected empty execution requests")
	}
	return nil
}

func decodeEngineNewPayloadV4Params(raw json.RawMessage, payload *executionPayloadV4, versionedHashes *[]string, parentBeaconBlockRoot *string, executionRequests *[]string) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	tok, err := dec.Token()
	if err != nil {
		return err
	}
	if tok != json.Delim('[') {
		return errors.New("non-array params")
	}

	decodeArg := func(index int, out any) error {
		if !dec.More() {
			return fmt.Errorf("expected 4 params, got %d", index)
		}
		if err := dec.Decode(out); err != nil {
			return fmt.Errorf("invalid argument %d: %w", index, err)
		}
		return nil
	}
	if err := decodeArg(0, payload); err != nil {
		return err
	}
	if err := decodeArg(1, versionedHashes); err != nil {
		return err
	}
	if err := decodeArg(2, parentBeaconBlockRoot); err != nil {
		return err
	}
	if err := decodeArg(3, executionRequests); err != nil {
		return err
	}
	if dec.More() {
		return errors.New("too many arguments, want at most 4")
	}
	_, err = dec.Token()
	return err
}

func buildPayload(targetJSONBytes, txBytes int) executionPayloadV4 {
	payload := executionPayloadV4{
		ParentHash:      hashHex(0x01),
		FeeRecipient:    addressHex(0x02),
		StateRoot:       hashHex(0x03),
		ReceiptsRoot:    hashHex(0x04),
		LogsBloom:       "0x" + strings.Repeat("00", 256),
		PrevRandao:      hashHex(0x05),
		BlockNumber:     "0x123456",
		GasLimit:        "0x3938700",
		GasUsed:         "0x3938700",
		Timestamp:       "0x65000000",
		ExtraData:       "0x",
		BaseFeePerGas:   "0x3b9aca00",
		BlockHash:       hashHex(0x06),
		Withdrawals:     []withdrawal{},
		BlobGasUsed:     "0x0",
		ExcessBlobGas:   "0x0",
		WithdrawalsRoot: hashHex(0x07),
	}

	tx := syntheticTx(txBytes)
	probe := rpcRequest{
		JSONRPC: "2.0",
		Method:  "engine_newPayloadV4",
		Params:  []any{payload, []string{}, hashHex(0x77), []string{}},
		ID:      1,
	}
	base, err := json.Marshal(probe)
	if err != nil {
		panic(err)
	}

	perTx := len(tx) + 3
	txCount := 1
	if targetJSONBytes > len(base) {
		txCount = int(math.Ceil(float64(targetJSONBytes-len(base)) / float64(perTx)))
	}
	payload.Transactions = make([]string, txCount)
	for i := range payload.Transactions {
		payload.Transactions[i] = tx
	}

	for {
		probe.Params[0] = payload
		body, err := json.Marshal(probe)
		if err != nil {
			panic(err)
		}
		if len(body) >= targetJSONBytes {
			return payload
		}
		missing := targetJSONBytes - len(body)
		add := int(math.Ceil(float64(missing) / float64(perTx)))
		if add < 1 {
			add = 1
		}
		for i := 0; i < add; i++ {
			payload.Transactions = append(payload.Transactions, tx)
		}
	}
}

func syntheticTx(size int) string {
	raw := make([]byte, size)
	for i := range raw {
		raw[i] = byte((i*31 + 17) % 251)
	}
	return "0x" + hex.EncodeToString(raw)
}

func hashHex(seed byte) string {
	b := make([]byte, 32)
	for i := range b {
		b[i] = seed + byte(i)
	}
	return "0x" + hex.EncodeToString(b)
}

func addressHex(seed byte) string {
	b := make([]byte, 20)
	for i := range b {
		b[i] = seed + byte(i)
	}
	return "0x" + hex.EncodeToString(b)
}

func makeJWT(secret []byte, now time.Time) (string, error) {
	header, err := json.Marshal(map[string]string{"alg": "HS256", "typ": "JWT"})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]int64{
		"iat": now.Unix(),
		"exp": now.Add(time.Minute).Unix(),
	})
	if err != nil {
		return "", err
	}
	unsigned := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(claims)
	sig := signJWT(secret, unsigned)
	return unsigned + "." + sig, nil
}

func verifyBearerJWT(secret []byte, auth string, now time.Time) error {
	const prefix = "Bearer "
	if !strings.HasPrefix(auth, prefix) {
		return errors.New("missing bearer token")
	}
	token := strings.TrimPrefix(auth, prefix)
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return errors.New("malformed jwt")
	}
	unsigned := parts[0] + "." + parts[1]
	expected := signJWT(secret, unsigned)
	if !hmac.Equal([]byte(expected), []byte(parts[2])) {
		return errors.New("invalid jwt signature")
	}
	claimsJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return err
	}
	var claims struct {
		IssuedAt int64 `json:"iat"`
		Expires  int64 `json:"exp"`
	}
	if err := json.Unmarshal(claimsJSON, &claims); err != nil {
		return err
	}
	if claims.Expires < now.Unix() {
		return errors.New("jwt expired")
	}
	return nil
}

func signJWT(secret []byte, unsigned string) string {
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte(unsigned))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func summarize(samples []sample, pick func(sample) time.Duration) summary {
	values := make([]time.Duration, len(samples))
	var total time.Duration
	for i, s := range samples {
		v := pick(s)
		values[i] = v
		total += v
	}
	sort.Slice(values, func(i, j int) bool {
		return values[i] < values[j]
	})
	p95Index := int(math.Ceil(float64(len(values))*0.95)) - 1
	if p95Index < 0 {
		p95Index = 0
	}
	return summary{
		avg: time.Duration(int64(total) / int64(len(values))),
		p95: values[p95Index],
	}
}

func printSummary(name string, s summary) {
	fmt.Printf("%-30s avg=%s p95=%s\n", name, formatDuration(s.avg), formatDuration(s.p95))
}

func printPercentSummary(name string, numerator summary, denominator summary) {
	fmt.Printf("%-30s avg=%s p95=%s\n", name, formatPercent(numerator.avg, denominator.avg), formatPercent(numerator.p95, denominator.p95))
}

func formatPercent(numerator time.Duration, denominator time.Duration) string {
	if denominator == 0 {
		return "n/a"
	}
	return fmt.Sprintf("%.2f%%", float64(numerator)/float64(denominator)*100)
}

func formatDuration(d time.Duration) string {
	ms := float64(d) / float64(time.Millisecond)
	if ms < 0 {
		return fmt.Sprintf("%.2fms", ms)
	}
	return fmt.Sprintf("%05.2fms", ms)
}
