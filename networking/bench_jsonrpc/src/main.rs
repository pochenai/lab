/* same with go
cargo run --release -- -target-json-mib 1
 */
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use hmac::{Hmac, Mac};
use serde::{de, Deserialize, Deserializer, Serialize, Serializer};
use serde_json::value::RawValue;
use sha2::Sha256;
use std::{
    cmp, env, fmt,
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    sync::Arc,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

type HmacSha256 = Hmac<Sha256>;
type BoxError = Box<dyn std::error::Error + Send + Sync>;
type Result<T> = std::result::Result<T, BoxError>;

const DEFAULT_TARGET_JSON_MIB: usize = 4;
const DEFAULT_ITERATIONS: usize = 200;
const DEFAULT_WARMUP: usize = 20;
const DEFAULT_TX_BYTES: usize = 256;
const JWT_DRIFT: i64 = 60;

#[derive(Clone, Debug)]
struct Config {
    iterations: usize,
    warmup: usize,
    target_json_mib: usize,
    tx_bytes: usize,
    addr: String,
    no_keepalive: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            iterations: DEFAULT_ITERATIONS,
            warmup: DEFAULT_WARMUP,
            target_json_mib: DEFAULT_TARGET_JSON_MIB,
            tx_bytes: DEFAULT_TX_BYTES,
            addr: "127.0.0.1:0".to_string(),
            no_keepalive: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct HexBytes(Vec<u8>);

impl HexBytes {
    fn repeated(byte: u8, len: usize) -> Self {
        Self(vec![byte; len])
    }
}

impl Serialize for HexBytes {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let out = encode_hex_prefixed(&self.0);
        serializer.serialize_str(&out)
    }
}

impl<'de> Deserialize<'de> for HexBytes {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct Visitor;

        impl<'de> de::Visitor<'de> for Visitor {
            type Value = HexBytes;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("0x-prefixed even-length hex string")
            }

            fn visit_borrowed_str<E>(self, value: &'de str) -> std::result::Result<Self::Value, E>
            where
                E: de::Error,
            {
                decode_hex_bytes(value).map_err(E::custom).map(HexBytes)
            }

            fn visit_str<E>(self, value: &str) -> std::result::Result<Self::Value, E>
            where
                E: de::Error,
            {
                decode_hex_bytes(value).map_err(E::custom).map(HexBytes)
            }
        }

        deserializer.deserialize_str(Visitor)
    }
}

#[allow(dead_code)]
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExecutionPayloadV4 {
    parent_hash: String,
    fee_recipient: String,
    state_root: String,
    receipts_root: String,
    logs_bloom: HexBytes,
    #[serde(rename = "prevRandao")]
    prev_randao: String,
    block_number: String,
    gas_limit: String,
    gas_used: String,
    timestamp: String,
    extra_data: HexBytes,
    base_fee_per_gas: String,
    block_hash: String,
    transactions: Vec<HexBytes>,
    withdrawals: Vec<Withdrawal>,
    blob_gas_used: String,
    excess_blob_gas: String,
    withdrawals_root: String,
}

#[allow(dead_code)]
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Withdrawal {
    index: String,
    validator_index: String,
    address: String,
    amount: String,
}

#[derive(Serialize)]
struct RpcRequest<'a> {
    jsonrpc: &'static str,
    method: &'static str,
    params: (
        &'a ExecutionPayloadV4,
        &'a [String],
        &'a str,
        &'a [HexBytes],
    ),
    id: u64,
}

#[derive(Deserialize)]
struct RawRpcRequest<'a> {
    jsonrpc: &'a str,
    method: &'a str,
    #[serde(borrow)]
    params: &'a RawValue,
    id: u64,
}

#[derive(Serialize)]
struct RpcResponse<'a> {
    jsonrpc: &'static str,
    id: u64,
    result: PayloadStatus<'a>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PayloadStatus<'a> {
    status: &'static str,
    latest_valid_hash: &'a str,
    validation_error: Option<&'a str>,
}

#[allow(dead_code)]
#[derive(Deserialize)]
struct RpcResponseOwned {
    result: PayloadStatusOwned,
}

#[allow(dead_code)]
#[derive(Deserialize)]
struct PayloadStatusOwned {
    status: String,
}

#[derive(Default, Clone, Copy)]
struct Sample {
    e2e: Duration,
    req_marshal: Duration,
    req_unmarshal: Duration,
    resp_marshal: Duration,
    resp_unmarshal: Duration,
}

