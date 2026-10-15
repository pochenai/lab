use std::env;
use std::hint::black_box;
use std::time::{Duration, Instant};

const DEFAULT_SIZE_GIB: usize = 1;
const DEFAULT_ITERATIONS: usize = 3;
const GIB: usize = 1024 * 1024 * 1024;

fn parse_arg(args: &[String], index: usize, default: usize, name: &str) -> Result<usize, String> {
    match args.get(index) {
        Some(value) => value
            .parse::<usize>()
            .map_err(|_| format!("invalid {name}: {value}")),
        None => Ok(default),
    }
}

fn main() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if args.len() > 3 {
        return Err(format!(
            "usage: {} [size_gib] [iterations]",
            args.first().map(String::as_str).unwrap_or("memory-bandwidth")
        ));
    }

    let size_gib = parse_arg(&args, 1, DEFAULT_SIZE_GIB, "size_gib")?;
    let iterations = parse_arg(&args, 2, DEFAULT_ITERATIONS, "iterations")?;
    if size_gib == 0 || iterations == 0 {
        return Err("size_gib and iterations must both be greater than zero".into());
    }
    let len = size_gib
        .checked_mul(GIB)
        .ok_or_else(|| "requested buffer size is too large".to_string())?;

    println!(
        "Allocating two {size_gib} GiB buffers ({} bytes each)...",
        len
    );
    let mut vec_a = Vec::new();
    vec_a
        .try_reserve_exact(len)
        .map_err(|error| format!("could not allocate vec A: {error}"))?;
    vec_a.resize(len, 0_u8);

    let mut vec_b = Vec::new();
    vec_b
        .try_reserve_exact(len)
        .map_err(|error| format!("could not allocate vec B: {error}"))?;
    vec_b.resize(len, 1_u8);

    let mut durations = Vec::with_capacity(iterations);
    for iteration in 1..=iterations {
        let start = Instant::now();
        black_box(&vec_b);
        vec_a.copy_from_slice(black_box(&vec_b));
        black_box(&vec_a);
        let elapsed = start.elapsed();
        durations.push(elapsed);
        println!(
            "iteration {iteration}: {:.3} s, copy throughput {:.2} GB/s, read+write traffic {:.2} GB/s",
            elapsed.as_secs_f64(),
            throughput_gb_s(len, elapsed),
            throughput_gb_s(len.saturating_mul(2), elapsed),
        );
    }

    let first = vec_a[0];
    let last = vec_a[len - 1];
    let sum: u64 = vec_a.iter().map(|&byte| u64::from(byte)).sum();
    if first != 1 || last != 1 || sum != len as u64 {
        return Err(format!(
            "copy verification failed: first={first}, last={last}, sum={sum}, expected sum={len}"
        ));
    }

    let best = durations
        .iter()
        .copied()
        .min()
        .expect("iterations is nonzero");
    println!(
        "verified: vec_a[0] = {}, vec_a[len - 1] = {}, all {len} bytes are 1",
        first, last
    );
    println!(
        "best: {:.2} GB/s copy throughput ({:.2} GB/s read+write traffic)",
        throughput_gb_s(len, best),
        throughput_gb_s(len.saturating_mul(2), best),
    );
    println!("Note: GB/s uses decimal gigabytes (1 GB = 1,000,000,000 bytes). A copy reads and writes each byte once.");
    Ok(())
}

fn throughput_gb_s(bytes: usize, elapsed: Duration) -> f64 {
    bytes as f64 / elapsed.as_secs_f64() / 1_000_000_000.0
}
