//! Durable current Swift ScrollbackMemoryManager payload codec. Native pressure
//! handling never shrinks a ring until its ANSI cache was written and verified.

use flate2::{Compression, Crc, read::ZlibDecoder, write::ZlibEncoder};
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;

pub const MAX_CACHE_BYTES: usize = 512 * 1024 * 1024;
const MAX_FILE_BYTES: usize = MAX_CACHE_BYTES + 1024 * 1024;
const ZLIB_V2: &[u8] = b"CHAU7_SCROLLBACK_ZLIB_V2\n";
const RAW_V2: &[u8] = b"CHAU7_SCROLLBACK_RAW_V2\n";
const ZLIB_V1: &[u8] = b"CHAU7_SCROLLBACK_ZLIB_V1\n";
const RAW_V1: &[u8] = b"CHAU7_SCROLLBACK_RAW_V1\n";
const META_BYTES: usize = 13;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum ContentKind {
    PlainText = 0,
    Ansi = 1,
}
#[derive(Debug, PartialEq, Eq)]
pub struct DecodedCache {
    pub data: Vec<u8>,
    pub kind: ContentKind,
    pub embedded_crc32: Option<u32>,
}
fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}
fn crc32(data: &[u8]) -> u32 {
    let mut crc = Crc::new();
    crc.update(data);
    crc.sum()
}

pub fn encode(data: &[u8], kind: ContentKind) -> io::Result<Vec<u8>> {
    if data.len() > MAX_CACHE_BYTES {
        return Err(invalid("scrollback exceeds the cache size bound"));
    }
    let mut compressed = ZlibEncoder::new(Vec::new(), Compression::default());
    compressed.write_all(data)?;
    let compressed = compressed.finish()?;
    let (header, stream) = if data.is_empty() {
        (RAW_V2, data)
    } else {
        (ZLIB_V2, compressed.as_slice())
    };
    let mut payload = Vec::with_capacity(header.len() + META_BYTES + stream.len());
    payload.extend_from_slice(header);
    payload.push(kind as u8);
    payload.extend_from_slice(&(data.len() as u64).to_le_bytes());
    payload.extend_from_slice(&crc32(data).to_le_bytes());
    payload.extend_from_slice(stream);
    Ok(payload)
}
fn decompress(stream: &[u8], expected: Option<usize>) -> io::Result<Vec<u8>> {
    let limit = expected.unwrap_or(MAX_CACHE_BYTES);
    let mut data = Vec::with_capacity(limit.min(1024 * 1024));
    ZlibDecoder::new(stream)
        .take(limit as u64 + 1)
        .read_to_end(&mut data)?;
    if data.len() > limit || expected.is_some_and(|size| data.len() != size) {
        return Err(invalid(
            "scrollback decompressed size does not match its bound",
        ));
    }
    Ok(data)
}
fn metadata(body: &[u8]) -> io::Result<(ContentKind, usize, u32, &[u8])> {
    if body.len() < META_BYTES {
        return Err(invalid("scrollback cache metadata is truncated"));
    }
    let kind = match body[0] {
        0 => ContentKind::PlainText,
        1 => ContentKind::Ansi,
        _ => return Err(invalid("unknown scrollback content kind")),
    };
    let size = u64::from_le_bytes(body[1..9].try_into().expect("metadata length checked"));
    if size > MAX_CACHE_BYTES as u64 {
        return Err(invalid("scrollback cache declared size is too large"));
    }
    let crc = u32::from_le_bytes(body[9..13].try_into().expect("metadata length checked"));
    Ok((kind, size as usize, crc, &body[META_BYTES..]))
}
pub fn decode(payload: &[u8]) -> io::Result<DecodedCache> {
    if payload.len() > MAX_FILE_BYTES {
        return Err(invalid("scrollback cache file is too large"));
    }
    for (header, compressed) in [(ZLIB_V2, true), (RAW_V2, false)] {
        if let Some(body) = payload.strip_prefix(header) {
            let (kind, size, crc, stream) = metadata(body)?;
            let data = if compressed {
                decompress(stream, Some(size))?
            } else {
                if stream.len() != size {
                    return Err(invalid("raw scrollback size mismatch"));
                }
                stream.to_vec()
            };
            if crc32(&data) != crc {
                return Err(invalid("scrollback cache CRC mismatch"));
            }
            return Ok(DecodedCache {
                data,
                kind,
                embedded_crc32: Some(crc),
            });
        }
    }
    let data = if let Some(stream) = payload.strip_prefix(ZLIB_V1) {
        decompress(stream, None)?
    } else if let Some(stream) = payload.strip_prefix(RAW_V1) {
        if stream.len() > MAX_CACHE_BYTES {
            return Err(invalid("legacy raw cache is too large"));
        }
        stream.to_vec()
    } else if let Ok(data) = decompress(payload, None) {
        data
    } else if payload.len() <= MAX_CACHE_BYTES && std::str::from_utf8(payload).is_ok() {
        payload.to_vec()
    } else {
        return Err(invalid("unknown or corrupt scrollback cache"));
    };
    Ok(DecodedCache {
        data,
        kind: ContentKind::PlainText,
        embedded_crc32: None,
    })
}
impl DecodedCache {
    pub fn replay_data(&self) -> Vec<u8> {
        if self.kind == ContentKind::Ansi {
            return self.data.clone();
        }
        // Plain legacy captures contain bare LF. The parser receives no PTY
        // ONLCR transform here, so normalize LF once, preserving existing CRLF.
        let mut result = Vec::with_capacity(self.data.len());
        let mut previous = 0;
        for b in &self.data {
            if *b == b'\n' && previous != b'\r' {
                result.push(b'\r');
            }
            result.push(*b);
            previous = *b;
        }
        result
    }
}
fn read_bounded(path: &Path) -> io::Result<Vec<u8>> {
    let file = fs::File::open(path)?;
    if file.metadata()?.len() > MAX_FILE_BYTES as u64 {
        return Err(invalid("scrollback cache file exceeds the bound"));
    }
    let mut payload = Vec::new();
    file.take(MAX_FILE_BYTES as u64 + 1)
        .read_to_end(&mut payload)?;
    if payload.len() > MAX_FILE_BYTES {
        return Err(invalid("scrollback cache grew beyond its bound"));
    }
    Ok(payload)
}
pub fn load(path: &Path) -> io::Result<DecodedCache> {
    decode(&read_bounded(path)?)
}

