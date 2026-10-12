import 'dart:convert';

const int _fnvOffsetBasis = 0x811c9dc5;
const int _fnvPrime = 0x01000193;

/// 32-bit FNV-1a hash of the UTF-8 bytes of [input], as an unsigned integer.
///
/// The multiplication is split into 16-bit halves so intermediate values stay
/// below 2^53 and the result is identical on the Dart VM and on the web.
int fnv1a32(String input) {
  var hash = _fnvOffsetBasis;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    final low = (hash & 0xffff) * _fnvPrime;
    final high = (((hash >>> 16) * _fnvPrime) & 0xffff) << 16;
    hash = (low + high) & 0xffffffff;
  }
  return hash;
}

/// Deterministic rollout bucket in `[0, 100)` for a flag and installation.
int rolloutBucket(String flagKey, String installationId) =>
    fnv1a32('$flagKey:$installationId') % 100;