#[derive(Clone, Copy)]
struct Summary {
    avg: Duration,
    p95: Duration,
}

struct HttpResponse {
    status_code: u16,
    body: Vec<u8>,
    server_unmarshal_ns: u64,
    server_resp_marshal_ns: u64,
}

struct HttpClient {
    addr: String,
    keep_alive: bool,
    conn: Option<BufReader<TcpStream>>,
}

fn main() -> Result<()> {
    let cfg = parse_args()?;
    validate_config(&cfg)?;

    let secret = Arc::new(vec![0x42; 32]);
    let target_json_bytes = cfg.target_json_mib * 1024 * 1024;
    let payload = build_payload(target_json_bytes, cfg.tx_bytes)?;
    let empty_hashes: Vec<String> = Vec::new();
    let empty_requests: Vec<HexBytes> = Vec::new();
    let parent_beacon_block_root = hash_hex(0x77);
    let setup_body = marshal_request(
        1,
        &payload,
        &empty_hashes,
        &parent_beacon_block_root,
        &empty_requests,
    )?;

    let endpoint = start_server(&cfg.addr, Arc::clone(&secret))?;
    let mut client = HttpClient::new(endpoint.clone(), !cfg.no_keepalive);

    let total = cfg.warmup + cfg.iterations;
    let mut results = Vec::with_capacity(cfg.iterations);
    for i in 0..total {
        let sample = call_once(
            &mut client,
            &secret,
            (i + 1) as u64,
            &payload,
            &empty_hashes,
            &parent_beacon_block_root,
            &empty_requests,
        )?;
        if i >= cfg.warmup {
            results.push(sample);
        }
    }

    println!("method: engine_newPayloadV4");
    println!("runtime: rust-serde");
    println!(
        "requests: {} measured + {} warmup",
        cfg.iterations, cfg.warmup
    );
    println!("target_json_mib: {}", cfg.target_json_mib);
    println!("target_json_bytes: {target_json_bytes}");
    println!("actual_json_bytes: {}", setup_body.len());
    println!("tx_count: {}", payload.transactions.len());
    println!("tx_bytes: {} raw bytes each", cfg.tx_bytes);
    println!("tx_decode: bytes");
    println!("http_keepalive: {}", !cfg.no_keepalive);
    println!();
    print_summary("e2e", summarize(&results, |s| s.e2e));
    print_summary(
        "json_marshal_client_request",
        summarize(&results, |s| s.req_marshal),
    );
    print_summary(
        "json_unmarshal_server_request",
        summarize(&results, |s| s.req_unmarshal),
    );
    print_summary(
        "json_marshal_server_response",
        summarize(&results, |s| s.resp_marshal),
    );
    print_summary(
        "json_unmarshal_client_response",
        summarize(&results, |s| s.resp_unmarshal),
    );

    Ok(())
}

fn parse_args() -> Result<Config> {
    let mut cfg = Config::default();
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-n" | "--n" => cfg.iterations = parse_next(&mut args, &arg)?,
            "-warmup" | "--warmup" => cfg.warmup = parse_next(&mut args, &arg)?,
            "-target-json-mib" | "--target-json-mib" => {
                cfg.target_json_mib = parse_next(&mut args, &arg)?;
            }
            "-tx-bytes" | "--tx-bytes" => cfg.tx_bytes = parse_next(&mut args, &arg)?,
            "-addr" | "--addr" => {
                cfg.addr = args
                    .next()
                    .ok_or_else(|| format!("missing value for {arg}"))?
            }
            "-no-keepalive" | "--no-keepalive" => cfg.no_keepalive = true,
            "-h" | "--help" => {
                print_help();
                std::process::exit(0);
            }
            _ => return Err(format!("unknown argument {arg}").into()),
        }
    }
    Ok(cfg)
}

