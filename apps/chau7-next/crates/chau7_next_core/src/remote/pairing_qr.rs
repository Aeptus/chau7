//! A scannable, theme-independent pairing image with a full QR quiet zone.
use super::models::RemotePairingInfo;
use chrono::{DateTime, Utc};
use qrcodegen::{QrCode, QrCodeEcc};

pub struct PairingQrImage {
    pub width: u32,
    /// Opaque grayscale BGRA pixels, ready for GPUI without a decoder or scaling.
    pub pixels: Vec<u8>,
}

impl PairingQrImage {
    pub fn render(info: &RemotePairingInfo, now: DateTime<Utc>) -> Result<Self, &'static str> {
        let payload = info.secure_qr_payload(now)?;
        // Bound memory and work before asking the encoder to select a version.
        if payload.len() > 2048 {
            return Err(
                "Pairing information is too large. Check the relay URL and refresh the code.",
            );
        }
        let code = QrCode::encode_text(&payload, QrCodeEcc::Medium).map_err(
            |_| "Cannot encode the pairing QR. Check Remote settings and refresh the code.",
        )?;
        let quiet = 4;
        // Integer modules avoid interpolation. Common payloads fit within 400 logical pixels.
        let scale = (400 / (code.size() + quiet * 2)).clamp(2, 4);
        let width = ((code.size() + quiet * 2) * scale) as u32;
        let mut pixels = vec![255; (width * width * 4) as usize];
        for y in 0..width {
            for x in 0..width {
                if code.get_module(x as i32 / scale - quiet, y as i32 / scale - quiet) {
                    let start = ((y * width + x) * 4) as usize;
                    pixels[start..start + 3].fill(0);
                }
            }
        }
        Ok(Self { width, pixels })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credential_fixture_renders_opaque_bounded_pixels_with_a_quiet_zone() {
        let info = serde_json::from_str(include_str!(
            "../../../../../../services/chau7-remote/docs/fixtures/pairing_info.json"
        ))
        .unwrap();
        let now = DateTime::parse_from_rfc3339("2026-07-01T12:00:00Z")
            .unwrap()
            .to_utc();
        let image = PairingQrImage::render(&info, now).unwrap();
        assert!(image.width <= 400);
        assert_eq!(image.pixels.len(), (image.width * image.width * 4) as usize);
        assert!(image.pixels.as_chunks::<4>().0.iter().all(|p| p[3] == 255));
        assert!(image.pixels.as_chunks::<4>().0.contains(&[0, 0, 0, 255]));
        let stride = image.width as usize * 4;
        assert!(image.pixels[..stride * 8].iter().all(|v| *v == 255));
        assert!(
            image.pixels[image.pixels.len() - stride * 8..]
                .iter()
                .all(|v| *v == 255)
        );
    }
}
