//! Workload helpers shared with the Mojo benchmark
//! (`bench/mojo/bench_slotmap.mojo` implements the same ones).

/// xorshift64*: the same generator the Mojo tests and benchmark use.
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(1))
    }

    pub fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
}

/// The seed used for every shuffle.
pub const SEED: u64 = 0x5EED;

/// Fisher-Yates shuffle, identical in both languages.
pub fn shuffle<T>(v: &mut [T]) {
    let mut rng = Rng::new(SEED);
    for i in (1..v.len()).rev() {
        let j = (rng.next() % (i as u64 + 1)) as usize;
        v.swap(i, j);
    }
}