fn parse_next<T>(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<T>
where
    T: std::str::FromStr,
    T::Err: fmt::Display + Send + Sync + 'static,
{
    let value = args
        .next()
        .ok_or_else(|| format!("missing value for {flag}"))?;
    value
        .parse::<T>()
        .map_err(|err| format!("invalid value for {flag}: {err}").into())
}

fn print_help() {
    println!("Usage: cargo run --release -- [flags]");
    println!("  -target-json-mib N   approximate JSON-RPC request body size in MiB (default 4)");
    println!("  -n N                 measured requests (default 200)");
    println!("  -warmup N            warmup requests (default 20)");
    println!("  -tx-bytes N          raw bytes per synthetic transaction (default 256)");
    println!("  -addr ADDR           local server listen address (default 127.0.0.1:0)");
    println!("  -no-keepalive        disable HTTP keep-alive");
}

fn validate_config(cfg: &Config) -> Result<()> {
    if cfg.iterations == 0 {
        return Err("-n must be positive".into());
    }
    if cfg.target_json_mib == 0 {
        return Err("-target-json-mib must be positive".into());
    }
    if cfg.tx_bytes == 0 {
        return Err("-tx-bytes must be positive".into());
    }
    Ok(())
}

fn call_once(
    client: &mut HttpClient,
    secret: &[u8],
    id: u64,
    payload: &ExecutionPayloadV4,
    versioned_hashes: &[String],
    parent_beacon_block_root: &str,
    execution_requests: &[HexBytes],
) -> Result<Sample> {
    let start = Instant::now();
    let token = make_jwt(secret, unix_now()?);

    let marshal_start = Instant::now();
    let body = marshal_request(
        id,
        payload,
        versioned_hashes,
        parent_beacon_block_root,
        execution_requests,
    )?;
    let req_marshal = marshal_start.elapsed();

    let response = client.post(&body, &token)?;
    if response.status_code != 200 {
        return Err(format!("unexpected HTTP status {}", response.status_code).into());
    }

    let resp_unmarshal_start = Instant::now();
    let decoded: RpcResponseOwned = serde_json::from_slice(&response.body)?;
    let resp_unmarshal = resp_unmarshal_start.elapsed();
    if decoded.result.status != "VALID" {
        return Err(format!("unexpected payload status {:?}", decoded.result.status).into());
    }

    Ok(Sample {
        e2e: start.elapsed(),
        req_marshal,
        req_unmarshal: Duration::from_nanos(response.server_unmarshal_ns),
        resp_marshal: Duration::from_nanos(response.server_resp_marshal_ns),
        resp_unmarshal,
    })
}

fn marshal_request(
    id: u64,
    payload: &ExecutionPayloadV4,
    versioned_hashes: &[String],
    parent_beacon_block_root: &str,
    execution_requests: &[HexBytes],
) -> serde_json::Result<Vec<u8>> {
    serde_json::to_vec(&RpcRequest {
        jsonrpc: "2.0",
        method: "engine_newPayloadV4",
        params: (
            payload,
            versioned_hashes,
            parent_beacon_block_root,
            execution_requests,
        ),
        id,
    })
}

fn start_server(addr: &str, secret: Arc<Vec<u8>>) -> Result<String> {
    let listener = TcpListener::bind(addr)?;
    let endpoint = listener.local_addr()?.to_string();
    thread::spawn(move || {
        for stream in listener.incoming() {
            match stream {
                Ok(stream) => {
                    let _ = stream.set_nodelay(true);
                    let secret = Arc::clone(&secret);
                    thread::spawn(move || {
                        if let Err(err) = handle_connection(stream, &secret) {
                            eprintln!("server connection error: {err}");
                        }
                    });
                }
                Err(err) => eprintln!("server accept error: {err}"),
            }
        }
    });
    Ok(endpoint)
}

fn handle_connection(stream: TcpStream, secret: &[u8]) -> Result<()> {
    let mut reader = BufReader::new(stream);
    loop {
        let request = match read_http_request(&mut reader) {
            Ok(Some(request)) => request,
            Ok(None) => return Ok(()),
            Err(err) => {
                let _ = write_http_response(reader.get_mut(), 400, b"bad request", false, 0, 0);
                return Err(err);
            }
        };

        let keep_alive = request.keep_alive;
        let response =
            match verify_bearer_jwt(secret, request.authorization.as_deref(), unix_now()?) {
                Ok(()) => handle_rpc_body(&request.body),
                Err(err) => Ok((401, err.to_string().into_bytes(), 0, 0)),
            }?;
        write_http_response(
            reader.get_mut(),
            response.0,
            &response.1,
            keep_alive,
            response.2,
            response.3,
        )?;
        if !keep_alive {
            return Ok(());
        }
    }
}

fn handle_rpc_body(body: &[u8]) -> Result<(u16, Vec<u8>, u64, u64)> {
    let unmarshal_start = Instant::now();
    let (id, payload) = parse_engine_new_payload_v4(body)?;
    let unmarshal_ns = unmarshal_start.elapsed().as_nanos() as u64;

    if payload.transactions.is_empty() {
        return Ok((
            400,
            b"payload has no transactions".to_vec(),
            unmarshal_ns,
            0,
        ));
    }

    let response = RpcResponse {
        jsonrpc: "2.0",
        id,
        result: PayloadStatus {
            status: "VALID",
            latest_valid_hash: &payload.block_hash,
            validation_error: None,
        },
    };
    let resp_marshal_start = Instant::now();
    let out = serde_json::to_vec(&response)?;
    let resp_marshal_ns = resp_marshal_start.elapsed().as_nanos() as u64;
    Ok((200, out, unmarshal_ns, resp_marshal_ns))
}

fn parse_engine_new_payload_v4(body: &[u8]) -> Result<(u64, ExecutionPayloadV4)> {
    let req: RawRpcRequest<'_> = serde_json::from_slice(body)?;
    if req.jsonrpc != "2.0" {
        return Err(format!("unexpected jsonrpc version {:?}", req.jsonrpc).into());
    }
    if req.method != "engine_newPayloadV4" {
        return Err(format!("unexpected method {:?}", req.method).into());
    }

    let (payload, versioned_hashes, parent_beacon_block_root, execution_requests): (
        ExecutionPayloadV4,
        Vec<String>,
        String,
        Vec<HexBytes>,
    ) = serde_json::from_str(req.params.get())?;

    if !versioned_hashes.is_empty() {
        return Err("expected empty versioned hashes".into());
    }
    if parent_beacon_block_root.is_empty() {
        return Err("missing parent beacon block root".into());
    }
    if !execution_requests.is_empty() {
        return Err("expected empty execution requests".into());
    }
    Ok((req.id, payload))
}

struct HttpRequest {
    authorization: Option<String>,
    keep_alive: bool,
    body: Vec<u8>,
}

fn read_http_request(reader: &mut BufReader<TcpStream>) -> Result<Option<HttpRequest>> {
    let mut line = String::new();
    let bytes = reader.read_line(&mut line)?;
    if bytes == 0 {
        return Ok(None);
    }
    if !line.starts_with("POST ") {
        return Err("expected POST request".into());
    }

    let mut content_length = None;
    let mut authorization = None;
    let mut keep_alive = true;
    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            return Err("unexpected EOF while reading headers".into());
        }
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed.is_empty() {
            break;
        }
        let Some((name, value)) = trimmed.split_once(':') else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        match name.as_str() {
            "content-length" => content_length = Some(value.parse::<usize>()?),
            "authorization" => authorization = Some(value.to_string()),
            "connection" if value.eq_ignore_ascii_case("close") => keep_alive = false,
            _ => {}
        }
    }

    let len = content_length.ok_or("missing content-length")?;
    let mut body = vec![0; len];
    reader.read_exact(&mut body)?;
    Ok(Some(HttpRequest {
        authorization,
        keep_alive,
        body,
    }))
}