/// Verify v2 integrity by streaming its decompression. A pressure flush must
/// not allocate a second full copy merely to prove that the disk write worked.
fn verify(payload: &[u8], expected: &[u8], expected_kind: ContentKind) -> io::Result<()> {
    let (body, compressed) = if let Some(body) = payload.strip_prefix(ZLIB_V2) {
        (body, true)
    } else if let Some(body) = payload.strip_prefix(RAW_V2) {
        (body, false)
    } else {
        return Err(invalid("verified writes require v2 cache metadata"));
    };
    let (kind, size, crc, stream) = metadata(body)?;
    if kind != expected_kind || size != expected.len() || crc != crc32(expected) {
        return Err(invalid("cache metadata changed after persistence"));
    }
    let mut reader: Box<dyn Read + '_> = if compressed {
        Box::new(ZlibDecoder::new(stream))
    } else {
        Box::new(stream)
    };
    let mut measured = Crc::new();
    let mut total = 0usize;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        total += count;
        if total > size {
            return Err(invalid("persisted cache expands beyond its declared size"));
        }
        measured.update(&buffer[..count]);
    }
    if total != size || measured.sum() != crc {
        return Err(invalid("persisted cache integrity verification failed"));
    }
    Ok(())
}

/// Write+sync a unique sibling file, verify it, then atomically replace the
/// cache. A failed write or verification leaves the previous cache untouched.
pub fn persist_verified(path: &Path, data: &[u8], kind: ContentKind) -> io::Result<u64> {
    let parent = path
        .parent()
        .ok_or_else(|| invalid("cache path has no parent"))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".scrollback-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let payload = encode(data, kind)?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&payload)?;
        file.sync_all()?;
        drop(file);
        verify(&read_bounded(&temporary)?, data, kind)?;
        fs::rename(&temporary, path)?;
        Ok(payload.len() as u64)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn v2_metadata_styles_crc_and_high_compression_ratio_round_trip() {
        let data = "\x1b[31mcolored row\x1b[0m\r\n"
            .repeat(100_000)
            .into_bytes();
        let encoded = encode(&data, ContentKind::Ansi).unwrap();
        assert!(data.len() > encoded.len() * 40);
        let decoded = decode(&encoded).unwrap();
        assert_eq!(decoded.kind, ContentKind::Ansi);
        assert_eq!(decoded.data, data);
        assert_eq!(decoded.embedded_crc32, Some(crc32(&data)));
        assert_eq!(decoded.replay_data(), data);
        verify(&encoded, &data, ContentKind::Ansi).unwrap();
    }
    #[test]
    fn corrupt_truncated_unknown_kind_size_and_crc_are_rejected() {
        let encoded = encode(b"content", ContentKind::Ansi).unwrap();
        assert!(decode(&encoded[..ZLIB_V2.len() + 3]).is_err());
        let mut bad = encoded.clone();
        bad[ZLIB_V2.len()] = 4;
        assert!(decode(&bad).is_err());
        let mut bad = encoded.clone();
        bad[ZLIB_V2.len() + 1..ZLIB_V2.len() + 9].copy_from_slice(&u64::MAX.to_le_bytes());
        assert!(decode(&bad).is_err());
        let mut bad = encoded;
        bad[ZLIB_V2.len() + 9] ^= 1;
        assert!(decode(&bad).is_err());
    }
    #[test]
    fn legacy_raw_zlib_and_headerless_payloads_normalize_bare_lf_once() {
        let plain = b"first\nsecond\r\nthird";
        let expected = b"first\r\nsecond\r\nthird";
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(plain).unwrap();
        let compressed = encoder.finish().unwrap();
        for payload in [
            plain.to_vec(),
            [RAW_V1, plain].concat(),
            [ZLIB_V1, &compressed].concat(),
            compressed,
        ] {
            let decoded = decode(&payload).unwrap();
            assert_eq!(decoded.kind, ContentKind::PlainText);
            assert_eq!(decoded.replay_data(), expected);
        }
        let decoded = decode(&encode(b"", ContentKind::Ansi).unwrap()).unwrap();
        assert!(decoded.data.is_empty());
    }
    #[test]
    fn durable_replacement_is_verified_and_failed_write_preserves_prior_cache() {
        let directory =
            std::env::temp_dir().join(format!("chau7-next-scrollback-{}", uuid::Uuid::new_v4()));
        let path = directory.join("session.gz");
        persist_verified(&path, b"first", ContentKind::Ansi).unwrap();
        persist_verified(&path, b"second", ContentKind::Ansi).unwrap();
        assert_eq!(load(&path).unwrap().data, b"second");
        assert_eq!(fs::read_dir(&directory).unwrap().count(), 1);
        let before = fs::read(&path).unwrap();
        let encoded = encode(b"third", ContentKind::Ansi).unwrap();
        assert!(verify(&encoded, b"different", ContentKind::Ansi).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
        fs::remove_dir_all(directory).unwrap();
    }
}
