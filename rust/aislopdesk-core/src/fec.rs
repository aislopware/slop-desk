//! Forward-error-correction over a frame's data fragments — a port of Swift
//! `FECScheme` / `XORParityFEC`.
//!
//! v1 ships a correct, fully-tested XOR/parity scheme that recovers exactly one lost
//! fragment per group; the [`FecScheme`] trait lets production swap in a Reed-Solomon
//! codec later over the same fragment groups without touching callers.

/// A forward-error-correction scheme over a frame's data fragments.
///
/// `parity` produces parity fragments from the frame's data fragments; `recover` fills
/// any `None` (lost) data fragment it can, leaving still-`None` entries for losses it
/// cannot repair (which the caller escalates to request-recovery).
pub trait FecScheme {
    /// The default group size: how many data fragments share one parity fragment when
    /// no explicit per-frame group size is supplied (`5` ⇒ 20% overhead in prod).
    fn group_size(&self) -> usize;

    /// Computes parity fragments for `data`, in group order, grouping by `group_size`.
    fn parity(&self, data: &[&[u8]], group_size: usize) -> Vec<Vec<u8>>;

    /// Fills recoverable holes (`None`) in `data` in place, using `parity` (keyed by
    /// group order), grouping by `group_size`. Entries that cannot be recovered stay
    /// `None`.
    fn recover(&self, data: &mut [Option<Vec<u8>>], parity: &[Option<Vec<u8>>], group_size: usize);

    /// Parity using the scheme's configured default [`group_size`](FecScheme::group_size).
    fn parity_default(&self, data: &[&[u8]]) -> Vec<Vec<u8>> {
        self.parity(data, self.group_size())
    }

    /// Recover using the scheme's configured default [`group_size`](FecScheme::group_size).
    fn recover_default(&self, data: &mut [Option<Vec<u8>>], parity: &[Option<Vec<u8>>]) {
        let group_size = self.group_size();
        self.recover(data, parity, group_size);
    }
}

/// XOR parity FEC: each group of `group_size` data fragments produces one parity
/// fragment = the byte-wise XOR of the group.
///
/// A single missing fragment in a group is
/// recovered as `parity XOR (surviving members)`; two or more losses in one group are
/// unrecoverable.
///
/// Each data fragment is length-prefixed (`[u32 BE len][bytes]`) BEFORE the XOR so that
/// recovery reproduces the *exact* original length even when group members differ in
/// size; the XOR is zero-padded to the longest member.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct XorParityFec {
    group_size: usize,
}

impl Default for XorParityFec {
    /// `group_size = 5` ⇒ 20% parity (the doc-17 / Sunshine default).
    fn default() -> Self {
        Self { group_size: 5 }
    }
}

impl XorParityFec {
    /// Builds an XOR parity scheme.
    ///
    /// # Panics
    /// Panics if `group_size == 0` (a programming error — matches the Swift
    /// `precondition(groupSize >= 1)`). The per-call `group_size` passed to `parity` /
    /// `recover` is floored to 1 defensively and never panics.
    #[must_use]
    pub const fn new(group_size: usize) -> Self {
        assert!(group_size >= 1, "group_size must be >= 1");
        Self { group_size }
    }

    /// `[u32 BE len][bytes]`. A fragment never approaches 4 GiB (MTU-bounded), so the
    /// `u32` length holds by construction; asserted in debug, panic-free in release.
    fn length_prefixed(data: &[u8]) -> Vec<u8> {
        debug_assert!(
            u32::try_from(data.len()).is_ok(),
            "FEC fragment exceeds u32 length"
        );
        let mut out = Vec::with_capacity(4 + data.len());
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        out.extend_from_slice(data);
        out
    }

    /// Inverse of [`length_prefixed`](Self::length_prefixed): reads the embedded length
    /// and slices exactly that many bytes, ignoring trailing zero padding. `None` if the
    /// declared length does not fit.
    fn strip_length_prefix(data: &[u8]) -> Option<Vec<u8>> {
        if data.len() < 4 {
            return None;
        }
        let length = u32::from_be_bytes([data[0], data[1], data[2], data[3]]) as usize;
        let end = 4usize.checked_add(length)?;
        if end <= data.len() {
            Some(data[4..end].to_vec())
        } else {
            None
        }
    }

    /// XOR of the length-prefixed encodings of a group, zero-padded to the longest.
    fn xor_encoded(group: &[&[u8]]) -> Vec<u8> {
        let encoded: Vec<Vec<u8>> = group.iter().map(|m| Self::length_prefixed(m)).collect();
        let width = encoded.iter().map(Vec::len).max().unwrap_or(0);
        let mut acc = vec![0u8; width];
        for member in &encoded {
            for (i, b) in member.iter().enumerate() {
                acc[i] ^= b;
            }
        }
        acc
    }