fn write_http_response(
    stream: &mut TcpStream,
    status: u16,
    body: &[u8],
    keep_alive: bool,
    unmarshal_ns: u64,
    resp_marshal_ns: u64,
) -> Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        _ => "Error",
    };
    let connection = if keep_alive { "keep-alive" } else { "close" };
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: {connection}\r\nX-JSONRPC-Unmarshal-Ns: {unmarshal_ns}\r\nX-JSONRPC-Resp-Marshal-Ns: {resp_marshal_ns}\r\n\r\n",
        body.len()
    );
    let mut response = Vec::with_capacity(header.len() + body.len());
    response.extend_from_slice(header.as_bytes());
    response.extend_from_slice(body);
    stream.write_all(&response)?;
    stream.flush()?;
    Ok(())
}

impl HttpClient {
    fn new(addr: String, keep_alive: bool) -> Self {
        Self {
            addr,
            keep_alive,
            conn: None,
        }
    }

    fn post(&mut self, body: &[u8], token: &str) -> Result<HttpResponse> {
        if self.conn.is_none() {
            let stream = TcpStream::connect(&self.addr)?;
            stream.set_nodelay(true)?;
            self.conn = Some(BufReader::new(stream));
        }
        match self.post_inner(body, token) {
            Ok(resp) => Ok(resp),
            Err(err) if self.keep_alive => {
                self.conn = None;
                let retry = self.post_inner(body, token);
                retry.map_err(|_| err)
            }
            Err(err) => Err(err),
        }
    }

    fn post_inner(&mut self, body: &[u8], token: &str) -> Result<HttpResponse> {
        let reader = self.conn.as_mut().ok_or("missing connection")?;
        let connection = if self.keep_alive {
            "keep-alive"
        } else {
            "close"
        };
        let header = format!(
            "POST / HTTP/1.1\r\nHost: {}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: {connection}\r\n\r\n",
            self.addr,
            body.len()
        );
        let mut request = Vec::with_capacity(header.len() + body.len());
        request.extend_from_slice(header.as_bytes());
        request.extend_from_slice(body);
        reader.get_mut().write_all(&request)?;
        reader.get_mut().flush()?;

        let response = read_http_response(reader)?;
        if !self.keep_alive {
            self.conn = None;
        }
        response.ok_or_else(|| "server closed connection".into())
    }
}

fn read_http_response(reader: &mut BufReader<TcpStream>) -> Result<Option<HttpResponse>> {
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        return Ok(None);
    }
    let mut parts = line.split_whitespace();
    let _http = parts.next().ok_or("missing HTTP version")?;
    let status_code = parts.next().ok_or("missing HTTP status")?.parse::<u16>()?;

    let mut content_length = None;
    let mut server_unmarshal_ns = 0;
    let mut server_resp_marshal_ns = 0;
    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            return Err("unexpected EOF while reading response headers".into());
        }
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed.is_empty() {
            break;
        }
        let Some((name, value)) = trimmed.split_once(':') else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        match name.as_str() {
            "content-length" => content_length = Some(value.parse::<usize>()?),
            "x-jsonrpc-unmarshal-ns" => server_unmarshal_ns = value.parse::<u64>()?,
            "x-jsonrpc-resp-marshal-ns" => server_resp_marshal_ns = value.parse::<u64>()?,
            _ => {}
        }
    }

    let len = content_length.ok_or("missing response content-length")?;
    let mut body = vec![0; len];
    reader.read_exact(&mut body)?;
    Ok(Some(HttpResponse {
        status_code,
        body,
        server_unmarshal_ns,
        server_resp_marshal_ns,
    }))
}

fn make_jwt(secret: &[u8], issued_at: i64) -> String {
    let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
    let payload = URL_SAFE_NO_PAD.encode(format!(r#"{{"iat":{issued_at}}}"#));
    let signing_input = format!("{header}.{payload}");
    let signature = hmac_sha256(secret, signing_input.as_bytes());
    format!("{signing_input}.{}", URL_SAFE_NO_PAD.encode(signature))
}

fn verify_bearer_jwt(secret: &[u8], auth: Option<&str>, now: i64) -> Result<()> {
    let auth = auth.ok_or("missing token")?;
    let token = auth.strip_prefix("Bearer ").ok_or("missing bearer token")?;
    let mut parts = token.split('.');
    let header = parts.next().ok_or("missing jwt header")?;
    let payload = parts.next().ok_or("missing jwt payload")?;
    let signature = parts.next().ok_or("missing jwt signature")?;
    if parts.next().is_some() {
        return Err("invalid jwt token".into());
    }

    let signing_input = format!("{header}.{payload}");
    let expected = hmac_sha256(secret, signing_input.as_bytes());
    let actual = URL_SAFE_NO_PAD.decode(signature)?;
    if !constant_time_eq(&expected, &actual) {
        return Err("invalid token signature".into());
    }

    #[derive(Deserialize)]
    struct Claims {
        iat: i64,
    }
    let claims: Claims = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload)?)?;
    if now - claims.iat > JWT_DRIFT {
        return Err("stale token".into());
    }
    if claims.iat - now > JWT_DRIFT {
        return Err("future token".into());
    }
    Ok(())
}

fn hmac_sha256(secret: &[u8], input: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(secret).expect("HMAC accepts any key length");
    mac.update(input);
    mac.finalize().into_bytes().to_vec()
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    diff == 0
}

fn unix_now() -> Result<i64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() as i64)
}