    /// `parity XOR (encoded survivors)` = the encoded form of the missing member,
    /// zero-padded. Trailing zeros beyond the embedded length are harmless because
    /// [`strip_length_prefix`](Self::strip_length_prefix) cuts to the declared length.
    fn xor_recover(parity: &[u8], survivors: &[&[u8]]) -> Vec<u8> {
        let encoded_survivors: Vec<Vec<u8>> =
            survivors.iter().map(|m| Self::length_prefixed(m)).collect();
        let width = parity
            .len()
            .max(encoded_survivors.iter().map(Vec::len).max().unwrap_or(0));
        let mut acc = vec![0u8; width];
        for (i, b) in parity.iter().enumerate() {
            acc[i] ^= b;
        }
        for member in &encoded_survivors {
            for (i, b) in member.iter().enumerate() {
                acc[i] ^= b;
            }
        }
        acc
    }
}

impl FecScheme for XorParityFec {
    fn group_size(&self) -> usize {
        self.group_size
    }

    fn parity(&self, data: &[&[u8]], group_size: usize) -> Vec<Vec<u8>> {
        let group_size = group_size.max(1); // defensive floor: a 0 size must never loop forever.
        let mut parities = Vec::new();
        let mut index = 0;
        while index < data.len() {
            let upper = (index + group_size).min(data.len());
            parities.push(Self::xor_encoded(&data[index..upper]));
            index += group_size;
        }
        parities
    }

    fn recover(&self, data: &mut [Option<Vec<u8>>], parity: &[Option<Vec<u8>>], group_size: usize) {
        let group_size = group_size.max(1); // defensive floor (matches `parity`).
        let mut group_index = 0;
        let mut index = 0;
        while index < data.len() {
            let upper = (index + group_size).min(data.len());
            let missing: Vec<usize> = (index..upper).filter(|&i| data[i].is_none()).collect();
            if missing.len() == 1 {
                if let Some(Some(parity_bytes)) = parity.get(group_index) {
                    let survivors: Vec<&[u8]> =
                        (index..upper).filter_map(|i| data[i].as_deref()).collect();
                    let recovered_encoded = Self::xor_recover(parity_bytes, &survivors);
                    if let Some(bytes) = Self::strip_length_prefix(&recovered_encoded) {
                        data[missing[0]] = Some(bytes);
                    }
                }
            }
            index += group_size;
            group_index += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slices(v: &[Vec<u8>]) -> Vec<&[u8]> {
        v.iter().map(Vec::as_slice).collect()
    }

    #[test]
    fn parity_count_matches_ceil_groups() {
        let fec = XorParityFec::new(5);
        let data: Vec<Vec<u8>> = (0..12u8).map(|i| vec![i; 3]).collect();
        // ceil(12/5) = 3 parity fragments.
        assert_eq!(fec.parity(&slices(&data), 5).len(), 3);
    }

    #[test]
    fn recovers_single_loss_per_group() {
        let fec = XorParityFec::new(5);
        let data: Vec<Vec<u8>> = vec![vec![1, 2], vec![3], vec![4, 5, 6], vec![7], vec![8, 9]];
        let parity = fec.parity(&slices(&data), 5);
        let mut received: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        received[2] = None; // lose the middle fragment
        let parity_opt: Vec<Option<Vec<u8>>> = parity.iter().cloned().map(Some).collect();
        fec.recover(&mut received, &parity_opt, 5);
        let recovered: Vec<Vec<u8>> = received.into_iter().map(Option::unwrap).collect();
        assert_eq!(recovered, data);
    }

    #[test]
    fn two_losses_in_one_group_unrecoverable() {
        let fec = XorParityFec::new(5);
        let data: Vec<Vec<u8>> = (0..5u8).map(|i| vec![i, i + 1]).collect();
        let parity = fec.parity(&slices(&data), 5);
        let mut received: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        received[1] = None;
        received[3] = None;
        let parity_opt: Vec<Option<Vec<u8>>> = parity.iter().cloned().map(Some).collect();
        fec.recover(&mut received, &parity_opt, 5);
        assert!(received[1].is_none() && received[3].is_none());
    }

    #[test]
    fn recovers_across_multiple_groups() {
        let fec = XorParityFec::new(2);
        let data: Vec<Vec<u8>> = vec![vec![10], vec![20], vec![30], vec![40], vec![50]];
        let parity = fec.parity(&slices(&data), 2); // 3 groups: [0,1][2,3][4]
        let mut received: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        received[0] = None; // group 0 hole
        received[3] = None; // group 1 hole
        received[4] = None; // group 2 (single member) hole — recoverable, parity = encoded(member)
        let parity_opt: Vec<Option<Vec<u8>>> = parity.iter().cloned().map(Some).collect();
        fec.recover(&mut received, &parity_opt, 2);
        let recovered: Vec<Vec<u8>> = received.into_iter().map(Option::unwrap).collect();
        assert_eq!(recovered, data);
    }

    #[test]
    fn missing_parity_leaves_hole() {
        let fec = XorParityFec::new(5);
        let data: Vec<Vec<u8>> = (0..3u8).map(|i| vec![i]).collect();
        let mut received: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        received[1] = None;
        fec.recover(&mut received, &[None], 5); // parity also lost
        assert!(received[1].is_none());
    }

    #[test]
    fn defensive_zero_group_size_does_not_loop() {
        let fec = XorParityFec::new(5);
        let data: Vec<Vec<u8>> = vec![vec![1], vec![2]];
        // group_size 0 floored to 1 → 2 parity fragments, each a single-member group.
        assert_eq!(fec.parity(&slices(&data), 0).len(), 2);
    }
}