fn build_payload(target_json_bytes: usize, tx_bytes: usize) -> Result<ExecutionPayloadV4> {
    let mut payload = base_payload();
    let tx = synthetic_tx(tx_bytes);
    let empty_hashes: Vec<String> = Vec::new();
    let empty_requests: Vec<HexBytes> = Vec::new();
    let parent_beacon_block_root = hash_hex(0x77);

    let base_len = marshal_request(
        1,
        &payload,
        &empty_hashes,
        &parent_beacon_block_root,
        &empty_requests,
    )?
    .len();
    let per_tx = tx_bytes * 2 + 5;
    let estimated = cmp::max(1, target_json_bytes.saturating_sub(base_len) / per_tx);
    payload.transactions = vec![tx.clone(); estimated];

    while marshal_request(
        1,
        &payload,
        &empty_hashes,
        &parent_beacon_block_root,
        &empty_requests,
    )?
    .len()
        < target_json_bytes
    {
        payload.transactions.push(tx.clone());
    }
    while payload.transactions.len() > 1 {
        let len = marshal_request(
            1,
            &payload,
            &empty_hashes,
            &parent_beacon_block_root,
            &empty_requests,
        )?
        .len();
        if len <= target_json_bytes {
            break;
        }
        payload.transactions.pop();
    }
    if marshal_request(
        1,
        &payload,
        &empty_hashes,
        &parent_beacon_block_root,
        &empty_requests,
    )?
    .len()
        < target_json_bytes
    {
        payload.transactions.push(tx);
    }
    Ok(payload)
}

fn base_payload() -> ExecutionPayloadV4 {
    ExecutionPayloadV4 {
        parent_hash: hash_hex(0x01),
        fee_recipient: address_hex(0x02),
        state_root: hash_hex(0x03),
        receipts_root: hash_hex(0x04),
        logs_bloom: HexBytes::repeated(0, 256),
        prev_randao: hash_hex(0x05),
        block_number: "0x1".to_string(),
        gas_limit: "0x1dcd6500".to_string(),
        gas_used: "0x1dcd6500".to_string(),
        timestamp: "0x661efdf0".to_string(),
        extra_data: HexBytes(Vec::new()),
        base_fee_per_gas: "0x3b9aca00".to_string(),
        block_hash: hash_hex(0x06),
        transactions: Vec::new(),
        withdrawals: Vec::new(),
        blob_gas_used: "0x0".to_string(),
        excess_blob_gas: "0x0".to_string(),
        withdrawals_root: hash_hex(0x07),
    }
}

fn synthetic_tx(tx_bytes: usize) -> HexBytes {
    let mut out = Vec::with_capacity(tx_bytes);
    for i in 0..tx_bytes {
        out.push((i as u8).wrapping_mul(31).wrapping_add(17));
    }
    HexBytes(out)
}

fn hash_hex(byte: u8) -> String {
    repeated_hex(byte, 32)
}

fn address_hex(byte: u8) -> String {
    repeated_hex(byte, 20)
}

fn repeated_hex(byte: u8, raw_len: usize) -> String {
    encode_hex_prefixed(&vec![byte; raw_len])
}

fn encode_hex_prefixed(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = Vec::with_capacity(2 + bytes.len() * 2);
    out.extend_from_slice(b"0x");
    for &byte in bytes {
        out.push(HEX[(byte >> 4) as usize]);
        out.push(HEX[(byte & 0x0f) as usize]);
    }
    String::from_utf8(out).expect("hex output is valid UTF-8")
}

fn decode_hex_bytes(input: &str) -> std::result::Result<Vec<u8>, String> {
    let raw = input
        .strip_prefix("0x")
        .ok_or_else(|| "missing 0x prefix".to_string())?;
    if raw.len() % 2 != 0 {
        return Err("hex string has odd length".to_string());
    }
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0;
    while i < bytes.len() {
        let hi = decode_nibble(bytes[i]).ok_or_else(|| "invalid hex character".to_string())?;
        let lo = decode_nibble(bytes[i + 1]).ok_or_else(|| "invalid hex character".to_string())?;
        out.push((hi << 4) | lo);
        i += 2;
    }
    Ok(out)
}

fn decode_nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn summarize<F>(samples: &[Sample], mut pick: F) -> Summary
where
    F: FnMut(Sample) -> Duration,
{
    let mut values: Vec<u128> = samples
        .iter()
        .copied()
        .map(|s| pick(s).as_nanos())
        .collect();
    values.sort_unstable();
    let total: u128 = values.iter().sum();
    let avg = total / values.len() as u128;
    let p95_index = ((values.len() * 95).div_ceil(100)).saturating_sub(1);
    Summary {
        avg: nanos(avg),
        p95: nanos(values[p95_index]),
    }
}

fn nanos(value: u128) -> Duration {
    Duration::from_nanos(value.min(u64::MAX as u128) as u64)
}

fn print_summary(label: &str, summary: Summary) {
    println!(
        "{label:<30} avg={} p95={}",
        format_duration(summary.avg),
        format_duration(summary.p95)
    );
}

fn format_duration(duration: Duration) -> String {
    format!("{:05.2}ms", duration.as_secs_f64() * 1000.0)
}
